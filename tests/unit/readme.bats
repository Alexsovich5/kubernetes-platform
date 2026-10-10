#!/usr/bin/env bats
#
# Checks README.md against the repository: every file in the Layout block
# exists, and the text carries no unmeasured claims or template leftovers.

README="$BATS_TEST_DIRNAME/../../README.md"
REPO_DIR="$BATS_TEST_DIRNAME/../.."

# Prints the lines inside the fenced code block that follows "## Layout".
layout_lines() {
  awk '
    /^## Layout/ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && /^```/ { if (in_block) exit; in_block = 1; next }
    in_block { print }
  ' "$README"
}

@test "README has a non-empty Layout code block" {
  run layout_lines
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 10 ]
}

@test "every path in the Layout block exists, except the vendor/ line" {
  missing=""
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    case "$path" in vendor/*) continue ;; esac
    [ -e "$REPO_DIR/$path" ] || missing="$missing $path"
  done < <(layout_lines)
  echo "missing:$missing"
  [ -z "$missing" ]
}

@test "Layout block lists README.md and this test file" {
  run layout_lines
  printf '%s\n' "${lines[@]}" | grep -qx 'README.md'
  printf '%s\n' "${lines[@]}" | grep -qx 'tests/unit/readme.bats'
}

@test "README contains no unmeasured metrics, status or history claims" {
  run bash -c "grep -ciE 'uptime|MTTR|availability %|cost reduction|developed during|career portfolio|timeline|status-complete' '$README'"
  [ "$output" = "0" ]
}

@test "README has no template placeholders or template comment block" {
  ! grep -q '{{[A-Z_]' "$README"
  ! grep -q 'Rules for this README' "$README"
}

@test "README states the pinned stack line" {
  grep -qF 'Personal project built on the 2016-era stack (Kubernetes 1.2.6, Helm 2.0.0-alpha.2, Prometheus 0.20.0, Go 1.6.3)' "$README"
}

@test "README names every simulated integration" {
  grep -qF 'Kubernetes nodes are simulated by a kubelet-less 1.2 control plane; pods are created but never run.' "$README"
  grep -qF 'No cloud load balancer; LoadBalancer services never receive an external IP.' "$README"
  grep -qF 'Tiller runs as a compose service rather than in-cluster, and every release is installed into its namespace (production).' "$README"
  grep -qF 'Script unit tests stub kubectl/helm/docker.' "$README"
}
