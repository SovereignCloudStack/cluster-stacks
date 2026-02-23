FROM alpine:3.21

LABEL org.opencontainers.image.source="https://github.com/SovereignCloudStack/cluster-stacks"
LABEL org.opencontainers.image.description="Cluster Stack Build Tools"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# Install system dependencies
RUN apk add --no-cache \
    bash \
    git \
    curl \
    tar \
    gzip \
    gawk \
    python3 \
    py3-yaml \
    jq \
    ca-certificates

# Install helm
RUN HELM_VERSION=v3.17.3 && \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | \
    tar -xz -C /usr/local/bin --strip-components=1 linux-amd64/helm

# Install yq (mikefarah)
RUN YQ_VERSION=v4.45.4 && \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# Install oras
RUN ORAS_VERSION=1.2.2 && \
    curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" | \
    tar -xz -C /usr/local/bin oras

# Install just
RUN JUST_VERSION=1.40.0 && \
    curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" | \
    tar -xz -C /usr/local/bin just

WORKDIR /workspace

# Verify installations
RUN bash --version | head -1 && \
    helm version --short && \
    yq --version && \
    oras version && \
    just --version && \
    git --version

# Allow git operations inside mounted volumes
RUN git config --global --add safe.directory /workspace

CMD ["/bin/bash"]
