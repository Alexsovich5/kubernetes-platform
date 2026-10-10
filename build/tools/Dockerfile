FROM kubernetes-platform:helm-v2.0.0-alpha.2

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
 && rm -rf bats-0.4.0

COPY cache/glide-v0.11.1-linux-amd64.tar.gz /tmp/build/cache/
RUN cd cache \
 && grep -E '  glide-v0\.11\.1-linux-amd64\.tar\.gz$' ../SHA256SUMS | sha256sum -c - \
 && tar -xzf glide-v0.11.1-linux-amd64.tar.gz \
 && install -m 0755 linux-amd64/glide /usr/local/bin/glide \
 && rm -rf linux-amd64 glide-v0.11.1-linux-amd64.tar.gz

COPY cache/etcd-v2.2.5-linux-amd64.tar.gz /tmp/build/cache/
RUN cd cache \
 && grep -E '  etcd-v2\.2\.5-linux-amd64\.tar\.gz$' ../SHA256SUMS | sha256sum -c - \
 && tar -xzf etcd-v2.2.5-linux-amd64.tar.gz \
 && install -m 0755 etcd-v2.2.5-linux-amd64/etcd etcd-v2.2.5-linux-amd64/etcdctl /usr/local/bin/ \
 && rm -rf etcd-v2.2.5-linux-amd64 etcd-v2.2.5-linux-amd64.tar.gz

# Kubernetes v1.2.6 control-plane binaries and kubectl.
COPY cache/kube-apiserver cache/kube-controller-manager cache/kube-scheduler cache/kubectl /tmp/build/cache/
RUN cd cache \
 && grep -E '  (kube-apiserver|kube-controller-manager|kube-scheduler|kubectl)$' ../SHA256SUMS | sha256sum -c - \
 && install -m 0755 kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/ \
 && cd / && rm -rf /tmp/build

# Create $HELM_HOME without installing Tiller.
RUN helm init --client-only

WORKDIR /go
