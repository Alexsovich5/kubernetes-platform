#!/usr/bin/env bats

load helpers

PROM_URL="http://prometheus:9090"

setup() {
  wait_for_url "$PROM_URL/api/v1/query?query=up" 60
}

# query_value <promql>
# Prints the sample value of the first result of an instant query.
query_value() {
  curl -fsG "$PROM_URL/api/v1/query" --data-urlencode "query=$1" |
    sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'
}

# wait_for_value <promql> <expected> <seconds>
wait_for_value() {
  local i=0 got
  while [ "$i" -lt "$3" ]; do
    got="$(query_value "$1")"
    if [ "$got" = "$2" ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  echo "$1 = '$got', want '$2'" >&2
  return 1
}

@test "platform-app target is up" {
  wait_for_value 'up{job="platform-app"}' 1 60
}

@test "apiserver discovered through Kubernetes SD is up" {
  wait_for_value 'up{job="kubernetes-apiserver"}' 1 60
}

@test "alert rules are loaded" {
  run curl -fs "$PROM_URL/alerts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PlatformAppDown"* ]]
  [[ "$output" == *"PlatformAppHighErrorRate"* ]]
}
