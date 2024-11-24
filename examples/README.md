Examples
========

Create a local Kubernetes cluster for example.
All commands are running from working directory in the root of the project:

```shell
k3d cluster create --port "80:80@loadbalancer" --port "443:443@loadbalancer"
kubectl cluster-info
k3d node create ingress --k3s-node-label "ingress-ready=true"
kubectl apply -f k8s
kubectl -n rails-app-operator set env deployment/rails-app-controller INGRESS_CLASS_NAME=traefik
kubectl apply -f https://github.com/jetstack/cert-manager/releases/latest/download/cert-manager.yaml
```

Busybox
-------

Deploy a very small and primitive application:

```shell
$ kubectl apply -f busybox.yaml
railsapp.jgaskins.dev/busybox created
```

Now you can check events, logs and created resources:

```shell
$ kubectl get events
...

$ kubectl -n rails-app-operator logs -l app=rails-app-controller
...

$ kubectl get po,deploy
NAME                                READY   STATUS    RESTARTS   AGE
pod/busybox-task-548cb4dd65-xrrtd   1/1     Running   0          2m52s

NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/busybox-task   1/1     1            1           2m52s
```

Lets remove all created resources:

```shell
$ kubectl delete rails-app busybox
railsapp.jgaskins.dev "busybox" deleted
```

Check again events, logs and resources:

```shell
$ kubectl get events
$ kubectl -n rails-app-operator logs -l app=rails-app-controller
$ kubectl get po,deploy
```

Nginx
-----

To make web application works lets preinstall cert-manager and ingress-nginx:

```shell
kubectl apply -f https://github.com/jetstack/cert-manager/releases/latest/download/cert-manager.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

Deploy a very small and primitive web application:

```shell
$ kubectl apply -f nginx.yaml
railsapp.jgaskins.dev/nginx created
```

Now you can check all events:

```shell
$ kubectl get events
...
10s         Normal    SuccessfulCreate                 job/nginx-before-create         Created pod: nginx-before-create-tx66j
9s          Normal    Scheduled                        pod/nginx-before-create-tx66j   Successfully assigned default/nginx-before-create-tx66j to k3d-k3s-default-server-0
9s          Normal    Pulling                          pod/nginx-before-create-tx66j   Pulling image "nginx"
...

$ kubectl
...
2024-04-28T12:26:58.870352Z   INFO - rails-app-operator: Kubernetes::Resource(Kubernetes::Job)(@api_version="batch/v1", @kind="Job", @metadata=Kubernetes::Metadata(@name="nginx-before-create" ...
2024-04-28T12:27:15.961415Z   INFO - rails-app-operator: Kubernetes::Deployment(@metadata=Kubernetes::Deployment::Metadata(@name="nginx-web" ...
```

Verify that everything is running:

```shell
$ kubectl get po,jobs,deployment,service,ingress
NAME                                  READY   STATUS    RESTARTS   AGE
pod/nginx-internal-7cfdf6d94b-w7v45   1/1     Running   0          5s
pod/nginx-web-7d9ccbb696-6hwqc        1/1     Running   0          5s

NAME                             READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/nginx-internal   1/1     1            1           5s
deployment.apps/nginx-web        1/1     1            1           5s

NAME                     TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/kubernetes       ClusterIP   10.43.0.1       <none>        443/TCP   6m37s
service/nginx-web        ClusterIP   10.43.186.177   <none>        80/TCP    5s
service/nginx-internal   ClusterIP   10.43.123.186   <none>        80/TCP    5s

NAME                                  CLASS     HOSTS               ADDRESS      PORTS     AGE
ingress.networking.k8s.io/nginx-web   traefik   nginx.example.com   172.30.0.3   80, 443   5s
```

Testing access to our application:

```shell
$ curl localhost
404 page not found
```
