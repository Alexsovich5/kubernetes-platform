#!/usr/bin/env bats

@test "go toolchain is 1.6.3" {
  run go version
  [ "$status" -eq 0 ]
  [[ "$output" == *"go1.6.3"* ]]
}

@test "bats is 0.4.0" {
  run bats --version
  [ "$status" -eq 0 ]
  [ "$output" = "Bats 0.4.0" ]
}

@test "HTTPS to github.com works with the installed CA bundle" {
  if [ "${OFFLINE:-0}" = "1" ]; then
    skip "OFFLINE=1"
  fi
  run curl -fsI https://github.com/
  [ "$status" -eq 0 ]
  run git ls-remote https://github.com/helm/helm refs/tags/v2.0.0-alpha.2
  [ "$status" -eq 0 ]
  [[ "$output" == *"refs/tags/v2.0.0-alpha.2"* ]]
}

@test "kubectl client is v1.2.6" {
  run kubectl version --client
  [ "$status" -eq 0 ]
  [[ "$output" == *'GitVersion:"v1.2.6"'* ]]
}

@test "helm client is v2.0.0-alpha.2" {
  run helm version
  [ "$status" -eq 0 ]
  [ "$output" = "v2.0.0-alpha.2" ]
}

@test "tiller binary is installed" {
  run command -v tiller
  [ "$status" -eq 0 ]
}
