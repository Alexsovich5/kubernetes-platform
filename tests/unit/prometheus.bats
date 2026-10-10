#!/usr/bin/env bats

SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount

setup() {
  # prometheus.yml references the service account files a pod mounts.
  mkdir -p "$SA_DIR"
  touch "$SA_DIR/token" "$SA_DIR/ca.crt"
}

@test "promtool is 0.20.0" {
  run promtool version
  [ "$status" -eq 0 ]
  [[ "$output" == *"version 0.20.0"* ]]
}

@test "prometheus.yml passes promtool check-config" {
  run promtool check-config prometheus/prometheus.yml
  [ "$status" -eq 0 ]
}

@test "prometheus-local.yml passes promtool check-config" {
  run promtool check-config prometheus/prometheus-local.yml
  [ "$status" -eq 0 ]
}

@test "alert_rules.yml passes promtool check-rules" {
  run promtool check-rules prometheus/alert_rules.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: 3 rules found"* ]]
}

@test "alert_rules_local.yml passes promtool check-rules" {
  run promtool check-rules prometheus/alert_rules_local.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: 3 rules found"* ]]
}

@test "check-config rejects a config whose rule file is missing" {
  tmp="$(mktemp -d)"
  cp prometheus/prometheus-local.yml "$tmp/"
  run promtool check-config "$tmp/prometheus-local.yml"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "check-config rejects an unknown scrape config key" {
  tmp="$(mktemp -d)"
  cp prometheus/alert_rules.yml "$tmp/"
  sed 's/kubernetes_sd_configs:/kubernetes_sd_config:/' prometheus/prometheus.yml > "$tmp/prometheus.yml"
  run promtool check-config "$tmp/prometheus.yml"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "prometheus-local.yml evaluates rules every 5s" {
  run grep -E '^  evaluation_interval: 5s$' prometheus/prometheus-local.yml
  [ "$status" -eq 0 ]
}

@test "local rules fire PlatformAppDown after 10s" {
  run grep -A2 '^ALERT PlatformAppDown$' prometheus/alert_rules_local.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"FOR 10s"* ]]
}

@test "prometheus.yml uses 0.20 SD syntax and no role: key" {
  run grep -E '^\s+(- )?role:' prometheus/prometheus.yml
  [ "$status" -ne 0 ]
  grep -q "in_cluster: true" prometheus/prometheus.yml
  grep -q "api_servers: \['https://kubernetes.default.svc'\]" prometheus/prometheus.yml
}

@test "pod port rewrite joins __address__ and the port annotation" {
  run grep -F 'source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]' prometheus/prometheus.yml
  [ "$status" -eq 0 ]
}
