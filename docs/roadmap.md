# Kubernetes Learning Roadmap

This repository documents the learning process for building a modern platform based on Kubernetes.

The ultimate goal is to deploy real-world applications using:

- Kubernetes
- Helm
- ArgoCD (GitOps)
- Harbor (container registry)
- Prometheus + Grafana (observability)
- Sealed Secrets (secure secrets management)
- Envoy Gateway / Ingress
- architecture ready for production

The learning is divided into incremental phases, starting from Docker Compose and progressing to a fully featured platform.

---

# Learning Phases

## Phase 00 — Local Docker Compose

Objective:

- understand the application architecture
- comprehend how containers communicate
- work with environment variables
- understand data persistence

Technologies:

- Docker
- Docker Compose
- containers
- internal networking

Expected outcome:

The application works fully locally using:

- frontend
- backend
- postgres

---

## Phase 01 — kubernetes basics

Objective:

- Set up a local Kubernetes cluster (in this projects, minikube will be used)
- understand Pods
- understand Deployments
- understand Services
- use kubectl

---

## Phase 02 — Kubernetes Application

Objective:

Migrate the Docker Compose application to Kubernetes.

You will learn:

- Deployments
- Services
- ConfigMaps
- Secrets
- PersistentVolumeClaims

---

## Phase 03 — Ingress

Objective:

- expose the application outside the cluster
- HTTP routing
- understand traffic flow

Technologies:

- Ingress
- ingress controller

---

## Phase 04 — Production Practices

Objective:

Operate applications in Kubernetes

- liveness probes
- readiness probes
- resource limits
- autoscaling

---

## Phase 05 — Helm

Objective:

- package Kubernetes applications
- parameterize deployments

Technologies:

- Helm charts

---

## Phase 06 — GitOps

Objective:

Manage deployments via Git

Technologies:

- ArgoCD

---

## Phase 07 — Observability

Objective:

Monitor the platform

Technologies:

- Prometheus
- Grafana

---

## Phase 08 — Secrets Management

Objective:

Manage secrets securely

Technologies:

- Sealed Secrets

---

## Phase 09 — Registry

Objective:

Manage container images

Technologies:

- Harbor

---

## Phase 10 — Gateway

Objective:

Manage traffic in the platform

Technologies:

- Envoy Gateway

---

## Phase 11 — Production Platform

Objective:

Build a production-ready platform

Includes:

- GitOps architecture
- comprehensive observability
- security
- automated deployments