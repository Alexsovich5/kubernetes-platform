#!/usr/bin/env bats
#
# Talks to the Compose Tiller service (HELM_HOST=tiller:44134).

load helpers

setup() {
  wait_for_url "http://tiller:44135/readiness" 60
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
