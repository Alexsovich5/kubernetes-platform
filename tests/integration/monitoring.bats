#!/usr/bin/env bats
#
# Applies k8s/monitoring.yaml to the kubelet-less control plane and checks
# the objects it creates. The first test's setup deletes any monitoring
# namespace left by earlier suites, so the manifest itself must create it.

load helpers

NS=monitoring

namespace_absent() {
  ! kubectl get namespace "$NS" >/dev/null 2>&1
}

wait_namespace_absent() {
  local i=0
  while [ "$i" -lt 90 ]; do
    namespace_absent && return 0
    sleep 1
    i=$((i + 1))
  done
  echo "namespace $NS still present after 90s" >&2
  return 1
}

setup() {
  wait_for_url "http://apiserver:8080/healthz" 60
  if [ "$BATS_TEST_NUMBER" -eq 1 ]; then
    kubectl delete namespace "$NS" >/dev/null 2>&1 || true
    wait_namespace_absent
  fi
}

@test "kubectl apply -f k8s/monitoring.yaml exits 0 without a pre-created namespace" {
  namespace_absent
  run kubectl apply -f k8s/monitoring.yaml
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the manifest created ns/monitoring and configmap/prometheus-config" {
  kubectl get namespace "$NS"
  run kubectl get configmap prometheus-config --namespace="$NS" \
    -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}'
  [ "$status" -eq 0 ]
  [ "$output" = "alert-rules.yml prometheus.yml " ]
}

@test "deployment/prometheus has 1 desired replica" {
  run kubectl get deployment prometheus --namespace="$NS" -o jsonpath='{.spec.replicas}'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "svc/prometheus is a NodePort on 30090" {
  run kubectl get svc prometheus --namespace="$NS" \
    -o jsonpath='{.spec.type} {.spec.ports[0].nodePort}'
  [ "$status" -eq 0 ]
  [ "$output" = "NodePort 30090" ]
}

@test "the stored config and rules equal the files under prometheus/" {
  diff <(kubectl get configmap prometheus-config --namespace="$NS" \
    -o go-template='{{index .data "prometheus.yml"}}') prometheus/prometheus.yml
  diff <(kubectl get configmap prometheus-config --namespace="$NS" \
    -o go-template='{{index .data "alert-rules.yml"}}') prometheus/alert_rules.yml
}

@test "the config volume mounts alert-rules.yml at alert_rules.yml" {
  run kubectl get deployment prometheus --namespace="$NS" \
    -o go-template='{{range (index .spec.template.spec.volumes 0).configMap.items}}{{.key}}={{.path}} {{end}}'
  [ "$status" -eq 0 ]
  [ "$output" = "prometheus.yml=prometheus.yml alert-rules.yml=alert_rules.yml " ]
}
