# kubernetes-platform: Implementation Plan

This plan implements `docs/SPEC.md`. There are 14 tasks and each task is one commit. After every task, `make test` passes. From T4 on, `make integration` also passes.

## Conventions for every task

- Go import path: `github.com/Alexsovich5/kubernetes-platform`. Inside containers the repo is mounted at `/go/src/github.com/Alexsovich5/kubernetes-platform` (called `$(REPO)` in the Makefile), so GOPATH and `vendor/` work the Go 1.6 way.
- Base image: every `FROM golang` line is `FROM golang:1.6.3@sha256:9bc3717d167110a13be0ca34936a1d2d509f1775499649a6be616330ab20dbd1`.
- `make test` runs `preflight`, `fetch` and `tools-image` if needed, then:
  `docker run --rm -v $(CURDIR):$(REPO) -w $(REPO) kubernetes-platform:tools-2016 make -f Makefile ci-unit`.
- `make integration` runs `make up`, waits for readiness, runs `docker compose run --rm tools bats tests/integration`, and always finishes with `docker compose down -v`. It never prunes images, volumes or networks, because other projects share the Docker host.
- `make up` runs `fetch`, `helm-image` (from T9), `tools-image` and `docker compose up -d --build`, in that order. `kp-tools` is built `FROM` the local `kp-helm` tag, so plain `docker compose up` on a fresh clone does not work.
- Dockerfiles use only Docker 1.10 features: no multi-stage builds, no `HEALTHCHECK`, and no `ARG` before `FROM`. The Compose file uses `version: '2'`.
- No Dockerfile downloads release files. `make fetch` downloads them on the host into the git-ignored `build/cache/` and runs `cd build/cache && sha256sum -c ../SHA256SUMS`. `build/SHA256SUMS` holds the hashes from the SPEC table. Dockerfiles `COPY` from `cache/` (build context `build/`) and run `sha256sum -c` again.
- The first `RUN` of `build/tools/Dockerfile` and `build/helm/Dockerfile` is `dpkg -i cache/ca-certificates_20141019+deb8u4_all.deb && update-ca-certificates`. It must come before any HTTPS access (`glide install`, `git clone`). See the SPEC note on the build-time trust store.
- Makefile recipes escape shell command substitution as `$$(…)`. A single `$(…)` is expanded by make as a variable and turns into an empty string.
- Every kubectl call in scripts and tests uses `--namespace=<ns>`. kubectl 1.2 has no `-n` shorthand.
- Shared Docker host: every image this repo builds is tagged `kubernetes-platform:<tag>` (`kubernetes-platform:tools-2016`, `kubernetes-platform:helm-v2.0.0-alpha.2`; "kp-tools" and "kp-helm" in the text name these two images). The Compose project name is `kubernetes-platform` (top-level `name:`), its network uses subnet `172.41.0.0/24`, and every published host port lies in `20100`–`20199` (for example host `20180` → app `8080`, host `20190` → Prometheus `9090`). Container ports and in-network addresses are unchanged.
- Commit messages contain no dates, no tool or AI attribution and no employer names.

---

### T1: Scaffold the tools image, Makefile and bats harness

- **Goal:** `make test` runs a bats suite inside a period Go image from the first commit.
- **Files:**
  - create `build/SHA256SUMS` (bats and ca-certificates entries for now; later tasks append lines from the SPEC table)
  - create `build/tools/Dockerfile`:
    - `FROM golang:1.6.3@sha256:…`
    - install the CA deb
    - `COPY cache/bats-v0.4.0.tar.gz`, `sha256sum -c`, install into `/usr/local`
  - create `Makefile` with these targets:
    - `preflight`: prints `docker system df` and `docker volume ls -qf dangling=true`, then runs `df -Pk /` in a throwaway `golang:1.6.3@sha256:…` container and fails if less than 15 GB is available
    - `fetch`: `curl -fsSL -o build/cache/<file> <url>` for each entry missing from the cache, then `sha256sum -c`
    - `tools-image`: `docker build -t kubernetes-platform:tools-2016 -f build/tools/Dockerfile build/`
    - `test`, `ci-unit` and `shell`
  - create `tests/unit/harness.bats`
  - create `.gitignore` (`bin/`, `*.tgz`, `build/cache/`) and `.dockerignore` (`.git`, `bin`, `build/cache`)
