require "kubernetes"
require "log"

LOG = Log.for("rails-app-operator")
Log.setup_from_env default_level: :info

# :nodoc:
# TODO: Upstream this into the Kubernetes shard
module Kubernetes
  struct ConfigMap
    include Serializable

    field api_version : String
    field metadata : Metadata
    field data : Hash(String, String)
  end

  define_resource(
    type: Kubernetes::ConfigMap,
    name: "configmap",
    group: "",
    version: "v1",
    kind: "ConfigMap",
  )

  class Client
    def apply_configmap(
      metadata : NamedTuple,
      data,
      status = nil,
      api_version : String = "v1",
      kind : String = "ConfigMap",
      force : Bool = false,
      field_manager : String? = nil
    )
      name = metadata[:name]
      namespace = metadata[:namespace]
      path = "/api/#{api_version}/namespaces/#{namespace}/configmaps/#{name}"
      params = URI::Params{
        "force"        => force.to_s,
        "fieldManager" => field_manager || "k8s-cr",
      }
      response = patch "#{path}?#{params}", {
        apiVersion: api_version,
        kind:       kind,
        metadata:   metadata,
        data:       data,
      }

      if body = response.body
        # {{type}}.from_json response.body
        # JSON.parse body
        (ConfigMap | Status).from_json body
      else
        raise "Missing response body"
      end
    end
  end

  # struct PersistentVolume
  #   include Serializable

  #   field capacity : JSON::Any
  #   field access_modes : Array(JSON::Any)
  #   field claim_ref : JSON::Any
  #   field persistent_volume_reclaim_policy : JSON::Any
  #   field storage_class_name : String?
  #   field mount_options : Array(String)?
  #   field volume_mode : JSON::Any
  #   field node_affinity : JSON::Any?
  # end

  # struct PersistentVolumeClaim
  #   include Serializable

  #   field access_modes : Array(JSON::Any)
  #   field selector : JSON::Any
  #   field resources : JSON::Any
  #   field volume_name : String?
  #   field storage_class_name : String?
  #   field volume_mode : JSON::Any
  #   field data_source : JSON::Any
  #   field data_source_ref : JSON::Any
  # end

  # define_resource "persistentvolumes",
  #   singular_name: "persistentvolume",
  #   group: "",
  #   type: Resource(PersistentVolume),
  #   prefix: "api",
  #   kind: "PersistentVolume"

  # define_resource "persistentvolumeclaims",
  #   singular_name: "persistentvolumeclaim",
  #   group: "",
  #   type: Resource(PersistentVolumeClaim),
  #   prefix: "api",
  #   kind: "PersistentVolumeClaim"
end

Kubernetes.import_crd "k8s/crd-rails-app.yaml"

module Kubernetes
  define_resource "certificates",
    group: "cert-manager.io",
    type: Resource(JSON::Any),
    kind: "Certificate",
    version: "v1",
    prefix: "apis",
    singular_name: "certificate"

  define_resource "persistentvolumes",
    singular_name: "persistentvolume",
    group: "",
    type: Resource(JSON::Any),
    prefix: "api",
    kind: "PersistentVolume",
    cluster_wide: true

  define_resource "persistentvolumeclaims",
    singular_name: "persistentvolumeclaim",
    group: "",
    type: Resource(JSON::Any),
    prefix: "api",
    kind: "PersistentVolumeClaim"
end

# Use this one in production
k8s = Kubernetes::Client.new
spawn do
  loop do
    sleep 1.hour
    k8s = Kubernetes::Client.new
  end
end

resources = k8s.rails_apps(namespace: nil)
version = resources.metadata.resource_version

spawn do
  loop do
    k8s.watch_jobs(labels: "app.kubernetes.io/managed-by=rails-app-operator") do |watch|
      job = watch.object
      next unless job.metadata.labels["rails_app"]?

      case watch.type
      in .added?, .modified?
        name = job.metadata.name.sub(/-before-(create|update)$/, "")
        namespace = job.metadata.namespace
        next unless resource = k8s.rails_app(name: name, namespace: namespace)

        if job.status["completionTime"]? # Job is complete!
          deploy(k8s, resource)

          delete_job k8s, job
        end
      in .deleted?
        delete_job_pods k8s, job
      in .error?
        LOG.error { watch.to_json }
      end
    end
  rescue ex
    LOG.error(exception: ex) { "Error" }
  end
end

