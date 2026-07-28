{{/*
Chart name.
*/}}
{{- define "p4-switch.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name, honoring .Release.Name.
*/}}
{{- define "p4-switch.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "p4-switch.labels" -}}
helm.sh/chart: {{ printf "%s-%s" (include "p4-switch.name" .) .Chart.Version | replace "+" "_" }}
{{ include "p4-switch.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "p4-switch.selectorLabels" -}}
app.kubernetes.io/name: {{ include "p4-switch.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