- **Tests to write first** (`tests/unit/harness.bats`):
  - `go version` prints `go1.6.3`
  - `bats --version` prints `Bats 0.4.0`
  - `curl -fsI https://github.com/` and `git ls-remote https://github.com/helm/helm refs/tags/v2.0.0-alpha.2` both succeed inside the image, which proves the updated CA bundle works. This test is skipped when `OFFLINE=1`.
- **Acceptance:** `make preflight && make test`
- **Commit:** `Add Docker tools image and Makefile test harness`
  > Introduce a golang:1.6.3 based tools image with bats 0.4.0, a host-side
  > fetch step with sha256 checks, and a Makefile test target.

### T2: Vendor Prometheus client with glide and add config loader

- **Goal:** Pin Go dependencies the 2016 way and implement `LoadConfig`.
- **Files:**
  - modify `build/tools/Dockerfile`: add glide v0.11.1 from `cache/`
  - create `glide.yaml`. Every package from the SPEC pin table is pinned explicitly, so glide does not import client_golang's Godeps revisions:
    - `github.com/prometheus/client_golang` version `0.7.0`
    - `github.com/prometheus/client_model` `fa8ad6fec335`
    - `github.com/prometheus/procfs` `c91d8eefde16`
    - `github.com/beorn7/perks` `b965b613227f`
    - `github.com/golang/protobuf` `f0a097ddac24`
    - `github.com/matttproud/golang_protobuf_extensions` `v1.0.0`
    - `bitbucket.org/ww/goautoneg` with `repo: https://github.com/munnerz/goautoneg`, `vcs: git`, `version: a547fc61f48d567d5b4ec6f8aee5573d8efce11d`
    - `gopkg.in/yaml.v2` `e4d366fc3c7938e2958e662b4258c7a89e1f0e3e`
  - create `glide.lock` and `vendor/…` (produced by `make vendor`, which runs `glide install --strip-vcs --strip-vendor` in the tools image, so `vendor/` holds no `.git` directories or client_golang `Godeps/_workspace` copies)
  - create `build/lock_dates.py`. It is a host-side Python 3 script that reads each `name`/`version` pair from `glide.lock`, maps `bitbucket.org/ww/goautoneg` to `github.com/munnerz/goautoneg`, and fetches `https://proxy.golang.org/<module>/@v/<version>.info`. It exits 1 if any `Time` is after 2016-07-31 or any lookup fails.
  - create `pkg/app/config.go` and `pkg/app/config_test.go`
  - modify `Makefile`:
    - `ci-unit` runs `test -z "$$(gofmt -l cmd pkg tests)"`, `go vet ./cmd/... ./pkg/...`, `go test ./pkg/...` and bats
    - add a `vendor` target and a `lock-check` target that runs `python3 build/lock_dates.py glide.lock` on the host
- **Tests to write first:**
  - `config_test.go`:
    - a missing directory gives an empty map and a nil error
    - two files give two keys with whitespace trimmed
    - entries starting with `..` and subdirectories are ignored, like ConfigMap volume internals
  - `tests/unit/gofmt.bats`: copies a deliberately misformatted fixture (`tests/fixtures/gofmt/bad.go.txt`) into a temp `pkg/` tree and asserts that the same `test -z "$(gofmt -l …)"` expression fails. This guards the `$$` escaping.
- **Before committing:** `make lock-check` exits 0. Every `glide.lock` entry must also match the revision in the SPEC pin table.
- **Acceptance:** `make test && make lock-check`
- **Commit:** `Vendor Prometheus client with glide and add config loader`
  > Pin client_golang 0.7.0, its transitive packages and yaml.v2 via glide,
  > using a git mirror for goautoneg. LoadConfig reads ConfigMap-style
  > directories into a key/value map.

### T3: Implement platform-app HTTP server with metrics and drain

- **Goal:** Build the Go workload described in SPEC item 1.
- **Files:**
  - create `pkg/app/server.go` and `pkg/app/server_test.go`
  - create `pkg/app/drain.go` (`RunDrain(s, sigs, d, exit)`) and `pkg/app/drain_test.go`
  - create `cmd/platform-app/main.go`:
    - env `LISTEN_ADDR`, `CONFIG_DIR`, `DRAIN_SECONDS`
    - `-ldflags -X main.version`
    - `signal.Notify(ch, syscall.SIGTERM)`, then `go app.RunDrain(srv, ch, drain, os.Exit)`
  - modify `Makefile`: add `build`, which runs `go build -o bin/platform-app ./cmd/platform-app` in the tools image
