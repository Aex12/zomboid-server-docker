# zomboid-server-docker

A small, non-root container image for the Project Zomboid dedicated server,
configured with the server's **own config files**, not environment variables.

- Debian slim + Valve's SteamCMD bootstrap. The game is installed into a
  volume by SteamCMD at startup, so the image stays small and contains no game
  files.
- Uses the JRE bundled with the server, so the Java version always matches the
  game build.
- Runs as UID 1000 and works with a read-only root filesystem.
- Config files are mounted read-only and symlinked into place, so a Kubernetes
  ConfigMap/Secret update reaches the server without a pod restart.
- A clean shutdown on `SIGTERM` sends `quit` to the server console, so the
  world is saved.

```
ghcr.io/<owner>/zomboid-server-docker:<version>
```

## Configuration

### Game settings: files in `/config`

Every regular file in `/config` is linked into `<ZOMBOID_DIR>/Server/` under
the same name. Use the file names the server expects for your `SERVER_NAME`:

| File                              | What                                   |
| --------------------------------- | -------------------------------------- |
| `servertest.ini`                  | Server options (ports, PvP, mods, ...) |
| `servertest_SandboxVars.lua`      | Sandbox / world rules                  |
| `servertest_spawnregions.lua`     | Spawn regions                          |

You don't need to write these by hand. Start the server once with an empty
`/config`. The server generates defaults for the installed game version in
`/data/zomboid/Server/`. Copy them out, edit them, and from then on mount them
in `/config`.

`servertest.ini` contains `Password=` and `RCONPassword=`, so you may want to
mount it from a Secret rather than a ConfigMap.

On start (and on `reloadoptions`) the server tries to write its config files
back and logs a `FileNotFoundException ... (Read-only file system)`. This is
expected and harmless: the server keeps running with the mounted values, and
the files in `/config` stay the single source of truth. In-game option changes
made by admins are not persisted.

### Container settings: environment variables

| Variable              | Default       | Description |
| --------------------- | ------------- | ----------- |
| `SERVER_NAME`         | `servertest`  | Server name; selects which config files and world the server uses. |
| `STEAM_BRANCH`        | `public`      | Steam branch to install (e.g. `public`, `unstable`). Clients must run the same build. |
| `UPDATE_ON_START`     | `true`        | Run SteamCMD `app_update` on every start. The game is always installed if missing. |
| `VALIDATE`            | `false`       | Add `validate` to the update (slow, re-hashes all files). |
| `MAX_MEMORY`          | *(unset)*     | JVM max heap, e.g. `6g`. Patched into `ProjectZomboid64.json` on each start. |
| `ADMIN_PASSWORD_FILE` | *(unset)*     | File containing the admin password, needed on the first start to create the admin account. |
| `CONFIG_MODE`         | `link`        | `link` (symlink, live updates) or `copy` (copied on each start). |

Extra container arguments are passed to `start-server.sh`, for example `-debug`.

### Volumes

| Path            | Content                                   | Persist?                            |
| --------------- | ----------------------------------------- | ----------------------------------- |
| `/data/server`  | Game install (several GB)                 | Recommended (avoids re-downloading) |
| `/data/zomboid` | Saves, player DB, logs, generated config  | **Yes**                             |
| `/data/steamcmd`, `/data/home` | SteamCMD and its state     | Optional                            |
| `/config`       | Your config files, read-only              | -                                   |
| `/tmp`          | Console FIFO, temp files                  | `tmpfs` / `emptyDir`, **must allow exec** |

Mounting a single volume at `/data` covers all of them. With the game install
persisted, `UPDATE_ON_START` only downloads what changed; a restart with no
game update takes about 30 seconds.

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

The server reads commands from a FIFO. Use `pz-console` to send it a command;
the output appears in the container logs:

```sh
kubectl exec deploy/zomboid -- pz-console players
kubectl exec deploy/zomboid -- pz-console reloadoptions
kubectl exec deploy/zomboid -- pz-console 'servermsg "Restart in 5 minutes"'
```

## Changing settings without a restart (Kubernetes)

1. Generate the ConfigMap **without** the hash suffix, so that a change edits
   the existing ConfigMap instead of rolling the Deployment:

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

2. Mount it as a directory (**no `subPath`**, because `subPath` mounts never
   update):

   ```yaml
   volumeMounts:
     - name: config
       mountPath: /config
       readOnly: true
   ```

3. After applying, wait for the kubelet to sync the volume (up to about a
   minute), then run `pz-console reloadoptions`.

Only `.ini` options are reloaded live. Sandbox settings and mod lists are read
at startup and need a restart.

## Kubernetes notes

- Run a single replica with `strategy: Recreate`; the world can't be shared.
- Set `terminationGracePeriodSeconds` to about 120, so the save on shutdown
  can finish.
- Set the memory limit comfortably above `MAX_MEMORY` (the JVM uses memory
  beyond its heap).
- Set `securityContext`: `runAsUser: 1000`, `runAsGroup: 1000`,
  `fsGroup: 1000`, `readOnlyRootFilesystem: true`, and mount an `emptyDir` at
  `/tmp`.

## Docker

```sh
docker run -d --name zomboid \
  -p 16261:16261/udp -p 16262:16262/udp \
  -v zomboid-data:/data \
  -v ./config:/config:ro \
  -v ./admin-password:/secrets/admin-password:ro \
  -e ADMIN_PASSWORD_FILE=/secrets/admin-password \
  -e MAX_MEMORY=6g \
  --read-only --tmpfs /tmp:exec \
  ghcr.io/<owner>/zomboid-server-docker:latest
```

Stop it with `docker stop -t 120 zomboid` so the save can finish.
