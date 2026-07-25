# wolf-chart — Wolf (Moonlight game streaming) on Kubernetes

A Helm chart for [Wolf](https://github.com/games-on-whales/wolf): game
streaming over Moonlight from a Kubernetes cluster. No X11 — Wolf renders
headless through EGL and encodes in hardware (NVENC on NVIDIA, VAAPI/QSV on
AMD/Intel), which sidesteps the NVKMS/display-engine issues that plague
Xorg-based setups on GPU passthrough.

**Model:** one `wolf` pod is the compositor + hardware encoder + Moonlight
server. Each game launcher runs as its **own pod**, scaled `0 <-> 1` on demand
by a shim wired into Wolf's `process` runner.

Built and tested on Talos Linux with the NVIDIA GPU Operator (driver + toolkit
as Talos system extensions, `driver.enabled=false toolkit.enabled=false`), a
consumer GeForce (RTX 3080 Ti) shared across pods via time-slicing. The
pre-chart raw manifests this grew out of live on the
[`workload` branch](../../tree/workload).

## What the chart gives you

- **Launchers as values** — each entry under `apps:` renders BOTH the game
  Deployment and its Moonlight menu entry (with the launcher's official
  games-on-whales icon as box art; override with `apps.<name>.icon`). All default to `enabled: false`;
  `values.yaml` documents what each launcher is best for (Steam, Heroic,
  Lutris). Games you install *inside* a launcher are runtime data on its home
  volume — no chart change needed.
- **`config.toml` managed for you** — an `apps-sync` sidecar reconciles your
  `apps:` into Wolf's config through its local unix-socket API. Pairing state
  (`paired_clients`, `uuid`) is never touched; manually added apps are left
  alone; Wolf's stock docker demo apps are pruned (disable with
  `appsSync.pruneDefault: false`).
- **One GPU vendor switch** — `gpu.vendor: nvidia | amd | intel | none` (see
  below).
- **Session-safe scaling** — game Deployments start at 0 replicas and the shim
  scales them per session; `helm upgrade` preserves the current scale.

## Requirements

- A GPU node with `/dev/dri` (all vendors) and, for NVIDIA, the driver +
  container toolkit or GPU Operator.
- Kernel modules on the node: `uinput`, `uhid`, `joydev` (virtual gamepads);
  user namespaces enabled (`user.max_user_namespaces > 0`) for Steam/Flatpak.
- Pods run **privileged** with hostPath device access. On PSA-enforcing
  clusters: `kubectl label ns games pod-security.kubernetes.io/enforce=privileged`
- Node-local storage path for Wolf state and game homes (`paths.base`).

## Install

```bash
helm repo add wolf-chart https://wmp.github.io/wolf-chart
helm repo update

cat > my-values.yaml <<'EOF'
gpu:
  vendor: nvidia            # nvidia | amd | intel | none
nodeSelector:
  kubernetes.io/hostname: my-gpu-node   # pin to your GPU node
paths:
  base: /var/lib/wolf       # node-local state; Talos: use /var/mnt/...

# Stream defaults for the game pods - match your Moonlight client/display:
session:
  width: 2560
  height: 1440
  refresh: 60

# NOTE memory limits: game pods default to 9Gi limit / 3Gi request.
# Heavy titles (modern AAA, shader compilation) can blow past 9Gi and the
# game gets OOM-killed mid-session - raise the default here, or per
# launcher via apps.<name>.resources.
appDefaults:
  resources:
    requests:
      cpu: "2"
      memory: 3Gi
    limits:
      memory: 9Gi

# All supported launchers - enable the ones you need:
apps:
  # Steam: your Steam library. Big Picture on a virtual display, Proton
  # preconfigured, gamepad-first. If most of your games are on Steam,
  # enable this one and you're done.
  steam:
    enabled: true
  # Heroic: Epic Games Store, GOG and Amazon Prime Gaming libraries -
  # a friendly launcher UI with Proton/Wine handled for you.
  heroic:
    enabled: false
  # Lutris: everything else - custom Wine setups, standalone installers
  # (drop them on /mnt/installers), emulators, battle.net-style launchers.
  # Power-user tool: full GUI for installing; add a second Moonlight entry
  # with args ["WOLF_LUTRIS_GAMEPAD_UI_ENABLE=1"] for a couch/gamepad
  # frontend.
  lutris:
    enabled: false
EOF

helm upgrade --install wolf wolf-chart/wolf -f my-values.yaml -n games --create-namespace
```

