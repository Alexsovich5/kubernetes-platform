# kubernetes-platform: Specification

Target period: March to July 2016. Every dependency is pinned to a release dated on or before 2016-07-31.

## Problem

Taking a containerised service from source to a monitored Kubernetes deployment in 2016 involved several loosely connected pieces: an application image, Kubernetes manifests, a Helm chart, cluster bootstrap and deploy scripts, and a Prometheus configuration that finds the workload. The current repository has those pieces only as unvalidated YAML and shell. The Dockerfile builds a Node app (`server.js`, `package.json`) that does not exist. Several files use API versions and config syntax from 2017 or later: RBAC `v1beta1`, Prometheus `role:` SD and `prom/prometheus:v1.7.0`. The deploy script calls `kubectl rollout status` and `kubectl -n`, and Kubernetes 1.2 has neither (kubectl 1.2 has no `-n` shorthand for `--namespace`).

This project rebuilds the repository as a small, working platform kit on the 2016 stack. It includes:

- a Go 1.6 sample workload that exposes health and Prometheus metrics
- manifests and a Helm 2 (alpha.2) chart that a real Kubernetes 1.2 control plane accepts
- scripts that bootstrap and deploy to that control plane
- a Prometheus 0.20 configuration with alert rules

All of it runs and is tested inside Docker.

## In scope

1. **Sample workload `platform-app` (Go 1.6).** An HTTP service on `:8080`:
   - `GET /` returns JSON `{hostname, version, message}`, where `message` comes from a ConfigMap-mounted file.
   - `GET /health` returns 200, or 503 while draining.
   - `GET /metrics` serves Prometheus metrics.
   - On SIGTERM it fails `/health`, waits `DRAIN_SECONDS`, then exits. The drain is intended to support rolling updates without dropped requests. That cannot be shown end to end here because pods never run (see Known limitations). A Go unit test covers the signal path.
2. **Container image.** The root `Dockerfile` builds `platform-app` from `golang:1.6.3@sha256:9bc3717d167110a13be0ca34936a1d2d509f1775499649a6be616330ab20dbd1` and replaces the broken Node Dockerfile.
3. **Kubernetes 1.2 manifests (`k8s/`).**
   - A Deployment (`extensions/v1beta1`) with a RollingUpdate strategy (`maxSurge: 1`, `maxUnavailable: 0`), readiness and liveness probes on `/health`, resource requests and limits, and `prometheus.io/*` pod annotations.
   - A ConfigMap.
   - A LoadBalancer Service and a ClusterIP Service.
4. **Self-healing, scaling and rolling update behaviour, shown on a real 1.2 control plane.**
   - The ReplicaSet controller recreates deleted pods.
   - `kubectl scale deployment platform-app --replicas=5` brings the ReplicaSet to 5 pods.
   - An image change creates a new ReplicaSet that follows `maxSurge`/`maxUnavailable`.
   - `kubectl rollout undo` reverts the change.
5. **Helm 2 chart (`helm/platform/`).** `Chart.yaml`, `values.yaml`, `.helmignore` and `templates/` (Deployment, Service, ConfigMap, `_helpers.tpl`) use the alpha.2 template contract, where values sit at the top level (`.replicaCount`, not `.Values.replicaCount`). The chart directory is named `platform` because alpha.2 `helm lint` and `helm package` require the directory name to equal the Chart.yaml `name`.
   - `helm lint helm/platform` prints exactly `Lint OK`. alpha.2 lint always exits 0, so the output is what gets checked.
   - `helm package --save=false helm/platform`, run from `/tmp`, writes `/tmp/platform-0.1.0.tgz`.
   - `helm install --name platform helm/platform` installs through Tiller. alpha.2 has no install namespace: every release goes into Tiller's own namespace, which the Compose Tiller sets to `production`.
6. **Cluster setup script (`scripts/setup-cluster.sh`).**
   - Checks prerequisites (`kubectl`, `helm`, `docker`, with `docker` skippable).
   - Creates the `production`, `staging` and `monitoring` namespaces idempotently.
   - Creates the `platform-sa` ServiceAccount.
   - Runs `helm init` when `HELM_HOST` is unset. When `HELM_HOST` points at an existing Tiller, it runs `helm init --client-only`, which creates `$HELM_HOME` without installing Tiller.
   - Every kubectl call uses `--namespace=<ns>`.
7. **Deploy script (`scripts/deploy.sh [namespace]`).**
   - Creates the namespace, applies the app manifests and the monitoring stack.
   - Waits for the rollout by polling Deployment status with `jsonpath` against `ROLLOUT_TIMEOUT`. Kubernetes 1.2 has no `rollout status`. The poll requires `status.observedGeneration == metadata.generation`, so stale status right after an apply is not reported as success.
   - `ROLLOUT_WAIT=0` skips the wait.
   - Every kubectl call uses `--namespace=<ns>`.
