# vmop-2384 N3 self-contained env: client + ctr (k3s v1.28) + seed payload.
FROM rancher/k3s:v1.21.14-k3s1 AS k3s-src

FROM ghcr.io/laude-institute/t-bench/ubuntu-24-04:20250624

ARG KUBECTL_VERSION=v1.31.0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg jq ripgrep \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o /usr/local/bin/kubectl \
 && chmod +x /usr/local/bin/kubectl \
 && kubectl version --client=true \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /root
ENV KUBECONFIG=/kube/config
COPY --from=k3s-src /bin/ctr /usr/local/bin/ctr

# Verifier preinstall (V7): curl/uv/pytest baked in at build time.
RUN apt-get update -qq && apt-get install -y -qq curl >/dev/null \
 && curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null \
 && $HOME/.local/bin/uv venv /opt/sweops-venv >/dev/null \
 && $HOME/.local/bin/uv pip install --python /opt/sweops-venv/bin/python pytest==8.4.1 >/dev/null

COPY seed.py /opt/seed.py
COPY seed-config.json /seed-data/seed-config.json
COPY seed-materials/ /seed-data/
COPY images/ /images/

# ---- resolution: baked buggy-pin source snapshot + Go toolchain ----
COPY src-snapshot/ /operator-src-clean/
COPY src-snapshot/ /operator-src/
# Warm the regression target package's FULL closure at bake time so the judge
# can run OFFLINE (GOPROXY=off) later: `go build` fetches build deps, then an
# ONLINE `go test` fetches test-only deps too (e.g. cloud.google.com/go) and
# runs green here because the pin tree has no hidden test yet. Both run on the
# /go-warm throwaway copy, so /operator-src keeps byte-identical go.mod/go.sum
# to /operator-src-clean (agent diffs stay clean). Network is available at
# build time (public), but NOT guaranteed at verify time -> judge runs offline.
RUN apt-get update -qq && apt-get install -y --no-install-recommends golang-go >/dev/null \
 && cp -a /operator-src-clean /go-warm \
 && cd /go-warm \
 && GOFLAGS=-mod=mod go build ./pkg/apis/zookeeper/v1beta1/... ./pkg/controller/zookeepercluster/... ./pkg/utils/... ./pkg/yamlexporter/... ./pkg/zk/... \
 && { GOFLAGS=-mod=mod go test -vet=off ./pkg/apis/zookeeper/v1beta1/... ./pkg/controller/zookeepercluster/... ./pkg/utils/... ./pkg/yamlexporter/... ./pkg/zk/... \
      || echo '[warm] some tests are red at the pin -- non-fatal, the judge checks its own set'; } \
 && rm -rf /go-warm /var/lib/apt/lists/*

# ---- full-tree warm: the build gate compiles ALL of this offline ----
RUN cp -a /operator-src-clean /go-warm-all && cd /go-warm-all \
 && { GOFLAGS=-mod=mod go build $(go list -f '{{if .GoFiles}}{{.ImportPath}}{{end}}' ./...) \
      || echo '[warm-all] full-tree build failed -- the offline build gate may be red'; } \
 && { GOFLAGS=-mod=mod go test -vet=off -run='^$' ./... \
      || echo '[warm-all] full-tree test-compile failed -- non-fatal'; } \
 && rm -rf /go-warm-all
