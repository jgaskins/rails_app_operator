# RailsApp Operator

This project is an operator intended to make it dead-simple to deploy a Rails app to a Kubernetes cluster.

## Installation

The Quickstart guide will get you there. A more detailed installation walkthrough will come later.

Notes:

1. This installation guide assumes you've already got a Kubernetes cluster running and `kubectl` installed
2. This guide is optimized for Kubernetes on AWS or DigitalOcean. If you're on GKE, things get more complicated. The absolute simplest way to setup Kubernetes is on DigitalOcean.

### Quickstart

Make a Docker container for your application. This is required since Kubernetes is all about deploying containers.

- [Install Docker](https://www.docker.com/products/docker-desktop) if you haven't already
- If you don't have a Docker Hub account
  - Create an account on [Docker Hub](https://hub.docker.com)
  - Run `docker login` to log the Docker CLI into your Docker Hub account
- [Create a new container repo](https://hub.docker.com/repository/create) for your app on Docker Hub
- Copy [this `Dockerfile` into your app](https://raw.githubusercontent.com/jgaskins/rails_app_operator/main/examples/Dockerfile) if you don't have one
- `docker build -t your-docker-hub-username/your-container-repo:latest .`
- `docker push your-docker-hub-username/your-container-repo:latest`

Run the following commands to install some of the other related operators into your cluster:

```bash
K8S_PROVIDER=aws # If you're on DigitalOcean, change this to `do` instead of `aws`

# Install Nginx Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/$K8S_PROVIDER/deploy.yaml

# Install Cert Manager (for automatically provisioning TLS certs)
kubectl apply -f https://github.com/jetstack/cert-manager/releases/latest/download/cert-manager.yaml

# Install the RailsApp CRD and operator deployment
kubectl apply -f https://raw.githubusercontent.com/jgaskins/rails_app_operator/main/k8s/crd-rails-app.yaml
kubectl apply -f https://raw.githubusercontent.com/jgaskins/rails_app_operator/main/k8s/operator.yaml
```

## Usage

Copy this Kubernetes resource definition into your repo:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  # Whichever namespace you want your application to run in.
  name: my-app-namespace
spec:
  finalizers:
  - kubernetes
---
apiVersion: jgaskins.dev/v1beta1
kind: RailsApp
metadata:
  # The kebab-case Kubernetes resource name for your Rails app
  name: my-app

  # MUST match the name of the `Namespace` above. If you do not provide a
  # namespace, it will install it into the `default` namespace.
  namespace: my-app-namespace

# Customize these below to your app
spec:
  # Change this to where your app's container is hosted. If you're on Docker Hub
  # you don't need to supply a host.
  image: my-docker-hub-account/my-app-repo:my-tag

  # If you deploy from a mutable tag (such as `latest`), this needs to be
  # `Always`. If you deploy from tags named after commit SHAs or git tags, you
  # can delete the line. When in doubt, just leave it as-is.
  image_pull_policy: Always

  # All entrypoints will have these environment variables
  env:
    - name: RAILS_ENV
      value: production
    - name: DATABASE_URL
      value: postgres:/// # Change this to your database's URL
    - name: SECRET_KEY_BASE
      value: deadbeef     # Generate a new value for this with `rails secret` and store the value here
    - name: RAILS_SERVE_STATIC_FILES
      value: "true"
    - name: RAILS_LOG_TO_STDOUT
      value: "true"
    - name: RAILS_MAX_THREADS
      value: "16"

  # Set up the various processes for your app to run
  entrypoints:
    - name: web
      # The command for your application to run. Must be an array, shellwords-style.
      command: [bundle, exec, rails, server]
      # If you supply `domain` and `port`, an Ingress resource will be created
      domain: computers.jgaskins.wtf
      # If you supply `port`, a Service resource will be created
      port: 3000
      # How many instances of this entrypoint you want to run
      replicas: 2

    # Notice the sidekiq entrypoint does not have a domain or port here. It does not
    # need to be reachable over the network. It only makes outbound connections.
    - name: sidekiq
      command: [bundle, exec, sidekiq]

  # The `before_create` and `before_update` hooks are invoked as Jobs before the
  # app is deployed. They are invoked before the Deployment resource is created
  # or updated, respectively, as indicated by their names. They are currently
  # required. If they fail, the app will not be deployed and the jobs will need
  # to be cleaned up manually with `kubectl`.
  before_create:
    command: [bundle, exec, rails, db:create, db:schema:load]
  before_update:
    command: [bundle, exec, rails, db:migrate]
```

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/jgaskins/rails_app_operator/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jamie Gaskins](https://github.com/jgaskins) - creator and maintainer
