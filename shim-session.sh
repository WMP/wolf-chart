#!/bin/bash
# Wolf session runner: session.sh <app-deployment> [ENV=VALUE ...]
# On session start -> on-screen status + dump compositor env to a file + scale app to 1.
# On session end   -> scale app to 0. Status is drawn with gst-launch on the session's Wayland output.
set -u
APP="${1:?usage: session.sh <deployment> [ENV=VALUE ...]}"
shift
K=/shim/kubectl
ENVF="${XDG_RUNTIME_DIR:?}/session-${APP}.env"
env | grep -E '^(WAYLAND_DISPLAY|PULSE_SERVER|PULSE_SINK|PULSE_SOURCE|GAMESCOPE_)' > "$ENVF"
# optional Deployment env overrides (e.g. launcher mode) BEFORE scaling up
if [ "$#" -gt 0 ]; then
    echo "[shim:$APP] set env: $*"
    "$K" -n games set env deploy/"$APP" "$@" >/dev/null 2>&1
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

scale() { "$K" -n games scale deploy "$APP" --replicas="$1" >/dev/null 2>&1 && echo "[shim:$APP] replicas=$1"; }
trap 'msg ""; scale 0; exit 0' EXIT TERM INT

msg "Starting ${APP}... first run may pull the container image (up to 5 min)"
scale 1
if "$K" -n games rollout status deploy/"$APP" --timeout=300s >/dev/null 2>&1; then
    echo "[shim:$APP] pod ready"
    msg ""   # clear the message - the app takes over the screen
else
    echo "[shim:$APP] pod not ready within 300s"
    msg "ERROR: ${APP} did not become ready within 5 min (see: kubectl -n games describe deploy ${APP})"
fi
while :; do sleep 3600 & wait $!; done
