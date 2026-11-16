#!/usr/bin/env bash
# Project Zomboid dedicated server entrypoint.
#
# Game configuration is NOT templated from environment variables. Put the
# server's own config files (<SERVER_NAME>.ini, <SERVER_NAME>_SandboxVars.lua,
# ...) in $CONFIG_DIR and they are linked into the server's config directory.
# Environment variables only control the container itself (install/update,
# JVM heap, where things live).
set -euo pipefail

STEAM_APP_ID=380870

STEAM_BRANCH="${STEAM_BRANCH:-public}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"
VALIDATE="${VALIDATE:-false}"
SERVER_NAME="${SERVER_NAME:-servertest}"
CONFIG_MODE="${CONFIG_MODE:-link}"
MAX_MEMORY="${MAX_MEMORY:-}"
ADMIN_PASSWORD_FILE="${ADMIN_PASSWORD_FILE:-}"

STEAMCMD_DIR="${STEAMCMD_DIR:-/data/steamcmd}"
SERVER_DIR="${SERVER_DIR:-/data/server}"
ZOMBOID_DIR="${ZOMBOID_DIR:-/data/zomboid}"
CONFIG_DIR="${CONFIG_DIR:-/config}"
CONSOLE_FIFO="${CONSOLE_FIFO:-/tmp/pz-console}"

log() { printf '[entrypoint] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

# SteamCMD updates itself in place, so it has to live on a writable path.
# The image carries a pristine bootstrap in /opt/steamcmd; copy it on first run.
install_steamcmd() {
  if [[ ! -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
    log "Bootstrapping SteamCMD into $STEAMCMD_DIR"
    mkdir -p "$STEAMCMD_DIR"
    cp -a /opt/steamcmd/. "$STEAMCMD_DIR/"
  fi
}

update_server() {
  local args=(
    +force_install_dir "$SERVER_DIR"
    +login anonymous
    +app_update "$STEAM_APP_ID" -beta "$STEAM_BRANCH"
  )
  [[ "$VALIDATE" == "true" ]] && args+=(validate)
  args+=(+quit)

  mkdir -p "$SERVER_DIR"
  local attempt
  for attempt in 1 2 3; do
    log "Installing/updating app $STEAM_APP_ID (branch: $STEAM_BRANCH, attempt $attempt/3)"
    # SteamCMD exit codes are unreliable (non-zero after self-updates, etc.),
    # so success is judged by the server files being present.
    "$STEAMCMD_DIR/steamcmd.sh" "${args[@]}" || true
    if [[ -x "$SERVER_DIR/start-server.sh" ]]; then
      return 0
    fi
    sleep 10
  done
  die "Server install failed: $SERVER_DIR/start-server.sh not found"
}

link_steamclient() {
  local src="$STEAMCMD_DIR/linux64/steamclient.so"
  if [[ -f "$src" ]]; then
    mkdir -p "$HOME/.steam/sdk64"
    ln -sfn "$src" "$HOME/.steam/sdk64/steamclient.so"
  fi
}

# The server reads its JVM flags from ProjectZomboid64.json, which Steam
# overwrites on update, so the heap size is patched on every start.
set_max_memory() {
  [[ -z "$MAX_MEMORY" ]] && return 0
  local json="$SERVER_DIR/ProjectZomboid64.json"
  [[ -f "$json" ]] || die "$json not found, cannot set MAX_MEMORY"
  [[ "$MAX_MEMORY" =~ ^[0-9]+[kKmMgG]$ ]] || die "MAX_MEMORY must look like 4096m or 6g, got '$MAX_MEMORY'"
  log "Setting JVM max heap to $MAX_MEMORY"
  sed -E -i "s/\"-Xmx[0-9]+[kKmMgG]\"/\"-Xmx${MAX_MEMORY}\"/" "$json"
}

# Link (or copy) every file in $CONFIG_DIR into <ZOMBOID_DIR>/Server/.
#
# link: symlinks. With a Kubernetes ConfigMap/Secret volume (no subPath) the
#       files update in place; run `pz-console reloadoptions` to apply .ini
#       changes without a restart.
# copy: plain copies, refreshed on every start. Use this if the server
#       refuses to start because it cannot write its config files.
install_config() {
  local dest_dir="$ZOMBOID_DIR/Server"
  mkdir -p "$dest_dir"

  shopt -s nullglob
  local files=("$CONFIG_DIR"/*)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    log "WARNING: $CONFIG_DIR is empty; the server will generate default config files in $dest_dir"
    return 0
  fi

  local src name dest
  for src in "${files[@]}"; do
    # Kubernetes volume internals (..data, ..<timestamp>) are dotfiles and
    # never match the glob; the visible entries are symlinks to files.
    [[ -f "$src" ]] || continue
    name="$(basename "$src")"
    dest="$dest_dir/$name"
    [[ "$name" == "$SERVER_NAME"* ]] || log "WARNING: $name does not start with SERVER_NAME '$SERVER_NAME' and will be ignored by the server"
    case "$CONFIG_MODE" in
      link) ln -sfn "$src" "$dest" ;;
      copy) rm -f "$dest"; cp -L "$src" "$dest" ;;
      *) die "CONFIG_MODE must be 'link' or 'copy', got '$CONFIG_MODE'" ;;
    esac
    log "Config: $name ($CONFIG_MODE)"
  done
}

# shellcheck disable=SC2329 # invoked via trap
shutdown() {
  log "Received stop signal, sending 'quit' to the server (it saves before exiting)"
  printf 'quit\n' >&3 || true
}

main() {
  install_steamcmd
  if [[ "$UPDATE_ON_START" == "true" || ! -x "$SERVER_DIR/start-server.sh" ]]; then
    update_server
  fi
  link_steamclient
  set_max_memory
  install_config

  local server_args=(-cachedir="$ZOMBOID_DIR" -servername "$SERVER_NAME")

  # The admin password is only needed to create the player database on the
  # first start. The game's launcher echoes its arguments to the log, so it
  # is not passed once the database exists.
  if [[ ! -f "$ZOMBOID_DIR/db/$SERVER_NAME.db" ]]; then
    if [[ -n "$ADMIN_PASSWORD_FILE" ]]; then
      [[ -r "$ADMIN_PASSWORD_FILE" ]] || die "ADMIN_PASSWORD_FILE '$ADMIN_PASSWORD_FILE' is not readable"
      log "First start: creating admin account (the launcher prints the password to the log once)"
      server_args+=(-adminpassword "$(<"$ADMIN_PASSWORD_FILE")")
    else
      log "WARNING: first start without ADMIN_PASSWORD_FILE; the server will wait for an admin password on its console (use pz-console)"
    fi
  fi

  # The server reads commands from stdin. Feed it from a FIFO so that the
  # stop handler and `pz-console` can send commands to it.
  rm -f "$CONSOLE_FIFO"
  mkfifo "$CONSOLE_FIFO"
  exec 3<>"$CONSOLE_FIFO"

  trap shutdown TERM INT

  log "Starting server '$SERVER_NAME'"
  cd "$SERVER_DIR"
  ./start-server.sh "${server_args[@]}" "$@" <&3 &
  server_pid=$!

  # `wait` returns early when a trapped signal arrives; keep waiting until
  # the server process has actually exited.
  local status=0
  while :; do
    if wait "$server_pid"; then status=0; else status=$?; fi
    kill -0 "$server_pid" 2>/dev/null || break
  done
  log "Server exited with status $status"
  exit "$status"
}

main "$@"
