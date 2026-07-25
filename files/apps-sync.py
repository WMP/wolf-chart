#!/usr/bin/env python3
"""Reconcile Wolf's Moonlight app list with the chart-rendered desired state.

Talks to Wolf's local API over its unix socket (GET /api/v1/apps,
POST /api/v1/apps/add, POST /api/v1/apps/delete). Wolf persists API changes
into config.toml itself, rewriting ONLY the apps section - pairing state
(paired_clients, uuid) is never touched.

Management contract:
  - desired apps come from APPS_FILE (JSON list rendered from values.yaml)
  - an existing app is "chart-managed" iff its run_cmd references the session
    shim; only managed apps are ever deleted or replaced
  - with PRUNE_DEFAULT=true, Wolf's stock docker-runner demo apps are also
    removed (they cannot work in this k8s setup)
  - manually added process apps are never touched

Wolf's add endpoint requires a full app object (including resolved GStreamer
pipeline strings). Those are copied from an existing app ("sample"); since
Wolf always boots with its default apps present, a sample exists on first
sync. It is cached to SAMPLE_CACHE (on the persistent config volume) so later
syncs work even after all defaults were pruned. Pipelines are not persisted
to config.toml by Wolf - they get re-resolved from [gstreamer] defaults on
restart - so a stale sample only affects the current process lifetime.
"""
import http.client
import json
import os
import socket
import sys
import time
import zlib

SOCKET_PATH = os.environ.get("WOLF_SOCKET_PATH", "/tmp/sockets/wolf.sock")
APPS_FILE = os.environ.get("APPS_FILE", "/opt/wolf-apps/apps.json")
PRUNE_DEFAULT = os.environ.get("PRUNE_DEFAULT", "true").lower() == "true"
INTERVAL = int(os.environ.get("SYNC_INTERVAL", "300"))
SAMPLE_CACHE = os.environ.get("SAMPLE_CACHE", "")
# marker identifying chart-managed apps; must match the run_cmd rendered by
# the chart (both come from the wolf.shim.path helper - see _helpers.tpl)
SHIM_MARKER = os.environ.get("SHIM_MARKER", "/shim-cfg/session.sh")
SAMPLE_FIELDS = (
    "h264_gst_pipeline",
    "hevc_gst_pipeline",
    "av1_gst_pipeline",
    "opus_gst_pipeline",
    "render_node",
)
# hevc/av1 are legitimately "" on hardware without those encoders
# (Wolf resolves them to empty strings) - only these must be non-empty:
REQUIRED_SAMPLE_FIELDS = (
    "h264_gst_pipeline",
    "opus_gst_pipeline",
    "render_node",
)


def log(msg):
    print(f"[apps-sync] {msg}", flush=True)


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost")
        self.unix_path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(10)
        sock.connect(self.unix_path)
        self.sock = sock


def api(method, endpoint, body=None):
    conn = UnixHTTPConnection(SOCKET_PATH)
    try:
        payload = json.dumps(body) if body is not None else None
        headers = {"Content-Type": "application/json"} if payload else {}
        conn.request(method, endpoint, body=payload, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        if resp.status != 200:
            raise RuntimeError(f"{method} {endpoint} -> {resp.status}: {data[:300]!r}")
        return json.loads(data) if data else {}
    finally:
        conn.close()


def app_id(title):
    # stable numeric-string id derived from the title (Moonlight-safe)
    return str(zlib.crc32(title.encode()))


def load_sample(current):
    """Pipeline/render_node template copied from any complete existing app."""
    for app in current:
        if all(app.get(f) for f in REQUIRED_SAMPLE_FIELDS):
            sample = {f: app.get(f, "") for f in SAMPLE_FIELDS}
            if SAMPLE_CACHE:
                try:
                    with open(SAMPLE_CACHE, "w") as fh:
                        json.dump(sample, fh)
                except OSError as exc:
                    log(f"warning: cannot write sample cache: {exc}")
            return sample
    if SAMPLE_CACHE and os.path.exists(SAMPLE_CACHE):
        try:
            with open(SAMPLE_CACHE) as fh:
                return json.load(fh)
        except (OSError, ValueError) as exc:
            log(f"warning: cannot read sample cache: {exc}")
    return None


def build_app(desired, sample):
    app = dict(sample)
    app.update(
        {
            "title": desired["title"],
            "id": app_id(desired["title"]),
            "support_hdr": False,
            "start_virtual_compositor": desired.get("start_virtual_compositor", True),
            "start_audio_server": desired.get("start_audio_server", True),
            # box art shown in Moonlight; Wolf accepts a URL or an in-container
            # path, and "" means no icon
            "icon_png_path": desired.get("icon_png_path", "") or "",
            "runner": desired["runner"],
        }
    )
    if desired.get("render_node"):
        app["render_node"] = desired["render_node"]
    return app


def reconcile(desired):
    current = api("GET", "/api/v1/apps").get("apps", [])
    sample = load_sample(current)
    by_title = {a["title"]: a for a in current}
    desired_titles = {d["title"] for d in desired}
    changed = False

    # delete: managed apps that are stale or whose run_cmd drifted,
    # plus (optionally) Wolf's stock docker demo apps
    for app in current:
        runner = app.get("runner") or {}
        run_cmd = runner.get("run_cmd", "") or ""
        managed = SHIM_MARKER in run_cmd
        is_docker = (runner.get("type") or "").lower() == "docker"
        stale = app["title"] not in desired_titles
        drifted = False
        if managed and not stale:
            want = next(d for d in desired if d["title"] == app["title"])
            drifted = want["runner"].get("run_cmd") != run_cmd or (
                (want.get("icon_png_path") or "") != (app.get("icon_png_path") or "")
            )
        if (managed and (stale or drifted)) or (PRUNE_DEFAULT and is_docker and stale):
            api("POST", "/api/v1/apps/delete", {"id": app["id"]})
            log(f"deleted: {app['title']!r}")
            by_title.pop(app["title"], None)
            changed = True

    # add: desired entries missing (or just deleted for drift)
    for want in desired:
        existing = by_title.get(want["title"])
        if existing is not None:
            if SHIM_MARKER not in ((existing.get("runner") or {}).get("run_cmd", "") or ""):
                log(f"warning: {want['title']!r} exists but is not chart-managed - leaving it alone")
            continue
        if sample is None:
            log(f"warning: no pipeline sample available yet - cannot add {want['title']!r}, will retry")
            continue
        api("POST", "/api/v1/apps/add", build_app(want, sample))
        log(f"added: {want['title']!r}")
        changed = True

    if changed:
        log("reconcile done (changes applied)")


def main():
    with open(APPS_FILE) as fh:
        desired = json.load(fh)
    log(f"desired apps: {[d['title'] for d in desired]}")
    while not os.path.exists(SOCKET_PATH):
        log(f"waiting for Wolf API socket {SOCKET_PATH} ...")
        time.sleep(3)
    while True:
        try:
            reconcile(desired)
        except Exception as exc:  # keep the sidecar alive; wolf may be restarting
            log(f"reconcile failed: {exc}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    sys.exit(main())
