#!/usr/bin/env bash
# Project Zomboid dedicated server entrypoint.
#
# Game configuration is NOT templated from environment variables. Put the
# server's own config files (<SERVER_NAME>.ini, <SERVER_NAME>_SandboxVars.lua,
# ...) in $CONFIG_DIR. Secret .ini values (Password, DiscordToken, ...) go in
# $INI_SECRETS_DIR as one file per key and are injected into the .ini.
# Environment variables only control the container itself (install/update,
# JVM heap, where things live).
set -euo pipefail

STEAM_APP_ID=380870

STEAM_BRANCH="${STEAM_BRANCH:-public}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"
VALIDATE="${VALIDATE:-false}"
SERVER_NAME="${SERVER_NAME:-servertest}"
MAX_MEMORY="${MAX_MEMORY:-}"
ADMIN_PASSWORD_FILE="${ADMIN_PASSWORD_FILE:-}"
CONFIG_POLL_INTERVAL="${CONFIG_POLL_INTERVAL:-10}"
ZOMBIEBUDDY="${ZOMBIEBUDDY:-false}"
ZOMBIEBUDDY_POLICY="${ZOMBIEBUDDY_POLICY:-allow-all}"
ZOMBIEBUDDY_ARGS="${ZOMBIEBUDDY_ARGS:-}"
ZOMBIEBUDDY_WORKSHOP_ID=3619862853
AUTO_UPDATE="${AUTO_UPDATE:-false}"
GAME_APP_ID=108600 # Workshop items belong to the game, not the server app

STEAMCMD_DIR="${STEAMCMD_DIR:-/data/steamcmd}"
SERVER_DIR="${SERVER_DIR:-/data/server}"
ZOMBOID_DIR="${ZOMBOID_DIR:-/data/zomboid}"
CONFIG_DIR="${CONFIG_DIR:-/config}"
INI_SECRETS_DIR="${INI_SECRETS_DIR:-/secrets/ini}"
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

# A copy, not a symlink: SteamCMD may update itself (auto-update checks run it
# while the server is up), and must not swap the library under the server.
copy_steamclient() {
  local src="$STEAMCMD_DIR/linux64/steamclient.so"
  local dest="$HOME/.steam/sdk64/steamclient.so"
  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dest")"
    rm -f "$dest" # older images left a symlink here; cp would write through it
    cp "$src" "$dest"
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

# Rewrite the JVM's vmArgs in ProjectZomboid64.json: drop any ZombieBuddy
# agent, then append $1 if given. Idempotent, safe to run on every start.
set_zombiebuddy_agent() {
  local json="$SERVER_DIR/ProjectZomboid64.json" tmp
  [[ -f "$json" ]] || die "$json not found"
  tmp="$(mktemp)"
  jq --arg agent "${1:-}" '
    .vmArgs = ([.vmArgs[] | select((startswith("-javaagent:") and contains("ZombieBuddy")) | not)]
               + (if $agent == "" then [] else [$agent] end))
  ' "$json" > "$tmp"
  cat "$tmp" > "$json"
  rm -f "$tmp"
}

# ZombieBuddy (https://github.com/zed-0xff/ZombieBuddy) is a Java agent that
# Java mods (e.g. RealLimbs) need on the server too. The agent must be on the
# JVM command line before the server starts, so it is downloaded here with
# SteamCMD instead of waiting for the server's own Workshop download.
setup_zombiebuddy() {
  if [[ "$ZOMBIEBUDDY" != "true" ]]; then
    set_zombiebuddy_agent ""
    return 0
  fi

  case "$ZOMBIEBUDDY_POLICY" in
    allow-all|deny-new) ;;
    prompt) log "WARNING: ZOMBIEBUDDY_POLICY=prompt: startup blocks until each new Java mod is approved via pz-console" ;;
    *) die "ZOMBIEBUDDY_POLICY must be allow-all, deny-new or prompt, got '$ZOMBIEBUDDY_POLICY'" ;;
  esac

  local src="$SERVER_DIR/steamapps/workshop/content/$GAME_APP_ID/$ZOMBIEBUDDY_WORKSHOP_ID/mods/ZombieBuddy/libs/ZombieBuddy.jar"
  local jar="$SERVER_DIR/ZombieBuddy.jar"

  if [[ "$UPDATE_ON_START" == "true" || ! -f "$src" ]]; then
    local attempt output downloaded=false
    for attempt in 1 2 3; do
      log "Downloading ZombieBuddy (Workshop $ZOMBIEBUDDY_WORKSHOP_ID, attempt $attempt/3)"
      output="$("$STEAMCMD_DIR/steamcmd.sh" +force_install_dir "$SERVER_DIR" +login anonymous \
                  +workshop_download_item "$GAME_APP_ID" "$ZOMBIEBUDDY_WORKSHOP_ID" +quit 2>&1 || true)"
      if [[ "$output" == *"Success. Downloaded item"* ]]; then
        downloaded=true
        break
      fi
      (( attempt < 3 )) && sleep 10
    done
    if [[ "$downloaded" != "true" ]]; then
      printf '%s\n' "$output" | tail -n 5
      [[ -f "$src" ]] || die "ZombieBuddy download failed"
      log "WARNING: ZombieBuddy update failed, using the previous download"
    fi
  fi
  [[ -f "$src" ]] || die "ZombieBuddy.jar not found at $src"

  # Copied on every start so the agent always matches the mod's Lua side.
  cp -f "$src" "$jar"

  # frontend=console: no GUI on a server. With allow-all nothing is prompted;
  # approvals for deny-new/prompt are kept in $HOME/.zombie_buddy.
  local agent="-javaagent:$jar=frontend=console,policy=$ZOMBIEBUDDY_POLICY${ZOMBIEBUDDY_ARGS:+,$ZOMBIEBUDDY_ARGS}"
  set_zombiebuddy_agent "$agent"
  log "ZombieBuddy enabled (policy: $ZOMBIEBUDDY_POLICY)"
}

