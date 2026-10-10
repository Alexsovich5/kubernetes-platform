#!/usr/bin/env bats
#
# Lints and packages helm/platform with the Helm v2.0.0-alpha.2 client.
# alpha.2 `helm lint` always exits 0, so the tests check its output instead.
# alpha.2 resolves the lint path against the working directory, so lint is
# always given a relative path.

REPO_DIR="$BATS_TEST_DIRNAME/../.."

setup() {
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
}

@test "helm lint helm/platform prints exactly Lint OK" {
  cd "$REPO_DIR"
  run helm lint helm/platform
  echo "$output"
  [ "$output" = "Lint OK" ]
}

@test "helm lint reports a chart whose Chart.yaml has no name" {
  cp -R "$REPO_DIR/helm/platform" "$WORK/platform"
  grep -v '^name:' "$REPO_DIR/helm/platform/Chart.yaml" > "$WORK/platform/Chart.yaml"
  cd "$WORK"
  run helm lint platform
  echo "$output"
  [ -n "$output" ]
  [ "$output" != "Lint OK" ]
}

@test "helm package --save=false writes platform-0.1.0.tgz to the working directory only" {
  before="$(cd "$REPO_DIR" && git status --porcelain --untracked-files=all 2>/dev/null; find helm -type f | sort)"
  cd "$WORK"
  run helm package --save=false "$REPO_DIR/helm/platform"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$WORK/platform-0.1.0.tgz" ]
  run tar -tzf "$WORK/platform-0.1.0.tgz"
  [[ "$output" == *"platform/Chart.yaml"* ]]
  [[ "$output" == *"platform/templates/deployment.yaml"* ]]
  after="$(cd "$REPO_DIR" && git status --porcelain --untracked-files=all 2>/dev/null; find helm -type f | sort)"
  [ "$before" = "$after" ]
  [ -z "$(find "$REPO_DIR" -name 'platform-*.tgz' -not -path '*/build/cache/*')" ]
}