- **Tests to write first:**
  - `httptest`:
    - `/` returns JSON with `version`, `hostname`, and `message` from config or the default `hello`
    - `/health` returns 200, then 503 after `StartDrain()`
    - `/metrics` contains `http_requests_total` with `handler="root"` after one `/` request
    - an unknown path returns 404
  - `drain_test.go`: with `d = 0`, sending `syscall.SIGTERM` on the channel makes `/health` return 503, and the fake `exit` receives `0` within 1 s
- **Acceptance:** `make test && make build`
- **Commit:** `Add platform-app HTTP service with health, metrics and drain`
  > Serve /, /health and /metrics using client_golang InstrumentHandler.
  > SIGTERM flips /health to 503 for DRAIN_SECONDS before exiting.

### T4: Replace Node Dockerfile and add Compose stack with app

- **Goal:** Make the image real and add the integration harness.
- **Files:**
  - modify `Dockerfile`:
    - `FROM golang:1.6.3@sha256:…`
    - copy into the GOPATH
    - `go install -ldflags "-X main.version=0.1.0" ./cmd/platform-app`
    - `EXPOSE 8080`, `CMD ["platform-app"]`
  - create `docker-compose.yml` (v2) with two services:
    - `app`: build `.`, image `kubernetes-platform:app-0.1.0` (the shared-host naming rule; the `k8s/` and chart manifests still reference `platform-app:0.1.0`), host port `20180` → container `8080`, `./tests/fixtures/config` mounted as `/app/config`
    - `tools`: image `kubernetes-platform:tools-2016`, repo mounted at `/go/src/github.com/Alexsovich5/kubernetes-platform`, `working_dir` set to the same path, `entrypoint: []`
  - create `tests/fixtures/config/message`
  - create `tests/integration/helpers.bash` with `wait_for_url <url> <seconds>`
  - create `tests/integration/app.bats`
  - modify `Makefile`: add `integration`, `up` and `down`
- **Tests to write first** (`app.bats`):
  - `curl -fs http://app:8080/health` returns `ok`
  - `/` includes `"version":"0.1.0"` and the fixture message
  - `/metrics` includes `http_requests_total`
- **Acceptance:** `make test && make integration`
- **Commit:** `Build platform-app image in Go and add compose integration suite`
  > Replace the Node Dockerfile, which referenced files that never existed,
  > with a golang:1.6.3 build. Add a v2 compose file and bats integration tests.

### T5: Add a local Kubernetes 1.2 control plane to Compose

- **Goal:** Run a real 1.2.6 apiserver, controller-manager and scheduler on etcd 2.2.5.
- **Files:**
  - modify `build/SHA256SUMS` and `build/tools/Dockerfile`: add etcd v2.2.5, then kube-apiserver, kube-controller-manager, kube-scheduler and kubectl v1.2.6 from `cache/` into `/usr/local/bin`
  - create `build/kubeconfig`: cluster `local`, `http://apiserver:8080`
  - modify `docker-compose.yml`: add these services
    - `etcd`: `etcd --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls http://etcd:2379`
    - `apiserver`: `kube-apiserver --etcd-servers=http://etcd:2379 --insecure-bind-address=0.0.0.0 --insecure-port=8080 --service-cluster-ip-range=10.0.0.0/24 --admission-control=NamespaceLifecycle,LimitRanger,ResourceQuota`
    - `controller-manager`: `network_mode: "service:apiserver"`, `depends_on: [apiserver]`, `kube-controller-manager --master=http://127.0.0.1:8080`
    - `scheduler`: `network_mode: "service:apiserver"`, `depends_on: [apiserver]`, `kube-scheduler --master=http://127.0.0.1:8080`

    kube-apiserver 1.2 checks the controller-manager and scheduler at the hard-coded `127.0.0.1:10252` and `127.0.0.1:10251`, so they must share its network namespace. Also set `KUBECONFIG=/go/src/github.com/Alexsovich5/kubernetes-platform/build/kubeconfig` on `tools`.
  - create `tests/integration/cluster.bats`
  - modify `tests/unit/harness.bats` to assert that `kubectl version --client` reports `v1.2.6`
