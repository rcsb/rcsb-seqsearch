{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "helm_chart.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "helm_chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "helm_chart.labels" -}}
helm.sh/chart: {{ include "helm_chart.chart" . }}
{{ include "helm_chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "helm_chart.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Persistent volume name. Utilize namespace aware naming to allow deployments of cluster resources for different environments.
*/}}
{{- define "helm_chart.pvname" -}}
{{- printf "%s-%s" .Release.Namespace .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
ConfigMap resource name. Ensure names conform to character limits in Kubernetes.
Per path, because config.json points at the path's own redis. Takes (dict "ctx" $ "path" "a").
*/}}
{{- define "helm_chart.configmapName" -}}
{{- printf "%s-config-%s" (include "helm_chart.fullname" .ctx | trunc 53 | trimSuffix "-") .path }}
{{- end }}

{{/*
ConfigMap resource name. Ensure names conform to character limits in Kubernetes
*/}}
{{- define "helm_chart.dbParamsName" -}}
{{- printf "%s-dbparams" (include "helm_chart.fullname" . | trunc 54 | trimSuffix "-") }}
{{- end }}

{{/*
Job state is shared by all pods of ONE path, never across paths: a and b hold different
weekly datasets, and mmseqs2-app hashes ticket ids from the query and the database NAMES
only (not the data version). Sharing state across paths would therefore serve path a's
cached results for path b's data. Hence every state resource below is per path.

All three take a dict: (dict "ctx" $ "path" "a").
*/}}

{{/*
Name for a path's redis Deployment/Service/PVC.
*/}}
{{- define "helm_chart.redisName" -}}
{{- printf "%s-redis-%s" (include "helm_chart.fullname" .ctx | trunc 54 | trimSuffix "-") .path }}
{{- end }}

{{/*
Selector labels for a path's redis pod. Deliberately distinct from helm_chart.selectorLabels:
the main a/b services select on those alone, and the redis pods must not match them.
*/}}
{{- define "helm_chart.redisSelectorLabels" -}}
app.kubernetes.io/name: {{ .ctx.Chart.Name }}-redis
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
rcsb.org/path: {{ .path | quote }}
{{- end }}

{{/*
Name for a path's jobs PVC (results cache), mounted RWX by all pods of that path.
*/}}
{{- define "helm_chart.jobsPvcName" -}}
{{- printf "%s-jobs-%s" (include "helm_chart.fullname" .ctx | trunc 55 | trimSuffix "-") .path }}
{{- end }}
