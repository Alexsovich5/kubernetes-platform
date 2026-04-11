#!/bin/bash
# Kubernetes Platform Deployment Script
# IT Operations Specialist - ACORIA (2016)

set -e

NAMESPACE=${1:-default}
RELEASE_NAME="platform"

echo "Deploying to namespace: $NAMESPACE"

# Create namespace if needed
kubectl get namespace "$NAMESPACE" 2>/dev/null || kubectl create namespace "$NAMESPACE"

# Apply configs
kubectl apply -f k8s/deployment.yaml -n "$NAMESPACE"
kubectl apply -f k8s/service.yaml -n "$NAMESPACE"

# Deploy monitoring
kubectl create namespace monitoring 2>/dev/null || true
kubectl apply -f k8s/monitoring.yaml

# Wait for rollout
echo "Waiting for deployment rollout..."
kubectl rollout status deployment/platform-app -n "$NAMESPACE" --timeout=300s

echo "Deployment complete"
kubectl get pods -n "$NAMESPACE" -l app=platform
