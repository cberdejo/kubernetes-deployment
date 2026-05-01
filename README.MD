# Kubernetes Learning Phases

![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)
![Docker Compose](https://img.shields.io/badge/Docker%20Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Helm](https://img.shields.io/badge/Helm-0F1689?style=for-the-badge&logo=helm&logoColor=white)
![Argo CD](https://img.shields.io/badge/Argo%20CD-EF7B4D?style=for-the-badge&logo=argo&logoColor=white)
![GitOps](https://img.shields.io/badge/GitOps-222222?style=for-the-badge&logo=git&logoColor=white)
![Harbor](https://img.shields.io/badge/Harbor-60B932?style=for-the-badge&logo=harbor&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=for-the-badge&logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-F46800?style=for-the-badge&logo=grafana&logoColor=white)
![Sealed Secrets](https://img.shields.io/badge/Sealed%20Secrets-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)
![Envoy Gateway](https://img.shields.io/badge/Envoy%20Gateway-AC6199?style=for-the-badge&logo=envoyproxy&logoColor=white)
![Longhorn](https://img.shields.io/badge/Longhorn-5E9CA0?style=for-the-badge&logo=rancher&logoColor=white)

This section of the repository gathers my hands-on Kubernetes learning path in a practical, progressive way. The goal is to make each phase useful both for my own review and for anyone who wants to learn by following real examples.

This project is focused on real-world application architecture and operations, covering the following key technologies and tools. This architecture is one of many possible approaches, and I chose this stack based on my hands-on experience working with these technologies:

- **Kubernetes** for orchestration
- **Helm** for packaging and deploying applications
- **Argo CD** for GitOps-based deployment automation
- **Harbor** as a private container registry
- **Prometheus** and **Grafana** for monitoring and observability
- **Sealed Secrets** for secure secret management in Kubernetes
- **Envoy Gateway** or Ingress controllers for external access and routing

The project is still a work in progress, and new phases will be added over time.

## Related Documentation

-  [Roadmap](docs/roadmap.md) - full long-term learning plan and upcoming stages.
-  [Glossary](docs/glossary.md) - key concepts and terminology used across the phases.


## Implemented Phases

| Phase                                        | What you will do                                                                                                                                     |
|-----------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| [Phase 00](/phases/00-local-compose/)         | Run the full app locally with Docker Compose. Understand container networking, use environment variables, and learn basics of data persistence.        |
| [Phase 01](/phases/01-kubernetes-basics/)    | Learn Kubernetes fundamentals by working with Pods, Deployments, and Services. Practice basic cluster operations with `kubectl`.                      |
| [Phase 02](/phases/02-kubernetes-application/)| Migrate the application from Docker Compose to Kubernetes. Use Deployments, Services, ConfigMaps, Secrets, and PersistentVolumeClaims (PVCs).          |
| [Phase 03](/phases/03-package-managment/)    | Move from static YAML manifests to Helm charts. Learn templating, `values.yaml`, releases, and reusable package-based Kubernetes deployments.           |
| [Phase 04](/phases/04-secure-secrets-managment/)| Secure application secrets with Sealed Secrets. Learn encryption workflow, Helm integration, and GitOps-friendly secret handling in Kubernetes.       |
| [Phase 05](/phases/05-distributed-persistent-storage/)| Replace local storage with Longhorn distributed block storage. Learn PV/PVC/StorageClass, CSI drivers, volume replication, and data persistence across node restarts and rescheduling. |
| [Phase 06](/phases/06-routing-and-traffic-exposure/)| Expose services through managed HTTPS routing. Learn Envoy Gateway, Gateway API, cert-manager, MetalLB, domain-based routing, TLS automation, and Terraform basics. |

## Recommended Lab Environment

Up to module 5 (from Phase 00 to Phase 04), **Minikube** is enough for most of the exercises. It is a practical choice to learn the Kubernetes basics, deploy applications, work with Helm, and understand secret management locally without needing a more complex setup.

From that point on, **Minikube starts to fall short**. It is great for learning core concepts, but it is not the best environment for more realistic scenarios involving high availability, multi-node scheduling, storage behavior, GitOps flows across environments, ingress/gateway experimentation, or production-like operations.

For the next stages, it is better to move to more realistic alternatives such as:

- **Talos Linux** on virtual machines or bare metal, if you want to learn Kubernetes with an immutable, API-driven operating system designed specifically for clusters.
- **A real multi-node cluster** on physical machines, mini PCs, or a homelab, if you want hands-on experience with networking, storage, failure scenarios, and operations closer to production.
- **k3s** on VMs or lightweight servers, if you want a simpler but realistic multi-node cluster that is easier to bootstrap and maintain.
- **Managed Kubernetes** such as **EKS**, **GKE**, or **AKS**, if you want to practice with cloud-native workflows and understand how Kubernetes is typically consumed in real companies.

## Interesting Lectures
[Kubernetes docs](https://kubernetes.io/docs/home/)

[Kubernetes Deployment Antipatterns – part 1](https://codefresh.io/blog/kubernetes-antipatterns-1/)

[Create Your First Helm Chart](https://techdocs.broadcom.com/us/en/vmware-tanzu/bitnami-secure-images/bitnami-secure-images/services/bsi-doc/apps-tutorials-create-first-helm-chart-index.html)

[Helms Resources](https://github.com/cdwv/awesome-helm)

[Kubernetes Secrets Management: Vault vs Sealed Secrets vs External Secrets (2025)](https://atmosly.com/blog/kubernetes-secrets-management-vault-vs-sealed-secrets-vs-external-secrets-2025)

[How to Structure Your Argo CD Repositories Using Application Sets](https://codefresh.io/blog/how-to-structure-your-argo-cd-repositories-using-application-sets/)

[How to Model Your GitOps Environments and Promote Releases between Them](https://codefresh.io/blog/how-to-model-your-gitops-environments-and-promote-releases-between-them/)

[What is Longhorn](https://longhorn.io/docs/latest/what-is-longhorn/)

[Kubernetes Persistent Volumes documentation](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)

## Special Thanks
Special Thanks to [jozayas](https://github.com/jozayas) who helped me to understand some core concepts and sent me some cool documentation and info.