- **Tests to write first:**
  - `kubectl get componentstatuses` shows `scheduler`, `controller-manager` and `etcd-0` as `Healthy`
  - `curl -fs http://apiserver:10252/healthz` and `curl -fs http://apiserver:10251/healthz` return `ok`
  - `kubectl api-versions` includes `extensions/v1beta1`
  - `kubectl get nodes` returns no nodes, which documents the kubelet-less design
- **Acceptance:** `make test && make integration`
- **Commit:** `Run Kubernetes 1.2 control plane on etcd 2.2 in compose`
  > Add etcd, kube-apiserver, controller-manager and scheduler v1.2.6
  > services plus kubectl in the tools image. The controllers share the
  > apiserver network namespace so component health checks work. No kubelet
  > is started.

### T6: Refactor app manifests for 1.2 and prove controller behaviour

- **Goal:** Make `k8s/` valid and consistent, and show it self-heals, scales and rolls updates on 1.2.
- **Files:**
  - modify `k8s/deployment.yaml`:
    - remove the `platform-worker` Deployment, the `DB_HOST` secret env and the leftover `NODE_ENV=production` env var
    - image `platform-app:0.1.0`
    - add `prometheus.io/scrape|port|path` pod annotations
    - keep the strategy, probes, resources and ConfigMap mount
  - create `k8s/configmap.yaml` (`platform-config`, key `message`)
  - keep `k8s/service.yaml` unchanged
  - create `tests/manifests/manifests_test.go` (package `manifests`, yaml.v2, splits multi-document files on `\n---`)
  - create `tests/integration/workload.bats`
  - modify `Makefile` so `ci-unit` also runs `go test ./tests/manifests/...`
- **Tests to write first:**
  - Unit (manifest invariants):
    - Service selectors are a subset of the Deployment template labels
    - probes use `/health` on `containerPort` 8080
    - requests and limits are set
    - RollingUpdate uses surge 1 and unavailable 0
    - the annotations are present
    - no image tag is `latest`
    - no container sets `NODE_ENV`
    - every `configMap` volume references a ConfigMap defined in `k8s/`
  - Integration (`workload.bats`, namespace `it-workload`, created and deleted per file, every call with `--namespace=it-workload`):
    - `kubectl apply -f k8s/configmap.yaml -f k8s/deployment.yaml -f k8s/service.yaml` succeeds
    - one ReplicaSet with `.spec.replicas=3` and 3 pods labelled `app=platform`
    - delete one pod, and within 30 s there are again 3 pods, none of them the deleted name (self-healing)
    - `kubectl scale deployment platform-app --replicas=5` gives a ReplicaSet with `.spec.replicas=5` and 5 pods within 30 s; scaling back to 3 returns 3 pods
    - `kubectl patch deployment platform-app` to image `platform-app:0.1.1` gives 2 ReplicaSets: new = 1, old = 3 (surge 1, unavailable 0, pods never ready)
    - `kubectl rollout undo deployment/platform-app` returns the template image to `0.1.0`
    - `service/platform-app` has a nodePort allocated, and `LoadBalancer Ingress` is empty
- **Acceptance:** `make test && make integration`
- **Commit:** `Refactor app manifests for Kubernetes 1.2 and test rollouts`
  > Drop the undocumented worker, DB secret and Node-era env var, pin the
  > image and add Prometheus annotations. Verify self-healing, scaling and
  > surge limits on 1.2.

### T7: Refactor deploy.sh to poll rollouts on 1.2

- **Goal:** Make the deploy script work with the 1.2 kubectl.
- **Files:**
  - modify `scripts/deploy.sh`:
    - `ROOT=$(cd "$(dirname "$0")/.." && pwd)`
    - `KUBECTL`, `ROLLOUT_WAIT` and `ROLLOUT_TIMEOUT` environment variables
    - replace every `-n "$NAMESPACE"` with `--namespace="$NAMESPACE"`
    - apply `k8s/configmap.yaml`, `k8s/deployment.yaml` and `k8s/service.yaml`, then `k8s/monitoring.yaml`. T12 makes that file define its own namespace; until then the script keeps `kubectl create namespace monitoring || true`
    - a poll loop on `-o jsonpath='{.status.observedGeneration} {.metadata.generation} {.status.updatedReplicas} {.status.availableReplicas} {.spec.replicas}'`, which succeeds only when the first two fields are equal and the last three are equal
    - exit 2 on timeout
  - create `tests/unit/stubs/kubectl` (logs `$*` to `$STUB_LOG`; canned output from `$STUB_KUBECTL_JSONPATH`)
  - create `tests/unit/deploy.bats`
  - create `tests/integration/scripts.bats` (deploy part)
