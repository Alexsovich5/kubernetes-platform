REPO         := /go/src/github.com/Alexsovich5/kubernetes-platform
GOLANG_IMAGE := golang:1.6.3@sha256:9bc3717d167110a13be0ca34936a1d2d509f1775499649a6be616330ab20dbd1
TOOLS_IMAGE  := kubernetes-platform:tools-2016
HELM_IMAGE   := kubernetes-platform:helm-v2.0.0-alpha.2
CACHE        := build/cache
# 15 GB in 1K blocks, as reported by df -Pk
MIN_FREE_KB  := 15728640
VERSION      := 0.1.0
SA_DIR       := /var/run/secrets/kubernetes.io/serviceaccount

# <file in build/cache>^<download URL>
FETCH_LIST := \
	bats-v0.4.0.tar.gz^https://github.com/sstephenson/bats/archive/v0.4.0.tar.gz \
	glide-v0.11.1-linux-amd64.tar.gz^https://github.com/Masterminds/glide/releases/download/v0.11.1/glide-v0.11.1-linux-amd64.tar.gz \
	ca-certificates_20141019+deb8u4_all.deb^http://snapshot.debian.org/archive/debian-security/20180707T093525Z/pool/updates/main/c/ca-certificates/ca-certificates_20141019%2Bdeb8u4_all.deb \
	etcd-v2.2.5-linux-amd64.tar.gz^https://github.com/etcd-io/etcd/releases/download/v2.2.5/etcd-v2.2.5-linux-amd64.tar.gz \
	kube-apiserver^https://storage.googleapis.com/kubernetes-release/release/v1.2.6/bin/linux/amd64/kube-apiserver \
	kube-controller-manager^https://storage.googleapis.com/kubernetes-release/release/v1.2.6/bin/linux/amd64/kube-controller-manager \
	kube-scheduler^https://storage.googleapis.com/kubernetes-release/release/v1.2.6/bin/linux/amd64/kube-scheduler \
	kubectl^https://storage.googleapis.com/kubernetes-release/release/v1.2.6/bin/linux/amd64/kubectl \
	prometheus-0.20.0.linux-amd64.tar.gz^https://github.com/prometheus/prometheus/releases/download/0.20.0/prometheus-0.20.0.linux-amd64.tar.gz

COMPOSE    := docker compose -p kubernetes-platform

DOCKER_RUN := docker run --rm -e OFFLINE -v $(CURDIR):$(REPO) -w $(REPO)

.PHONY: preflight fetch helm-image tools-image test ci-unit shell vendor lock-check build up down integration test-all

preflight:
	docker system df
	@echo "dangling volumes:"
	docker volume ls -qf dangling=true
	@docker image inspect $(GOLANG_IMAGE) >/dev/null 2>&1 || \
		for attempt in 1 2 3; do docker pull $(GOLANG_IMAGE) && break; sleep 5; done
	@avail=$$(docker run --rm $(GOLANG_IMAGE) df -Pk / | awk 'NR==2 {print $$4}'); \
	if [ -z "$$avail" ]; then echo "preflight: could not read free disk space" >&2; exit 1; fi; \
	echo "preflight: $$avail KB free in the Docker VM (need $(MIN_FREE_KB))"; \
	if [ "$$avail" -lt $(MIN_FREE_KB) ]; then \
		echo "preflight: less than 15 GB free in the Docker VM" >&2; exit 1; \
	fi

