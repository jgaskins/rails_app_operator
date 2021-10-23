require "kubernetes"

Kubernetes.import_crd "k8s/crd-rails-app.yaml"

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

    deploy(k8s, resource.spec, job)
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
    k8s.apply_job(
      metadata: {
        name:                           "#{name}-before-create",
        namespace:                      namespace,
        "app.kubernetes.io/managed-by": "rails-app-operator",
        labels:                         {rails_app: name},
      },
      spec: {
        template: {
          spec: {
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
    )
  when .modified?
    k8s.apply_job(
      metadata: {
        name:                           "#{name}-before-update",
        namespace:                      namespace,
        "app.kubernetes.io/managed-by": "rails-app-operator",
        labels:                         {rails_app: name},
      },
      spec: {
        template: {
          spec: {
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

def deploy(k8s : Kubernetes::Client, rails_app : RailsApp, job : Kubernetes::Resource(Kubernetes::Job))
  name = job.metadata.name.sub(/-before-(create|update)$/, "")
  namespace = job.metadata.namespace

  if job.status["completionTime"]? # Job is complete!
    k8s.delete_job name: job.metadata.name, namespace: namespace
    k8s.pods(label_selector: "job-name=#{job.metadata.name}", namespace: namespace).each do |job_pod|
      if job_pod.status["phase"]? == "Succeeded"
        k8s.delete_pod job_pod
      end
    end

    rails_app.entrypoints.each do |entrypoint|
      entrypoint_name = "#{name}-#{entrypoint.name}"
      k8s.apply_deployment(
        metadata: {
          name:      entrypoint_name,
          namespace: namespace,
        },
        spec: {
          replicas: entrypoint.replicas,
          selector: {
            matchLabels: {app: entrypoint_name},
          },
          template: {
            metadata: {
              labels: {app: entrypoint_name},
            },
            spec: {
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
                  readinessProbe: if port = entrypoint.port
                    {
                      tcpSocket:           {port: port},
                      initialDelaySeconds: 3,
                      periodSeconds:       3,
                    }
                  end,
                },
              ],
            },
          },
        },
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
          k8s.apply_ingress(
            metadata: {
              name:      entrypoint_name,
              namespace: namespace,
              labels:    {app: name},
            },
            spec: {
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
end
