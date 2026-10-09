REPO         := /go/src/github.com/Alexsovich5/kubernetes-platform
GOLANG_IMAGE := golang:1.6.3@sha256:9bc3717d167110a13be0ca34936a1d2d509f1775499649a6be616330ab20dbd1
TOOLS_IMAGE  := kubernetes-platform:tools-2016
CACHE        := build/cache
# 15 GB in 1K blocks, as reported by df -Pk
MIN_FREE_KB  := 15728640

# <file in build/cache>^<download URL>
FETCH_LIST := \
	bats-v0.4.0.tar.gz^https://github.com/sstephenson/bats/archive/v0.4.0.tar.gz \
	ca-certificates_20141019+deb8u4_all.deb^http://snapshot.debian.org/archive/debian-security/20180707T093525Z/pool/updates/main/c/ca-certificates/ca-certificates_20141019%2Bdeb8u4_all.deb

DOCKER_RUN := docker run --rm -e OFFLINE -v $(CURDIR):$(REPO) -w $(REPO)

.PHONY: preflight fetch tools-image test ci-unit shell

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

tools-image: fetch
	@for attempt in 1 2 3; do \
		docker build -t $(TOOLS_IMAGE) -f build/tools/Dockerfile build/ && exit 0; \
		echo "tools-image: build failed (attempt $$attempt)" >&2; sleep 5; \
	done; exit 1

test: preflight fetch tools-image
	$(DOCKER_RUN) $(TOOLS_IMAGE) make -f Makefile ci-unit

# Runs inside the tools image.
ci-unit:
	bats tests/unit

shell: tools-image
	$(DOCKER_RUN) -it $(TOOLS_IMAGE) bash
