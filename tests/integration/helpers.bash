# Shared helpers for the integration suites. Sourced by bats files and by
# the Makefile readiness step.

# wait_for_url <url> <seconds>
# Polls <url> once per second until it answers with a 2xx status or
# <seconds> have passed. Returns 0 on success, 1 on timeout.
wait_for_url() {
  local url="$1" seconds="$2" i=0
  while [ "$i" -lt "$seconds" ]; do
    if curl -fs -o /dev/null "$url"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  echo "wait_for_url: $url not ready after ${seconds}s" >&2
  return 1
}
