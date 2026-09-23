#!/bin/bash
# Kubernetes Cluster Setup Script

set -e

echo "=== Kubernetes Cluster Setup ==="

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || { echo "kubectl required"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker required"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm required"; exit 1; }

# Initialize Helm
echo "Initializing Helm..."
helm init --wait

# Create namespaces
for ns in production staging monitoring; do
    kubectl create namespace "$ns" 2>/dev/null || echo "Namespace $ns already exists"
done

# Apply RBAC
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: platform-sa
  namespace: production
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: platform-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
- kind: ServiceAccount
  name: platform-sa
  namespace: production
EOF

echo "Cluster setup complete"
kubectl cluster-info