Then wait for the wolf pod, add the node's IP in Moonlight and pair — the
post-install notes (`helm status wolf -n games`) contain the exact
pairing commands (Wolf's API listens on a local unix socket).

Installing from source instead: `git clone` this repo, then
`helm dependency build . && helm upgrade --install wolf . -f my-values.yaml -n games --create-namespace`.

## How a session works

1. In Moonlight you pick an app; Wolf starts a session and runs the app's
   `run_cmd` = `bash /shim-cfg/session.sh <deployment> [ENV=VAL ...]`.
2. The shim writes the compositor session env (`WAYLAND_DISPLAY`, `PULSE_*`,
   `GAMESCOPE_*`) to a file on a shared hostPath, pushes the geometry the client
   negotiated into the Deployment's env (the GOW images bake the resolution into
   the compositor config at container startup, so `session.width/height/refresh`
   are only what a pod *starts* with), then
   `kubectl scale deploy <app> --replicas=1`.
3. The game pod mounts the same shared socket dir, loads that env via a
   `startup.d` hook, and its client connects to Wolf's compositor.
4. On session end the shim's trap scales the Deployment back to 0.

One Deployment can back several Moonlight entries: `apps.<name>.args` sets the
default entry's `ENV=VAL` overrides and `apps.<name>.entries`
(`[{title, args}]`) adds more — e.g. Lutris full GUI for installing vs. a
gamepad frontend for playing. The shim applies the env with `kubectl set env`
before scaling up.

## GPU vendors

Wolf picks the encoder at runtime (NVENC → VAAPI → QSV → software) and the
games-on-whales images ship mesa, so all three vendors work.

`gpu.vendor` sets the extended resource on GPU containers (`nvidia.com/gpu` /
`amd.com/gpu` / `gpu.intel.com/i915`), the NVIDIA env
(`NVIDIA_DRIVER_CAPABILITIES=all` — NVENC needs the `video` capability) and
the game pods' `GOW_REQUIRED_DEVICES`. Override the resource name with
`gpu.resource` for MIG slices (`nvidia.com/mig-1g.10gb`), time-slice renames
(`nvidia.com/gpu.shared`) or the new Intel driver (`gpu.intel.com/xe`), or set
it to `""` to request nothing — with no device plugin installed, privileged +
the `/dev/dri` hostPath is enough for access; use `nodeSelector` for
placement. Set `gpu.runtimeClassName: nvidia` on k3s/RKE2 where the NVIDIA
runtime is not the containerd default. GPU sharing (NVIDIA time-slicing,
Intel `sharedDevNum`) is configured on the device-plugin side — workloads
still request 1 unit.

The GBM hook (`files/ensure-gbm-symlink.sh`, postStart in every pod) handles a
cross-distro NVIDIA quirk: libgbm only searches `/usr/lib/<arch>/gbm/` for
`nvidia-drm_gbm.so`, but where the driver injection drops
`libnvidia-allocator.so.1` varies (Talos CDI: `/usr/local/lib`; GPU Operator
driver container: `/usr/lib/x86_64-linux-gnu`). Without the symlink, EGL/GBM
apps panic (`Failed to create GsCUDABuf`). The hook searches the usual
locations plus the linker cache; it is a no-op where the toolkit already made
the symlink, and on AMD/Intel.

## Multiple GPU nodes

A Wolf session **cannot span nodes**: the compositor and the game pod share
Wayland/PulseAudio unix sockets over a node-local hostPath plus `hostIPC`, and
the video path is zero-copy DMABUF on one GPU. Two consequences:

- **Same-node guarantee** — game pods carry a required `podAffinity` to the
  wolf server pod, so they always schedule onto whichever node the wolf pod
  runs on.
- **Scaling out = one release per GPU node**, each in its own namespace (the
  shim reads its namespace from the ServiceAccount, so instances don't step on
  each other), with `nodeSelector` pinned to that node. Each instance uses
  `hostNetwork`, so each node is its own Moonlight host — clients pair with
  each one separately.

