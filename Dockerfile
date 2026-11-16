# syntax=docker/dockerfile:1

# --- Stage 1: fetch the SteamCMD bootstrap from Valve -------------------------
FROM debian:trixie-slim AS steamcmd

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/steamcmd \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C /opt/steamcmd

# --- Stage 2: runtime ---------------------------------------------------------
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

# lib32gcc-s1 / lib32stdc++6: SteamCMD is a 32-bit binary.
# The Project Zomboid server ships its own JRE, so no Java is installed here.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      jq \
      lib32gcc-s1 \
      lib32stdc++6 \
      tini \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 1000 --user-group --no-create-home --home-dir /data/home steam \
 && mkdir -p /data /config \
 && chown steam:steam /data

COPY --from=steamcmd /opt/steamcmd /opt/steamcmd
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 pz-console /usr/local/bin/pz-console

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
