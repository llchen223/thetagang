# Docker daemon at boot with Colima (`com.user.colima.plist`)

The trading job (`com.user.thetagang`, see [README](./README.md#scheduling-with-launchd-comuserthetagangplist)) runs from `launchd` and `docker run`s the image. That only works if a **Docker daemon is already running** when the job fires.

**Do not rely on Docker Desktop for this.** On macOS, Docker Desktop's engine is a per-user GUI app — it only runs while a user is *logged in* to the desktop. A `launchd` daemon fires regardless of login, so when the machine is at the login screen (logged off) the 07:00 job runs but fails with:

```
Cannot connect to the Docker daemon at unix:///Users/<user>/.docker/run/docker.sock. Is the docker daemon running?
```

The fix is a **headless Docker daemon that runs at boot**, provided by [Colima](https://github.com/abiosoft/colima) (a Lima VM running the Docker engine), managed by its own `launchd` daemon.

## How the pieces fit together

```
boot
 └─ com.user.colima            (LaunchDaemon, RunAtLoad + KeepAlive)
      └─ colima start -f  ───►  Lima VM (Ubuntu) running dockerd
                                socket: /Users/lchen/.colima/default/docker.sock
weekdays 07:00
 └─ com.user.thetagang         (LaunchDaemon, StartCalendarInterval)
      └─ start.sh
           ├─ export DOCKER_HOST=unix:///Users/lchen/.colima/default/docker.sock
           ├─ wait until `docker info` succeeds
           └─ docker run llchen223/thetagang:main ...
```

`com.user.colima` is a **long-running service** (no schedule): `RunAtLoad` starts it at boot before/independent of any login, and `KeepAlive` restarts it if it ever exits. It just keeps the Docker VM up so the engine is ready whenever the 07:00 job needs it.

## Two boot requirements for the unattended case

`RunAtLoad` and `StartCalendarInterval` only deliver on their promise of "runs with nobody logged in" if the OS is actually up and awake at 07:00. Two macOS behaviors break that, and both bit this setup on **2026-06-02** (the 07:00 run silently didn't fire after a reboot):

### 1. FileVault must be OFF

With **FileVault on**, a reboot stops at the **pre-boot unlock screen**: macOS is not fully booted and **no `/Library/LaunchDaemons` jobs run** until a human logs in and unlocks the disk. So after an unattended reboot, `com.user.colima` never starts and the 07:00 `com.user.thetagang` trigger never has a daemon to fire — nothing runs, no error, until someone signs in.

> Diagnosis that proved it on 2026-06-02: machine booted 05:28, but the colima
> process didn't start until **07:01:45 — exactly at the `lchen` console login**
> (`ps -o lstart -p <colima_pid>`, `last`), so the 07:00 trigger was already
> gone. `fdesetup status` showed `FileVault is On`.

Auto-login is **not** a workaround — macOS disables it while FileVault is on. The fix used here was to **turn FileVault off** so reboots go straight into macOS and the daemons start headless:

```sh
sudo fdesetup disable          # prompts for a FileVault user's password
fdesetup status                # → "FileVault is Off"
```

Tradeoff: the disk is no longer encrypted at rest. If you must keep FileVault on, you instead have to reboot with `sudo fdesetup authrestart` (unlocks the disk for the *next* boot only) — which does **not** help an unexpected power loss.

### 2. Wake/power-on schedule so the Mac is up at 07:00

Even fully booted, a Mac that is **asleep or powered off** at 07:00 can miss the trigger — `StartCalendarInterval` does not reliably "catch up" a time missed during sleep. Schedule a wake (and power-on) shortly before the job:

```sh
sudo pmset repeat wakeorpoweron MTWRF 06:58:00
pmset -g sched                 # → "wakepoweron at 6:58AM weekdays only"
```

With FileVault off, a `poweron` event boots straight into macOS, so the 06:58 wake + headless daemons cover both "asleep" and "was powered off" cases.

## Prerequisites

Installed via Homebrew:

```sh
brew install colima docker
```

- `colima` — the VM/daemon manager.
- `docker` — the **standalone** Docker CLI at `/opt/homebrew/bin/docker`. This is required: Colima's docker-runtime dependency check looks for `docker` on `PATH`, and the daemon runs with a restricted `PATH` that does **not** include `/usr/local/bin` (the legacy location of Docker Desktop's CLI symlink). `start.sh` also uses `/opt/homebrew/bin/docker`, so the whole runtime path stands on its own.

> **Docker Desktop is not used here and is no longer installed** (removed
> 2026-06-02, reclaiming ~29 GB). Colima fully replaces it. If you ever reinstall
> Docker Desktop, disable its login autostart so the two engines don't both come
> up — set `"AutoStart": false` in
> `~/Library/Group Containers/group.com.docker/settings-store.json` (Settings →
> General → "Start Docker Desktop when you sign in") — and be aware that opening
> it flips the default `docker` context back to `desktop-linux`.

## The image lives in Colima's own store

Colima has a **separate image store** (an image built or pulled under any other daemon is not visible to Colima), and `llchen223/thetagang:main` is **private on Docker Hub** (a plain `docker pull` fails with "pull access denied"). Get the image into Colima's store one of these ways:

**Build it directly against Colima** — the normal path now that Docker Desktop is gone:

```sh
DOCKER_HOST=unix:///Users/lchen/.colima/default/docker.sock ./scripts/build-local.sh
# or run `docker context use colima` once, then build/run normally
```

**Or pull from Docker Hub** (needs a login, since the repo is private):

```sh
docker login
DOCKER_HOST=unix:///Users/lchen/.colima/default/docker.sock \
  docker pull llchen223/thetagang:main
```

**Or, if some other local daemon still has the image**, stream it across without a registry:

```sh
docker --context <other> save llchen223/thetagang:main | docker --context colima load
```

`docker run` only pulls when the image is absent locally, so once it's in Colima's store it's reused on every scheduled run. If you ever prune it, reload it one of the ways above.

## Install / load the daemon

```sh
# 1. Copy the plist into the system LaunchDaemons directory (requires sudo).
sudo cp config/com.user.colima.plist /Library/LaunchDaemons/

# 2. launchd requires root ownership and non-group/other-writable perms.
sudo chown root:wheel /Library/LaunchDaemons/com.user.colima.plist
sudo chmod 644        /Library/LaunchDaemons/com.user.colima.plist

# 3. Bootstrap (register + start) the daemon in the system domain.
sudo launchctl bootstrap system /Library/LaunchDaemons/com.user.colima.plist
```

On first start Colima downloads the Lima guest image and boots the VM (~30 s). The plist runs, as user `lchen`:

```
colima start --foreground --cpu 4 --memory 6 --disk 40 --vm-type vz \
  --mount /Users/lchen/workspace/thetagang:w
```

- **`--foreground`** keeps the process attached so `launchd` can supervise it (with `KeepAlive`).
- **`--mount …:w`** makes the host config dir writable inside the VM, so the container's `-v /Users/lchen/workspace/thetagang:/etc/thetagang` bind-mount can be written to.
- Resources `4 CPU / 6 GB / 40 GB` are sized for the IB Gateway/TWS JVM on a 16 GB host; adjust to taste.

## Manage

```sh
# Service state, pid, restart count (via launchd).
sudo launchctl print system/com.user.colima | grep -E 'state|pid|runs|last exit'

# Colima's own view (running? socket path?).
/opt/homebrew/bin/colima status

# Is the engine reachable on the expected socket?
DOCKER_HOST=unix:///Users/lchen/.colima/default/docker.sock \
  /opt/homebrew/bin/docker info | grep -E 'Server Version|Name:'

# Daemon log (colima start output).
tail -f /Users/lchen/.colima/colima-daemon.log
```

## Update or remove

```sh
# After editing the plist, boot it out and back in.
sudo launchctl bootout system/com.user.colima
sudo cp config/com.user.colima.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/com.user.colima.plist

# Remove entirely (also stops the VM via KeepAlive teardown).
sudo launchctl bootout system/com.user.colima
sudo rm /Library/LaunchDaemons/com.user.colima.plist
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Daemon crash-loops, log says `dependency check failed for docker: docker not found` | The standalone CLI isn't on the daemon's `PATH`. `brew install docker` (lands in `/opt/homebrew/bin`, which the plist's `PATH` includes), then `brew link --overwrite docker` if it wasn't symlinked. |
| `start.sh` fails with "Cannot connect to the Docker daemon" | Colima isn't up. Check `colima status` and `/Users/lchen/.colima/colima-daemon.log`. The job also waits up to ~5 min for the socket, so a slow boot shouldn't be fatal. |
| `pull access denied for llchen223/thetagang` on a scheduled run | The image isn't in Colima's store (it's private on Docker Hub). Load it — see [above](#the-image-lives-in-colimas-own-store). |
| VM won't start at a true logged-off boot | The `vz` (Apple Virtualization.framework) backend is the only piece not verifiable from a logged-in session. If it ever fails headless, change `--vm-type vz` to `--vm-type qemu` in the plist (no entitlement/session sensitivity) and reload. |
| Nothing runs at 07:00 after a reboot, no error in either log, colima only starts when you log in | **FileVault is on** — daemons don't run until the disk is unlocked at login. Turn it off (`sudo fdesetup disable`) or reboot via `sudo fdesetup authrestart`. See [Two boot requirements](#two-boot-requirements-for-the-unattended-case). |
| Job missed when the Mac was asleep / powered off at 07:00 | No wake scheduled. `sudo pmset repeat wakeorpoweron MTWRF 06:58:00`; verify with `pmset -g sched`. |

## Verifying the headless case

The whole point is operation with **no user logged in**. First confirm the [two boot requirements](#two-boot-requirements-for-the-unattended-case) are satisfied:

- `fdesetup status` → `FileVault is Off`
- `pmset -g sched` → `wakepoweron at 6:58AM weekdays only`

Then test end-to-end: log out (or reboot) and after the next weekday 07:00 trigger, check:

- `/Users/lchen/.colima/colima-daemon.log` — VM came up at boot
- `/Users/lchen/workspace/thetagang/thetagang.log` — the run connected to the engine instead of erroring on the socket

If `runs = 0` in `sudo launchctl print system/com.user.thetagang` and the colima process's `lstart` (`ps -o lstart -p <pid>`) matches your login time rather than boot time, the daemons waited for login — recheck FileVault.
