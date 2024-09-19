{{/*
Expand the name of the chart.
*/}}
{{- define "gitlab-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "gitlab-agent.fullname" -}}
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
{{- define "gitlab-agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "gitlab-agent.labels" -}}
helm.sh/chart: {{ include "gitlab-agent.chart" . }}
{{ include "gitlab-agent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.additionalLabels }}
{{ toYaml .Values.additionalLabels }}
{{- end -}}
{{- end }}

{{/*
Agent Pod labels in YAML format
*/}}
{{- define "gitlab-agent.agentPodLabels" -}}
{{- $labels := (include "gitlab-agent.labels" . | fromYaml) -}}
{{- if .Values.podLabels }}
{{- $labels = merge $labels .Values.podLabels -}}
{{- end }}
{{- $labels | toYaml -}}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "gitlab-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gitlab-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
selectorLabelsStr returns a string of the selector labels in the format of key1=value1,key2=value2
*/}}
{{- define "gitlab-agent.selectorLabelsStr" -}}
{{- $labels := include "gitlab-agent.selectorLabels" . -}}
{{- $oneLineLabels := $labels | replace "\n" "," | replace ": " "=" -}}
{{- trimSuffix "," $oneLineLabels | trim -}}
{{- end }}

{{/*
Secret Name
*/}}
{{- define "gitlab-agent.secretName" -}}
{{- if .Values.config.secretName }}
{{- .Values.config.secretName }}
{{- else }}
{{- printf "%s-token" (include "gitlab-agent.fullname" .) -}}
{{- end }}
{{- end }}

{{/*
Common annotations
*/}}
{{- define "gitlab-agent.annotations" -}}
{{- $ := index . 0 }}
{{- $annotations := index . 1 }}
{{- $observabilityEnabled := ($.Values.config.observability).enabled }}
{{- $token := $.Values.config.token }}
{{- /*
If observability is disabled, always remove the prometheus annotations to avoid Prometheus scraping a closed port
*/ -}}
{{- if (not $observabilityEnabled) }}
{{- $annotations := unset $annotations "prometheus.io/path" }}
{{- $annotations := unset $annotations "prometheus.io/port" }}
{{- $annotations := unset $annotations "prometheus.io/scrape" }}
{{- end }}
{{- with $token }}
{{ printf "checksum/token: %s" (. | sha256sum) }}
{{- end }}
{{- with $annotations }}
{{ toYaml $annotations }}
{{- end }}
{{- if and (not $token) (not $annotations) }}
{{ printf "{}" -}}
{{- end }}
{{- end }}

{{/*
Observability TLS Secret Name
*/}}
{{- define "gitlab-agent.observabilitySecretName" -}}
{{- $name := (((.Values.config.observability).tls).secret).name }}
{{- if $name }}
{{-   $name }}
{{- else }}
{{-   printf "%s-observability" (include "gitlab-agent.fullname" .) -}}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "gitlab-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "gitlab-agent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Expand the OCS service account name.
*/}}
{{- define "gitlab-agent.ocs.serviceAccountName" -}}
{{- printf "%s-ocs-scanning-pod-sa" (include "gitlab-agent.fullname" .) }}
{{- end }}

{{/*
Expand the OCS Role name.
*/}}
{{- define "gitlab-agent.ocs.roleName" -}}
{{- printf "%s:ocs"  (include "gitlab-agent.fullname" .) }}
{{- end }}

{{/*
Expand the OCS ClusterRole name.
*/}}
{{- define "gitlab-agent.ocs.clusterRoleName" -}}
{{- printf "%s:%s:ocs" .Release.Namespace (include "gitlab-agent.fullname" .) }}
{{- end }}

{{/*
Expand the OCS ClusterRoleBinding name.
*/}}
{{- define "gitlab-agent.ocs.clusterRoleBindingName" -}}
{{- printf "%s:%s:ocs" .Release.Namespace (include "gitlab-agent.fullname" .) }}
{{- end }}

{{/*
Returns if the OCS is enabled
*/}}
{{- define "gitlab-agent.ocs.enabled" -}}
{{- if (.Values.config.operational_container_scanning).enabled -}}
"true"
{{- else -}}
"false"
{{- end -}}
{{- end -}}

{{/*
Service name
*/}}
{{- define "gitlab-agent.serviceName" -}}
{{- printf "%s-service" (include "gitlab-agent.fullname" . | trunc 55) -}}
{{- end }}

{{/*
Validate service.internalPort equals to the port that is set in config.api.listenAddress.
*/}}
{{- define "gitlab-agent.validateApiPort" -}}
{{- if (.Values.config.receptive).enabled -}}
  {{- $listenAddress := (.Values.config.api).listenAddress | toString }}
  {{- if not (contains ":" $listenAddress) }}
  {{- fail "config.api.listenAddress must be in the format of host:port or :port." }}
  {{- end }}

  {{- $listenPort := mustRegexSplit ":" (.Values.config.api).listenAddress -1 | last -}}
  {{- $internalPort := (.Values.service).internalPort | toString -}}
  {{- if ne $listenPort $internalPort -}}
  {{- fail (printf "The service.internalPort \"%s\" must be equal to the port that is set in config.api.listenAddress \"%s\"" $internalPort $listenPort) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate service.privateApiPort equals to the port that is set in config.privateApi.listenAddress.
*/}}
{{- define "gitlab-agent.validatePrivateApiPort" }}
{{- if (.Values.config.receptive).enabled -}}
  {{- $listenAddress := .Values.config.privateApi.listenAddress | toString }}
  {{- if not (contains ":" $listenAddress) }}
  {{- fail "config.privateApi.listenAddress must be in the format of host:port or :port." }}
  {{- end }}

  {{- $listenPort := mustRegexSplit ":" .Values.config.privateApi.listenAddress -1 | last -}}
  {{- $privateApiPort := (.Values.service).privateApiPort | toString -}}
  {{- if ne $listenPort $privateApiPort -}}
  {{- fail (printf "service.privateApiPort \"%s\" must be equal to the port that is set in config.privateApi.listenAddress \"%s\"" $privateApiPort $listenPort) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Ingress name
*/}}
{{- define "gitlab-agent.ingressName" -}}
{{- printf "%s-ingress" (include "gitlab-agent.fullname" .) -}}
{{- end }}

{{/*
Own Private API Scheme
*/}}
{{- define "gitlab-agent.ownPrivateApi.scheme" -}}
{{- printf "%s" (ternary "grpcs" "grpc" (eq $.Values.config.privateApi.tls.enabled true)) -}}
{{- end }}
