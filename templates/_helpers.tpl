{{/*
Wolf images (all through common.images.image so global.imageRegistry applies)
*/}}
{{- define "wolf.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) -}}
{{- end -}}

{{- define "wolf.kubectl.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.kubectlImage "global" .Values.global) -}}
{{- end -}}

{{- define "wolf.busybox.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.busyboxImage "global" .Values.global) -}}
{{- end -}}

{{- define "wolf.appsSync.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.appsSync.image "global" .Values.global) -}}
{{- end -}}

{{- define "wolf.filebrowser.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.filebrowser.image "global" .Values.global) -}}
{{- end -}}

{{/*
Per-app image; expects (dict "app" <app values> "context" $)
*/}}
{{- define "wolf.app.image" -}}
{{- include "common.images.image" (dict "imageRoot" .app.image "global" .context.Values.global) -}}
{{- end -}}

{{- define "wolf.imagePullSecrets" -}}
{{- include "common.images.renderPullSecrets" (dict "images" (list .Values.image .Values.kubectlImage .Values.busyboxImage .Values.appsSync.image) "context" $) -}}
{{- end -}}

{{- define "wolf.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "common.names.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Extended GPU resource name resolved from gpu.vendor / gpu.resource.
Empty output = request nothing.
*/}}
{{- define "wolf.gpu.resourceName" -}}
{{- if ne .Values.gpu.vendor "none" -}}
{{- if eq .Values.gpu.resource "auto" -}}
{{- if eq .Values.gpu.vendor "nvidia" -}}nvidia.com/gpu
{{- else if eq .Values.gpu.vendor "amd" -}}amd.com/gpu
{{- else if eq .Values.gpu.vendor "intel" -}}gpu.intel.com/i915
{{- end -}}
{{- else -}}
{{- .Values.gpu.resource -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Resources map with the GPU extended resource merged into limits.
Expects (dict "resources" <map> "context" $). User-provided limits win.
*/}}
{{- define "wolf.mergedResources" -}}
{{- $res := deepCopy (.resources | default (dict)) -}}
{{- $gpuRes := include "wolf.gpu.resourceName" .context -}}
{{- if $gpuRes -}}
{{- $limits := mustMergeOverwrite (dict $gpuRes .context.Values.gpu.count) (deepCopy ($res.limits | default (dict))) -}}
{{- $_ := set $res "limits" $limits -}}
{{- end -}}
{{- toYaml $res -}}
{{- end -}}

{{/*
GOW_REQUIRED_DEVICES for game pods: explicit override or auto by vendor.
*/}}
{{- define "wolf.gowRequiredDevices" -}}
{{- if .Values.appDefaults.gowRequiredDevices -}}
{{- .Values.appDefaults.gowRequiredDevices -}}
{{- else if eq .Values.gpu.vendor "nvidia" -}}
/dev/input/* /dev/dri/* /dev/nvidia*
{{- else -}}
/dev/input/* /dev/dri/*
{{- end -}}
{{- end -}}

{{/*
Host paths (all default under paths.base)
*/}}
{{- define "wolf.paths.config" -}}
{{- .Values.paths.config | default (printf "%s/cfg" .Values.paths.base) -}}
{{- end -}}

{{- define "wolf.paths.sockets" -}}
{{- .Values.paths.sockets | default (printf "%s/sockets" .Values.paths.base) -}}
{{- end -}}

{{- define "wolf.paths.homes" -}}
{{- .Values.paths.homes | default (printf "%s/homes" .Values.paths.base) -}}
{{- end -}}

{{/*
Path of the session shim inside the wolf container. Single source of truth:
used to build every run_cmd, to mount the scripts ConfigMap, and passed to the
apps-sync sidecar as SHIM_MARKER (chart-managed-app detection).
*/}}
{{- define "wolf.shim.path" -}}/shim-cfg/session.sh{{- end -}}

{{/*
Name of a game app's Deployment. Single source of truth: it is both the
rendered Deployment's metadata.name and the target the shim scales (baked
into run_cmd by wolf.desiredApps). Expects (dict "name" <app key> "context" $).
*/}}
{{- define "wolf.app.deployName" -}}
{{- printf "%s-%s" (include "common.names.fullname" .context) .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Match labels of the wolf server pod (used by the game pods' podAffinity)
*/}}
{{- define "wolf.serverMatchLabels" -}}
{{- include "common.labels.matchLabels" (dict "customLabels" .Values.commonLabels "context" $) }}
app.kubernetes.io/component: server
{{- end -}}

{{/*
Desired Wolf app list (JSON) rendered from .Values.apps for the sync sidecar.
One Deployment may back several Moonlight entries (default entry + .entries).
*/}}
{{- define "wolf.desiredApps" -}}
{{- $out := list -}}
{{- range $name, $app := .Values.apps -}}
{{- if $app.enabled -}}
{{- $deploy := include "wolf.app.deployName" (dict "name" $name "context" $) -}}
{{- $entries := list (dict "title" ($app.title | default $name) "args" ($app.args | default (list)) "icon" ($app.icon | default "")) -}}
{{- range ($app.entries | default (list)) -}}
{{/* extra Moonlight entries share the launcher's icon unless they set their own */}}
{{- $entries = append $entries (dict "title" .title "args" (.args | default (list)) "icon" (.icon | default ($app.icon | default ""))) -}}
{{- end -}}
{{- range $e := $entries -}}
{{- $cmd := printf "bash %s %s" (include "wolf.shim.path" $) $deploy -}}
{{- if $e.args -}}
{{- $cmd = printf "%s %s" $cmd (join " " $e.args) -}}
{{- end -}}
{{- $entry := dict "title" $e.title "start_virtual_compositor" true "start_audio_server" true "icon_png_path" $e.icon "runner" (dict "type" "process" "run_cmd" $cmd) -}}
{{- if $.Values.gpu.renderNode -}}
{{- $_ := set $entry "render_node" $.Values.gpu.renderNode -}}
{{- end -}}
{{- $out = append $out $entry -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out | toPrettyJson -}}
{{- end -}}

{{/*
Validate values; aggregated and fail-ed from NOTES.txt
*/}}
{{- define "wolf.validateValues" -}}
{{- $messages := list -}}
{{- if not (has .Values.gpu.vendor (list "nvidia" "amd" "intel" "none")) -}}
{{- $messages = append $messages "gpu.vendor must be one of: nvidia, amd, intel, none" -}}
{{- end -}}
{{- range $name, $app := .Values.apps -}}
{{- if and $app.enabled (not $app.image) -}}
{{- $messages = append $messages (printf "apps.%s is enabled but has no image" $name) -}}
{{- end -}}
{{- end -}}
{{- $message := join "\n" $messages -}}
{{- if $message -}}
{{- printf "\nVALUES VALIDATION:\n%s" $message | fail -}}
{{- end -}}
{{- end -}}
