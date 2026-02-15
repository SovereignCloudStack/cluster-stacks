FROM alpine:3.19

LABEL org.opencontainers.image.source="https://github.com/SovereignCloudStack/cluster-stacks"
LABEL org.opencontainers.image.description="Cluster Stack Build Tools - Alpine-based container with all dependencies"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# Install system dependencies
RUN apk add --no-cache \
    bash \
    git \
    curl \
    python3 \
    py3-pip \
    py3-yaml \
    py3-requests \
    jq \
    ca-certificates \
    helm \
    yq

# Install oras
RUN ORAS_VERSION=1.1.0 && \
    curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" | \
    tar -xz -C /usr/local/bin oras

# Install Task
RUN TASK_VERSION=v3.35.1 && \
    curl -fsSL "https://github.com/go-task/task/releases/download/${TASK_VERSION}/task_linux_amd64.tar.gz" | \
    tar -xz -C /usr/local/bin task

# Create working directory
WORKDIR /workspace

# Verify installations
RUN bash --version && \
    git --version && \
    python3 --version && \
    helm version --short && \
    yq --version && \
    oras version && \
    task --version

# Copy scripts and Taskfile (if building in CI)
# Uncomment these lines when building the image in CI/CD:
# COPY hack/ /workspace/hack/
# COPY Taskfile.yml /workspace/
# COPY task.env.example /workspace/
# RUN chmod +x /workspace/hack/*.sh /workspace/hack/*.py

# Set git safe directory (for running in containers)
RUN git config --global --add safe.directory /workspace

# Default command
CMD ["/bin/bash"]
