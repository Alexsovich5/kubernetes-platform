# kubernetes-platform

A small platform kit that takes a Go HTTP service from source to a monitored Kubernetes deployment. It contains the `platform-app` sample workload (health, drain and Prometheus metrics endpoints), Kubernetes 1.2 manifests, a Helm 2 chart, cluster setup and deploy scripts, and a Prometheus configuration with alert rules. Everything runs and is tested in Docker against a real Kubernetes 1.2 control plane, Tiller and Prometheus started by Docker Compose.

Personal project built on the 2016-era stack (Kubernetes 1.2.6, Helm 2.0.0-alpha.2, Prometheus 0.20.0, Go 1.6.3).

## Status

**Implemented**

- `platform-app` (`cmd/platform-app`, `pkg/app`): `GET /` returns JSON with hostname, version and a message read from a ConfigMap-mounted file; `GET /health` returns 200, or 503 while draining; `GET /metrics` serves Prometheus metrics. On SIGTERM it fails `/health`, waits `DRAIN_SECONDS`, then exits. Tested by `pkg/app/*_test.go` and `tests/integration/app.bats`.
- Container image: the root `Dockerfile` builds `platform-app` from a digest-pinned `golang:1.6.3` image. Built by Compose and exercised by `tests/integration/app.bats`.
- Kubernetes 1.2 manifests (`k8s/`): an `extensions/v1beta1` Deployment with a RollingUpdate strategy (surge 1, unavailable 0), `/health` probes, requests and limits and `prometheus.io/*` annotations, plus a ConfigMap and LoadBalancer and ClusterIP Services. Checked by `tests/manifests/manifests_test.go`.
- Controller behaviour on a real 1.2 control plane: deleted pods are recreated, `kubectl scale` resizes the ReplicaSet, an image patch creates a second ReplicaSet within the surge limit, and `kubectl rollout undo` restores the template. Tested by `tests/integration/workload.bats`.
- Helm chart (`helm/platform`) using the alpha.2 template contract: `helm lint` prints `Lint OK`, `helm package` produces `platform-0.1.0.tgz`, and `helm install` creates labelled objects through Tiller. Tested by `tests/unit/helm-chart.bats` and `tests/integration/helm.bats`.
- `scripts/setup-cluster.sh`: checks prerequisites, creates the `production`, `staging` and `monitoring` namespaces idempotently, creates the `platform-sa` ServiceAccount and runs `helm init` (or `helm init --client-only` when `HELM_HOST` is set). Tested by `tests/unit/setup-cluster.bats` and `tests/integration/scripts.bats`.
- `scripts/deploy.sh [namespace]`: applies the app and monitoring manifests and polls Deployment status with `jsonpath` (including `observedGeneration`) until `ROLLOUT_TIMEOUT`, exiting 2 on timeout; `ROLLOUT_WAIT=0` skips the wait. Tested by `tests/unit/deploy.bats` and `tests/integration/scripts.bats`.
- Prometheus 0.20 configuration (`prometheus/`): Kubernetes service discovery in 0.20 syntax, alert rules in 0.x syntax (`PlatformAppDown`, `PlatformAppHighErrorRate`) and a Compose variant. Checked with `promtool` in `make test`; `tests/integration/prometheus.bats` and `tests/integration/alerts/app-down.bats` check scraping and that `PlatformAppDown` fires when the app stops.
- Monitoring manifest (`k8s/monitoring.yaml`): `monitoring` Namespace, a ConfigMap kept byte-identical to the files in `prometheus/`, a Prometheus 0.20.0 Deployment and a NodePort Service on 30090. Tested by `tests/manifests/manifests_test.go` and `tests/integration/monitoring.bats`.
- Local stack (`docker-compose.yml`): etcd 2.2.5, kube-apiserver, kube-controller-manager and kube-scheduler 1.2.6, Tiller v2.0.0-alpha.2, `platform-app` and Prometheus 0.20.0. Tested by `tests/integration/cluster.bats`, and the documented setup, `helm install` and monitoring sequence by `tests/integration/e2e.bats`.
- Test harness: `make test` runs gofmt, `go vet`, Go unit and manifest tests, `helm lint`/`helm package`, `promtool` checks and the bats script tests inside the tools image; `make integration` runs the bats suites against the Compose stack.

**Not implemented / known limitations**

