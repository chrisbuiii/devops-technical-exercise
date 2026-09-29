{{/*
Chart name, truncated to the 63-char limit Kubernetes imposes on names.
*/}}
{{- define "greeter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name: "<release>-<chart>", or just the release name if it
already contains the chart name. Truncated to 63 chars.
*/}}
{{- define "greeter.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Common labels applied to every object. Uses the recommended app.kubernetes.io
label set so the objects play well with standard tooling.
*/}}
{{- define "greeter.labels" -}}
app.kubernetes.io/name: {{ include "greeter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.config.version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
Selector labels: the stable subset used to match pods to their controller and
Service. These must never include values that change between releases.
*/}}
{{- define "greeter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "greeter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
