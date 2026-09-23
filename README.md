# Kubernetes Container Orchestration Platform

Enterprise container orchestration platform using Kubernetes for deploying, scaling, and managing containerized applications with integrated monitoring via Prometheus.

Personal project, built to explore a complete deploy path from Helm chart to monitored workload. It is not production software — see **Status** below for exactly what is and isn't implemented.

## Status

**Implemented**

- Deployment, Service and monitoring manifests
- Helm chart with values
- Cluster setup and deploy scripts
- Prometheus scrape config

**Not implemented / known limitations**

- Manifests and scripts only — there is no controller or application code
- Helm chart is `apiVersion: v1` (Helm 2 era) and needs migration
- Never applied to a live cluster
- No `helm lint`/`kubeconform` validation in CI

## Layout

```
Dockerfile
helm/
  Chart.yaml
  values.yaml
k8s/
  deployment.yaml
  monitoring.yaml
  service.yaml
prometheus/
  prometheus.yml
scripts/
  deploy.sh
  setup-cluster.sh
```