8. **Prometheus 0.20 monitoring (`prometheus/`).**
   - `prometheus.yml`: in-cluster Kubernetes SD in 0.20 syntax (`api_servers`, `in_cluster`, relabelling on `__meta_kubernetes_role`) for the apiserver, nodes, annotated pods and annotated services.
   - `alert_rules.yml`: 0.x rule syntax (`ALERT … IF … FOR … LABELS … ANNOTATIONS`). The file is referenced today but missing.
   - `prometheus-local.yml`: the Docker Compose variant, which scrapes `platform-app` statically and discovers the local apiserver through Kubernetes SD.
9. **Monitoring stack manifest (`k8s/monitoring.yaml`).** Creates the `monitoring` Namespace, a ConfigMap whose content is kept byte-identical to `prometheus/prometheus.yml` and `prometheus/alert_rules.yml` by a test, a Prometheus 0.20.0 Deployment, and a NodePort Service on 30090.
10. **Local runnable stack (`docker-compose.yml`, file format v2):**
    - etcd 2.2.5
    - kube-apiserver 1.2.6, plus kube-controller-manager and kube-scheduler 1.2.6 in the apiserver's network namespace (`network_mode: "service:apiserver"`, `--master=http://127.0.0.1:8080`). kube-apiserver 1.2 health-checks them at the hard-coded `127.0.0.1:10252` and `127.0.0.1:10251`.
    - Tiller v2.0.0-alpha.2 (`tiller --listen :44134 --namespace production`)
    - `platform-app`
    - Prometheus 0.20.0

    `make up` fetches the release files, builds `kp-helm` and then `kp-tools` in that order, and runs `docker compose up -d --build`. A plain `docker compose up` on a fresh clone fails, because `kp-tools` is built `FROM` the local `kp-helm` tag.
11. **Test harness.** `make test` runs gofmt, `go vet`, the Go unit tests, the manifest invariant tests, the bats script tests with stubbed CLIs, `helm lint`/`helm package` and `promtool check-config`/`check-rules`, all inside the period tools image. `make integration` runs bats suites against the Compose stack.

## Out of scope

| Original README item | Reason |
|---|---|
| Running pods on real nodes (kubelet) | kubelet 1.2 cannot run on the host's cgroup v2 kernel with a Docker 29 daemon, whose minimum API version is above what kubelet 1.2 speaks. The control plane is real, but pods stay `Pending` (see Simulated integrations). |
| Cloud LoadBalancer provisioning | There is no cloud provider. The apiserver accepts `type: LoadBalancer` and allocates a nodePort, but no external IP is ever assigned. |
| RBAC ClusterRoleBinding in `setup-cluster.sh` | RBAC does not exist in Kubernetes 1.2 (alpha in 1.3, `v1beta1` in 1.6). The script creates only the ServiceAccount. |
| `platform-worker` Deployment and `QUEUE_URL` | Not described in the original README, and it depends on a queue system that the README never defines. |
| `DB_HOST` secret in the Deployment | Not described in the README, and the project has no database. |
| Ingress (`ingress.enabled` in values) | Disabled in the original, and there is no ingress controller to run in 2016 without a kubelet. The key is removed. |
| Alertmanager notification routing | The README asks only for "monitoring and alerting". Rules are evaluated and exposed as `ALERTS` in Prometheus, and nothing pages. |
| `helm upgrade` | The command does not exist in Helm v2.0.0-alpha.2. Upgrades are done by re-applying manifests or installing a release under a new name. |
| Docker 1.10 engine | The host runs a modern engine. Dockerfiles and Compose stay within Docker 1.10 and Compose 1.6 features (no multi-stage builds, no `ARG` before `FROM`, Compose file format `2`). |
| Business-impact percentages, status badge and employer/role/date statements from the original README | Unmeasurable. Dropped. |
| Pushing images to a registry | No registry exists in the period stack or in the README. Images are built and tagged locally as `platform-app:0.1.0`. |

## Architecture

```
                         docker compose (network: kp)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │                                                                           │
 │  etcd:2379 ◄── kube-apiserver:8080 ─┐ shared network namespace            │
 │  (2.2.5)       (1.2.6, insecure)    ├ kube-controller-manager (:10252)    │
 │                     ▲   ▲   ▲       └ kube-scheduler (:10251)             │
 │        kubectl apply│   │   │ kubernetes_sd (role=apiserver)              │
 │   scripts/*.sh ─────┘   │   │                                             │
 │                tiller:44134 │             platform-app:8080  ◄── scrape ──┤
 │  helm (HELM_HOST) ─►(alpha.2, ns production) (Go 1.6, /metrics)           │
 │                             └──────────── prometheus:9090 ────────────────┘
 │                                           (0.20.0, rules → ALERTS)        │
 │  tools container (kp-tools): go, glide, bats, kubectl, helm, promtool     │
 └───────────────────────────────────────────────────────────────────────────┘
```