- Kubernetes nodes are simulated by a kubelet-less 1.2 control plane; pods are created but never run.
- No cloud load balancer; LoadBalancer services never receive an external IP.
- Tiller runs as a compose service rather than in-cluster, and every release is installed into its namespace (production).
- Script unit tests stub kubectl/helm/docker.
- No kubelet: kubelet 1.2 cannot run against the host's cgroup v2 kernel and current Docker daemon. Probes, container start, zero-downtime rolling updates and in-cluster pod discovery by Prometheus are never exercised end to end; the app is tested as a Compose container instead.
- No RBAC: it does not exist in Kubernetes 1.2, so `setup-cluster.sh` creates only the ServiceAccount.
- No `platform-worker` Deployment or queue, no database secret and no Ingress.
- No Alertmanager: alerts are evaluated and visible as `ALERTS` in Prometheus, and nothing sends notifications.
- No `helm upgrade` or rollback; neither exists in Helm v2.0.0-alpha.2.
- Images are built and tagged locally and never pushed to a registry.
- Dockerfiles and the Compose file stay within Docker 1.10 and Compose file format 2 features, but run on a current Docker engine.
- Tiller alpha.2 keeps releases in memory: they are lost when the container restarts, and a deleted release name cannot be reused while Tiller runs, so each test suite uses its own release names.
- `helm delete` in alpha.2 removes the Deployment but leaves its ReplicaSet and Pods orphaned (Kubernetes 1.2 has no garbage collector); they have to be deleted by the `release` label.
- The control plane uses the unauthenticated insecure port 8080 and is reachable only on the Compose network.
- The `helm init` path of `setup-cluster.sh` and the `prom/prometheus:0.20.0` image in `k8s/monitoring.yaml` are written for a real cluster and are not exercised here.
- The build images install a newer jessie CA bundle (`ca-certificates 20141019+deb8u4`) so they can reach GitHub over HTTPS. All images are amd64 only, and the `golang:1.6.3` base is a later rebuild of the 1.6.3 toolchain.
- Building the Helm image compiles Helm from source and needs network access and about 15 GB of free Docker disk at peak.

## Built with

- **Go 1.6.3** with glide v0.11.1 — `github.com/prometheus/client_golang` 0.7.0, `gopkg.in/yaml.v2` e4d366f (manifest tests only)
- **Kubernetes 1.2.6** — kube-apiserver, kube-controller-manager, kube-scheduler and kubectl on etcd 2.2.5
- **Helm / Tiller v2.0.0-alpha.2**, built from source
- **Prometheus and promtool 0.20.0**
- **bats 0.4.0** for script tests
- **Docker Compose** file format 2

## Running it

Everything runs in Docker images built from the pinned release files, so nothing needs installing locally beyond Docker and make.

```bash
make up                  # fetch release files, build kp-helm then kp-tools, start Compose
curl -s localhost:20180/ && curl -s 'localhost:20190/api/v1/query?query=up'
make down                # stop the stack
```

The app is published on host port 20180 and Prometheus on 20190. A plain `docker compose up` on a fresh clone does not work, because the tools image is built from the locally tagged Helm image.

## Tests

```bash
make test                # unit and static checks inside the tools image
make integration         # bats suites against the Compose stack, then tears it down
make test-all            # both
```

The tests cover the Go service, manifest invariants, chart and Prometheus config validity, the scripts with stubbed CLIs, and controller, Helm and Prometheus behaviour against the Compose stack; they do not cover running pods, because no node exists.

## Layout

```
.dockerignore
.gitignore
Dockerfile
Makefile
README.md
build/SHA256SUMS
build/helm/Dockerfile
build/kubeconfig
build/lock_dates.py
build/tools/Dockerfile
cmd/platform-app/main.go
docker-compose.yml
docs/IMPLEMENTATION_PLAN.md
docs/SPEC.md
glide.lock
glide.yaml
helm/platform/.helmignore
helm/platform/Chart.yaml
helm/platform/templates/_helpers.tpl
helm/platform/templates/configmap.yaml
helm/platform/templates/deployment.yaml
helm/platform/templates/service.yaml
helm/platform/values.yaml
k8s/configmap.yaml
k8s/deployment.yaml
k8s/monitoring.yaml
k8s/service.yaml
pkg/app/config.go
pkg/app/config_test.go
pkg/app/drain.go
pkg/app/drain_test.go
pkg/app/server.go
pkg/app/server_test.go
prometheus/alert_rules.yml
prometheus/alert_rules_local.yml
prometheus/prometheus-local.yml
prometheus/prometheus.yml
scripts/deploy.sh
scripts/setup-cluster.sh
tests/fixtures/config/message
tests/fixtures/gofmt/bad.go.txt
tests/integration/alerts/app-down.bats
tests/integration/app.bats
tests/integration/cluster.bats
tests/integration/e2e.bats
tests/integration/helm.bats
tests/integration/helpers.bash
tests/integration/monitoring.bats
tests/integration/prometheus.bats
tests/integration/scripts.bats
tests/integration/workload.bats
tests/manifests/manifests_test.go
tests/unit/deploy.bats
tests/unit/gofmt.bats
tests/unit/harness.bats
tests/unit/helm-chart.bats
tests/unit/prometheus.bats
tests/unit/readme.bats
tests/unit/setup-cluster.bats
tests/unit/stubs/docker
tests/unit/stubs/helm
tests/unit/stubs/kubectl
vendor/  (glide-managed, not listed)
```
