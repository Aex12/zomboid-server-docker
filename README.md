# zomboid-server-docker

A small, non-root container image for the Project Zomboid dedicated server,
configured with the server's **own config files**, not environment variables.

- Debian slim + Valve's SteamCMD bootstrap. The game is installed into a
  volume by SteamCMD at startup, so the image stays small and contains no game
  files.
- Uses the JRE bundled with the server, so the Java version always matches the
  game build.
- Runs as UID 1000 and works with a read-only root filesystem.
- Config comes from read-only mounted files; secret values (join password,
  Discord token, ...) are kept in separate files and injected into the `.ini`.
- Config and secret changes are picked up while the server runs and applied
  with `reloadoptions`, with no restart.
- A clean shutdown on `SIGTERM` sends `quit` to the server console, so the
  world is saved.
- A readiness check (`pz-ready`) that passes once players can join, for a
  Kubernetes readiness probe (see [Readiness](#readiness)).
- Optional automatic restarts, when a game or Workshop update is out and/or
  on a schedule, without kicking anyone (see [Automatic restarts](#automatic-restarts)).

```
ghcr.io/<owner>/zomboid-server:<version>
```

## Configuration

### Game settings: files in `/config`

Put the server's config files in `/config`, named for your `SERVER_NAME`:

| File                              | What                                   |
| --------------------------------- | -------------------------------------- |
| `servertest.ini`                  | Server options (ports, PvP, mods, ...) |
| `servertest_SandboxVars.lua`      | Sandbox / world rules                  |
| `servertest_spawnregions.lua`     | Spawn regions                          |

You don't need to write these by hand. Start the server once with an empty
`/config`. The server generates defaults for the installed game version in
`/data/zomboid/Server/`. Copy them out, edit them, and from then on mount them
in `/config`.

`<SERVER_NAME>.ini` is rendered into `/data/zomboid/Server/` with secrets
injected (see below). The other files are symlinked. The server tries to write
those back on start and logs a `FileNotFoundException ... (Read-only file
system)`. That is expected and harmless: the files in `/config` stay the single
source of truth.

### Secrets: files in `/secrets/ini`

Keep secret `.ini` values out of `/config`: leave them empty there
(`Password=`) and put each one in `/secrets/ini/<Key>`, with the value as the
file's content:

```
/secrets/ini/Password        -> Password=<content>
/secrets/ini/DiscordToken    -> DiscordToken=<content>
```

The value replaces that key's line in the rendered `.ini`; keys missing from
the `.ini` are appended. Values are copied verbatim (`;`, `#`, `=` are fine);
a trailing newline is stripped and multi-line values are rejected. Only key
names are logged, never values. The rendered file is mode `0600`.

Settings worth keeping secret: `Password` (join password), `DiscordToken`,
`WebhookAddress` and `RCONPassword` if you enable those. RCON is disabled
while `RCONPassword` is empty. You don't need it for administration
(`pz-console` sends commands to the same console), but automatic restarts use it
to count players. Inside the container it is reached on `127.0.0.1`, so there
is no need to publish the RCON port.

The admin password is not an `.ini` setting; see `ADMIN_PASSWORD_FILE`.

### Live reload

Every `CONFIG_POLL_INTERVAL` seconds the entrypoint checks `/config` and
`/secrets/ini` for changes. On a change it re-renders the config and sends
`reloadoptions` to the server. Only `.ini` options are reloaded live; sandbox
settings and mod lists are read at startup and need a restart.

### Container settings: environment variables

| Variable               | Default        | Description |
| ---------------------- | -------------- | ----------- |
| `SERVER_NAME`          | `servertest`   | Server name; selects which config files and world the server uses. |
| `STEAM_BRANCH`         | `public`       | Steam branch to install (e.g. `public`, `unstable`). Clients must run the same build. |
| `UPDATE_ON_START`      | `true`         | Run SteamCMD `app_update` on every start. The game is always installed if missing. |
| `VALIDATE`             | `false`        | Add `validate` to the update (slow, re-hashes all files). |
| `MAX_MEMORY`           | *(unset)*      | JVM max heap, e.g. `6g`. Patched into `ProjectZomboid64.json` on each start. |
| `ADMIN_PASSWORD_FILE`  | *(unset)*      | File containing the admin password, used on the first start to create the admin account. |
| `CONFIG_POLL_INTERVAL` | `10`           | Seconds between config change checks. `0` disables live reload. |
| `INI_SECRETS_DIR`      | `/secrets/ini` | Directory of secret `.ini` values. |
| `ZOMBIEBUDDY`          | `false`        | Install and load the [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) Java agent (see below). |
| `ZOMBIEBUDDY_POLICY`   | `allow-all`    | ZombieBuddy approval policy for Java mod JARs: `allow-all`, `deny-new` or `prompt`. |
| `ZOMBIEBUDDY_ARGS`     | *(unset)*      | Extra ZombieBuddy agent parameters, comma-separated (e.g. `verbosity=1`). |
| `AUTO_UPDATE`          | `false`        | Restart the server when a game or Workshop update is out (see below). Needs `RCONPassword`. |
| `AUTO_UPDATE_INTERVAL` | `15m`          | How often to check Steam for updates. |
| `RESTART_SCHEDULE`     | *(unset)*      | Cron expression for scheduled restarts, e.g. `0 4 * * *` (see below). Needs `RCONPassword`. |
| `RESTART_MIN_UPTIME`   | `off`          | Skip a scheduled restart if the server has been up for less than this, e.g. `72h`. |
| `TZ`                   | *(UTC)*        | Time zone of `RESTART_SCHEDULE`, e.g. `Europe/Madrid`. |
| `RESTART_REMINDER`     | `30m`          | How often to repeat the in-game warning while players are online. |
| `RESTART_EMPTY_GRACE`  | `2m`           | How long the server must stay empty after the last player leaves before it restarts. |
| `RESTART_MAX_WAIT`     | `off`          | If set (e.g. `6h`), restart anyway this long after the restart became pending, after a countdown. |
| `RESTART_COUNTDOWN`    | `10m`          | Warning time before a `RESTART_MAX_WAIT` restart. |
| `DISCORD_WEBHOOK_FILE` | *(unset)*      | File containing a Discord webhook URL; automatic restarts post their notices there. |

Durations take `s`, `m`, `h` or `d` (`90s`, `15m`, `6h`); a bare number is seconds.

Extra container arguments are passed to `start-server.sh`, for example `-debug`.

### Java mods (ZombieBuddy)

Some mods ship Java code and need the
[ZombieBuddy](https://steamcommunity.com/sharedfiles/filedetails/?id=3619862853)
Java agent. Mods whose JAR is client-only (`media/java/client/`) are skipped
on a dedicated server, but others (e.g. RealLimbs) also run on the server, and
the agent has to be on the JVM command line before the server starts.

With `ZOMBIEBUDDY=true`, on every start the entrypoint:

1. downloads the ZombieBuddy Workshop item with SteamCMD (anonymously), so the
   agent always matches the mod version the server loads;
2. copies `ZombieBuddy.jar` to the game directory;
3. adds `-javaagent:…/ZombieBuddy.jar=frontend=console,policy=$ZOMBIEBUDDY_POLICY`
   to the server's JVM options (`ProjectZomboid64.json`).

Setting it back to `false` removes the agent again. You still list
`ZombieBuddy` and its Workshop ID in `Mods=` / `WorkshopItems=` like any mod.

Approval policy: ZombieBuddy normally asks before loading each new or changed
Java mod JAR. A server can't show a dialog, so:

- `allow-all` (default): every Java mod JAR loads, including after Workshop
  updates. Java mods run unrestricted, so only use mods you trust.
- `deny-new`: only JARs already approved in `$HOME/.zombie_buddy/mod_approvals.json`
  load; anything new or updated is skipped silently.
- `prompt`: asks on the server console; startup waits until you answer with
  `pz-console`.

Players need ZombieBuddy installed on their own game too (see the mod's
installation guide).

### Automatic restarts

A background watcher (`pz-auto-restart`) restarts the server when a game or
Workshop update is out (`AUTO_UPDATE=true`), on a schedule
(`RESTART_SCHEDULE`), or both. Whatever the reason, once a restart is pending:

- **Nobody online:** it restarts right away.
- **Players online:** it warns them in game (repeated every
  `RESTART_REMINDER`) and restarts once everyone has left and the server
  has stayed empty for `RESTART_EMPTY_GRACE`. Nobody gets kicked, unless
  `RESTART_MAX_WAIT` is set: then the server restarts that long after the
  restart became pending, after a `RESTART_COUNTDOWN` warning.
- Updates found or a schedule match while waiting join the same restart.

#### Updates

When a Workshop mod (or the game) updates, players who already have the new
version can't join a server still running the old one. With
`AUTO_UPDATE=true`, the watcher checks Steam every `AUTO_UPDATE_INTERVAL`.
What is checked:

- **Workshop items** in `WorkshopItems=`: the `time_updated` from the Steam Web
  API against the installed copy (`steamapps/workshop/appworkshop_108600.acf`).
  Items not installed yet are skipped.
- **The game** on `STEAM_BRANCH`: the build ID from SteamCMD against the
  installed one (`steamapps/appmanifest_380870.acf`). Only with
  `UPDATE_ON_START=true`, since otherwise a restart wouldn't install it.

The restart is `quit` on the console: the server saves and exits, the container
exits with status 0, and the container runtime starts it again (Kubernetes
always does; with Docker use `--restart unless-stopped`). On start, SteamCMD
installs the game update and the server downloads the updated Workshop items.

It never restarts twice for the same version: if an update is still missing
after a restart for it, the watcher logs a warning and leaves it alone. Its
state lives in `/data/zomboid/auto-restart/`.

#### Scheduled restarts

`RESTART_SCHEDULE` takes a cron expression, run by
[supercronic](https://github.com/aptible/supercronic) in the container's `TZ`
(UTC unless set). An invalid expression stops the container at start.

| Schedule | `RESTART_SCHEDULE` | `RESTART_MIN_UPTIME` |
| --- | --- | --- |
| Every day at 6:00 | `0 6 * * *` | |
| Every 4 hours | `0 */4 * * *` | |
| Every 3 days at 4:00 | `0 4 * * *` | `72h` |
| Mondays and Thursdays at 5:30 | `30 5 * * mon,thu` | |

At a match the restart becomes pending, unless the server has been up for less
than `RESTART_MIN_UPTIME`. That covers "every N days", which cron can't express
well (`*/3` in the day field restarts on the 31st and again on the 1st), and
avoids a scheduled restart shortly after another one (e.g. for an update). Note
that `72h` with a 4:00 schedule needs an uptime of a full 72 hours, so set it a
bit lower (e.g. `71h`) if the server comes back a few minutes after 4:00.

Every restart also installs game and Workshop updates, as on any start.

#### Requirements

The watcher needs RCON to count players (set `RCONPassword`, see
[Secrets](#secrets-files-in-secretsini)); without it, automatic restarts stay
off and log why. Follow it in the logs with `grep auto-restart`.

#### Discord notices

Set `DISCORD_WEBHOOK_FILE` to a file holding a
[Discord webhook](https://support.discord.com/hc/en-us/articles/228383668) URL
(in Discord: *Server Settings → Integrations → Webhooks → New Webhook → Copy
Webhook URL*). The watcher posts when:

- a restart is pending while players are online (and when an update or the
  schedule adds to it),
- the server restarts,
- the server is back online after that restart.

Keep the URL secret: anyone with it can post to the channel. Mount it like the
other secrets, not in an environment variable. Don't put it in `/secrets/ini`:
every file there is written into the `.ini`.

### Volumes

| Path            | Content                                   | Persist?                            |
| --------------- | ----------------------------------------- | ----------------------------------- |
| `/data/server`  | Game install (several GB)                 | Recommended (avoids re-downloading) |
| `/data/zomboid` | Saves, player DB, logs, rendered config   | **Yes**                             |
| `/data/steamcmd`, `/data/home` | SteamCMD and its state     | Optional                            |
| `/config`       | Your config files, read-only              | -                                   |
| `/secrets/ini`  | Secret `.ini` values, read-only           | -                                   |
| `/tmp`          | Console FIFO, temp files                  | `tmpfs` / `emptyDir`, **must allow exec** |

Mounting a single volume at `/data` covers all of the `/data` paths. With the
game install persisted, `UPDATE_ON_START` only downloads what changed; a
restart with no game update takes about 30 seconds.

`/tmp` must not be `noexec`: the server's SQLite driver extracts and loads a
native library from it. Without exec, the server fails with
`NativeLibraryNotFoundException`. Kubernetes `emptyDir` is fine; with Docker
use `--tmpfs /tmp:exec`.

The game's launcher prints its arguments to the log. On the first start that
includes the admin password from `ADMIN_PASSWORD_FILE`. It is not passed again
once the player database exists.

### Ports

`16261/udp` and `16262/udp` (the defaults; set by `DefaultPort` /
`UDPPort` in the `.ini`).

## Server console

The container's stdin is forwarded to the server console, so you can attach
to it like the server's own terminal: type commands, see the output live.

```sh
kubectl attach -i deploy/zomboid   # needs `stdin: true` in the pod spec
docker attach --sig-proxy=false zomboid   # needs `docker run -i`
```

Keep `tty: false` (Kubernetes) and don't use `docker run -t`: with a TTY,
Ctrl+C in the attached terminal sends SIGINT to the container and stops the
server. Without one, Ctrl+C only ends the attach.

For one-off commands, `pz-console` writes to the same console; the output
appears in the container logs:

```sh
kubectl exec deploy/zomboid -- pz-console players
kubectl exec deploy/zomboid -- pz-console save
kubectl exec deploy/zomboid -- pz-console 'servermsg "Restart in 5 minutes"'
```

With RCON enabled, `pz-rcon` sends a command the same way but prints the
reply right there instead of in the logs:

```sh
kubectl exec deploy/zomboid -- pz-rcon players
```

## Kubernetes

Config in a ConfigMap, secrets in Secrets (for example SOPS-encrypted). Use
`disableNameSuffixHash` so that an edit updates the existing ConfigMap in
place (picked up by live reload) instead of rolling the Deployment:

```yaml
# kustomization.yaml
configMapGenerator:
  - name: zomboid-config
    files:
      - config/servertest.ini
      - config/servertest_SandboxVars.lua
    options:
      disableNameSuffixHash: true
```

```yaml
# secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: zomboid-ini-secrets
stringData:
  Password: friends-only
---
apiVersion: v1
kind: Secret
metadata:
  name: zomboid-admin
stringData:
  admin-password: change-me
```

```yaml
# deployment.yaml (excerpt)
env:
  - name: ADMIN_PASSWORD_FILE
    value: /secrets/admin/admin-password
volumeMounts:
  - { name: data, mountPath: /data }
  - { name: tmp, mountPath: /tmp }
  - { name: config, mountPath: /config, readOnly: true }
  - { name: ini-secrets, mountPath: /secrets/ini, readOnly: true }
  - { name: admin, mountPath: /secrets/admin, readOnly: true }
readinessProbe:
  exec: { command: ["pz-ready"] }
  periodSeconds: 10
volumes:
  - { name: data, persistentVolumeClaim: { claimName: zomboid-data } }
  - { name: tmp, emptyDir: {} }
  - { name: config, configMap: { name: zomboid-config } }
  - { name: ini-secrets, secret: { secretName: zomboid-ini-secrets } }
  - { name: admin, secret: { secretName: zomboid-admin } }
```

Mount config and secrets as directories, **never with `subPath`**: `subPath`
mounts are not updated when the ConfigMap or Secret changes. The kubelet syncs
changes within about a minute, then live reload applies them.

Also:

- Run a single replica with `strategy: Recreate`; the world can't be shared.
- Set `terminationGracePeriodSeconds` to about 120, so the save on shutdown
  can finish.
- Set the memory limit comfortably above `MAX_MEMORY` (the JVM uses memory
  beyond its heap).
- Set `securityContext`: `runAsUser: 1000`, `runAsGroup: 1000`,
  `fsGroup: 1000`, `readOnlyRootFilesystem: true`.

### Readiness

`pz-ready` passes once the server has bound its game port (`DefaultPort`
from the `.ini`, default 16261). The server does that as the last step of
startup, after the game update, Workshop downloads and loading the world, so
**Ready means players can join**. Until then the pod shows `0/1`, and
`kubectl wait --for=condition=Ready` and GitOps health checks (Argo CD, Flux)
wait for a joinable server instead of a started container.

It only checks that the server has started, not that it is responsive: a hung
server stays Ready. There is deliberately no liveness probe (killing a game
server on a false positive loses progress) and no startup probe (it would
restart a server that is legitimately waiting on its console, e.g. on the
first start without `ADMIN_PASSWORD_FILE`).

Don't run the pod with `hostNetwork: true`. Besides exposing the host's
network to the container, it breaks the check: `pz-ready` reads the
container's socket table (`/proc/net/udp`), which with `hostNetwork` is the
host's, so any other process on the node using the port would make the pod
look Ready.

## Docker

```sh
docker run -d --name zomboid --restart unless-stopped \
  -p 16261:16261/udp -p 16262:16262/udp \
  -v zomboid-data:/data \
  -v ./config:/config:ro \
  -v ./secrets/ini:/secrets/ini:ro \
  -v ./secrets/admin-password:/secrets/admin-password:ro \
  -e ADMIN_PASSWORD_FILE=/secrets/admin-password \
  -e MAX_MEMORY=6g \
  --read-only --tmpfs /tmp:exec \
  ghcr.io/<owner>/zomboid-server:latest
```

Stop it with `docker stop -t 120 zomboid` so the save can finish.
