FROM golang:1.6.3@sha256:9bc3717d167110a13be0ca34936a1d2d509f1775499649a6be616330ab20dbd1

WORKDIR /tmp/build
COPY SHA256SUMS /tmp/build/SHA256SUMS

# Newer root store (adds ISRG_Root_X1) so HTTPS to GitHub works during builds.
COPY cache/ca-certificates_20141019+deb8u4_all.deb /tmp/build/cache/
RUN (cd cache && grep -E '  ca-certificates_20141019\+deb8u4_all\.deb$' ../SHA256SUMS | sha256sum -c -) \
 && DEBIAN_FRONTEND=noninteractive dpkg -i cache/ca-certificates_20141019+deb8u4_all.deb && update-ca-certificates

COPY cache/bats-v0.4.0.tar.gz /tmp/build/cache/
RUN cd cache \
 && grep -E '  bats-v0\.4\.0\.tar\.gz$' ../SHA256SUMS | sha256sum -c - \
 && tar -xzf bats-v0.4.0.tar.gz \
 && bats-0.4.0/install.sh /usr/local \
 && cd / && rm -rf /tmp/build

WORKDIR /go
