# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV. go-git/go-git is a pure-Go project, so the base
# (C/C++ only — NO Go toolchain) needs Go added here as a USER root step, then the OSS-Fuzz
# Go fuzzing tooling (go-fuzz / go-118-fuzz-build) that turns the native Go fuzz harnesses
# into libFuzzer-instrumented binaries linked with $LIB_FUZZING_ENGINE.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t go-git-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# NOTE: the OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); the Go fuzz
# binary is built with ASan and links the libFuzzer engine. build.sh handles the Go specifics.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the Go toolchain to match go-git's go.mod (`go 1.25.0`). We install this exact version so
# GOTOOLCHAIN=local builds without any network toolchain fetch.
ARG GO_VERSION=1.25.0
ARG GO_SHA256=2852af0cb20a13139b3448992e69b868e50ed0f8a1e5940ee1de9e19a123b613

# ── Toolchain path: /opt/toolchains/go (SPEC §6.2 item 8 — HOME-independent) ─────────────────
# All Go caches go under /opt/toolchains/go-path so both the root (build-time) step and the
# non-root mayhem (uid 2000) PATCH re-run see EXACTLY the same GOROOT/GOPATH/GOMODCACHE without
# depending on $HOME. The path must survive across docker run invocations of the same image.
ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/cache/go-build \
    GOTOOLCHAIN=local \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/bin:/usr/bin:/bin

USER root
RUN repro-sources-list.sh 2>/dev/null || true; \
    apt-get update && apt-get install -yq --no-install-recommends wget ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/toolchains \
    && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz \
    && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
    && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm /tmp/go.tgz \
    && mv /opt/toolchains/go /opt/toolchains/go-${GO_VERSION} \
    && ln -s go-${GO_VERSION} /opt/toolchains/go \
    && go version \
    && mkdir -p /opt/toolchains/go-path \
    && go install github.com/mdempsky/go114-fuzz-build@latest \
    && ln -sf "/opt/toolchains/go-path/bin/go114-fuzz-build" "/opt/toolchains/go-path/bin/go-fuzz" \
    && go install github.com/AdamKorcz/go-118-fuzz-build@latest \
    && go install golang.org/x/tools/cmd/goimports@latest \
    && ls -la /opt/toolchains/go-path/bin/

# Pre-warm the go-git module cache (so the non-root build does not need the network).
# Also pre-warm github.com/AdamKorcz/go-118-fuzz-build/testing — build.sh calls
# `go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest` per target; without
# this the offline re-run fails trying to reach proxy.golang.org.
RUN git clone --depth 1 https://github.com/go-git/go-git /tmp/gogit-warm \
    && cd /tmp/gogit-warm \
    && go mod download 2>/dev/null || true \
    && GOFLAGS=-mod=mod go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>/dev/null || true \
    && cd / && rm -rf /tmp/gogit-warm \
    && chown -R 2000:2000 /opt/toolchains/go-path \
    && chmod -R a+rX /opt/toolchains/go

USER mayhem

# Non-root mayhem (uid 2000): GOROOT/GOPATH/GOMODCACHE/GOCACHE are all under /opt/toolchains —
# already set in ENV above. GOTOOLCHAIN=local: GO_VERSION already matches go.mod, no fetch needed.
# GOFLAGS and GOPROXY are set in build.sh for air-gap friendliness.

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run go-git's own Go test suite at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
