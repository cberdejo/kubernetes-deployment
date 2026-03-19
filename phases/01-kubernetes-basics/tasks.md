# Phase 01 — Tasks: Kubernetes Basics

## Task 1: Set up Minikube

**Goal:** Have a working local Kubernetes cluster.

### Steps

1. Start minikube:

```bash
minikube start
```

2. Verify the cluster is running:

```bash
minikube status
kubectl cluster-info
kubectl get nodes
```

### Expected result

- `minikube status` shows `Running` for host, kubelet, and apiserver.
- `kubectl get nodes` shows one node with status `Ready`.

---

## Task 2: Run your first Pod

**Goal:** Create a Pod manually and inspect it.

### Steps

1. Create a file `nginx-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-pod
  labels:
    app: nginx
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
```

2. Apply it:

```bash
kubectl apply -f nginx-pod.yaml
```

3. Verify:

```bash
kubectl get pods
kubectl describe pod nginx-pod
kubectl logs nginx-pod
```

4. Open a shell inside the container:

```bash
kubectl exec -it nginx-pod -- bash
curl localhost:80
exit
```

5. Clean up:

```bash
kubectl delete -f nginx-pod.yaml
```

### Expected result

- The Pod reaches `Running` status.
- `curl localhost:80` inside the container returns the nginx welcome page.
- After deletion, `kubectl get pods` shows no pods.

---

## Task 3: Create a Deployment

**Goal:** Deploy nginx using a Deployment and understand how replicas work.

### Steps

1. Create a file `nginx-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
```

2. Apply it:

```bash
kubectl apply -f nginx-deployment.yaml
```

3. Verify the resources created:

```bash
kubectl get deployments
kubectl get replicasets
kubectl get pods
```

4. Observe self-healing — delete one Pod and watch Kubernetes recreate it:

```bash
kubectl get pods
kubectl delete pod <pod-name>
kubectl get pods --watch
```

5. Scale the Deployment:

```bash
kubectl scale deployment/nginx-deployment --replicas=5
kubectl get pods
kubectl scale deployment/nginx-deployment --replicas=2
kubectl get pods
```

### Expected result

- Initially, 3 Pods are running.
- Deleting a Pod triggers automatic recreation (the count returns to 3).
- Scaling changes the number of running Pods.

---

## Task 4: Expose with a Service (ClusterIP)

**Goal:** Create a ClusterIP Service and access nginx from inside the cluster.

### Steps

1. Make sure the Deployment from Task 3 is running.

2. Create a file `nginx-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:
    app: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

3. Apply it:

```bash
kubectl apply -f nginx-service.yaml
```

4. Verify:

```bash
kubectl get services
kubectl describe service nginx-service
```

5. Test connectivity from inside the cluster using a temporary Pod:

```bash
kubectl run curl-test --image=curlimages/curl --rm -it -- curl http://nginx-service:80
```

### Expected result

- `kubectl get services` shows `nginx-service` with a ClusterIP.
- The curl command returns the nginx welcome page, proving DNS-based service discovery works.

---

## Task 5: Expose with a Service (NodePort)

**Goal:** Access nginx from your host machine using a NodePort Service.

### Steps

1. Create a file `nginx-nodeport.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-nodeport
spec:
  type: NodePort
  selector:
    app: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
      nodePort: 30080
```

2. Apply it:

```bash
kubectl apply -f nginx-nodeport.yaml
```

3. Get the minikube IP and access the service:

```bash
minikube ip
curl http://$(minikube ip):30080
```

4. Alternatively, use minikube's built-in tunnel:

```bash
minikube service nginx-nodeport --url
```

### Expected result

- Curling `<minikube-ip>:30080` returns the nginx welcome page from your host machine.
- You understand the difference between ClusterIP (internal only) and NodePort (externally accessible).

---

## Task 6: Labels and selectors

**Goal:** Practice filtering resources using labels.

### Steps

1. Add labels to the Deployment Pods (already done via `app: nginx`).

2. List Pods by label:

```bash
kubectl get pods -l app=nginx
kubectl get pods -l app=nginx -o wide
```

3. Create a second Deployment with a different label to see the difference:

```bash
kubectl create deployment httpd --image=httpd:2.4 --replicas=2
kubectl get pods --show-labels
kubectl get pods -l app=nginx
kubectl get pods -l app=httpd
```

4. Clean up:

```bash
kubectl delete deployment httpd
```

### Expected result

- You can filter Pods by label.
- You understand that Services and Deployments use labels to select which Pods they manage.

---

## Task 7: Explore namespaces

**Goal:** Understand how namespaces organize resources.

### Steps

1. List existing namespaces:

```bash
kubectl get namespaces
```

2. See what runs in the `kube-system` namespace:

```bash
kubectl get pods -n kube-system
```

3. Create a custom namespace and deploy into it:

```bash
kubectl create namespace learning
kubectl apply -f nginx-deployment.yaml -n learning
kubectl get pods -n learning
```

4. Verify that the default namespace is unaffected:

```bash
kubectl get pods
```

5. Clean up:

```bash
kubectl delete namespace learning
```

### Expected result

- Resources in different namespaces are isolated from each other.
- Deleting a namespace removes all resources within it.

---

## Task 8: Clean up everything

**Goal:** Remove all resources created during this phase.

### Steps

```bash
kubectl delete -f nginx-nodeport.yaml
kubectl delete -f nginx-service.yaml
kubectl delete -f nginx-deployment.yaml
kubectl get all
```

### Expected result

- `kubectl get all` shows only the default `kubernetes` ClusterIP service.

---

## Checklist

- [ ] Minikube cluster is running
- [ ] Created and inspected a Pod manually
- [ ] Created a Deployment with replicas
- [ ] Observed self-healing after deleting a Pod
- [ ] Scaled a Deployment up and down
- [ ] Created a ClusterIP Service and tested internal connectivity
- [ ] Created a NodePort Service and accessed it from the host
- [ ] Filtered resources using label selectors
- [ ] Worked with namespaces
- [ ] Cleaned up all resources