- **Tests to write first:**
  - Unit:
    - the default namespace is `default`
    - an existing namespace is not re-created
    - the apply order is correct
    - `ROLLOUT_WAIT=0` skips polling
    - a poll with `2 2 3 3 3` exits 0
    - a poll stuck at `1 2 3 3 3` (stale observedGeneration) with `ROLLOUT_TIMEOUT=2` exits 2
    - a poll stuck at `2 2 1 0 3` with `ROLLOUT_TIMEOUT=2` exits 2 with `rollout timed out`
    - `grep -c ' -n ' "$STUB_LOG"` is 0 and every namespaced call contains `--namespace=`
  - Integration:
    - `ROLLOUT_WAIT=0 scripts/deploy.sh it-deploy` creates the namespace, Deployment and Services
    - `ROLLOUT_TIMEOUT=5 scripts/deploy.sh it-deploy` exits 2 (no nodes)
- **Acceptance:** `make test && make integration`
- **Commit:** `Make deploy script poll rollout status on Kubernetes 1.2`
  > kubectl 1.2 has neither rollout status nor the -n shorthand, so poll
  > Deployment status via jsonpath, including observedGeneration, and pass
  > --namespace explicitly. Resolve manifests relative to the script.

### T8: Refactor setup-cluster.sh for a 1.2 cluster

- **Goal:** Make cluster bootstrap idempotent without RBAC.
- **Files:**
  - modify `scripts/setup-cluster.sh`:
    - prerequisite checks honour `SKIP_DOCKER_CHECK`
    - a `NAMESPACES` loop
    - create the ServiceAccount `platform-sa` with `--namespace=production`, only if it is absent
    - remove the RBAC heredoc
    - run `helm init` when `HELM_HOST` is unset and `helm init --client-only` when it is set; remove the `--wait` flag, which does not exist in alpha.2
  - create `tests/unit/stubs/helm` and `tests/unit/stubs/docker`
  - create `tests/unit/setup-cluster.bats`
  - extend `tests/integration/scripts.bats`
- **Tests to write first:**
  - Unit:
    - a missing `helm` on PATH exits 1 with `helm required`
    - namespaces are created only when `get` fails
    - without `HELM_HOST` the helm stub log holds exactly one `init` line with no `--client-only`; with `HELM_HOST` it holds exactly one `init --client-only`
    - there is no `rbac.authorization.k8s.io` string in any kubectl input
    - there is no ` -n ` in any kubectl call
  - Integration:
    - `SKIP_DOCKER_CHECK=1 HELM_HOST=unused:1 scripts/setup-cluster.sh` twice in a row exits 0 both times
    - the namespaces exist, and `kubectl get serviceaccount platform-sa --namespace=production` exits 0

    The helm stub on PATH is used until T9.
- **Acceptance:** `make test && make integration`
- **Commit:** `Make cluster setup script idempotent and valid for Kubernetes 1.2`
  > Remove the RBAC binding, which needs Kubernetes 1.6, and helm init --wait,
  > which alpha.2 lacks. Use client-only init when HELM_HOST targets a
  > running Tiller.

### T9: Build Helm and Tiller v2.0.0-alpha.2 from source

