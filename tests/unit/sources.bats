#!/usr/bin/env bats
#
# Build inputs come only over HTTPS and are checked against build/SHA256SUMS;
# no Dockerfile downloads files or weakens package verification.

REPO_DIR="$BATS_TEST_DIRNAME/../.."

dockerfiles() {
  find "$REPO_DIR" -path "$REPO_DIR/vendor" -prune -o -path "$REPO_DIR/build/cache" -prune -o \
    -name 'Dockerfile*' -type f -print
}

@test "every make fetch URL uses https" {
  run bash -c "grep -oE '\^[a-z]+://' '$REPO_DIR/Makefile' | sort -u"
  [ "$status" -eq 0 ]
  [ "$output" = "^https://" ]
}

# Prints the file names of the FETCH_LIST entries ("<file>^<url>").
fetch_files() {
  grep -oE '^	[^ ^$]+\^[a-z]+://' "$REPO_DIR/Makefile" | sed -E 's/^	//; s/\^.*//'
}

@test "every fetched file has a SHA256SUMS entry" {
  run fetch_files
  [ "${#lines[@]}" -ge 5 ]
  missing=""
  for file in "${lines[@]}"; do
    awk -v f="$file" '$2 == f { found = 1 } END { exit !found }' "$REPO_DIR/build/SHA256SUMS" ||
      missing="$missing $file"
  done
  echo "missing:$missing"
  [ -z "$missing" ]
}

@test "the source checker finds the Dockerfiles" {
  run dockerfiles
  [ "${#lines[@]}" -ge 3 ]
}

@test "no Dockerfile uses http:// or skips package verification" {
  run grep -nE 'http://|--allow-unauthenticated|--force-yes|trusted=yes|AllowUnauthenticated|--no-check-gpg|--no-check-certificate|--insecure' $(dockerfiles)
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "no Dockerfile downloads with curl, wget or ADD <url>" {
  run grep -nE '(^|[^-])(curl|wget) |^ADD +https?://' $(dockerfiles)
  echo "$output"
  [ "$status" -eq 1 ]
}
