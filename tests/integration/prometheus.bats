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
  [[ "$output" == *"PlatformAppAbsent"* ]]
}

@test "PlatformAppAbsent stays inactive while the app target is scraped" {
  wait_for_value 'up{job="platform-app"}' 1 60
  sleep 15
  # Prometheus 0.x keeps writing ALERTS samples with value 0 for a while after
  # an alert turns inactive (it is briefly pending before the first scrape),
  # so only samples with value 1 mean the alert is active.
  run query_value 'count(ALERTS{alertname="PlatformAppAbsent"} == 1)'
  echo "active PlatformAppAbsent samples: '$output'"
  [ -z "$output" ]
}
