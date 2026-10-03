# vmop-2384 N3 self-contained env: client + ctr (k3s v1.28) + seed payload.
FROM rancher/k3s:v1.28.10-k3s1 AS k3s-src

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

# ---- resolution: baked buggy-pin source snapshot ----
COPY src-snapshot/ /operator-src-clean/
COPY src-snapshot/ /operator-src/
RUN curl -fsSL 'https://go.dev/dl/go1.25.5.linux-amd64.tar.gz' -o /tmp/go.tgz \
 && rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz && /usr/local/go/bin/go version
ENV PATH=/usr/local/go/bin:$PATH
RUN cp -a /operator-src-clean /go-warm \
 && cd /go-warm \
 && { GOFLAGS=-mod=mod go mod download \
      || echo '[warm] go mod download failed -- the offline regression judge may not resolve its imports'; } \
 && GOFLAGS=-mod=mod go build ./internal/controller/operator/... ./internal/controller/operator/converter/... ./internal/controller/operator/converter/v1alpha1/... ./internal/controller/operator/factory/build/... ./internal/controller/operator/factory/finalize/... ./internal/controller/operator/factory/k8stools/... ./internal/controller/operator/factory/reconcile/... ./internal/controller/operator/factory/vlagent/... ./internal/controller/operator/factory/vlcluster/... ./internal/controller/operator/factory/vlsingle/... ./internal/controller/operator/factory/vmagent/... ./internal/controller/operator/factory/vmalert/... ./internal/controller/operator/factory/vmalertmanager/... ./internal/controller/operator/factory/vmanomaly/config/... ./internal/controller/operator/factory/vmauth/... ./internal/controller/operator/factory/vmcluster/... ./internal/controller/operator/factory/vmsingle/... ./internal/controller/operator/factory/vtcluster/... ./internal/controller/operator/factory/vtsingle/... \
 && { GOFLAGS=-mod=mod go test -vet=off ./internal/controller/operator/... ./internal/controller/operator/converter/... ./internal/controller/operator/converter/v1alpha1/... ./internal/controller/operator/factory/build/... ./internal/controller/operator/factory/finalize/... ./internal/controller/operator/factory/k8stools/... ./internal/controller/operator/factory/reconcile/... ./internal/controller/operator/factory/vlagent/... ./internal/controller/operator/factory/vlcluster/... ./internal/controller/operator/factory/vlsingle/... ./internal/controller/operator/factory/vmagent/... ./internal/controller/operator/factory/vmalert/... ./internal/controller/operator/factory/vmalertmanager/... ./internal/controller/operator/factory/vmanomaly/config/... ./internal/controller/operator/factory/vmauth/... ./internal/controller/operator/factory/vmcluster/... ./internal/controller/operator/factory/vmsingle/... ./internal/controller/operator/factory/vtcluster/... ./internal/controller/operator/factory/vtsingle/... \
      || echo '[warm] some tests are red at the pin -- non-fatal, the judge checks its own set'; } \
 && rm -rf /go-warm

# ---- full-tree warm: the build gate compiles ALL of this offline ----
RUN cp -a /operator-src-clean /go-warm-all && cd /go-warm-all \
 && { GOFLAGS=-mod=mod go build $(go list -f '{{if .GoFiles}}{{.ImportPath}}{{end}}' ./...) \
      || echo '[warm-all] full-tree build failed -- the offline build gate may be red'; } \
 && { GOFLAGS=-mod=mod go test -vet=off -run='^$' ./... \
      || echo '[warm-all] full-tree test-compile failed -- non-fatal'; } \
 && rm -rf /go-warm-all
