#!/usr/bin/env bats

load helpers

APP_URL="http://app:8080"

setup() {
  wait_for_url "$APP_URL/health" 30
}

@test "/health returns ok" {
  run curl -fs "$APP_URL/health"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "/ reports version 0.1.0 and the fixture message" {
  run curl -fs "$APP_URL/"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"version":"0.1.0"'* ]]
  [[ "$output" == *'"message":"hello from compose"'* ]]
}

@test "/metrics exposes http_requests_total" {
  curl -fs "$APP_URL/" >/dev/null
  run curl -fs "$APP_URL/metrics"
  [ "$status" -eq 0 ]
  [[ "$output" == *"http_requests_total"* ]]
}
