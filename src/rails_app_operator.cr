require "kubernetes"

Kubernetes.import_crd "k8s/crd-rails-app.yaml"

# Use this one in production
# k8s = Kubernetes::Client.new

# Using this for dev so I can use the Kubernetes API from outside the cluster
k8s = Kubernetes::Client.new(
  server: URI.parse(ENV["K8S"]? || "https://#{ENV["KUBERNETES_SERVICE_HOST"]}:#{ENV["KUBERNETES_SERVICE_PORT"]}"),
  token: ENV["TOKEN"]? || File.read("/var/run/secrets/kubernetes.io/serviceaccount/token"),
  certificate_file: ENV["CA_CERT"]? || "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
)

pp k8s.rails_apps(namespace: nil)

k8s.watch_rails_apps do |watch|
  resource = watch.object
  rails_app = resource.spec
  name = resource.metadata.name
  namespace = resource.metadata.namespace
  web_name = "#{name}-web"
  worker_name = "#{name}-worker"

  case watch
  when .added?, .modified?
    pp k8s.apply_deployment(
      api_version: "apps/v1",
      kind: "Deployment",
      metadata: {
        name:      web_name,
        namespace: namespace,
      },
      spec: {
        replicas: rails_app.web.replicas,
        selector: {
          matchLabels: {app: web_name},
        },
        template: {
          metadata: {
            labels: {app: web_name},
          },
          spec: {
            containers: [
              {
                name:            "web",
                image:           rails_app.image,
                imagePullPolicy: rails_app.image_pull_policy,
                env:             rails_app.env,
                command:         rails_app.web.command,
                ports:           [{containerPort: 3000}],
              },
            ],
          },
        },
      },
    )

    pp k8s.apply_service(
      api_version: "v1",
      kind: "Service",
      metadata: {
        name:      web_name,
        namespace: namespace,
      },
      spec: {
        selector: {app: web_name},
        ports:    [{port: 3000}],
      },
    )

    pp k8s.apply_ingress(
      api_version: "networking.k8s.io/v1",
      kind: "Ingress",
      metadata: {
        name:      web_name,
        namespace: namespace,
      },
      spec: {
        rules: [
          {
            host: rails_app.domain,
            http: {
              paths: [
                {
                  backend: {
                    service: {
                      name: web_name,
                      port: {
                        number: 3000,
                      },
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
  when .deleted?
    k8s.delete_deployment name: web_name, namespace: namespace
  end
end
