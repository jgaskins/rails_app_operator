require "kubernetes"

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
Kubernetes.define_resource(
  name: "certificates",
  group: "cert-manager.io",
  type: Kubernetes::Resource(JSON::Any),
  kind: "Certificate",
  version: "v1",
  prefix: "apis",
  singular_name: "certificate",
)

module Kubernetes
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

# Using this for dev so I can use the Kubernetes API from outside the cluster
# k8s = Kubernetes::Client.new(
#   server: URI.parse(ENV["K8S"]? || "https://#{ENV["KUBERNETES_SERVICE_HOST"]}:#{ENV["KUBERNETES_SERVICE_PORT"]}"),
#   token: ENV["TOKEN"]? || File.read("/var/run/secrets/kubernetes.io/serviceaccount/token"),
#   certificate_file: ENV["CA_CERT"]? || "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
# )

resources = k8s.rails_apps(namespace: nil)
version = resources.metadata.resource_version

spawn do
  k8s.watch_jobs(labels: "app.kubernetes.io/managed-by=rails-app-operator") do |watch|
    job = watch.object
    next unless job.metadata.labels["rails_app"]?

    name = job.metadata.name.sub(/-before-(create|update)$/, "")
    namespace = job.metadata.namespace
    next unless resource = k8s.rails_app(name: name, namespace: namespace)

    if job.status["completionTime"]? # Job is complete!
      deploy(k8s, resource)

      k8s.delete_job name: job.metadata.name, namespace: namespace
      k8s.pods(label_selector: "job-name=#{job.metadata.name}", namespace: namespace).each do |job_pod|
        if job_pod.status["phase"]? == "Succeeded"
          k8s.delete_pod job_pod
        end
      end
    end
  end
end

puts "Watching Rails Apps..."
k8s.watch_rails_apps(resource_version: version) do |watch|
  resource = watch.object
  rails_app = resource.spec
  name = resource.metadata.name
  namespace = resource.metadata.namespace

  case watch
  when .added?, .modified?
    rails_app.directories.each do |dir|
      if files = dir.files
        k8s.apply_configmap(
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
        k8s.apply_persistentvolumeclaim(
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
        k8s.delete_configmap(namespace: namespace, name: dir_resource_name)
      elsif dir.persistent_storage
        k8s.delete_persistentvolumeclaim(namespace: namespace, name: dir_resource_name)
      end
    rescue ex
      Log.for("rails-app-operator").error { ex }
      ex.backtrace?.try(&.each do |line|
        Log.for("rails-app-operator").error { line }
      end)
      raise ex
    end
  end

  case watch
  when .added?
    labels = {
      rails_app:                      name,
      "app.kubernetes.io/managed-by": "rails-app-operator",
      "app.kubernetes.io/component":  "before-create",
    }
    k8s.apply_job(
      metadata: {
        name:      "#{name}-before-create",
        namespace: namespace,
        labels:    labels,
      },
      spec: {
        template: {
          metadata: {labels: labels},
          spec:     pod_spec(resource, command: rails_app.before_create.command).merge({
            restartPolicy: "OnFailure",
          }),
        },
      },
      force: true,
    )
  when .modified?
    labels = {
      rails_app:                      name,
      "app.kubernetes.io/managed-by": "rails-app-operator",
      "app.kubernetes.io/component":  "before-update",
    }
    k8s.apply_job(
      metadata: {
        name:      "#{name}-before-update",
        namespace: namespace,
        labels:    labels,
      },
      spec: {
        template: {
          metadata: {labels: labels},
          spec:     pod_spec(resource, command: rails_app.before_update.command).merge({
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
      k8s.delete_deployment name: entrypoint_name, namespace: namespace
      k8s.delete_service name: entrypoint_name, namespace: namespace
      k8s.delete_ingress name: entrypoint_name, namespace: namespace
    end
  end
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

    k8s.apply_deployment(
      metadata: {
        name:      entrypoint_name,
        namespace: namespace,
        labels:    labels,
      },
      spec: {
        replicas: entrypoint.replicas,
        selector: {matchLabels: labels},
        template: {
          metadata: {labels: labels},
          spec:     pod_spec(resource, entrypoint: entrypoint),
        },
      },
      force: true,
    )

    if (port = entrypoint.port)
      k8s.apply_service(
        metadata: {
          name:      entrypoint_name,
          namespace: namespace,
          labels:    {app: name},
        },
        spec: {
          selector: {app: entrypoint_name},
          ports:    [{port: port}],
        },
      )

      if domain = entrypoint.domain
        secret_name = "#{entrypoint_name}-tls"
        k8s.apply_certificate(
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

        k8s.apply_ingress(
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
)
  name = resource.metadata.name
  namespace = resource.metadata.namespace
  rails_app = resource.spec

  env = rails_app.env
  env_from = rails_app.env_from
  container_spec = {
    name:            "app",
    image:           rails_app.image,
    imagePullPolicy: rails_app.image_pull_policy,
    env:             env
      # Ensure that env vars in the entrypoint override ones defined
      # on the rails_app. We can't allow duplicate entries.
      .uniq(&.name),
    envFrom:      env_from,
    command:      command,
    volumeMounts: rails_app.directories.map { |dir|
      {name: "#{name}-#{dir.name}", mountPath: dir.path}
    },
  }
  if entrypoint
    health_check = entrypoint.health_check
    env += entrypoint.env
    env_from += entrypoint.env_from
    container_spec = container_spec.merge({
      ports: if port = entrypoint.port
        [{containerPort: port}]
      end,
      resources:    entrypoint.resources,
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

  {
    serviceAccountName: entrypoint.try(&.service_account) || rails_app.service_account,
    imagePullSecrets:   rails_app.image_pull_secrets
      .map { |name| {name: name} },
    containers: {container_spec},
    volumes:    rails_app.directories.map { |dir|
      n = "#{name}-#{dir.name}"
      if files = dir.files
        {name: n, configMap: {name: n}}
      elsif storage = dir.persistent_storage
        {name: n, persistentVolumeClaim: {claimName: n}}
      end
    },
  }
end
