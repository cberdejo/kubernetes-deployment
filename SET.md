## 1. Minikube
1. If needed you can use `minikube` (local `Kubernetes`, focusing on making it easy to learn and develop for `Kubernetes`). To [install](https://minikube.sigs.k8s.io/docs/start/?arch=%2Flinux%2Fx86-64%2Fstable%2Fbinary+download) it:
    ```bash
    https://minikube.sigs.k8s.io/docs/start/?arch=%2Flinux%2Fx86-64%2Fstable%2Fbinary+download
    ```
1. If using `minikube` use `minikube start`
## 2. Kubectl
1. You need to install [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
    ```bash
       curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    ```
## 3. Helm
1. [Install Helm](https://helm.sh/docs/intro/install/)
    ```bash
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
    chmod 700 get_helm.sh
    ./get_helm.sh
    ```
    1.1 For `minikube` enable ingress (`Harbor` needs it to enter web)

    ```bash 
    minikube addons enable ingress
    ```
## 4. Harbor
1. [Install Harbor](https://goharbor.io/docs/2.14.0/install-config/)

2.  First add repo using `helm`
```bash
helm repo add harbor https://helm.goharbor.io
helm repo update
```

3. Install `helm`:

```bash
helm install harbor harbor/harbor -f infraestructure/harbor/harbor-values.yaml
```

4. Config DNS:
```bash
minikube ip 
#Lets suppose the ip is: 192.168.49.2
```
update host file:

```bash 
sudo nano /etc/hosts
```

Paste `192.168.49.2  core.harbor.domain` 



5. Check result

```bash
kubectl get pods
```

6. Accessing the UI (Remote Server / SSH Context)
Since `minikube` creates an internal network inside the remote server, updating your local `/etc/hosts` is not enough. You need to forward the traffic.

    **Option A: SSH Tunnel (Recommended for security)**
    1. On the remote server, forward Harbor to localhost:
    ```bash
    # Check the exact service name (usually harbor-portal or harbor-harbor-portal)
    kubectl port-forward service/harbor-portal 8080:80
    ```
    2. On your **local machine**, create the tunnel:
    ```bash
    # Replace user@remote-server with your credentials
    ssh -L 9090:localhost:8080 user@remote-server-ip
    ```
    3. Open your local browser at: `http://localhost:9090`

    **Option B: Direct Exposure (If ports are open)**
    1. Bind the port to all interfaces on the remote server:
    ```bash
    kubectl port-forward --address 0.0.0.0 service/harbor-portal 8080:80
    ```
    2. Open your local browser at: `http://REMOTE-SERVER-IP:8080`


7. Production Checklist (The "Right Way") 
    * **Network:** Do not use `port-forward`. Use a Cloud **Load Balancer** pointing to an **Ingress Controller** (Nginx/Traefik).
    * **DNS:** Use a real domain (e.g., `registry.company.com`) managed via DNS records, not `/etc/hosts`.
    * **Security:** Use **Cert-Manager** for automatic HTTPS (Let's Encrypt).
    * **Storage:** Configure `values.yaml` to store images in Object Storage (**S3**, GCS, Azure Blob) instead of the server's local disk for persistence and scalability.
    * Every time you change the `values.yaml`you can apply the changes like this:
        ```bash
        helm upgrade harbor harbor/harbor -f infraestructure/harbor/harbor-values.yaml
        ```
    * [View Here How to configure harbor-values.yaml](https://goharbor.io/docs/1.10/install-config/configure-yml-file/)