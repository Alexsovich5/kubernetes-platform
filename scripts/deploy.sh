#!/bin/bash
# Deploys the platform app manifests and the monitoring stack, then waits for
# the platform-app Deployment rollout to finish.
#
# Usage: scripts/deploy.sh [namespace]
#
# Environment:
#   KUBECTL          kubectl binary to run (default: kubectl)
#   ROLLOUT_WAIT     set to 0 to skip waiting for the rollout (default: 1)
#   ROLLOUT_TIMEOUT  seconds to wait for the rollout (default: 300)
#
# Exit status: 0 on success, 2 if the rollout did not finish in time, and
# any other non-zero status if a kubectl call failed.

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAMESPACE=${1:-default}
KUBECTL=${KUBECTL:-kubectl}
ROLLOUT_WAIT=${ROLLOUT_WAIT:-1}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-300}

echo "Deploying to namespace: $NAMESPACE"

if ! "$KUBECTL" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  "$KUBECTL" create namespace "$NAMESPACE"
fi

"$KUBECTL" apply --namespace="$NAMESPACE" -f "$ROOT/k8s/configmap.yaml"
"$KUBECTL" apply --namespace="$NAMESPACE" -f "$ROOT/k8s/deployment.yaml"
"$KUBECTL" apply --namespace="$NAMESPACE" -f "$ROOT/k8s/service.yaml"

# monitoring.yaml creates the monitoring Namespace itself and sets
# namespace: monitoring on each of its other objects.
"$KUBECTL" apply -f "$ROOT/k8s/monitoring.yaml"

if [ "$ROLLOUT_WAIT" = "0" ]; then
  echo "Skipping rollout wait (ROLLOUT_WAIT=0)"
  exit 0
fi

# kubectl 1.2 has no "rollout status", so poll the Deployment status. The
# rollout is done when the controller has seen the latest spec
# (observedGeneration == generation) and the updated, available and desired
# replica counts are all equal.
echo "Waiting up to ${ROLLOUT_TIMEOUT}s for deployment/platform-app..."
deadline=$((SECONDS + ROLLOUT_TIMEOUT))
while :; do
  status=$("$KUBECTL" get deployment platform-app --namespace="$NAMESPACE" \
    -o jsonpath='{.status.observedGeneration} {.metadata.generation} {.status.updatedReplicas} {.status.availableReplicas} {.spec.replicas}' \
    2>/dev/null || true)
  read -r observed generation updated available desired <<< "$status"
  if [ -n "$observed" ] && [ "$observed" = "$generation" ] &&
     [ -n "$desired" ] && [ "$updated" = "$desired" ] && [ "$available" = "$desired" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "rollout timed out after ${ROLLOUT_TIMEOUT}s (status: ${status:-none})" >&2
    exit 2
  fi
  sleep 1
done

echo "Deployment complete"
"$KUBECTL" get pods --namespace="$NAMESPACE" -l app=platform
