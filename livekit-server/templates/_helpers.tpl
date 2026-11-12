{{/*
Expand the name of the chart.
*/}}
{{- define "livekit-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "livekit-server.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "livekit-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "livekit-server.labels" -}}
helm.sh/chart: {{ include "livekit-server.chart" . }}
{{ include "livekit-server.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "livekit-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "livekit-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "livekit-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "livekit-server.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Per-node SFU instances. Empty name = the default single workload (no name suffix).
*/}}
{{- define "livekit-server.instanceFullname" -}}
{{- $root := index . "root" -}}
{{- $inst := index . "instance" -}}
{{- $base := include "livekit-server.fullname" $root -}}
{{- if and $inst $inst.name -}}
{{- printf "%s-%s" $base $inst.name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $base -}}
{{- end -}}
{{- end }}

{{- define "livekit-server.instancePodLabels" -}}
{{- $root := index . "root" -}}
{{- $inst := index . "instance" -}}
{{ include "livekit-server.selectorLabels" $root }}
{{- if and $inst $inst.name }}
livekit.io/instance: {{ $inst.name | quote }}
{{- end }}
{{- end }}

{{/*
The TURN name an instance sets for itself (instances[].turn.domain). Empty when
the instance uses the shared livekit.turn.domain.
*/}}
{{- define "livekit-server.instanceTurnDomain" -}}
{{- $inst := index . "instance" -}}
{{- if and $inst $inst.turn -}}
{{- default "" $inst.turn.domain -}}
{{- end -}}
{{- end }}

{{/*
Secret with the TURN certificate of one instance: instances[].turn.secretName
when set, otherwise the shared livekit.turn.secretName.
*/}}
{{- define "livekit-server.instanceTurnSecretName" -}}
{{- $root := index . "root" -}}
{{- $inst := index . "instance" -}}
{{- $own := "" -}}
{{- if and $inst $inst.turn -}}
{{- $own = default "" $inst.turn.secretName -}}
{{- end -}}
{{- default "" (default $root.Values.livekit.turn.secretName $own) -}}
{{- end }}

{{/*
Number of instances that set their own TURN name.
*/}}
{{- define "livekit-server.instanceTurnDomainCount" -}}
{{- $count := 0 -}}
{{- range $inst := default list .Values.instances -}}
{{- if include "livekit-server.instanceTurnDomain" (dict "instance" $inst) -}}
{{- $count = add1 $count -}}
{{- end -}}
{{- end -}}
{{- $count -}}
{{- end }}

{{/*
"true" when the chart fills in the Sentinels of a redis-ha release:
redisSentinel.enabled is set and livekit.redis names no Redis itself.
*/}}
{{- define "livekit-server.redisSentinelActive" -}}
{{- $wiring := default dict .Values.redisSentinel -}}
{{- $redis := default dict .Values.livekit.redis -}}
{{- if and $wiring.enabled (not (or $redis.address $redis.sentinel_addresses $redis.cluster_addresses)) -}}
true
{{- end -}}
{{- end }}

{{/*
Sentinel addresses of the redis-ha release, one per replica:
<serviceName>-server-<n>.<serviceName>:<port>, as a JSON list.
*/}}
{{- define "livekit-server.redisSentinelAddresses" -}}
{{- $wiring := .Values.redisSentinel -}}
{{- $service := tpl (required "redisSentinel.serviceName is required with redisSentinel.enabled: the headless Service of the redis-ha StatefulSet" $wiring.serviceName) . -}}
{{- $addresses := list -}}
{{- range $n := until (int $wiring.replicas) -}}
{{- $addresses = append $addresses (printf "%s-server-%d.%s:%d" $service $n $service (int $wiring.port)) -}}
{{- end -}}
{{- toJson $addresses -}}
{{- end }}

{{/*
LiveKit server config for one instance. Sets rtc.node_ip and disables STUN
discovery when the instance lists a media VIP. Sets turn.domain when the
instance has its own TURN name. Sets redis.sentinel_addresses when the chart
fills in the Sentinels of a redis-ha release.
*/}}
{{- define "livekit-server.instanceLivekitConfig" -}}
{{- $root := index . "root" -}}
{{- $inst := index . "instance" -}}
{{- $cfg := deepCopy $root.Values.livekit -}}
{{- if include "livekit-server.redisSentinelActive" $root -}}
{{- $redis := default dict $cfg.redis -}}
{{- $_ := set $redis "sentinel_addresses" (include "livekit-server.redisSentinelAddresses" $root | fromJsonArray) -}}
{{- if not $redis.sentinel_master_name -}}
{{- $_ := set $redis "sentinel_master_name" $root.Values.redisSentinel.masterName -}}
{{- end -}}
{{- $_ := set $cfg "redis" $redis -}}
{{- end -}}
{{- if and $inst $inst.node_ip -}}
{{- $rtc := default dict $cfg.rtc -}}
{{- if not $rtc -}}
{{- $rtc = dict -}}
{{- end -}}
{{- $_ := set $rtc "node_ip" $inst.node_ip -}}
{{- $_ := set $rtc "use_external_ip" false -}}
{{- $_ := set $cfg "rtc" $rtc -}}
{{- end -}}
{{- $turnDomain := include "livekit-server.instanceTurnDomain" . -}}
{{- if $turnDomain -}}
{{- $turn := default dict $cfg.turn -}}
{{- $_ := set $turn "domain" $turnDomain -}}
{{- $_ := set $cfg "turn" $turn -}}
{{- end -}}
{{- toYaml $cfg -}}
{{- end }}

{{/*
Create the name of the service monitor to use
*/}}
{{- define "livekit-server.serviceMonitorName" -}}
{{- if .Values.serviceMonitor.create }}
{{- default (include "livekit-server.fullname" .) .Values.serviceMonitor.name }}
{{- else }}
{{- default "default" .Values.serviceMonitor.name }}
{{- end }}
{{- end }}

{{/*
Container image. A set image.digest pins the pull (repository:tag@digest).
*/}}
{{- define "livekit-server.image" -}}
{{- $ref := printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $ref .Values.image.digest -}}
{{- else -}}
{{- $ref -}}
{{- end -}}
{{- end }}
