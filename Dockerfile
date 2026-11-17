# syntax=docker/dockerfile:1

# --- Stage 1: downloads (SteamCMD bootstrap, rcon-cli) ------------------------
FROM debian:trixie-slim AS downloads

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/steamcmd \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C /opt/steamcmd

# rcon-cli (https://github.com/gorcon/rcon-cli), a static binary, for pz-rcon.
ARG RCON_CLI_VERSION=0.10.3
ARG RCON_CLI_SHA256=6962a641ebf9a5957bd0cda1b8acf3e34a23686ae709f6c6a14ac3898521a5cc
RUN curl -fsSL -o /tmp/rcon.tar.gz \
      "https://github.com/gorcon/rcon-cli/releases/download/v${RCON_CLI_VERSION}/rcon-${RCON_CLI_VERSION}-amd64_linux.tar.gz" \
 && echo "${RCON_CLI_SHA256}  /tmp/rcon.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/rcon.tar.gz -C /tmp \
 && install -m 0755 "/tmp/rcon-${RCON_CLI_VERSION}-amd64_linux/rcon" /usr/local/bin/rcon

# supercronic (https://github.com/aptible/supercronic), a static binary, for
# RESTART_SCHEDULE.
ARG SUPERCRONIC_VERSION=0.2.51
ARG SUPERCRONIC_SHA256=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123
RUN curl -fsSL -o /tmp/supercronic \
      "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
 && echo "${SUPERCRONIC_SHA256}  /tmp/supercronic" | sha256sum -c - \
 && install -m 0755 /tmp/supercronic /usr/local/bin/supercronic

# --- Stage 2: runtime ---------------------------------------------------------
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

# lib32gcc-s1 / lib32stdc++6: SteamCMD is a 32-bit binary.
# The Project Zomboid server ships its own JRE, so no Java is installed here.
# tzdata: TZ for RESTART_SCHEDULE.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      jq \
      lib32gcc-s1 \
      lib32stdc++6 \
      tini \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 1000 --user-group --no-create-home --home-dir /data/home steam \
 && mkdir -p /data /config \
 && chown steam:steam /data

COPY --from=downloads /opt/steamcmd /opt/steamcmd
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --from=downloads /usr/local/bin/rcon /usr/local/bin/supercronic /usr/local/bin/
COPY --chmod=0755 pz-console pz-rcon pz-auto-restart pz-ready /usr/local/bin/

ENV HOME=/data/home \
    STEAMCMD_DIR=/data/steamcmd \
    SERVER_DIR=/data/server \
    ZOMBOID_DIR=/data/zomboid \
    CONFIG_DIR=/config \
    CONSOLE_FIFO=/tmp/pz-console

USER 1000:1000
WORKDIR /data

EXPOSE 16261/udp 16262/udp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