Data flow:

1. `setup-cluster.sh` creates the namespaces and the ServiceAccount through the apiserver.
2. `helm install --name platform helm/platform` sends the chart to Tiller. Tiller renders it and creates the Deployment, Service and ConfigMap in its own namespace (`production`) through the apiserver.
3. Alternatively, `deploy.sh` applies `k8s/*.yaml` directly.
4. The controller-manager creates ReplicaSets and Pods. The pods stay Pending because no node exists.
5. In Compose, `platform-app` runs as a container. Prometheus scrapes it statically and discovers the apiserver through Kubernetes SD.
6. `alert_rules.yml` turns `up == 0` into a `PlatformAppDown` alert.

Images (all built locally from `golang:1.6.3@sha256:9bc3717d…dbd1`):

- `platform-app:0.1.0` — root `Dockerfile`, build context `.`.
- `kp-helm:v2.0.0-alpha.2` — `build/helm/Dockerfile`, build context `build/`. Builds the `helm` and `tiller` binaries from source at tag `v2.0.0-alpha.2`. Clone, glide install, `go install` and the removal of `/go/src/*`, `/go/pkg` and `~/.glide` happen in one `RUN`, so only the two binaries stay in the image.
- `kp-tools:2016` — `build/tools/Dockerfile`, build context `build/`, `FROM kp-helm:v2.0.0-alpha.2`. Adds bats, glide, etcd, the Kubernetes binaries and Prometheus/promtool from `build/cache/`, and runs `helm init --client-only` so `$HELM_HOME` exists. The control-plane, Tiller and Prometheus services in Compose run from this image with different commands.

Before T9, `kp-tools` is `FROM golang:1.6.3@sha256:…`.

Build inputs: `make fetch` downloads every release file on the host into the git-ignored `build/cache/` and checks it with `sha256sum -c build/SHA256SUMS` (the values below). Dockerfiles `COPY` the files from `build/cache/` and run `sha256sum -c` again. No Dockerfile downloads a tarball.

## Data model & interfaces

**platform-app** (`github.com/Alexsovich5/kubernetes-platform`, GOPATH layout, `vendor/` managed by glide):

```
cmd/platform-app/main.go   // wires env, signal.Notify(SIGTERM) and os.Exit into RunDrain
pkg/app/config.go   func LoadConfig(dir string) (map[string]string, error)
                    // each regular file in dir → key=filename, value=trimmed contents;
                    // missing dir → empty map, nil error; hidden files (..data symlinks) skipped
pkg/app/server.go   type Server struct { Version, Hostname string; Config map[string]string; draining int32 }
                    func NewServer(version string, cfg map[string]string) *Server
                    func (s *Server) Handler() http.Handler   // /, /health, /metrics
                    func (s *Server) StartDrain()             // /health → 503
pkg/app/drain.go    func RunDrain(s *Server, sigs <-chan os.Signal, d time.Duration, exit func(int))
                    // blocks for one signal, calls StartDrain, sleeps d, calls exit(0)
```

Environment:

| Variable | Default | Purpose |
|---|---|---|
| `LISTEN_ADDR` | `:8080` | Address the HTTP server binds to |
| `CONFIG_DIR` | `/app/config` | Directory holding the ConfigMap files |
| `DRAIN_SECONDS` | `5` | Seconds to fail `/health` after SIGTERM before exiting |

`version` is set with `-ldflags "-X main.version=0.1.0"`.

HTTP:

- `GET /` → `200 {"hostname":"…","version":"0.1.0","message":"<CONFIG_DIR/message or \"hello\">"}`
- `GET /health` → `200 ok` or `503 draining`
- `GET /metrics` → Prometheus text format: `http_requests_total{handler,method,code}` and the `http_request_duration_microseconds` summary from `prometheus.InstrumentHandler`, plus the Go and process collectors.

**Helm values (`helm/platform/values.yaml`, alpha.2, top-level):**

```yaml
replicaCount: 3
image: {repository: platform-app, tag: "0.1.0", pullPolicy: IfNotPresent}
service: {type: LoadBalancer, port: 80, targetPort: 8080}
resources: {requests: {cpu: 250m, memory: 256Mi}, limits: {cpu: 500m, memory: 512Mi}}
message: "hello from helm"
monitoring: {enabled: true}      # adds prometheus.io/scrape|port|path pod annotations
```