- **Goal:** Provide the period Helm binaries, since no downloadable alpha.2 build survives.
- **Files:**
  - create `build/helm/Dockerfile` (build context `build/`):
    - `FROM golang:1.6.3@sha256:…`
    - install the CA deb
    - `COPY` glide v0.11.1 from `cache/` and run `sha256sum -c`
    - one single `RUN` that does all of the following, so the sources and caches never persist in a layer:
      - `git clone --branch v2.0.0-alpha.2 https://github.com/helm/helm /go/src/k8s.io/helm`
      - rewrite the `bitbucket.org/ww/goautoneg` entry in `glide.lock` to `repo: https://github.com/munnerz/goautoneg`, `vcs: git`, `version: a547fc61f48d567d5b4ec6f8aee5573d8efce11d`
      - `glide install`, retried up to 5 times inside the same `RUN` (glide clones dependencies in parallel and single clones fail intermittently over the network; repositories already fetched are reused)
      - `go install k8s.io/helm/cmd/helm k8s.io/helm/cmd/tiller`
      - `rm -rf /go/src/* /go/pkg ~/.glide`
  - modify `build/tools/Dockerfile`: `FROM kubernetes-platform:helm-v2.0.0-alpha.2`, then `RUN helm init --client-only` so `$HELM_HOME` exists
  - modify `Makefile`: `helm-image` runs `preflight`, then `docker build -t kubernetes-platform:helm-v2.0.0-alpha.2 -f build/helm/Dockerfile build/`; `tools-image` and `up` depend on `helm-image`
  - modify `docker-compose.yml`:
    - add the `tiller` service: `tiller --listen :44134 --namespace production`, with `KUBECONFIG=/go/src/github.com/Alexsovich5/kubernetes-platform/build/kubeconfig`
    - set `HELM_HOST=tiller:44134` on `tools`
  - create `tests/integration/helm.bats` (smoke part)
  - modify `tests/unit/harness.bats`
  - modify `tests/integration/scripts.bats`: drop the helm stub, so the setup-cluster test runs the real `helm init --client-only`
- **Tests to write first:**
  - Unit: the output of `helm version` equals `v2.0.0-alpha.2`. alpha.2 prints only the client version and has no `--client` flag.
  - Integration:
    - `helm list` exits 0 with `HELM_HOST=tiller:44134`
    - `curl -fs http://tiller:44135/readiness` succeeds
- **Acceptance:** `make preflight && make test && make integration`, then `docker image ls kubernetes-platform:helm-v2.0.0-alpha.2` shows an image under 1 GB
- **Commit:** `Build Helm and Tiller v2.0.0-alpha.2 from source for tooling`
  > No alpha.2 binaries remain downloadable, so compile them with glide in a
  > single layer, substituting a git mirror for the retired bitbucket
  > goautoneg repo.

### T10: Turn the chart into a working alpha.2 chart under helm/platform

- **Goal:** Make the chart lint, package and install through Tiller.
- **Files:**
  - `git mv helm/Chart.yaml helm/platform/Chart.yaml` and `git mv helm/values.yaml helm/platform/values.yaml`. alpha.2 lint and package require the directory name to equal Chart.yaml `name: platform`.
  - modify `helm/platform/Chart.yaml`: remove `apiVersion` and the maintainer entry; set `version: 0.1.0`
  - modify `helm/platform/values.yaml`: flat alpha.2 values per SPEC; remove `ingress`
  - create `helm/platform/.helmignore`
  - create `helm/platform/templates/_helpers.tpl` (`fullname`)
  - create `helm/platform/templates/deployment.yaml`, `service.yaml` and `configmap.yaml`:
    - top-level values (`{{.replicaCount}}`, `{{.image.repository}}`)
    - `heritage: {{.Release.Service}}` and `release: {{.Release.Name}}` labels on the Deployment and the pod template
    - the same strategy, probes and annotations as `k8s/`
  - modify `Makefile`: `ci-unit` adds
    - `helm lint helm/platform | tee /dev/stderr | grep -qx 'Lint OK'`
    - `cd /tmp && rm -f platform-0.1.0.tgz && helm package --save=false $(REPO)/helm/platform && test -f /tmp/platform-0.1.0.tgz`
  - create `tests/unit/helm-chart.bats`
  - extend `tests/integration/helm.bats`
