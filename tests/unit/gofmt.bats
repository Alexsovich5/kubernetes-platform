#!/usr/bin/env bats

# Runs the gofmt guard exactly as the ci-unit recipe expands it, so a
# missing $$ escape in the Makefile (which turns the check into
# `test -z ""`) makes these tests fail.

setup() {
  REPO_DIR="$BATS_TEST_DIRNAME/../.."
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/pkg/sample"
  GOFMT_CHECK="$(make -s -n -f "$REPO_DIR/Makefile" ci-unit | grep 'gofmt -l')"
}

teardown() {
  rm -rf "$WORK"
}

@test "ci-unit contains a gofmt check that keeps its command substitution" {
  [ -n "$GOFMT_CHECK" ]
  [[ "$GOFMT_CHECK" == *'$(gofmt -l cmd pkg tests)'* ]]
}

@test "gofmt check fails on a misformatted file under pkg/" {
  cp "$BATS_TEST_DIRNAME/../fixtures/gofmt/bad.go.txt" "$WORK/pkg/sample/bad.go"
  run bash -c "cd '$WORK' && $GOFMT_CHECK"
  [ "$status" -ne 0 ]
}

@test "gofmt check passes once the file is formatted" {
  cp "$BATS_TEST_DIRNAME/../fixtures/gofmt/bad.go.txt" "$WORK/pkg/sample/bad.go"
  gofmt -w "$WORK/pkg/sample/bad.go"
  run bash -c "cd '$WORK' && $GOFMT_CHECK"
  [ "$status" -eq 0 ]
}
