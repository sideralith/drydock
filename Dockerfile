# drydock — containerized Claude Code sandbox.
#
# Architecture: Docker-out-of-Docker (DooD) via /var/run/docker.sock bind mount.
# The container does NOT run a docker daemon. The CLI inside talks to the host's
# daemon, so sibling containers in any project's docker-compose stack are
# visible and `docker exec` / project Makefile targets work transparently.
#
# Build args mirror the host's UID/GID and the docker group GID so that files
# created from inside this container land on the host with the user's ownership
# and the docker socket is readable.

FROM debian:12-slim

# USER_NAME has NO default — it's supplied by the drydock CLI (`id -un`) so the
# container user / $HOME mirror the invoking host user. Building this image with
# a bare `docker build` (no --build-arg USER_NAME=...) is unsupported.
ARG USER_NAME
ARG USER_UID=1000
ARG USER_GID=1000
ARG HOST_DOCKER_GID=1001

RUN [ -n "${USER_NAME}" ] || { \
        echo 'ERROR: USER_NAME build-arg is required — invoke via the drydock CLI, not a bare docker build' >&2; \
        exit 1; \
    }

ENV DEBIAN_FRONTEND=noninteractive

# ── Base tooling ─────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        jq \
        make \
        git \
        rsync \
        less \
        procps \
        vim-tiny \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# ── Docker CLI + Compose plugin ──────────────────────────────────────────────
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Legacy `docker-compose` (v1 invocation) → `docker compose` (v2 plugin) shim
RUN printf '#!/bin/sh\nexec docker compose "$@"\n' > /usr/local/bin/docker-compose \
    && chmod +x /usr/local/bin/docker-compose

# ── GitHub CLI ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── User + groups matching host ──────────────────────────────────────────────
RUN set -eux; \
    if getent group ${USER_GID} >/dev/null 2>&1; then \
        existing="$(getent group ${USER_GID} | cut -d: -f1)"; \
        if [ "$existing" != "${USER_NAME}" ]; then \
            groupmod -n ${USER_NAME} "$existing"; \
        fi; \
    else \
        groupadd -g ${USER_GID} ${USER_NAME}; \
    fi; \
    useradd -u ${USER_UID} -g ${USER_GID} -m -s /bin/bash ${USER_NAME}; \
    if getent group ${HOST_DOCKER_GID} >/dev/null 2>&1; then \
        existing_docker="$(getent group ${HOST_DOCKER_GID} | cut -d: -f1)"; \
        usermod -aG "$existing_docker" ${USER_NAME}; \
    else \
        groupadd -g ${HOST_DOCKER_GID} docker-host; \
        usermod -aG docker-host ${USER_NAME}; \
    fi

USER ${USER_NAME}

# PATH order:
#   ~/.local/bin first → contains the host-shared claude/engram/gentle-ai/gga/uv binaries
#   ~/.local/share/pnpm → contains node (some MCP plugins are JS-based)
#   System paths after
ENV PATH=/home/${USER_NAME}/.local/bin:/home/${USER_NAME}/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# WORKDIR is set per-invocation by the drydock CLI via env or compose override.
WORKDIR /home/${USER_NAME}

# Default: launch Claude Code interactively. Mounts provide the binary at runtime.
CMD ["claude"]