Chart templates put `heritage: {{.Release.Service}}` and `release: {{.Release.Name}}` on the Deployment and on the pod template, so ReplicaSets and Pods carry the `release` label.

**Scripts:**

- `scripts/setup-cluster.sh`
  - Environment: `SKIP_DOCKER_CHECK=1`, `HELM_HOST`, `NAMESPACES` (default `"production staging monitoring"`).
  - Exits 1 with `"<tool> required"` when a prerequisite is missing.
  - Runs `helm init` without `HELM_HOST` and `helm init --client-only` with it.
- `scripts/deploy.sh [namespace]`
  - Environment: `ROLLOUT_WAIT` (default 1), `ROLLOUT_TIMEOUT` (seconds, default 300), `KUBECTL` (default `kubectl`).
  - Polls `-o jsonpath='{.status.observedGeneration} {.metadata.generation} {.status.updatedReplicas} {.status.availableReplicas} {.spec.replicas}'`.
  - Exits 0 when `observedGeneration == generation` and `updatedReplicas == availableReplicas == spec.replicas`.
  - Exits 2 with `"rollout timed out"` when the timeout is reached.
  - Resolves manifest paths relative to the script, not the working directory.
- Both scripts pass the namespace as `--namespace=<ns>`, never `-n`, which kubectl 1.2 rejects.

**Kubernetes labels:** `app: platform`, `tier: backend`. Services select on both. Pod annotations: `prometheus.io/scrape: "true"`, `prometheus.io/port: "8080"`, `prometheus.io/path: /metrics`.

**Prometheus rules (`prometheus/alert_rules.yml`, 0.x syntax):**

```
ALERT PlatformAppDown
  IF up{job="platform-app"} == 0
  FOR 30s
  LABELS { severity = "page" }
  ANNOTATIONS { summary = "platform-app instance {{ $labels.instance }} down" }

ALERT PlatformAppHighErrorRate
  IF sum(rate(http_requests_total{job="platform-app",code=~"5.."}[5m])) / sum(rate(http_requests_total{job="platform-app"}[5m])) > 0.05
  FOR 5m
  LABELS { severity = "warning" }
  ANNOTATIONS { summary = "platform-app 5xx ratio above 5%" }
```

`prometheus-local.yml` uses `scrape_interval: 5s` and `evaluation_interval: 5s`, and loads `alert_rules_local.yml`, a copy of the rules with `FOR 10s`, so the integration test finishes quickly.

**Kubeconfig for tools and Tiller (`build/kubeconfig`):** a single cluster `local` with `server: http://apiserver:8080`, no auth. This is the 1.2 insecure port, and only the Compose network can reach it.

## Stack & pinned versions

| Component | Version | Released | Why it was the popular choice then |
|---|---|---|---|
| Go | 1.6.3 | 2016-07-17 | Current stable Go. The vendor directory is on by default in 1.6. |
| Kubernetes (apiserver, controller-manager, scheduler, kubectl) | v1.2.6 | 2016-07-15 | The README targets 1.2. This is the last 1.2 patch in the period, and Deployments and ConfigMaps are beta and enabled by default. |
| etcd | v2.2.5 | 2016-02-01 | The etcd line that Kubernetes 1.2 was built and tested against (etcd2 API). |
| Helm / Tiller | v2.0.0-alpha.2 | 2016-06-23 | The newest Helm 2 release in the period. It introduced YAML `values.yaml`, which matches the existing chart. alpha.3 came out on 2016-08-10, after the period. |
| Prometheus + promtool | 0.20.0 | 2016-06-15 | The last 0.x release. 1.0.0 (2016-07-18) is in period, but the target stack specifies 0.x. It has Kubernetes SD and the 0.x rule language. |
| glide | v0.11.1 | 2016-07-21 | The dominant Go vendoring tool in mid-2016. Helm itself used it. |
| bats | v0.4.0 | 2014-08-13 | The standard shell-script test runner of the time. |
| github.com/prometheus/client_golang | tag `0.7.0` (commit 6dbab81, `v0.0.0-20150727152018-6dbab8106ed3`) | 2015-07-27 | The last tagged client release before 0.8.0 (2016-08-17). Provides `InstrumentHandler`. |
| github.com/prometheus/client_model | fa8ad6f (`v0.0.0-20150212101744-fa8ad6fec335`) | 2015-02-12 | Transitive dependency of client_golang. |
| github.com/prometheus/procfs | c91d8ee (`v0.0.0-20150616144631-c91d8eefde16`) | 2015-06-16 | Transitive (process collector). |
| github.com/beorn7/perks | b965b61 (`v0.0.0-20150223135152-b965b613227f`) | 2015-02-23 | Transitive (summary quantiles). |
| github.com/golang/protobuf | f0a097d (`v0.0.0-20160413040752-f0a097ddac24`) | 2016-04-13 | Transitive. The same commit Helm alpha.2 pins. |
| github.com/matttproud/golang_protobuf_extensions | v1.0.0 | 2016-04-23 | Transitive (pbutil). |
| bitbucket.org/ww/goautoneg, fetched from `https://github.com/munnerz/goautoneg` (`vcs: git`) | a547fc61f48d567d5b4ec6f8aee5573d8efce11d (`v0.0.0-20120707110453-a547fc61f48d`) | 2012-07-07 | Imported directly by client_golang 0.7.0 (`prometheus/registry.go`). The original Mercurial repository (Godeps rev `75cd24fc2f2c`) no longer exists. This git mirror carries the same changeset. |
| gopkg.in/yaml.v2 | e4d366f (`v2.0.0-20160715033755-e4d366fc3c79`) | 2016-07-15 | The standard Go YAML library. Used only by the manifest invariant tests. |
| k8s.io/helm (build input for kp-helm) | v2.0.0-alpha.2 | 2016-06-23 | See Helm above. Built from source because no binaries survive. |
| Docker Compose file format | 2 | Compose 1.6 (2016-02) | Current at the time. Networks, named volumes and `network_mode: service:`. |

