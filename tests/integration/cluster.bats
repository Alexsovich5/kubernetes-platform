#!/usr/bin/env bats

load helpers

APISERVER_URL="http://apiserver:8080"

setup() {
  wait_for_url "$APISERVER_URL/healthz" 60
  wait_for_url "http://apiserver:10252/healthz" 60
  wait_for_url "http://apiserver:10251/healthz" 60
}

# component_healthy <name> <output>
component_healthy() {
  printf '%s\n' "$2" | awk -v n="$1" '$1 == n && $2 == "Healthy" { found = 1 } END { exit !found }'
}

@test "componentstatuses reports scheduler, controller-manager and etcd-0 Healthy" {
  run kubectl get componentstatuses
  [ "$status" -eq 0 ]
  component_healthy scheduler "$output"
  component_healthy controller-manager "$output"
  component_healthy etcd-0 "$output"
}

@test "controller-manager answers on apiserver:10252" {
  run curl -fs http://apiserver:10252/healthz
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "scheduler answers on apiserver:10251" {
  run curl -fs http://apiserver:10251/healthz
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "api-versions includes extensions/v1beta1" {
  run kubectl api-versions
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'extensions/v1beta1'
}

@test "no nodes are registered because no kubelet runs" {
  run kubectl get nodes --no-headers
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