info "Watching Rails Apps"
loop do
  k8s.watch_rails_apps(resource_version: version) do |watch|
    info watch
    resource = watch.object
    rails_app = resource.spec
    name = resource.metadata.name
    namespace = resource.metadata.namespace
    version = resource.metadata.resource_version

    case watch
    when .added?, .modified?
      rails_app.directories.each do |dir|
        if files = dir.files
          info k8s.apply_configmap(
            metadata: {
              name:      "#{name}-#{dir.name}",
              namespace: namespace,
            },
            data: files.each_with_object({} of String => String) { |file, hash|
              hash[file.filename] = file.content
            },
            force: true,
          )
        elsif storage = dir.persistent_storage
          info k8s.apply_persistentvolumeclaim(
            metadata: {
              namespace: namespace,
              name:      "#{name}-#{dir.name}",
              # Do we need to set this?
              # finalizers: %w[
              #   kubernetes.io/pv-protection
              # ],
            },
            spec: {
              accessModes:      storage.access_modes,
              storageClassName: storage.storage_class,
              resources:        {
                requests: {
                  storage: storage.size,
                },
              },
            },
          )
        end
      end
    when .deleted?
      rails_app.directories.each do |dir|
        dir_resource_name = "#{name}-#{dir.name}"
        if dir.files
          info k8s.delete_configmap(namespace: namespace, name: dir_resource_name)
        elsif dir.persistent_storage
          info k8s.delete_persistentvolumeclaim(namespace: namespace, name: dir_resource_name)
        end
      rescue ex
        error ex
        ex.backtrace?.try(&.each { |line| error line })
        raise ex
      end
    end

    # TODO: Extract the bodies of this into a single method
    if watch.added? && resource.metadata.creation_timestamp > 1.minute.ago
      labels = {
        rails_app:                      name,
        "app.kubernetes.io/managed-by": "rails-app-operator",
        "app.kubernetes.io/component":  "before-create",
      }
      delete_job k8s, namespace: namespace, name: "#{name}-before-create"
      delete_job k8s, namespace: namespace, name: "#{name}-before-update"
      info k8s.apply_job(
        metadata: {
          name:      "#{name}-before-create",
          namespace: namespace,
          labels:    labels,
        },
        spec: {
          template: {
            metadata: {labels: labels},
            spec:     pod_spec(
              resource,
              command: rails_app.before_create.command,
              env: rails_app.before_create.env,
              env_from: rails_app.before_create.env_from,
              node_selector: rails_app.node_selector.merge(rails_app.before_create.node_selector),
            ).merge({
              restartPolicy: "OnFailure",
            }),
          },
        },
        force: true,
      )
    elsif watch.deleted?
      # do nothing here
    else # Updated or the K8s control plane telling us it's added but it's really just an update
      labels = {
        rails_app:                      name,
        "app.kubernetes.io/managed-by": "rails-app-operator",
        "app.kubernetes.io/component":  "before-update",
      }
      delete_job k8s, namespace: namespace, name: "#{name}-before-create"
      delete_job k8s, namespace: namespace, name: "#{name}-before-update"
      info k8s.apply_job(
        metadata: {
          name:      "#{name}-before-update",
          namespace: namespace,
          labels:    labels,
        },
        spec: {
          template: {
            metadata: {labels: labels},
            spec:     pod_spec(
              resource,
              command: rails_app.before_update.command,
              env: rails_app.before_update.env,
              env_from: rails_app.before_update.env_from,
              node_selector: rails_app.node_selector.merge(rails_app.before_update.node_selector),
            ).merge({
              restartPolicy: "OnFailure",
            }),
          },
        },
        force: true,
      )
    end

    case watch
    when .deleted?
      rails_app.entrypoints.each do |entrypoint|
        entrypoint_name = "#{name}-#{entrypoint.name}"
        info k8s.delete_deployment name: entrypoint_name, namespace: namespace
        info k8s.delete_service name: entrypoint_name, namespace: namespace
        info k8s.delete_ingress name: entrypoint_name, namespace: namespace
      end
      info k8s.delete_job name: "#{name}-before-create", namespace: namespace
      info k8s.delete_job name: "#{name}-before-update", namespace: namespace
    end
  end
rescue ex
  LOG.error(exception: ex) { "Error" }
end