The Go pins above were checked with `tools/check_period.py` against a temporary `go.mod` (goautoneg listed under its mirror path `github.com/munnerz/goautoneg`), and it exited 0 with 8 checked and 0 problems. The repository uses `glide.yaml`/`glide.lock` and not `go.mod`, because Go modules did not exist until 2018.

`glide.yaml` pins every package in this table explicitly, the transitive ones included. Otherwise glide would take client_golang 0.7.0's Godeps pins (procfs `6c34ef8`, protobuf `c22ae3c`, pbutil `fc2b8d3`) and the lock would not match this table. Every `glide.lock` entry must be a commit dated on or before 2016-07-31. Task T2 checks this with `build/lock_dates.py`.

Binary downloads (fetched on the host by `make fetch`, listed with their sha256 in `build/SHA256SUMS`; hashes computed on 2026-09-23 from these URLs):

| File | URL | sha256 |
|---|---|---|
| `kubectl` | `https://storage.googleapis.com/kubernetes-release/release/v1.2.6/bin/linux/amd64/kubectl` | `7ffe8d6867ec8f3d82e6ff12560580b03c056d7afcadaddd011283ca7bd453c3` |
| `kube-apiserver` | `…/v1.2.6/bin/linux/amd64/kube-apiserver` | `c142555c9394a248d0e620c773b37d0a138626ea326035c253ac10d0adcaf864` |
| `kube-controller-manager` | `…/v1.2.6/bin/linux/amd64/kube-controller-manager` | `367fc7d8f7bfbae30e2d5579727fe1f704c87fd07c14319d0558ae842d4b2f07` |
| `kube-scheduler` | `…/v1.2.6/bin/linux/amd64/kube-scheduler` | `e16fb12b1e197732086a038aa7921b8bd739b9ac98085040b69ea63d795c0c7e` |
| `etcd-v2.2.5-linux-amd64.tar.gz` | `https://github.com/etcd-io/etcd/releases/download/v2.2.5/etcd-v2.2.5-linux-amd64.tar.gz` | `aa6037406257d2a1bc48ffa769afe7a4f8a04cc1ffcd36ef84f9ee8bc4eca756` |
| `prometheus-0.20.0.linux-amd64.tar.gz` | `https://github.com/prometheus/prometheus/releases/download/0.20.0/prometheus-0.20.0.linux-amd64.tar.gz` | `660ba94efb1f4cff4934dc55bfe1b920f9bc4630bf731de4a67599b048c42c5c` |
| `glide-v0.11.1-linux-amd64.tar.gz` | `https://github.com/Masterminds/glide/releases/download/v0.11.1/glide-v0.11.1-linux-amd64.tar.gz` | `de0c7870738c6bc11128761d53a99ad68687b0a213fe52cea15ad05d93f10e42` |
| `bats-v0.4.0.tar.gz` | `https://github.com/sstephenson/bats/archive/v0.4.0.tar.gz` | `480d8d64f1681eee78d1002527f3f06e1ac01e173b761bc73d0cf33f4dc1d8d7` |
| `ca-certificates_20141019+deb8u4_all.deb` | `http://snapshot.debian.org/archive/debian-security/20180707T093525Z/pool/updates/main/c/ca-certificates/ca-certificates_20141019%2Bdeb8u4_all.deb` | `df55d3ec4f25868d367471411be80a3a117d152419f505068893bfc0f76fa817` |

