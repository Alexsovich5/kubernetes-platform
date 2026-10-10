FROM golang:1.6.3@sha256:9bc3717d167110a13be0ca34936a1d2d509f1775499649a6be616330ab20dbd1

WORKDIR /tmp/build
COPY SHA256SUMS /tmp/build/SHA256SUMS

# Newer root store (adds ISRG_Root_X1) so HTTPS to GitHub works during builds.
COPY cache/ca-certificates_20141019+deb8u4_all.deb /tmp/build/cache/
RUN (cd cache && grep -E '  ca-certificates_20141019\+deb8u4_all\.deb$' ../SHA256SUMS | sha256sum -c -) \
 && DEBIAN_FRONTEND=noninteractive dpkg -i cache/ca-certificates_20141019+deb8u4_all.deb && update-ca-certificates

COPY cache/glide-v0.11.1-linux-amd64.tar.gz /tmp/build/cache/
RUN cd cache \
 && grep -E '  glide-v0\.11\.1-linux-amd64\.tar\.gz$' ../SHA256SUMS | sha256sum -c - \
 && tar -xzf glide-v0.11.1-linux-amd64.tar.gz \
 && install -m 0755 linux-amd64/glide /usr/local/bin/glide \
 && cd / && rm -rf /tmp/build

# Clone, resolve dependencies, compile and clean up in one layer so only the
# helm and tiller binaries in /go/bin remain in the image. The Mercurial
# goautoneg repository pinned by Helm's glide.lock no longer exists, so its
# entry is pointed at a git mirror of the same changeset. glide clones the
# dependencies in parallel and single clones can fail over a flaky network, so
# glide install is retried; repositories already fetched are reused.
RUN git clone --branch v2.0.0-alpha.2 --depth 1 https://github.com/helm/helm /go/src/k8s.io/helm \
 && cd /go/src/k8s.io/helm \
 && sed -i 's|^  version: 75cd24fc2f2c$|  version: a547fc61f48d567d5b4ec6f8aee5573d8efce11d\n  repo: https://github.com/munnerz/goautoneg\n  vcs: git|' glide.lock \
 && grep -A2 -x -- '- name: bitbucket.org/ww/goautoneg' glide.lock | grep -qx '  repo: https://github.com/munnerz/goautoneg' \
 && { ok=0; for attempt in 1 2 3 4 5; do \
      if glide install; then ok=1; break; fi; \
      echo "glide install failed (attempt $attempt)" >&2; sleep 5; \
    done; [ "$ok" = 1 ]; } \
 && go install k8s.io/helm/cmd/helm k8s.io/helm/cmd/tiller \
 && cd / && rm -rf /go/src/* /go/pkg ~/.glide

WORKDIR /go
