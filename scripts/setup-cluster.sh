#!/bin/bash
# Bootstraps a cluster for the platform: creates the namespaces and the
# platform-sa ServiceAccount, then initialises Helm. Safe to run repeatedly.
#
# Environment:
#   SKIP_DOCKER_CHECK  set to 1 to skip the docker prerequisite check
#   NAMESPACES         namespaces to create
#                      (default: "production staging monitoring")
#   HELM_HOST          address of a running Tiller; when set, only the Helm
#                      client is initialised (helm init --client-only)
#
# Exit status: 0 on success, 1 if a prerequisite is missing, and any other
# non-zero status if a kubectl or helm call failed.

set -e

NAMESPACES=${NAMESPACES:-"production staging monitoring"}

echo "=== Kubernetes Cluster Setup ==="

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 required" >&2; exit 1; }
}

require kubectl
if [ "${SKIP_DOCKER_CHECK:-}" != "1" ]; then
  require docker
fi
require helm

for ns in $NAMESPACES; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "Namespace $ns already exists"
  else
    kubectl create namespace "$ns"
  fi
done

if kubectl get serviceaccount platform-sa --namespace=production >/dev/null 2>&1; then
  echo "ServiceAccount platform-sa already exists"
else
  kubectl create serviceaccount platform-sa --namespace=production
fi

echo "Initializing Helm..."
if [ -n "${HELM_HOST:-}" ]; then
  helm init --client-only
else
  helm init
fi

echo "Cluster setup complete"
kubectl cluster-info
