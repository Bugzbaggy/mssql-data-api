{{- define "appdb-data-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "appdb-data-api.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "appdb-data-api.name" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Bare `app:` label matches the manifests this chart replaces; Deployment selectors
     are immutable, so changing it would break an upgrade over an existing Deployment. */}}
{{- define "appdb-data-api.selectorLabels" -}}
app: {{ include "appdb-data-api.name" . }}
{{- end -}}

{{- define "appdb-data-api.labels" -}}
{{ include "appdb-data-api.selectorLabels" . }}
app.kubernetes.io/name: {{ include "appdb-data-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "appdb-data-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "appdb-data-api.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "appdb-data-api.secretStoreName" -}}
{{- default (include "appdb-data-api.fullname" .) .Values.secretStore.name -}}
{{- end -}}