fetch:
	@mkdir -p $(CACHE)
	@for entry in $(FETCH_LIST); do \
		file=$${entry%%^*}; url=$${entry#*^}; \
		if [ ! -f "$(CACHE)/$$file" ]; then \
			ok=0; \
			for attempt in 1 2 3; do \
				echo "fetch: $$file (attempt $$attempt)"; \
				if curl -fsSL -o "$(CACHE)/$$file.part" "$$url"; then ok=1; break; fi; \
				sleep 3; \
			done; \
			if [ "$$ok" != 1 ]; then rm -f "$(CACHE)/$$file.part"; echo "fetch: failed to download $$url" >&2; exit 1; fi; \
			mv "$(CACHE)/$$file.part" "$(CACHE)/$$file"; \
		fi; \
	done
	cd $(CACHE) && sha256sum -c ../SHA256SUMS

# Compiles helm and tiller from source; needs network access and disk headroom.
helm-image: preflight fetch
	@for attempt in 1 2 3; do \
		docker build -t $(HELM_IMAGE) -f build/helm/Dockerfile build/ && exit 0; \
		echo "helm-image: build failed (attempt $$attempt)" >&2; sleep 5; \
	done; exit 1

tools-image: fetch helm-image
	@for attempt in 1 2 3; do \
		docker build -t $(TOOLS_IMAGE) -f build/tools/Dockerfile build/ && exit 0; \
		echo "tools-image: build failed (attempt $$attempt)" >&2; sleep 5; \
	done; exit 1

test: preflight fetch helm-image tools-image
	$(DOCKER_RUN) $(TOOLS_IMAGE) make -f Makefile ci-unit

# Runs inside the tools image.
ci-unit:
	test -z "$$(gofmt -l cmd pkg tests)"
	go vet ./cmd/... ./pkg/...
	go test ./pkg/... ./tests/manifests/...
	helm lint helm/platform | tee /dev/stderr | grep -qx 'Lint OK'
	@# prometheus.yml reads the in-cluster service account files that a pod
	@# mounts; promtool 0.20 checks that they exist, so provide empty ones.
	mkdir -p $(SA_DIR) && touch $(SA_DIR)/token $(SA_DIR)/ca.crt
	promtool check-config prometheus/prometheus.yml
	promtool check-config prometheus/prometheus-local.yml
	promtool check-rules prometheus/alert_rules.yml
	promtool check-rules prometheus/alert_rules_local.yml
	cd /tmp && rm -f platform-0.1.0.tgz && helm package --save=false $(REPO)/helm/platform && test -f /tmp/platform-0.1.0.tgz
	bats tests/unit

# Resolves glide.yaml into glide.lock and vendor/ inside the tools image.
vendor: tools-image
	@for attempt in 1 2 3; do \
		$(DOCKER_RUN) $(TOOLS_IMAGE) glide install --strip-vcs --strip-vendor && exit 0; \
		echo "vendor: glide install failed (attempt $$attempt)" >&2; sleep 5; \
	done; exit 1

# Host-side: every glide.lock revision must be dated on or before 2016-07-31.
lock-check:
	python3 build/lock_dates.py glide.lock

# Builds bin/platform-app (linux/amd64) inside the tools image.
build: tools-image
	$(DOCKER_RUN) $(TOOLS_IMAGE) go build -ldflags "-X main.version=$(VERSION)" -o bin/platform-app ./cmd/platform-app

# Starts the Compose stack. The helm and tools images are local tags, so
# build them first, in that order.
up: fetch helm-image tools-image
	@for attempt in 1 2 3; do \
		$(COMPOSE) up -d --build && exit 0; \
		echo "up: compose up failed (attempt $$attempt)" >&2; sleep 5; \
	done; exit 1

down:
	$(COMPOSE) down

# Runs the bats integration suites on the Compose network and always tears
# the stack down afterwards. Only this project's containers, networks and
# anonymous volumes are removed; nothing is pruned.
integration:
	@status=0; \
	$(MAKE) up || status=$$?; \
	if [ "$$status" = 0 ]; then $(COMPOSE) run --rm tools bash -c '. tests/integration/helpers.bash && wait_for_url http://app:8080/health 60 && wait_for_url http://apiserver:8080/healthz 90 && wait_for_url http://prometheus:9090/api/v1/query?query=up 60' || status=$$?; fi; \
	if [ "$$status" = 0 ]; then $(COMPOSE) run --rm tools bats tests/integration || status=$$?; fi; \
	if [ "$$status" = 0 ]; then $(COMPOSE) stop app || status=$$?; fi; \
	if [ "$$status" = 0 ]; then $(COMPOSE) run --rm tools bats tests/integration/alerts || status=$$?; fi; \
	$(COMPOSE) down -v; \
	exit $$status

# Runs the unit suite, then the integration suites against a fresh stack.
test-all:
	$(MAKE) test
	$(MAKE) integration

shell: tools-image
	$(DOCKER_RUN) -it $(TOOLS_IMAGE) bash
