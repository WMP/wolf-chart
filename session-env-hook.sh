# Sourced by /opt/gow/startup-app.sh (as the game user). Loads the Wolf session
# env (WAYLAND_DISPLAY, PULSE_*) that the shim wrote to the shared volume.
if [ -n "${SESSION_ENV_FILE:-}" ] && [ -f "${SESSION_ENV_FILE}" ]; then
    set -a; . "${SESSION_ENV_FILE}"; set +a
    echo "[session-env] loaded ${SESSION_ENV_FILE}: $(tr '\n' ' ' < ${SESSION_ENV_FILE})"
fi