def deploy(k8s : Kubernetes::Client, resource : Kubernetes::Resource(RailsApp))
  rails_app = resource.spec
  name = resource.metadata.name
  namespace = resource.metadata.namespace

  rails_app.entrypoints.each do |entrypoint|
    entrypoint_name = "#{name}-#{entrypoint.name}"
    labels = {
      app:                            entrypoint_name,
      "app.kubernetes.io/created-by": "rails-app-operator",
      "app.kubernetes.io/managed-by": "rails-app-operator",
      "app.kubernetes.io/name":       entrypoint_name,
    }

    deployment_strategy = entrypoint.deployment_strategy
    if (duration_minutes = deployment_strategy.duration_minutes) && (surge_percentage = deployment_strategy.surge)
      min_ready_seconds = (duration_minutes.minutes * (surge_percentage.to_i(strict: false) / 100)).total_seconds.to_i32
      progress_deadline = (duration_minutes.minutes.total_seconds * 1.2).to_i
    end

    info k8s.apply_deployment(
      metadata: {
        name:      entrypoint_name,
        namespace: namespace,
        labels:    labels,
      },
      spec: {
        replicas:                entrypoint.replicas,
        minReadySeconds:         min_ready_seconds,
        progressDeadlineSeconds: progress_deadline,
        strategy:                {
          rollingUpdate: {
            maxSurge:       deployment_strategy.surge,
            maxUnavailable: deployment_strategy.max_unavailable,
          },
        },
        selector: {matchLabels: labels},
        template: {
          metadata: {labels: labels},
          spec:     pod_spec(
            resource,
            entrypoint: entrypoint,
          ),
        },
      },
      force: true,
    )

    if (port = entrypoint.port)
      info k8s.apply_service(
        metadata: {
          name:      entrypoint_name,
          namespace: namespace,
          labels:    {app: name},
        },
        spec: {
          selector: {app: entrypoint_name},
          ports:    [{port: port}],
        },
        force: true,
      )

      if domain = entrypoint.domain
        secret_name = "#{entrypoint_name}-tls"
        info k8s.apply_certificate(
          metadata: {
            name:      secret_name,
            namespace: namespace,
          },
          spec: {
            secretName: secret_name,
            dnsNames:   [domain],
            issuerRef:  {
              name: ENV.fetch("CERT_ISSUER_NAME", "letsencrypt"),
              kind: ENV.fetch("CERT_ISSUER_KIND", "ClusterIssuer"),
            },
          },
        )

        info k8s.apply_ingress(
          metadata: {
            name:        entrypoint_name,
            namespace:   namespace,
            labels:      {app: name},
            annotations: entrypoint.ingress.try(&.annotations),
          },
          spec: {
            tls: [
              {
                hosts:      [domain],
                secretName: secret_name,
              },
            ],
            ingressClassName: ENV["INGRESS_CLASS_NAME"]? || "nginx",
            rules:            [
              {
                host: domain,
                http: {
                  paths: [
                    {
                      backend: {
                        service: {
                          name: entrypoint_name,
                          port: {number: port},
                        },
                      },
                      path:     entrypoint.path,
                      pathType: entrypoint.path_type,
                    },
                  ],
                },
              },
            ],
          },
        )
      end
    end
  end
end

def pod_spec(
  resource : Kubernetes::Resource(RailsApp),
  *,
  entrypoint : RailsApp::Entrypoints? = nil,
  command : Array(String)? = entrypoint.try(&.command),
  env : Array = [] of RailsApp::Entrypoints::Env,
  env_from : Array = [] of RailsApp::Entrypoints::EnvFrom,
  node_selector = {} of String => JSON::Any
)
  name = resource.metadata.name
  namespace = resource.metadata.namespace
  rails_app = resource.spec

  container_spec = {
    name:            "app",
    image:           entrypoint.try(&.image) || rails_app.image,
    imagePullPolicy: rails_app.image_pull_policy,
    command:         command,
    volumeMounts:    rails_app.directories.map { |dir|
      {name: "#{name}-#{dir.name}", mountPath: dir.path}
    },
  }
  if entrypoint
    health_check = entrypoint.health_check
    env += entrypoint.env
    env_from += entrypoint.env_from
    node_selector = node_selector.merge(entrypoint.node_selector)
    container_spec = container_spec.merge({
      ports: if port = entrypoint.port
        [{containerPort: port}]
      end,
      resources:     entrypoint.resources,
      livenessProbe: if (port = entrypoint.port) && health_check
        {
          httpGet:             {path: health_check.path, port: port},
          initialDelaySeconds: health_check.start_after,
          periodSeconds:       health_check.run_every,
          failureThreshold:    health_check.failure_threshold,
        }
      end,
      readinessProbe: if (port = entrypoint.port) && health_check
        {
          httpGet:             {path: health_check.path, port: port},
          initialDelaySeconds: health_check.start_after,
          periodSeconds:       health_check.run_every,
          failureThreshold:    health_check.failure_threshold,
        }
      end,
    })
  end
  container_spec = container_spec.merge({
    env:     (env + rails_app.env).uniq(&.name.strip),
    envFrom: env_from + rails_app.env_from,
  })

  {
    serviceAccountName: entrypoint.try(&.service_account) || rails_app.service_account,
    imagePullSecrets:   rails_app.image_pull_secrets
      .map { |name| {name: name} },
    containers:   {container_spec},
    nodeSelector: rails_app.node_selector.merge(node_selector),
    volumes:      rails_app.directories.map { |dir|
      n = "#{name}-#{dir.name}"
      if files = dir.files
        {name: n, configMap: {name: n}}
      elsif storage = dir.persistent_storage
        {name: n, persistentVolumeClaim: {claimName: n}}
      end
    },
  }
end

def info(result)
  LOG.info { result }
end

def error(result)
  LOG.error { result }
end

def delete_job(k8s, namespace : String, name : String)
  if job = k8s.job(namespace: namespace, name: name)
    delete_job k8s, job
  else
    LOG.info { "No job to delete: #{namespace}/#{name}" }
  end
end

def delete_job(k8s, job)
  info k8s.delete_job name: job.metadata.name, namespace: job.metadata.namespace
  delete_job_pods k8s, job
end

def delete_job_pods(k8s, job)
  k8s.pods(label_selector: "job-name=#{job.metadata.name}", namespace: job.metadata.namespace).each do |job_pod|
    if job_pod.status["phase"]? == "Succeeded"
      info k8s.delete_pod job_pod
    end
  end
end
