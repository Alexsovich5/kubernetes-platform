#!/usr/bin/env bats
#
# Runs scripts/setup-cluster.sh and scripts/deploy.sh against the
# kubelet-less control plane. The deploy tests use the it-deploy namespace:
# the first deploy test's setup removes any leftover namespace and the last
# test's teardown deletes it.

load helpers

NS=it-deploy
FIRST_DEPLOY_TEST=3
LAST_TEST=4

namespace_absent() {
  ! kubectl get namespace "$NS" >/dev/null 2>&1
}

wait_namespace_absent() {
  local i=0
  while [ "$i" -lt 60 ]; do
    namespace_absent && return 0
    sleep 1
    i=$((i + 1))
  done
  echo "namespace $NS still present after 60s" >&2
  return 1
}

setup() {
  wait_for_url "http://apiserver:8080/healthz" 60
  if [ "$BATS_TEST_NUMBER" -eq "$FIRST_DEPLOY_TEST" ]; then
    kubectl delete namespace "$NS" >/dev/null 2>&1 || true
    wait_namespace_absent
  fi
}

teardown() {
  if [ "$BATS_TEST_NUMBER" -eq "$LAST_TEST" ]; then
    kubectl delete namespace "$NS" >/dev/null 2>&1 || true
  fi
}

@test "setup-cluster.sh exits 0 on two runs in a row" {
  stub_bin="$BATS_TMPDIR/setup-cluster-helm-$$"
  mkdir -p "$stub_bin"
  # Helm is not built until later, so the helm stub stands in for it.
  ln -sf "$BATS_TEST_DIRNAME/../unit/stubs/helm" "$stub_bin/helm"

  PATH="$stub_bin:$PATH" SKIP_DOCKER_CHECK=1 HELM_HOST=unused:1 run scripts/setup-cluster.sh
  echo "$output"
  [ "$status" -eq 0 ]

  PATH="$stub_bin:$PATH" SKIP_DOCKER_CHECK=1 HELM_HOST=unused:1 run scripts/setup-cluster.sh
  echo "$output"
  rm -rf "$stub_bin"
  [ "$status" -eq 0 ]
}

@test "setup-cluster.sh created the namespaces and platform-sa" {
  kubectl get namespace production
  kubectl get namespace staging
  kubectl get namespace monitoring
  kubectl get serviceaccount platform-sa --namespace=production
}

@test "ROLLOUT_WAIT=0 deploy.sh creates the namespace, Deployment and Services" {
  ROLLOUT_WAIT=0 run scripts/deploy.sh "$NS"
  echo "$output"
  [ "$status" -eq 0 ]
  kubectl get namespace "$NS"
  kubectl --namespace="$NS" get configmap platform-config
  kubectl --namespace="$NS" get deployment platform-app
  kubectl --namespace="$NS" get service platform-app platform-internal
  kubectl --namespace=monitoring get deployment prometheus
}

@test "deploy.sh exits 2 when the rollout cannot finish (no nodes)" {
  ROLLOUT_TIMEOUT=5 run scripts/deploy.sh "$NS"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"rollout timed out"* ]]
}
