{{- define "app-web.name" -}}
{{- required "app.name is required" .Values.app.name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "app-web.fullname" -}}
{{- printf "%s-web" (include "app-web.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app-web.labels" -}}
app.kubernetes.io/name: {{ include "app-web.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "app-web.name" . }}
app.kubernetes.io/component: web
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "app-web.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app-web.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "app-web.image" -}}
{{- if not .Values.image.repository -}}
{{- fail "image.repository is required" -}}
{{- end -}}
{{- if not .Values.image.digest -}}
{{- fail "image.digest is required: a tag can move after review, a digest cannot" -}}
{{- end -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" .Values.image.digest) -}}
{{- fail "image.digest must be a sha256 digest, not a tag" -}}
{{- end -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- end -}}

{{- define "app-web.serviceAccountName" -}}
{{- if .Values.app.serviceAccount.create -}}
{{- include "app-web.fullname" . -}}
{{- else -}}
{{- default "default" .Values.app.serviceAccount.name -}}
{{- end -}}
{{- end -}}
