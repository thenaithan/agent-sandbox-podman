# agent-pod base image: a non-root shell with Claude Code and common build tools.
# Deliberately headless: no browser, no display, no container runtime.
FROM registry.fedoraproject.org/fedora:44 AS base

ARG CLAUDE_CODE_VERSION=2.1.301
ARG AGENT_UID=1000
ARG AGENT_GID=1000

# Packages come from signed Fedora repos only (no curl | bash, no gpgcheck=0 repos).
RUN dnf install -y --setopt=install_weak_deps=False \
        bash coreutils findutils procps-ng iproute util-linux-core \
        git openssh-clients curl ca-certificates \
        make gcc gcc-c++ python3 python3-pip \
        nodejs npm unzip jq ripgrep && \
    dnf clean all

# npm lifecycle scripts are a common supply-chain vector, so they stay off
# globally. Claude Code is the one exception: its postinstall (install.cjs)
# puts the native binary in place. The build then checks that it runs.
RUN npm install -g --ignore-scripts=false "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && \
    npm config set --global ignore-scripts true && \
    npm cache clean --force && \
    claude --version

# Podman is installed but only usable with `agent-pod run --containers`, which
# grants the capabilities newuidmap needs. Without the flag it fails closed.
RUN dnf install -y --setopt=install_weak_deps=False \
        podman fuse-overlayfs passt shadow-utils && \
    dnf clean all

RUN groupadd -g "${AGENT_GID}" agent && \
    useradd -m -u "${AGENT_UID}" -g agent -s /bin/bash agent && \
    mkdir -p /workspace && chown agent:agent /workspace && \
    # Nested user namespace range, inside the pod's own mapped range.
    echo "agent:10000:55000" > /etc/subuid && \
    echo "agent:10000:55000" > /etc/subgid

# Plugin registries written by earlier setups store absolute /root/.claude
# paths. Point that path at the agent's config so they keep resolving.
RUN chmod 0755 /root && ln -s /home/agent/.claude /root/.claude

# Pre-create the config tree as the agent, so the shared-config bind mounts
# don't make Podman create these directories root-owned in the home volume.
RUN install -d -o agent -g agent /home/agent/.claude /home/agent/.claude/projects \
        /home/agent/.claude/projects/-workspace /home/agent/.claude/projects/-workspace/memory

# Nested storage uses fuse-overlayfs and lives in the agent's home volume.
COPY config/nested-storage.conf /etc/containers/storage.conf

COPY --chmod=0755 bin/agent-pod-verify bin/agent-pod-init /usr/local/bin/

# First-run state for Claude Code, copied into a new home volume by
# agent-pod-init so each project skips the setup screens. Nothing secret.
RUN install -d /etc/agent-pod && \
    printf '{"hasCompletedOnboarding": true, "lastOnboardingVersion": "%s"}\n' \
        "${CLAUDE_CODE_VERSION}" > /etc/agent-pod/claude-seed.json

COPY --chmod=0644 config/prompt.sh /etc/profile.d/agent-pod-prompt.sh

# The root filesystem is mounted read-only at runtime, so the agent cannot
# update or patch its own binary; upgrades happen by rebuilding the image.
ENV DISABLE_AUTOUPDATER=1 \
    LANG=C.UTF-8

USER agent
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/agent-pod-init"]
CMD ["/bin/bash", "-l"]

# --- browser: base + Google Chrome (headless use) and fonts, for `run --browser`.
# Chrome's repo is GPG-signed; the key is checked on install.
FROM base AS browser
USER root
RUN printf '%s\n' '[google-chrome]' 'name=google-chrome' \
        'baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64' \
        'enabled=1' 'gpgcheck=1' 'gpgkey=https://dl.google.com/linux/linux_signing_key.pub' \
        > /etc/yum.repos.d/google-chrome.repo && \
    dnf install -y --setopt=install_weak_deps=False \
        google-chrome-stable google-noto-sans-fonts google-noto-emoji-fonts \
        google-noto-sans-thai-fonts google-noto-serif-thai-fonts && \
    dnf clean all && \
    # The setuid sandbox helper can't work under no-new-privileges; Chrome uses
    # its namespace sandbox instead. Drop the suid bit so nothing setuid ships.
    chmod 0755 /opt/google/chrome/chrome-sandbox && \
    google-chrome --version
USER agent
