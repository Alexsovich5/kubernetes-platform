#!/usr/bin/env bats
#
# Applies the k8s/ app manifests to the kubelet-less control plane and checks
# what the 1.2 controllers do with them: ReplicaSet creation, self-healing,
# scaling, the rolling-update surge limit and rollback. The tests run in order
# and share the it-workload namespace, which the first test's setup creates
# and the last test's teardown deletes.

load helpers

NS=it-workload
LAST_TEST=7

# kns runs kubectl in the test namespace. A function rather than a string
# variable, because bats 0.4.0 leaves IFS set to a newline after `run`.
kns() {
  kubectl --namespace="$NS" "$@"
}

# until_true <seconds> <command...>
# Runs <command> once per second until it succeeds or <seconds> have passed.
until_true() {
  local seconds="$1" i=0
  shift
  while [ "$i" -lt "$seconds" ]; do
    if "$@"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  echo "until_true: '$*' still failing after ${seconds}s" >&2
  return 1
}

namespace_absent() {
  ! kubectl get namespace "$NS" >/dev/null 2>&1
}

# Prints "<name> <spec.replicas>" for every ReplicaSet in the namespace.
replicasets() {
  kns get rs -o go-template='{{range .items}}{{.metadata.name}} {{.spec.replicas}}{{"\n"}}{{end}}'
}

# Prints the names of the platform pods, one per line.
pod_names() {
  kns get pods -l app=platform -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}'
}

pod_count_is() {
  [ "$(pod_names | grep -c .)" -eq "$1" ]
}

# rs_replicas_are <sorted space-separated replica counts>
rs_replicas_are() {
  [ "$(replicasets | awk '{print $2}' | sort -n | xargs)" = "$1" ]
}

template_image() {
  kns get deployment platform-app -o go-template='{{(index .spec.template.spec.containers 0).image}}'
}

setup() {
  wait_for_url "http://apiserver:8080/healthz" 60
  if [ "$BATS_TEST_NUMBER" -eq 1 ]; then
    kubectl delete namespace "$NS" >/dev/null 2>&1 || true
    until_true 60 namespace_absent
    kubectl create namespace "$NS"
  fi
}

teardown() {
  if [ "$BATS_TEST_NUMBER" -eq "$LAST_TEST" ]; then
    kubectl delete namespace "$NS" >/dev/null 2>&1 || true
  fi
}

@test "kubectl apply accepts the ConfigMap, Deployment and Services" {
  run kns apply -f k8s/configmap.yaml -f k8s/deployment.yaml -f k8s/service.yaml
  [ "$status" -eq 0 ]
  kns get configmap platform-config
  kns get deployment platform-app
  kns get service platform-app platform-internal
}

@test "the Deployment creates one ReplicaSet with 3 replicas and 3 pods" {
  until_true 30 rs_replicas_are "3"
  until_true 30 pod_count_is 3
  [ "$(replicasets | wc -l)" -eq 1 ]
}

@test "a deleted pod is replaced and the count returns to 3" {
  victim="$(pod_names | head -n 1)"
  [ -n "$victim" ]
  kns delete pod "$victim"
  until_true 30 pod_count_is 3
  [ -z "$(pod_names | grep -x "$victim")" ]
}

@test "scaling to 5 and back to 3 changes the ReplicaSet and pod count" {
  kns scale deployment platform-app --replicas=5
  until_true 30 rs_replicas_are "5"
  until_true 30 pod_count_is 5

  kns scale deployment platform-app --replicas=3
  until_true 30 rs_replicas_are "3"
  until_true 30 pod_count_is 3
}

@test "an image patch surges one new pod and keeps the 3 old ones" {
  kns patch deployment platform-app \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","image":"platform-app:0.1.1"}]}}}}'
  [ "$(template_image)" = "platform-app:0.1.1" ]
  until_true 30 rs_replicas_are "1 3"
  # No pod ever becomes ready, so maxUnavailable 0 holds the rollout here.
  sleep 5
  rs_replicas_are "1 3"
  pod_count_is 4
}

@test "rollout undo restores the platform-app:0.1.0 template" {
  run kns rollout undo deployment/platform-app
  [ "$status" -eq 0 ]
  [ "$(template_image)" = "platform-app:0.1.0" ]
}

@test "the LoadBalancer Service gets a nodePort but no ingress" {
  node_port="$(kns get service platform-app -o go-template='{{(index .spec.ports 0).nodePort}}')"
  [ "$node_port" -ge 30000 ]
  [ "$node_port" -le 32767 ]
  ingress="$(kns get service platform-app -o go-template='{{range .status.loadBalancer.ingress}}{{.ip}}{{.hostname}}{{end}}')"
  [ -z "$ingress" ]
}
