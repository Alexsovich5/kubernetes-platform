#!/usr/bin/env bats

# Runs after the host has stopped the app container.

load ../helpers

PROM_URL="http://prometheus:9090"

firing_count() {
  curl -fsG "$PROM_URL/api/v1/query" \
    --data-urlencode 'query=ALERTS{alertname="PlatformAppDown",alertstate="firing"}' |
    grep -o '"alertname":"PlatformAppDown"' | wc -l
}

@test "PlatformAppDown fires within 60s of the app stopping" {
  local i=0 n=0
  while [ "$i" -lt 60 ]; do
    n="$(firing_count)"
    if [ "$n" -gt 0 ]; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  [ "$n" -gt 0 ]
}