- **Build-time trust store (a documented exception to the period rule).** `golang:1.6.3` ships jessie `ca-certificates 20141019+deb8u1`, which lacks `ISRG_Root_X1`. Today's GitHub release-asset and git endpoints chain to roots that store may not trust. `glide install` (T2, T9) and `git clone` (T9) run inside the images over HTTPS. Both `build/tools/Dockerfile` and `build/helm/Dockerfile` therefore `dpkg -i` the jessie package `20141019+deb8u4` (first seen on snapshot.debian.org on 2018-07-07; it contains `ISRG_Root_X1.crt`) before any HTTPS access. This package is post-period. It affects only which roots the build trusts, never the project's code or runtime dependencies. The T1 harness test checks HTTPS from inside the image. The failure could not be reproduced here because the host Docker disk was full, so it was not confirmed by pulling.
- Helm alpha.2 binaries are gone: GCS `kubernetes-helm` returns 403, `get.helm.sh` returns 404, and the GitHub release has no assets. `build/helm/Dockerfile` builds them from `git clone --branch v2.0.0-alpha.2 https://github.com/helm/helm $GOPATH/src/k8s.io/helm` with `glide install`.
  - Helm's `glide.lock` pins `bitbucket.org/ww/goautoneg` at hg revision `75cd24fc2f2c`, and that Mercurial repository no longer exists. Before `glide install`, the Dockerfile rewrites the entry to `repo: https://github.com/munnerz/goautoneg`, `vcs: git`, `version: a547fc61f48d567d5b4ec6f8aee5573d8efce11d`. The app's own `glide.yaml` uses the same override (see the pin table).

## Docker images

| Image | Tag / digest | Hub check (2026-09-23) | Pull on the host (Docker 29.6.2, amd64) | Use |
|---|---|---|---|---|
| `golang` | `1.6.3@sha256:9bc3717d167110a13be0ca34936a1d2d509f1775499649a6be616330ab20dbd1` | 200. Schema-2 manifest (`application/vnd.docker.distribution.manifest.v2+json`), digest confirmed via `registry-1.docker.io`. `tag_last_pushed` 2016-12-01. | pulled OK earlier. Not re-pulled because the host Docker disk is full. | Base for every image in this repo. The toolchain is Go 1.6.3 (2016-07-17), but this image build dates from 2016-12-01, after the period. It is the only surviving 1.6.3 image. Every `FROM` pins it by digest. |
| `golang` | `1.6` | 200. `tag_last_pushed` 2017-02-16. | not used | A floating tag that last moved in 2017-02 (Go 1.6.4 on jessie). Not used. |
| `prom/prometheus` | `0.20.0` | 200 | **fails**: schema-1 manifest (`application/vnd.docker.distribution.manifest.v1+prettyjws`) that Docker 28.2 and later cannot pull | Referenced only inside `k8s/monitoring.yaml`, as a 2016 cluster would. Locally, Prometheus runs from the 0.20.0 release tarball inside `kp-tools`. |

No other registry images are used. etcd, Kubernetes, Helm and Prometheus all come from release binaries or source builds on top of `golang:1.6.3`. All images are amd64 only.

**Disk budget.** The kp-helm build clones `k8s.io/kubernetes` and about 40 other repositories, several GB at peak. `make preflight` runs before any image build. It prints `docker system df` and `docker volume ls -qf dangling=true`. It then runs `df -Pk /` in a throwaway `golang:1.6.3@sha256:…` container and fails when less than 15 GB is free in the Docker VM. `make integration` ends with `docker compose down -v` and `docker image prune -f`.

## Simulated/mocked integrations

| Real system | Replacement | Notes |
|---|---|---|
| Kubernetes worker nodes (kubelet, container runtime) | **Kubelet-less control plane.** Real kube-apiserver, controller-manager and scheduler 1.2.6 on etcd 2.2.5 in Compose, with no nodes registered. | Pods are created by the real controllers and stay `Pending`. Self-healing, scaling and rolling-update tests assert controller behaviour (ReplicaSet and Pod object counts), not running containers. |
| Cloud load balancer (`type: LoadBalancer`) | None. The apiserver allocates the nodePort, and the external IP stays `<pending>`. | Documented as a limitation. |
| Tiller in-cluster (`helm init`) | Tiller alpha.2 as a Compose service (`--namespace production`), reached with `HELM_HOST=tiller:44134` and using `build/kubeconfig`. | `setup-cluster.sh` still supports `helm init` for a real cluster. That path is untested. |
| Kubernetes-hosted Prometheus | Prometheus 0.20.0 as a Compose service, using `prometheus-local.yml`. | The Kubernetes SD part of the config runs for real against the local apiserver (role `apiserver`). |
| `kubectl`, `helm` and `docker` in the script unit tests | **bats stubs** in `tests/unit/stubs/` that record their arguments to `$STUB_LOG` and return canned output | Integration tests run the same scripts against the real control plane. |

