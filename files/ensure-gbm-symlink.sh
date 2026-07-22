#!/bin/sh
# Ensure the NVIDIA GBM backend symlink exists (EGL/GBM apps panic without it:
# "Failed to create GsCUDABuf"). Where libnvidia-allocator.so.1 lands depends on
# the k8s distro / how the driver is injected:
#   - Talos + CDI spec:                 /usr/local/lib
#   - GPU Operator driver container:    /usr/lib/x86_64-linux-gnu
#   - some setups:                      /usr/local/nvidia/lib64
# Newer nvidia-container-toolkit creates the gbm symlink itself - then this is
# a no-op. On AMD/Intel nodes (mesa) there is no NVIDIA lib and we exit quietly.
set -u
GBM_DIR=/usr/lib/x86_64-linux-gnu/gbm
[ -e "$GBM_DIR/nvidia-drm_gbm.so" ] && exit 0

LIB=""
for d in /usr/local/lib /usr/local/nvidia/lib64 /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    if [ -e "$d/libnvidia-allocator.so.1" ]; then LIB="$d/libnvidia-allocator.so.1"; break; fi
done
# fallback: ask the dynamic linker cache
[ -z "$LIB" ] && LIB="$(ldconfig -p 2>/dev/null | sed -n 's/.*=> \(.*libnvidia-allocator\.so\.1\)$/\1/p' | head -1)"
[ -z "$LIB" ] && exit 0   # no NVIDIA userspace here (AMD/Intel node) - nothing to do

mkdir -p "$GBM_DIR"
ln -sf "$LIB" "$GBM_DIR/nvidia-drm_gbm.so"
echo "[gbm-symlink] $GBM_DIR/nvidia-drm_gbm.so -> $LIB"
