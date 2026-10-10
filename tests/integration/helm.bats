#!/usr/bin/env bats
#
# Talks to the Compose Tiller service (HELM_HOST=tiller:44134). Helm
# v2.0.0-alpha.2 has no install namespace, so every release lands in Tiller's
# own namespace, production. The install tests run in order: the releases
# created by the install tests are deleted by the delete test, and the last
# test's teardown removes the ReplicaSets and Pods that alpha.2 deletes leave
# behind.

load helpers

NS=production
LAST_TEST=8

kns() {
  kubectl --namespace="$NS" "$@"
}

# until_true <seconds> <command...>
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

deployment_replicas() {
  kns get deployment "$1" -o go-template='{{.spec.replicas}}'
}

# Prints the spec.replicas of every ReplicaSet of release $1.
release_rs_replicas() {
  kns get rs -l "release=$1" -o go-template='{{range .items}}{{.spec.replicas}}{{"\n"}}{{end}}'
}

release_pod_count_is() {
  [ "$(kns get pods -l "release=$1" -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' | grep -c .)" -eq "$2" ]
}

release_rs_is() {
  [ "$(release_rs_replicas "$1" | xargs)" = "$2" ]
}

deployment_absent() {
  ! kns get deployment "$1" >/dev/null 2>&1
}

release_absent() {
  ! helm list | awk '{print $1}' | grep -qx "$1"
}

remove_release_leftovers() {
  local rel
  for rel in it-helm it-helm-2; do
    helm delete "$rel" >/dev/null 2>&1 || true
    kns delete deployment,service,configmap -l "release=$rel" >/dev/null 2>&1 || true
    kns delete rs,pods -l "release=$rel" >/dev/null 2>&1 || true
  done
}

setup() {
  wait_for_url "http://tiller:44135/readiness" 60
  wait_for_url "http://apiserver:8080/healthz" 60
  if [ "$BATS_TEST_NUMBER" -eq 5 ]; then
    kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
    remove_release_leftovers
  fi
}

teardown() {
  if [ "$BATS_TEST_NUMBER" -eq "$LAST_TEST" ]; then
    kns delete rs,pods -l release=it-helm || true
    kns delete rs,pods -l release=it-helm-2 || true
  fi
}

@test "helm version prints v2.0.0-alpha.2" {
  run helm version
  [ "$status" -eq 0 ]
  [ "$output" = "v2.0.0-alpha.2" ]
}

@test "HELM_HOST points at the tiller service" {
  [ "$HELM_HOST" = "tiller:44134" ]
}

@test "helm list exits 0 against tiller" {
  run helm list
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "tiller readiness endpoint answers" {
  run curl -fs http://tiller:44135/readiness
  [ "$status" -eq 0 ]
}

@test "helm install --dry-run renders a Deployment with 3 replicas" {
  run helm install --dry-run --debug helm/platform
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Deployment"* ]]
  [[ "$output" == *"replicas: 3"* ]]
}

@test "helm install --name it-helm creates a Deployment with a ReplicaSet of 3 pods" {
  run helm install --name it-helm helm/platform
  echo "$output"
  [ "$status" -eq 0 ]
  run deployment_replicas it-helm-platform
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
  run kns get deployment it-helm-platform -o go-template='{{.metadata.labels.release}} {{.spec.template.metadata.labels.release}} {{.metadata.labels.heritage}}'
  [ "$output" = "it-helm it-helm Tiller" ]
  kns get service it-helm-platform
  run kns get configmap it-helm-platform -o go-template='{{.data.message}}'
  [ "$output" = "hello from helm" ]
  until_true 60 release_rs_is it-helm 3
  until_true 60 release_pod_count_is it-helm 3
}

@test "helm install -f with replicaCount: 2 gives 2 replicas" {
  values="$(mktemp)"
  printf 'replicaCount: 2\n' > "$values"
  run helm install --name it-helm-2 -f "$values" helm/platform
  rm -f "$values"
  echo "$output"
  [ "$status" -eq 0 ]
  run deployment_replicas it-helm-2-platform
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  until_true 60 release_rs_is it-helm-2 2
  until_true 60 release_pod_count_is it-helm-2 2
}

@test "helm delete removes the release Deployments" {
  run helm delete it-helm
  echo "$output"
  [ "$status" -eq 0 ]
  run helm delete it-helm-2
  echo "$output"
  [ "$status" -eq 0 ]
  until_true 60 deployment_absent it-helm-platform
  until_true 60 deployment_absent it-helm-2-platform
  until_true 30 release_absent it-helm
  until_true 30 release_absent it-helm-2
}