The final README must say that nodes, the cloud LB and in-cluster Tiller are simulated or absent, as described above.

## Existing code inventory

| File | Decision | Reason |
|---|---|---|
| `Dockerfile` | refactor | It builds a nonexistent Node app (`node:4-slim`, `server.js`). Rewrite it to build `platform-app` from `golang:1.6.3@sha256:…`, keeping port 8080 and the single-stage layout. |
| `README.md` | refactor | Regenerated in the last task from `tools/readme_template.md`, with honest status and the git-derived layout. |
| `helm/Chart.yaml` | refactor + move to `helm/platform/Chart.yaml` | alpha.2 lint and package require the chart directory to be named after the chart (`platform`). Keep `name`, `description` and `home`. Remove `apiVersion` (not part of the alpha.2 chart metadata). Remove the maintainer name, which came from the generated README. Set `version: 0.1.0`. |
| `helm/values.yaml` | refactor + move to `helm/platform/values.yaml` | Same directory rule. Keep replicas, image, service and resources. Pin the image tag to `0.1.0` instead of `latest`. Add `message`. Remove `ingress` and `monitoring.prometheus.scrapeInterval` (no template can use them). |
| `k8s/deployment.yaml` | refactor | Keep the app Deployment (strategy, probes, resources and ConfigMap mount are correct for 1.2). Remove the worker Deployment, the `DB_HOST` secret (out of scope) and the leftover `NODE_ENV=production` env var from the Node-era app, which the Go workload does not use. Pin the image and add Prometheus annotations. |
| `k8s/service.yaml` | keep | Both Services are valid in 1.2 and select the right labels. |
| `k8s/monitoring.yaml` | refactor | Replace `prom/prometheus:v1.7.0` (2017) with `0.20.0` and the `role:` SD syntax (Prometheus 1.3+) with 0.20 syntax. Add the Namespace object and alert rules. The deploy script previously created the namespace out of band. |
| `prometheus/prometheus.yml` | refactor | Convert to 0.20 `kubernetes_sd_configs` (`api_servers`, `in_cluster`, `__meta_kubernetes_role`). Fix the pod-port relabel, which uses `${1}:${2}` with only one source label. Its `alert_rules.yml` reference becomes real. |
| `scripts/deploy.sh` | refactor | Keep its flow (namespace, apply, monitoring, wait, list pods). Replace every `-n "$NAMESPACE"` with `--namespace="$NAMESPACE"`, because kubectl 1.2 has no `-n` shorthand. Replace `kubectl rollout status --timeout`, which does not exist in 1.2, with a jsonpath poll that also compares `observedGeneration` with `generation`. Resolve paths relative to the script. Add `ROLLOUT_WAIT` and `ROLLOUT_TIMEOUT`. |
| `scripts/setup-cluster.sh` | refactor | Keep the prerequisite checks and namespace loop. Remove the RBAC `v1beta1` ClusterRoleBinding (not in 1.2) and `helm init --wait` (the flag is not in alpha.2). Add `HELM_HOST`, which switches to `helm init --client-only`, and `SKIP_DOCKER_CHECK`. Use `--namespace=` on every kubectl call. |

No existing file is deleted. The two chart files move from `helm/` to `helm/platform/` with `git mv`. The worker Deployment is removed from inside `k8s/deployment.yaml`.

## Test strategy

- **Go unit tests** (`go test ./pkg/... ./tests/manifests/...`, standard `testing` and `net/http/httptest`):
  - `LoadConfig`: missing directory, regular files, skipped `..data` symlink entries, value trimming.
  - Handlers: `/` JSON shape and message fallback, `/health` 200 then 503 after `StartDrain`, and `/metrics` containing `http_requests_total` after a request.
  - `RunDrain`: `syscall.SIGTERM` sent on an injected channel with `d = 0` makes `/health` return 503 and calls the injected `exit` with 0.
- **Manifest invariant tests** (`tests/manifests`, Go with yaml.v2). They check `k8s/*.yaml`:
  - Service selectors match the Deployment template labels.
  - Probes target `/health` on the container port.
  - Every container has requests and limits.
  - The strategy is RollingUpdate with surge 1 and unavailable 0.
  - The Prometheus annotations are present.
  - No `latest` image tags, and no `NODE_ENV` env var.
  - The `k8s/monitoring.yaml` ConfigMap data is byte-equal to `prometheus/prometheus.yml` and `prometheus/alert_rules.yml`.
- **Script unit tests** (bats 0.4.0 with stubbed `kubectl`, `helm` and `docker`):
  - argument sequences
  - idempotency on "already exists"
  - missing-prerequisite errors
  - `HELM_HOST` switching `helm init` to `helm init --client-only`
  - the rollout poll's success, stale-generation and timeout paths (exit 2)
  - namespace defaulting
  - no ` -n ` in any recorded kubectl call
