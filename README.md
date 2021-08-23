# RailsApp Operator

This project is an operator intended to make it dead-simple to deploy a Rails app to a Kubernetes cluster.

## Installation

The Quickstart guide will get you there. A more detailed installation walkthrough will come later.

Notes:

1. This installation guide assumes you've already got a Kubernetes cluster running and `kubectl` installed
2. This guide is optimized for Kubernetes on AWS or DigitalOcean. If you're on GKE, things get more complicated. The absolute simplest way to setup Kubernetes is on DigitalOcean.

### Quickstart

Run the following commands to install some of the other related operators into your cluster:

```bash
K8S_PROVIDER=aws # If you're on DigitalOcean, change this to `do` instead of `aws`

# Install Nginx Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v0.49.0/deploy/static/provider/$K8S_PROVIDER/deploy.yaml

# Install Cert Manager (for automatically provisioning TLS certs)
kubectl apply -f https://github.com/jetstack/cert-manager/releases/latest/download/cert-manager.yaml

# Install the RailsApp CRD
kubectl apply -f https://github.com/jgaskins/rails_app_controller/tree/main/k8s/crd-railsapp.yaml
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
apiVersion: jgaskins.dev/v1
kind: RailsApp
metadata:
  # The kebab-case Kubernetes resource name for your Rails app
  name: my-app
  namespace: my-app-namespace # MUST match the name of the `Namespace` above
spec:
  image: my-docker-hub-account/my-app-repo:my-tag
  # If you deploy from a mutable tag (such as `latest`), this needs to be
  # `Always`. If you deploy from a commit SHA or git tag, you can delete the
  # line.
  image_pull_policy: Always
  # The domain you want to run your app at
  domain: example.com
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
  web:
    command: ["bundle", "exec", "rails", "server"]
  worker:
    command: ["bundle", "exec", "sidekiq"]
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
