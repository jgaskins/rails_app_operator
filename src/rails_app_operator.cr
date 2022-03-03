require "kubernetes"

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

# Use this one in production
k8s = Kubernetes::Client.new

# Using this for dev so I can use the Kubernetes API from outside the cluster
# k8s = Kubernetes::Client.new(
#   server: URI.parse(ENV["K8S"]? || "https://#{ENV["KUBERNETES_SERVICE_HOST"]}:#{ENV["KUBERNETES_SERVICE_PORT"]}"),
#   token: ENV["TOKEN"]? || File.read("/var/run/secrets/kubernetes.io/serviceaccount/token"),
#   certificate_file: ENV["CA_CERT"]? || "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
# )

result = k8s.rails_apps(namespace: nil)
version = result.metadata.resource_version

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
          spec:     {
            # imagePullSecrets must be an "associative list" when used with
            # server-side apply, which means elements must be `map`s. According
            # to the Kubernetes reference for PodSpec objects, these maps must
            # have a `name` key.
            #
            # See https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.22/#podspec-v1-core
            imagePullSecrets: rails_app.image_pull_secrets
              .map { |name| {name: name} },
            containers: [
              {
                name:            "job",
                image:           rails_app.image,
                imagePullPolicy: rails_app.image_pull_policy,
                command:         rails_app.before_create.command,
                env:             rails_app.env,
              },
            ],
            restartPolicy: "OnFailure",
          },
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
          spec:     {
            imagePullSecrets: rails_app.image_pull_secrets
              .map { |name| {name: name} },
            containers: [
              {
                name:            "job",
                image:           rails_app.image,
                imagePullPolicy: rails_app.image_pull_policy,
                command:         rails_app.before_update.command,
                env:             rails_app.env,
              },
            ],
            restartPolicy: "OnFailure",
          },
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
    health_check = entrypoint.health_check
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
          spec:     {
            imagePullSecrets: rails_app.image_pull_secrets
              .map { |name| {name: name} },
            containers: [
              {
                name:            "app",
                image:           rails_app.image,
                imagePullPolicy: rails_app.image_pull_policy,
                env:             rails_app.env,
                command:         entrypoint.command,
                ports:           if port = entrypoint.port
                  [{containerPort: port}]
                end,
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
              },
            ],
          },
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
        pp k8s.apply_certificate(
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
            name:      entrypoint_name,
            namespace: namespace,
            labels:    {app: name},
          },
          spec: {
            tls: [
              {
                hosts:      [domain],
                secretName: secret_name,
              },
            ],
            rules: [
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
                      path:     "/",
                      pathType: "Prefix",
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