- **Static checks:** `gofmt -l` is empty, `go vet`, `helm lint helm/platform` prints `Lint OK`, `helm package --save=false` produces `platform-0.1.0.tgz`, `promtool check-config` (both configs), `promtool check-rules` (both rule files).
- **Integration** (`make integration`: bats inside `kp-tools` on the Compose network, one Tiller process with namespace `production`):
  - `app.bats`: `/health`, `/`, `/metrics` against the running container.
  - `cluster.bats`: `kubectl get componentstatuses` shows `scheduler`, `controller-manager` and `etcd-0` as Healthy (they share the apiserver's network namespace), and the API group `extensions/v1beta1` serves deployments.
  - `workload.bats`:
    - `kubectl apply -f k8s/` succeeds.
    - One ReplicaSet exists with 3 pods.
    - Deleting a pod brings the count back to 3 (self-healing).
    - `kubectl scale deployment platform-app --replicas=5` brings the ReplicaSet to 5 pods, and scaling back to 3 returns it to 3.
    - `kubectl patch` of the container image (`kubectl set image` arrives only in 1.3) creates a second ReplicaSet with 1 replica while the old one keeps 3 (surge 1, unavailable 0).
    - `kubectl rollout undo` restores the original template.
  - `scripts.bats`: `setup-cluster.sh` creates the namespaces and ServiceAccount. `deploy.sh` with `ROLLOUT_WAIT=0` applies everything, and with `ROLLOUT_TIMEOUT=5` exits 2, because the pods never become available with no nodes.
  - `helm.bats` (release names `it-helm` and `it-helm-2`, never `platform`):
    - `helm version` prints `v2.0.0-alpha.2`.
    - `helm list` exits 0 against `HELM_HOST=tiller:44134`, and `curl -fs http://tiller:44135/readiness` succeeds.
    - `helm install --name it-helm helm/platform` creates the objects with the chart's labels in `production`.
    - `-f` overrides `replicaCount` on `it-helm-2`.
    - `helm delete` removes each Deployment.
    - Teardown runs `kubectl delete rs,pods -l release=<name> --namespace=production`, because alpha.2 deletes do not cascade.
  - `prometheus.bats`: `up{job="platform-app"} == 1`. `up{job="kubernetes-apiserver"} == 1` through Kubernetes SD. After the host runs `docker compose stop app`, `alerts/app-down.bats` sees `ALERTS{alertname="PlatformAppDown",alertstate="firing"}` within 60 s.
  - `monitoring.bats`: `kubectl apply -f k8s/monitoring.yaml` creates the namespace, ConfigMap, Deployment and NodePort 30090.
  - `e2e.bats`: the README flow in order (setup, `helm install --name platform helm/platform`, monitoring apply). It is the only suite that uses the release name `platform`, and its teardown removes the orphaned ReplicaSets and Pods the same way.

## Known limitations that will remain

- No kubelet, so pods never run inside Kubernetes. Probes, container start, zero-downtime rolling updates and in-cluster Prometheus pod discovery are never exercised end to end. The app is tested as a Compose container instead.
- LoadBalancer Services never get an external IP.
- The control plane uses the unauthenticated insecure port 8080 with the ServiceAccount admission controller disabled. It is suitable only for the local Compose network. The controller-manager and scheduler share the apiserver container's network namespace, so restarting the apiserver requires restarting them too.
- Helm alpha.2 has no install namespace: every release goes into Tiller's namespace (`production` here). There is no `upgrade` or `rollback`.
- Tiller alpha.2 keeps releases in memory, so they are lost when the Tiller container restarts. While Tiller runs, a deleted release's name stays reserved and cannot be reused, which is why each suite uses its own release names.
- `helm delete` in alpha.2 deletes the Deployment without a reaper, and Kubernetes 1.2 has no garbage collector. The release's ReplicaSet and Pods are left orphaned until they are deleted by label.
- `setup-cluster.sh`'s `helm init` path and `k8s/monitoring.yaml`'s `prom/prometheus:0.20.0` image are written for a real 2016 cluster, and neither is exercised here. The image cannot be pulled on Docker 28.2 or later.
- No Alertmanager, so alerts are visible only in Prometheus.
- Every image is amd64 only. The `golang:1.6.3` image is a December 2016 rebuild of the 1.6.3 toolchain. The build images trust a post-period jessie CA bundle (`ca-certificates 20141019+deb8u4`) so they can reach GitHub over HTTPS.
- Building `kp-helm` needs network access and about 15 GB of free Docker disk at peak. The final image keeps only the `helm` and `tiller` binaries.