- **Tests to write first:**
  - Unit (`helm-chart.bats`):
    - `helm lint helm/platform` output is exactly `Lint OK` (alpha.2 lint always exits 0, so the exit code is not checked)
    - a copy of the chart with `name` removed from Chart.yaml produces lint output other than `Lint OK`
    - `helm package --save=false` run from a temp directory produces `platform-0.1.0.tgz` there and writes nothing into the repo
  - Integration (`helm.bats`, releases land in Tiller's namespace `production`):
    - `helm install --dry-run --debug helm/platform` output contains `kind: Deployment` and `replicas: 3`
    - `helm install --name it-helm helm/platform` creates `deployment/it-helm-platform` in `production` with a ReplicaSet of 3 pods
    - `helm install --name it-helm-2 -f <tmp values with replicaCount: 2> helm/platform` gives 2 replicas
    - `helm delete it-helm` and `helm delete it-helm-2` remove the Deployments
    - teardown: `kubectl delete rs,pods -l release=it-helm --namespace=production` and the same for `it-helm-2`, because alpha.2 deletes leave the ReplicaSet and Pods orphaned
- **Acceptance:** `make test && make integration`
- **Commit:** `Move chart to helm/platform and add alpha.2 templates`
  > alpha.2 requires the chart directory to match the chart name. Provide
  > Deployment, Service and ConfigMap templates using top-level values. Lint
  > and package in unit tests; install via Tiller.

### T11: Add Prometheus 0.20 config, alert rules and Compose service

- **Goal:** Get working monitoring and alerting in period syntax.
- **Files:**
  - modify `build/SHA256SUMS` and `build/tools/Dockerfile`: add the prometheus and promtool 0.20.0 tarball from `cache/`
  - modify `prometheus/prometheus.yml`:
    - 0.20 `kubernetes_sd_configs` with `in_cluster: true` and `api_servers: ['https://kubernetes.default.svc']`
    - jobs `kubernetes-apiserver`, `kubernetes-nodes`, `kubernetes-pods` and `kubernetes-services`, keyed on `__meta_kubernetes_role` and `__meta_kubernetes_pod_annotation_prometheus_io_*`
    - fix the port rewrite with two source labels (`__address__` and the port annotation)
  - create `prometheus/alert_rules.yml`
  - create `prometheus/prometheus-local.yml`:
    - jobs `platform-app` (static `app:8080`) and `kubernetes-apiserver` (SD `api_servers: ['http://apiserver:8080']`)
    - `global: {scrape_interval: 5s, evaluation_interval: 5s}`
  - create `prometheus/alert_rules_local.yml`
  - modify `docker-compose.yml`: add the `prometheus` service (tools image, `prometheus -config.file=/etc/prometheus/prometheus-local.yml -storage.local.path=/prometheus`, port 9090). The command waits in a `bash -c` loop until `http://apiserver:8080/api/v1/pods` answers and then `exec`s Prometheus, because 0.20 Kubernetes SD stops discovering for good if its first list fails.
  - modify `Makefile`: `ci-unit` adds `promtool check-config` on both configs and `promtool check-rules` on both rule files
    - promtool 0.20 `check-config` stats `bearer_token_file` and `ca_file`. `prometheus.yml` points them at the in-cluster service-account mount, so `ci-unit` (and `tests/unit/prometheus.bats`) first create empty `token` and `ca.crt` files under `/var/run/secrets/kubernetes.io/serviceaccount`, as a pod would have.
  - create `tests/integration/prometheus.bats`
  - create `tests/integration/alerts/app-down.bats`
  - modify `Makefile`: after the main `bats tests/integration` run, `integration` runs `docker compose stop app` on the host, then `docker compose run --rm tools bats tests/integration/alerts`. A period docker CLI inside the container cannot talk to the modern daemon, so the stop step must run on the host.
- **Tests to write first:**
  - Unit: the promtool checks, plus a check that `prometheus-local.yml` contains `evaluation_interval: 5s`
  - Integration:
    - `/api/v1/query?query=up{job="platform-app"}` returns value `1`
    - `up{job="kubernetes-apiserver"}` returns `1`
    - `alerts/app-down.bats`: with the app stopped, `ALERTS{alertname="PlatformAppDown",alertstate="firing"}` is non-empty within 60 s
- **Acceptance:** `make test && make integration`
- **Commit:** `Add Prometheus 0.20 scrape config, alert rules and compose service`
  > Rewrite Kubernetes SD in 0.20 syntax and add the missing alert rules.
  > A compose Prometheus scrapes platform-app and the local apiserver.

### T12: Refactor monitoring manifest and keep it in sync

- **Goal:** Make `k8s/monitoring.yaml` deployable on 1.2 and consistent with `prometheus/`.
- **Files:**
  - modify `k8s/monitoring.yaml`:
    - add a `Namespace monitoring` document first
    - the ConfigMap `prometheus-config` holds `prometheus.yml` and `alert_rules.yml` verbatim
    - image `prom/prometheus:0.20.0`
    - args `-config.file=/etc/prometheus/prometheus.yml -storage.local.path=/prometheus`
    - NodePort 30090 kept
  - modify `scripts/deploy.sh`: remove the out-of-band `create namespace monitoring`
  - modify `tests/unit/deploy.bats`
  - modify `tests/manifests/manifests_test.go`: ConfigMap data must equal the files byte for byte
  - create `tests/integration/monitoring.bats`
- **Tests to write first:**
  - Unit: the sync test, which fails until the ConfigMap is regenerated; no `v1.x` Prometheus image tag
  - Integration: `kubectl apply -f k8s/monitoring.yaml` creates `ns/monitoring`, `configmap/prometheus-config`, `deployment/prometheus` with 1 desired replica, and `svc/prometheus` with nodePort 30090
- **Acceptance:** `make test && make integration`
- **Commit:** `Align monitoring manifest with Prometheus 0.20 config`
  > Embed the repo's prometheus.yml and alert rules verbatim, pin the
  > 0.20.0 image and create the monitoring namespace in the manifest.

### T13: Add end-to-end test of the documented workflow

- **Goal:** Prove the setup, Helm install and monitoring sequence works start to finish.
- **Files:**
  - create `tests/integration/e2e.bats`
  - modify `Makefile`: add `test-all` (runs `test` then `integration`)
- **Tests to write first** (`e2e.bats`), each against the live stack:
  1. `SKIP_DOCKER_CHECK=1 scripts/setup-cluster.sh`
  2. `helm install --name platform helm/platform`. There is no `--namespace` flag, because the release lands in Tiller's namespace `production`.
  3. `kubectl apply -f k8s/monitoring.yaml`
  4. assert:
     - `kubectl get deployment platform-platform --namespace=production -o jsonpath='{.spec.replicas}'` is `3`
     - `svc/prometheus` exists in `monitoring`
     - the compose Prometheus still reports `up{job="kubernetes-apiserver"} == 1`
  5. teardown: `helm delete platform`, then `kubectl delete rs,pods -l release=platform --namespace=production`

  `platform` is used as a release name only in this file. alpha.2 never frees a deleted release name while Tiller runs, and `helm.bats` uses `it-helm`/`it-helm-2`, so file order does not matter.
- **Acceptance:** `make test-all`
- **Commit:** `Add end-to-end test for setup, helm install and monitoring`
  > Exercise the documented workflow in order against the compose control
  > plane and add a test-all target that runs unit and integration suites.

### T14: Regenerate README from template

- **Goal:** Write an honest README that follows `tools/readme_template.md`.
- **Files:** modify `README.md`.
- **README contents:**
  - title and a one-paragraph description
  - "Personal project built on the 2016-era stack (Kubernetes 1.2.6, Helm 2.0.0-alpha.2, Prometheus 0.20.0, Go 1.6.3)"
  - Implemented bullets that map to SPEC items 1 to 11 and their tests
  - Not implemented: every Out-of-scope row except the one about dropped business-impact, status and employer statements (it is not repeated in the README), plus explicit mock statements:
    - "Kubernetes nodes are simulated by a kubelet-less 1.2 control plane; pods are created but never run."
    - "No cloud load balancer; LoadBalancer services never receive an external IP."
    - "Tiller runs as a compose service rather than in-cluster, and every release is installed into its namespace (production)."
    - "Script unit tests stub kubectl/helm/docker."
  - Known limitations from the SPEC (release-name reuse, orphaned ReplicaSets after `helm delete`, post-period CA bundle in the build images)
  - Built with: the pinned versions
  - Running it: `make up` (fetches release files, builds `kp-helm` then `kp-tools`, starts Compose), with smoke command `curl -s localhost:8080/ && curl -s 'localhost:9090/api/v1/query?query=up'`, and `make down` to stop
  - Tests: `make test`, and `make integration`/`make test-all`
  - Layout: the output of `{ git ls-files | grep -v '^vendor/'; echo 'vendor/  (glide-managed, not listed)'; }` inside a code block
  - No badges, employer, role, dates or metrics. Remove the template comment block.
- **Tests to write first:** `tests/unit/readme.bats`:
  - every path in the Layout block, except the `vendor/` line, exists (`test -e`)
  - `grep -ciE 'uptime|MTTR|availability %|cost reduction|developed during|career portfolio|timeline|status-complete' README.md` prints `0`
  - Employer and personal names are not written into any repo file. At review time they are checked with the external tools grep, outside the repo.
- **Acceptance:** `make test`
- **Commit:** `Rewrite README from template with honest status and layout`
  > Describe what is implemented, what is simulated and what is out of
  > scope, with a file layout generated from git ls-files.
