#!/usr/bin/env bats
#
# Runs the documented workflow in order against the Compose control plane:
# setup-cluster.sh, helm install of the chart, then the monitoring manifest.
# Helm v2.0.0-alpha.2 installs into Tiller's namespace, production, and never
# frees a deleted release name while Tiller runs, so the release name
# "platform" is used only in this file. The last test's teardown deletes the
# release and the ReplicaSets and Pods that alpha.2 deletes leave behind.

load helpers

NS=production
RELEASE=platform
LAST_TEST=5
PROM_URL="http://prometheus:9090"

# query_value <promql>
# Prints the sample value of the first result of an instant query.
query_value() {
  curl -fsG "$PROM_URL/api/v1/query" --data-urlencode "query=$1" |
    sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'
}

# wait_for_value <promql> <expected> <seconds>
wait_for_value() {
  local i=0 got
  while [ "$i" -lt "$3" ]; do
    got="$(query_value "$1")"
    if [ "$got" = "$2" ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  echo "$1 = '$got', want '$2'" >&2
  return 1
}

setup() {
  wait_for_url "http://apiserver:8080/healthz" 60
  wait_for_url "http://tiller:44135/readiness" 60
}

teardown() {
  if [ "$BATS_TEST_NUMBER" -eq "$LAST_TEST" ]; then
    helm delete "$RELEASE" || true
    kubectl delete rs,pods -l "release=$RELEASE" --namespace="$NS" || true
  fi
}

@test "setup-cluster.sh prepares the cluster" {
  SKIP_DOCKER_CHECK=1 run scripts/setup-cluster.sh
  echo "$output"
  [ "$status" -eq 0 ]
  kubectl get namespace production
  kubectl get namespace monitoring
  kubectl get serviceaccount platform-sa --namespace=production
}

@test "helm install --name platform installs the chart into production" {
  run helm install --name "$RELEASE" helm/platform
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "kubectl apply -f k8s/monitoring.yaml exits 0" {
  run kubectl apply -f k8s/monitoring.yaml
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "deployment platform-platform wants 3 replicas and svc/prometheus exists" {
  run kubectl get deployment platform-platform --namespace="$NS" -o jsonpath='{.spec.replicas}'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
  kubectl get svc prometheus --namespace=monitoring
}

@test "compose Prometheus still reports the apiserver up" {
  wait_for_value 'up{job="kubernetes-apiserver"}' 1 60
}
