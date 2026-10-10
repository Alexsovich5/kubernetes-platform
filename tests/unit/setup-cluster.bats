#!/usr/bin/env bats
#
# Runs scripts/setup-cluster.sh with the kubectl, helm and docker stubs from
# tests/unit/stubs on PATH and checks the calls it makes.

SETUP="$BATS_TEST_DIRNAME/../../scripts/setup-cluster.sh"
STUBS="$BATS_TEST_DIRNAME/stubs"

setup() {
  STUB_BIN="$BATS_TMPDIR/setup-cluster-bin-$$"
  rm -rf "$STUB_BIN"
  mkdir -p "$STUB_BIN"
  for tool in kubectl helm docker; do
    ln -s "$STUBS/$tool" "$STUB_BIN/$tool"
  done
  # Only the stubs and the base system directories, so no real kubectl,
  # helm or docker is picked up.
  export PATH="$STUB_BIN:/usr/bin:/bin"
  export STUB_LOG="$BATS_TMPDIR/setup-cluster-kubectl-$$.log"
  export STUB_HELM_LOG="$BATS_TMPDIR/setup-cluster-helm-$$.log"
  export STUB_NAMESPACES=""
  export STUB_SERVICEACCOUNTS=""
  unset HELM_HOST SKIP_DOCKER_CHECK NAMESPACES
  : > "$STUB_LOG"
  : > "$STUB_HELM_LOG"
}

teardown() {
  rm -rf "$STUB_BIN"
  rm -f "$STUB_LOG" "$STUB_HELM_LOG"
}

@test "a missing helm on PATH exits 1 with helm required" {
  rm "$STUB_BIN/helm"
  run "$SETUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"helm required"* ]]
  [ ! -s "$STUB_HELM_LOG" ]
}

@test "a missing docker exits 1 unless SKIP_DOCKER_CHECK is set" {
  rm "$STUB_BIN/docker"
  run "$SETUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker required"* ]]

  SKIP_DOCKER_CHECK=1 run "$SETUP"
  [ "$status" -eq 0 ]
}

@test "namespaces are created only when get fails" {
  STUB_NAMESPACES="staging" run "$SETUP"
  [ "$status" -eq 0 ]
  grep -qx "get namespace production" "$STUB_LOG"
  grep -qx "get namespace staging" "$STUB_LOG"
  grep -qx "get namespace monitoring" "$STUB_LOG"
  grep -qx "create namespace production" "$STUB_LOG"
  grep -qx "create namespace monitoring" "$STUB_LOG"
  [ -z "$(grep 'create namespace staging' "$STUB_LOG")" ]
}

@test "NAMESPACES overrides the namespace list" {
  NAMESPACES="production team-x" run "$SETUP"
  [ "$status" -eq 0 ]
  [ "$(grep '^create namespace ' "$STUB_LOG" | xargs)" = "create namespace production create namespace team-x" ]
}

@test "platform-sa is created in production only when it is absent" {
  run "$SETUP"
  [ "$status" -eq 0 ]
  grep -qx "get serviceaccount platform-sa --namespace=production" "$STUB_LOG"
  grep -qx "create serviceaccount platform-sa --namespace=production" "$STUB_LOG"

  : > "$STUB_LOG"
  STUB_SERVICEACCOUNTS="platform-sa" run "$SETUP"
  [ "$status" -eq 0 ]
  grep -qx "get serviceaccount platform-sa --namespace=production" "$STUB_LOG"
  [ -z "$(grep 'create serviceaccount' "$STUB_LOG")" ]
}

@test "without HELM_HOST helm runs one plain init" {
  run "$SETUP"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^init' "$STUB_HELM_LOG")" -eq 1 ]
  [ "$(grep -c -- '--client-only' "$STUB_HELM_LOG")" -eq 0 ]
  [ -z "$(grep -- '--wait' "$STUB_HELM_LOG")" ]
}

@test "with HELM_HOST helm runs one init --client-only" {
  HELM_HOST=tiller:44134 run "$SETUP"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^init' "$STUB_HELM_LOG")" -eq 1 ]
  [ "$(grep -cx 'init --client-only' "$STUB_HELM_LOG")" -eq 1 ]
}

@test "no kubectl input mentions rbac.authorization.k8s.io" {
  run "$SETUP"
  [ "$status" -eq 0 ]
  [ -s "$STUB_LOG" ]
  [ "$(grep -c 'rbac.authorization.k8s.io' "$STUB_LOG")" -eq 0 ]
}

@test "no kubectl call uses -n" {
  run "$SETUP"
  [ "$status" -eq 0 ]
  [ -s "$STUB_LOG" ]
  [ "$(grep -c ' -n ' "$STUB_LOG")" -eq 0 ]
}
