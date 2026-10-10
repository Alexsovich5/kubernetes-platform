#!/usr/bin/env bats
#
# Runs scripts/deploy.sh against the kubectl stub in tests/unit/stubs and
# checks the calls it makes, the rollout poll and the exit codes.

DEPLOY="$BATS_TEST_DIRNAME/../../scripts/deploy.sh"

setup() {
  export KUBECTL="$BATS_TEST_DIRNAME/stubs/kubectl"
  export STUB_LOG="$BATS_TMPDIR/deploy-stub-$$.log"
  export STUB_NAMESPACES=""
  export STUB_KUBECTL_JSONPATH="2 2 3 3 3"
  unset ROLLOUT_WAIT ROLLOUT_TIMEOUT
  : > "$STUB_LOG"
}

teardown() {
  rm -f "$STUB_LOG"
}

# Prints the stub log lines that start with the given kubectl verb.
calls() {
  grep "^$1 " "$STUB_LOG" || true
}

@test "the default namespace is default" {
  STUB_NAMESPACES="default" run "$DEPLOY"
  [ "$status" -eq 0 ]
  grep -qx "get namespace default" "$STUB_LOG"
  [ "$(calls apply | grep -c -- '--namespace=default')" -eq 3 ]
}

@test "an existing namespace is not re-created" {
  STUB_NAMESPACES="team-a" run "$DEPLOY" team-a
  [ "$status" -eq 0 ]
  [ -z "$(grep 'create namespace team-a' "$STUB_LOG")" ]
}

@test "a missing namespace is created" {
  run "$DEPLOY" team-b
  [ "$status" -eq 0 ]
  grep -qx "create namespace team-b" "$STUB_LOG"
}

@test "manifests are applied in order: configmap, deployment, service, monitoring" {
  run "$DEPLOY" team-a
  [ "$status" -eq 0 ]
  applied="$(calls apply | sed -n 's/.*-f \([^ ]*\).*/\1/p' | xargs -n1 basename | xargs)"
  [ "$applied" = "configmap.yaml deployment.yaml service.yaml monitoring.yaml" ]
  # Manifest paths resolve relative to the script, not the working directory.
  [ "$(calls apply | grep -c ' -f /')" -eq 4 ]
}

@test "the monitoring namespace comes from monitoring.yaml, not a separate create" {
  run "$DEPLOY" team-a
  [ "$status" -eq 0 ]
  [ -z "$(grep 'namespace monitoring' "$STUB_LOG")" ]
  grep -q 'apply -f /.*/k8s/monitoring.yaml' "$STUB_LOG"
}

@test "ROLLOUT_WAIT=0 skips polling" {
  STUB_KUBECTL_JSONPATH="1 2 0 0 3" ROLLOUT_WAIT=0 run "$DEPLOY" team-a
  [ "$status" -eq 0 ]
  [ -z "$(grep jsonpath "$STUB_LOG")" ]
}

@test "a poll with 2 2 3 3 3 exits 0" {
  STUB_KUBECTL_JSONPATH="2 2 3 3 3" run "$DEPLOY" team-a
  [ "$status" -eq 0 ]
  [ "$(grep -c 'get deployment platform-app.*jsonpath=' "$STUB_LOG")" -ge 1 ]
}

@test "a stale observedGeneration (1 2 3 3 3) times out with exit 2" {
  STUB_KUBECTL_JSONPATH="1 2 3 3 3" ROLLOUT_TIMEOUT=2 run "$DEPLOY" team-a
  [ "$status" -eq 2 ]
}

@test "a poll stuck at 2 2 1 0 3 exits 2 with rollout timed out" {
  STUB_KUBECTL_JSONPATH="2 2 1 0 3" ROLLOUT_TIMEOUT=2 run "$DEPLOY" team-a
  [ "$status" -eq 2 ]
  [[ "$output" == *"rollout timed out"* ]]
}

@test "no call uses -n and every namespaced call passes --namespace=" {
  run "$DEPLOY" team-a
  [ "$status" -eq 0 ]
  [ "$(grep -c ' -n ' "$STUB_LOG")" -eq 0 ]
  # Namespace and monitoring.yaml calls are cluster-scoped or carry their own
  # namespace; every other call targets the app namespace.
  namespaced="$(grep -v -e '^get namespace ' -e '^create namespace ' -e 'monitoring.yaml' "$STUB_LOG")"
  [ -n "$namespaced" ]
  [ -z "$(echo "$namespaced" | grep -v -- '--namespace=team-a')" ]
}