With a single release and >1 matching GPU node, always pin `nodeSelector` to
one host — game homes and Wolf state live on that node's hostPaths, so a
silent reschedule would look like your saves disappeared.

## Values overview

See `values.yaml` for the full annotated reference. The high-traffic knobs:

| Key | What it does |
|---|---|
| `apps.<name>.enabled` | deploy the launcher + its Moonlight entry (default `false`) |
| `apps.<name>.{image,home,args,entries,env,resources}` | per-launcher overrides |
| `apps.<name>.icon` | box art in Moonlight — URL or path inside the wolf container, `""` for none (the three built-in launchers default to their games-on-whales icon) |
| `appDefaults.{sessionWaitSeconds,scaleDownWhenNoSession}` | how long a game pod waits for a session before scaling its own Deployment to 0 (releases the GPU unit; needs the SA token in game pods) |
| `appDefaults.resources` | default game-pod resources — **memory limit `9Gi`**: too low for heavy titles (OOM-kill mid-session), raise here or per launcher |
| `gpu.{vendor,resource,count,runtimeClassName,renderNode}` | GPU vendor switch (see above) |
| `nodeSelector` | pin the wolf pod to your GPU node |
| `paths.base` | node-local hostPath root for config/sockets/homes |
| `session.{width,height,refresh,runSway,user,uid,gid}` | stream resolution/refresh + in-pod user defaults for game pods |
| `storage.installers.*` | shared RWX PVC (or `existingClaim`) mounted at `storage.installers.mountPath`, default `/mnt/installers` |
| `apps.<name>.extraVolumes` / `extraVolumeMounts` | extra shares per launcher (e.g. a read-only NFS mount with installers) |
| `filebrowser.enabled` | no-auth HTTP file manager for saves/mods (LAN only!); `filebrowser.extraVolumes`/`extraVolumeMounts` expose extra shares under `/srv` |
| `appsSync.{enabled,pruneDefault,interval}` | the config.toml reconciler |
| `extraDeploy` | arbitrary extra manifests rendered with the release |

## Known limitations

- **No sound for apps the sidecar creates until [wolf#466](https://github.com/games-on-whales/wolf/pull/466) lands.**
  Wolf drops `start_audio_server` when an app is added through its API
  ([wolf#465](https://github.com/games-on-whales/wolf/issues/465)): the session
  starts a virtual compositor but no virtual sink, so the game's audio ends up in
  `auto_null` and Moonlight is silent. Video is unaffected. Wolf parses the flag
  correctly from `config.toml`, so the stop-gap is to set
  `start_audio_server = true` in that app's `[[profiles.apps]]` block under
  `paths.config` and restart the wolf pod; the value survives until apps-sync
  recreates the entry (a title, args or icon change does that).
- If a session ends via SIGKILL (Wolf killing the shim before its trap runs),
  the Deployment can be left at `replicas=1`. The in-pod wrapper waits
  `appDefaults.sessionWaitSeconds` (default 60) for a session socket and then
  scales the Deployment back to 0 itself, so a pod that nobody is streaming to
  releases its GPU unit and CPU/memory requests. It never exits to achieve that -
  a Deployment pod always has restartPolicy=Always, so exiting means an endless
  kubelet restart loop. Set `appDefaults.scaleDownWhenNoSession: false` to keep
  the ServiceAccount token out of the game pods; such a pod then idles on its GPU
  unit instead. A proper controller (Fenrir) is still the cleaner fix.
- Game-pod `replicas` are preserved across `helm upgrade` via `lookup`, which
  only works server-side: `helm template` and `helm diff` render `replicas: 0`
  (phantom drift when a session is active), and GitOps controllers
  (ArgoCD/Flux) would scale running games to 0 on sync — add
  `ignoreDifferences` on `/spec/replicas` for the app Deployments.
- `helm upgrade` that changes the chart's shell scripts restarts the wolf pod
  (and any game pod whose scripts changed) — avoid upgrading during an active
  session.
- GPU time-slicing does **not** partition VRAM — a game and a heavy ML
  workload won't fit in VRAM at the same time.