# Print the regular, non-hidden files of a directory. Kubernetes volume
# internals (..data, ..<timestamp>) are dotfiles and never match the glob;
# the visible entries are symlinks to files, which -f follows.
list_files() {
  local f
  [[ -d "$1" ]] || return 0
  for f in "$1"/*; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

# Read a secret file into the variable named $2: trailing newlines and a
# trailing CR are stripped; embedded newlines are rejected.
read_secret() {
  # Underscored names so they don't shadow the caller's variable named in $2.
  local _file="$1" _value
  _value="$(<"$_file")"
  _value="${_value%$'\r'}"
  [[ "$_value" != *$'\n'* ]] || { log "ERROR: secret $(basename "$_file") contains a newline"; return 1; }
  printf -v "$2" '%s' "$_value"
}

# Write <SERVER_NAME>.ini from $CONFIG_DIR, replacing the value of every key
# that has a file in $INI_SECRETS_DIR. Done line by line in bash so values
# containing ';', '#' or '=' (mod lists, passwords) are copied verbatim.
render_ini() {
  local name="$SERVER_NAME.ini"
  local src="$CONFIG_DIR/$name"
  local dest="$ZOMBOID_DIR/Server/$name"
  local tmp="$dest.tmp"

  declare -A secrets=()
  local file key value
  while IFS= read -r file; do
    key="$(basename "$file")"
    if [[ ! "$key" =~ ^[A-Za-z0-9_]+$ ]]; then
      log "WARNING: ignoring $file: not a valid .ini key name"
      continue
    fi
    read_secret "$file" value || return 1
    secrets[$key]="$value"
  done < <(list_files "$INI_SECRETS_DIR")

  if [[ ! -f "$src" ]]; then
    (( ${#secrets[@]} == 0 )) || log "WARNING: $src not found; secrets from $INI_SECRETS_DIR are not applied"
    return 0
  fi

  declare -A injected=()
  local line
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      key="${line%%=*}"
      if [[ "$line" == *=* && "$key" =~ ^[A-Za-z0-9_]+$ && -v "secrets[$key]" ]]; then
        printf '%s=%s\n' "$key" "${secrets[$key]}"
        injected[$key]=1
      else
        printf '%s\n' "$line"
      fi
    done < "$src"
    # Secrets for keys that are missing from the .ini are appended.
    for key in "${!secrets[@]}"; do
      [[ -v "injected[$key]" ]] || printf '%s=%s\n' "$key" "${secrets[$key]}"
    done
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$dest"

  if (( ${#secrets[@]} > 0 )); then
    log "Config: $name (rendered, secrets: $(printf '%s\n' "${!secrets[@]}" | sort | paste -sd ' '))"
  else
    log "Config: $name (rendered)"
  fi
}

# Install everything from $CONFIG_DIR into <ZOMBOID_DIR>/Server/:
# the .ini is rendered (secrets injected), every other file is symlinked.
install_config() {
  local dest_dir="$ZOMBOID_DIR/Server"
  mkdir -p "$dest_dir"

  local files=()
  mapfile -t files < <(list_files "$CONFIG_DIR")
  if (( ${#files[@]} == 0 )); then
    log "WARNING: $CONFIG_DIR is empty; the server will generate default config files in $dest_dir"
  fi

  local src name
  for src in "${files[@]}"; do
    name="$(basename "$src")"
    [[ "$name" == "$SERVER_NAME"* ]] || log "WARNING: $name does not start with SERVER_NAME '$SERVER_NAME' and will be ignored by the server"
    [[ "$name" == "$SERVER_NAME.ini" ]] && continue
    ln -sfn "$src" "$dest_dir/$name"
    log "Config: $name (linked)"
  done

  render_ini
}

# Hash of the names and contents of all config and secret files.
config_fingerprint() {
  local f
  { list_files "$CONFIG_DIR"; list_files "$INI_SECRETS_DIR"; } | while IFS= read -r f; do
    printf '%s\n' "$f"
    cat "$f" 2>/dev/null || true
  done | md5sum
}

# Poll for config/secret changes; on change re-install the config and ask the
# server to reload its .ini. Runs in the background next to the server.
watch_config() {
  local last="$1" current
  while sleep "$CONFIG_POLL_INTERVAL"; do
    current="$(config_fingerprint)"
    [[ "$current" == "$last" ]] && continue
    last="$current"
    log "Config change detected"
    # Subshell: a failing step must not kill the watcher.
    if ( install_config ); then
      log "Sending 'reloadoptions' (sandbox and mod changes need a restart)"
      printf 'reloadoptions\n' >&3
    else
      log "WARNING: config not reloaded; fix the error above"
    fi
  done
}

watcher_pid=""
updater_pid=""
stdin_pid=""

stop_helpers() {
  local pid
  for pid in "$watcher_pid" "$updater_pid" "$stdin_pid"; do
    [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
  done
}

# shellcheck disable=SC2329 # invoked via trap
shutdown() {
  log "Received stop signal, sending 'quit' to the server (it saves before exiting)"
  [[ -z "$watcher_pid" ]] || kill "$watcher_pid" 2>/dev/null || true
  [[ -z "$updater_pid" ]] || kill "$updater_pid" 2>/dev/null || true
  printf 'quit\n' >&3 || true
}

main() {
  install_steamcmd
  if [[ "$UPDATE_ON_START" == "true" || ! -x "$SERVER_DIR/start-server.sh" ]]; then
    update_server
  fi
  copy_steamclient
  set_max_memory
  setup_zombiebuddy

  local fingerprint
  fingerprint="$(config_fingerprint)"
  install_config

  local server_args=(-cachedir="$ZOMBOID_DIR" -servername "$SERVER_NAME")

  # The admin password is only needed to create the player database on the
  # first start. The game's launcher echoes its arguments to the log, so it
  # is not passed once the database exists.
  if [[ ! -f "$ZOMBOID_DIR/db/$SERVER_NAME.db" ]]; then
    if [[ -n "$ADMIN_PASSWORD_FILE" ]]; then
      [[ -r "$ADMIN_PASSWORD_FILE" ]] || die "ADMIN_PASSWORD_FILE '$ADMIN_PASSWORD_FILE' is not readable"
      local admin_password
      read_secret "$ADMIN_PASSWORD_FILE" admin_password || die "invalid ADMIN_PASSWORD_FILE"
      log "First start: creating admin account (the launcher prints the password to the log once)"
      server_args+=(-adminpassword "$admin_password")
    else
      log "WARNING: first start without ADMIN_PASSWORD_FILE; the server will wait for an admin password on its console (use pz-console)"
    fi
  fi

  # The server reads commands from stdin. Feed it from a FIFO so that the
  # stop handler, the config watcher and `pz-console` can send commands.
  rm -f "$CONSOLE_FIFO"
  mkfifo "$CONSOLE_FIFO"
  exec 3<>"$CONSOLE_FIFO"

  trap shutdown TERM INT

  log "Starting server '$SERVER_NAME'"
  cd "$SERVER_DIR"
  ./start-server.sh "${server_args[@]}" "$@" <&3 &
  local server_pid=$!

  if [[ "$CONFIG_POLL_INTERVAL" != "0" ]]; then
    watch_config "$fingerprint" &
    watcher_pid=$!
  fi

  if [[ "$AUTO_UPDATE" == "true" ]]; then
    export SERVER_NAME STEAM_BRANCH UPDATE_ON_START STEAMCMD_DIR SERVER_DIR ZOMBOID_DIR CONSOLE_FIFO
    pz-auto-update &
    updater_pid=$!
  fi

  # Forward the container's own stdin to the console, so `kubectl attach -i` /
  # `docker attach` work like the server's terminal. Without an open stdin
  # this reads /dev/null and exits immediately.
  cat >&3 &
  stdin_pid=$!

  # `wait` returns early when a trapped signal arrives; keep waiting until
  # the server process has actually exited.
  local status=0
  while :; do
    if wait "$server_pid"; then status=0; else status=$?; fi
    kill -0 "$server_pid" 2>/dev/null || break
  done
  stop_helpers
  log "Server exited with status $status"
  exit "$status"
}

main "$@"
