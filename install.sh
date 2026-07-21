#!/bin/bash
# Recreate the Wolf stack on the cluster from this repo
# (ConfigMaps built from the .sh sources + manifests).
set -e
KC="${KUBECONFIG:-$HOME/.kube/config}"
NS="${NS:-games}"
k() { kubectl --kubeconfig "$KC" -n "$NS" "$@"; }

# ConfigMaps are generated FROM THE SCRIPTS (source of truth) - not from
# pre-rendered yaml, so they never drift from the .sh files.
k create configmap wolf-shim --from-file=session.sh=shim-session.sh \
  --dry-run=client -o yaml | k apply -f -
k create configmap wolf-session-env \
  --from-file=05-session-env.sh=session-env-hook.sh \
  --from-file=20-sway-tweaks.sh=sway-tweaks-hook.sh \
  --dry-run=client -o yaml | k apply -f -

kubectl --kubeconfig "$KC" -n "$NS" apply -f rbac.yaml -f pvc-installers.yaml \
  -f deployment.yaml -f app-heroic.yaml -f app-steam.yaml -f app-lutris.yaml -f filebrowser.yaml

echo "Done. Add your app entries to Wolf's config.toml on disk - see README."
