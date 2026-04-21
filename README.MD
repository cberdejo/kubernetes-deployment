# Kubernetes Learning Phases

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

## Interesting Lecture
[Kubernetes docs](https://kubernetes.io/docs/home/)

[Kubernetes Secrets Management: Vault vs Sealed Secrets vs External Secrets (2025)](https://atmosly.com/blog/kubernetes-secrets-management-vault-vs-sealed-secrets-vs-external-secrets-2025)

[How to Structure Your Argo CD Repositories Using Application Sets](https://codefresh.io/blog/how-to-structure-your-argo-cd-repositories-using-application-sets/)

[How to Model Your GitOps Environments and Promote Releases between Them](https://codefresh.io/blog/how-to-model-your-gitops-environments-and-promote-releases-between-them/)