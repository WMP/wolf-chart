# Wolf on Kubernetes (Talos + NVIDIA passthrough)

Game streaming over Moonlight, running [Wolf](https://github.com/games-on-whales/wolf)
on a Kubernetes cluster. No X11 — Wolf renders headless through EGL and encodes
with NVENC, which sidesteps the NVKMS/display-engine issues that plague Xorg-based
setups on GPU passthrough.

**Model:** one `wolf` pod is the compositor + NVENC + Moonlight server. Each game
runs as its **own pod**, scaled `0 <-> 1` on demand by a shim wired into Wolf's
`process` runner. This is a hand-rolled precursor to what
[Fenrir](https://github.com/games-on-whales/fenrir) will do with CRDs once it
matures — here it's plain manifests + a small shim, which keeps networking simple
(flannel + hostNetwork, no CNI swap) and, crucially, works today.

Built and tested on Talos Linux with the NVIDIA GPU Operator (driver + toolkit as
Talos system extensions, `driver.enabled=false toolkit.enabled=false`). A consumer
GeForce (RTX 3080 Ti) is shared across pods via the operator's time-slicing.

## Files

| File | Purpose |
|---|---|
| `deployment.yaml` | the `wolf` pod (compositor); ServiceAccount `wolf`, an initContainer that copies `kubectl` in, and a postStart GBM symlink (see "Talos quirks") |
| `app-{heroic,steam,lutris}.yaml` | game pods (`replicas: 0`; the shim scales them). Each has a wrapper that waits for the session's Wayland socket and exits cleanly if there is none |
| `filebrowser.yaml` | simple HTTP file manager for uploading saves/mods, NodePort 30808 |
| `pvc-installers.yaml` | shared RWX volume for installers/mods (`/mnt/installers`) |
| `rbac.yaml` | ServiceAccount `wolf` + a Role letting it scale Deployments in the namespace |
| `shim-session.sh` | session runner: dumps session env to a file, scales the app Deployment `0<->1` (ConfigMap `wolf-shim`) |
| `session-env-hook.sh` | startup.d hook: loads the session env inside the game pod (ConfigMap `wolf-session-env`) |
| `sway-tweaks-hook.sh` | startup.d hook: sway focus/floating rules + keybindings (ConfigMap `wolf-session-env`) |
| `install.sh` | recreates everything from this repo (ConfigMaps built from the `.sh` sources + manifests) |

## How a session works

1. In Moonlight you pick an app; Wolf starts a session and runs the app's
   `run_cmd` = `bash /shim-cfg/session.sh <deployment> [ENV=VAL ...]`.
2. The shim writes the compositor session env (`WAYLAND_DISPLAY`, `PULSE_*`,
   `GAMESCOPE_*`) to a file on a shared hostPath, then
   `kubectl scale deploy <app> --replicas=1`.
3. The game pod mounts the same shared socket dir, loads that env via a
   `startup.d` hook, and its client connects to Wolf's compositor.
4. On session end the shim's trap scales the Deployment back to 0.

## Wolf app entries (config.toml — lives on disk, not in this repo)

Wolf's `config.toml` sits on a hostPath (e.g. `/var/mnt/steam/wolf-cfg`). Each app
is an entry pointing at the shim:

```toml
[[profiles.apps]]
title = 'Name shown in Moonlight'
start_virtual_compositor = true
    [profiles.apps.runner]
    type = 'process'
    run_cmd = 'bash /shim-cfg/session.sh <deployment> [ENV=VAL ...]'
```

The optional trailing `ENV=VAL` args let one Deployment back two Moonlight entries
(e.g. Lutris full GUI for installing vs. gamepad UI for playing) — the shim runs
`kubectl set env` on the Deployment before scaling it up.

## Adding a game

1. `cp app-heroic.yaml app-<name>.yaml` — change the name, image and `home` hostPath.
2. Add a `[[profiles.apps]]` entry to `config.toml` with
   `run_cmd = 'bash /shim-cfg/session.sh app-<name>'`.
3. `kubectl apply -f app-<name>.yaml` and restart the `wolf` pod.

## Talos / CDI quirks worth knowing

These bit us; documented so you don't rediscover them:

- **GBM backend** — the NVIDIA CDI spec on Talos injects `libnvidia-allocator.so`
  under `/usr/local/lib`, but libgbm only searches `/usr/lib/<arch>/gbm/`. Without
  a `nvidia-drm_gbm.so` symlink there, EGL/GBM apps panic (`Failed to create
  GsCUDABuf`). The `wolf` pod's postStart creates that symlink.
- **kernel modules** — `uinput`, `uhid`, `joydev` must be in the Talos machine
  config (`machine.kernel.modules`), or the container gets a *directory* at
  `/dev/uinput` instead of the device (virtual gamepads then fail).
- **user namespaces** — Steam/pressure-vessel and Flatpak need
  `user.max_user_namespaces` > 0; Talos (KSPP) defaults it to 0. Set via
  `machine.sysctls`.
- **`/dev/dri`** must be mounted into the game pods (render node for DMABUF).

## Known limitations

- If a session ends via SIGKILL (Wolf killing the shim before its trap runs), the
  Deployment can be left at `replicas=1`; the in-pod wrapper then exits cleanly
  instead of crash-looping. A proper controller (Fenrir) is the real fix.
- Time-slicing does **not** partition VRAM — a game and a heavy ML workload won't
  fit in VRAM at the same time.

## What you must provide

- An NFS server for installers/downloads — replace `NFS_SERVER` and the export
  paths in the `*.yaml` files with your own.
- hostPath locations for game homes (`/var/mnt/steam/...`) — adjust to your node.
- Wolf's `config.toml` with your app entries (not shipped here).
