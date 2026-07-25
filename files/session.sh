#!/bin/bash
# Wolf session runner: session.sh <app-deployment> [ENV=VALUE ...]
# On session start -> on-screen status + dump compositor env to a file + scale app to 1.
# On session end   -> scale app to 0. Status is drawn with gst-launch on the session's Wayland output.
set -u
APP="${1:?usage: session.sh <deployment> [ENV=VALUE ...]}"
shift
K=/shim/kubectl
# namespace of the wolf pod (from the ServiceAccount) - lets several Wolf
# instances coexist on one cluster, each in its own namespace
NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo games)"
ENVF="${XDG_RUNTIME_DIR:?}/session-${APP}.env"
env | grep -E '^(WAYLAND_DISPLAY|PULSE_SERVER|PULSE_SINK|PULSE_SOURCE|GAMESCOPE_)' > "$ENVF"

# The stream geometry is whatever the Moonlight client asked for, so it is only
# known now - and it MUST reach the game pod as container env, not just through
# the session env file: the GOW images bake it into the compositor's config at
# container startup (launch-comp.sh writes `output * resolution
# ${GAMESCOPE_WIDTH}x${GAMESCOPE_HEIGHT}` for sway, and passes -W/-H to
# gamescope) before the startup.d hook loads the session env. A pod left with
# the chart's static session.* defaults renders at the wrong size and Wolf
# encodes a crop of it (e.g. a 1920x1200 stream cut out of a 2560x1440 sway
# output). Setting identical values is a no-op patch, so same-geometry sessions
# do not churn the pod.
GEOM=""
for var in GAMESCOPE_WIDTH GAMESCOPE_HEIGHT GAMESCOPE_REFRESH; do
    val="$(sed -n "s/^${var}=//p" "$ENVF" | head -1)"
    [ -n "$val" ] && GEOM="$GEOM $var=$val"
done
# geometry + optional per-entry overrides (e.g. launcher mode), BEFORE scaling up
if [ -n "$GEOM" ] || [ "$#" -gt 0 ]; then
    echo "[shim:$APP] set env:$GEOM $*"
    # shellcheck disable=SC2086
    "$K" -n "$NS" set env deploy/"$APP" $GEOM "$@" >/dev/null 2>&1
fi
echo "[shim:$APP] start: $(tr '\n' ' ' < $ENVF)"

MSG_PID=""
msg() {  # draw a fullscreen message on the session (kills the previous one)
    [ -n "$MSG_PID" ] && { kill "$MSG_PID" 2>/dev/null; wait "$MSG_PID" 2>/dev/null; }
    MSG_PID=""
    [ -z "${1:-}" ] && return 0
    gst-launch-1.0 -q videotestsrc pattern=solid-color foreground-color=0xFF10161E is-live=true \
        ! video/x-raw,width=1920,height=1080,framerate=10/1 \
        ! textoverlay text="$1" font-desc="Sans 16" halignment=center valignment=center \
        ! waylandsink >/dev/null 2>&1 &
    MSG_PID=$!
}

scale() { "$K" -n "$NS" scale deploy "$APP" --replicas="$1" >/dev/null 2>&1 && echo "[shim:$APP] replicas=$1"; }
trap 'msg ""; scale 0; exit 0' EXIT TERM INT

TIMEOUT="${SHIM_STARTUP_TIMEOUT:-300}"
msg "Starting ${APP}... first run may pull the container image"
scale 1
if "$K" -n "$NS" rollout status deploy/"$APP" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
    echo "[shim:$APP] pod ready"
    msg ""   # clear the message - the app takes over the screen
else
    echo "[shim:$APP] pod not ready within ${TIMEOUT}s"
    msg "ERROR: ${APP} did not become ready within ${TIMEOUT}s (see: kubectl -n ${NS} describe deploy ${APP})"
fi
while :; do sleep 3600 & wait $!; done
