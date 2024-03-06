{{/*
Checks whether we have a regular clouds.yaml or one with application credentials.
*/}}
{{- define "isAppCredential" -}}
{{- if and .Values.clouds.openstack.auth.username (not .Values.clouds.openstack.auth.application_credential_id) -}}
{{- else if and (not .Values.clouds.openstack.auth.username) .Values.clouds.openstack.auth.application_credential_id -}}
true
{{- else }}
{{ fail "please provide either username or application_credential_id, not both, not none" }}
{{- end }}
{{- end }}

{{/*
Creates name of the namespace: appcredxxx in case of an application credential, project_name otherwise
*/}}
{{- define "namespaceName" -}}
{{- if include "isAppCredential" . -}}
appcred-{{ substr 0 10 .Values.clouds.openstack.auth.application_credential_id }}
{{- else -}}
{{ .Values.clouds.openstack.auth.project_name }}
{{ end }}
{{- end }}




{{/*
Templates the cloud.conf as needed by the openstack CCM
*/}}
{{- define "cloud.conf" -}}
[Global]
auth-url={{ .Values.clouds.openstack.auth.auth_url }}
region={{ .Values.clouds.openstack.region_name }}
{{ if include "isAppCredential" . }}
application-credential-id={{ .Values.clouds.openstack.auth.application_credential_id }}
application-credential-secret={{ .Values.clouds.openstack.auth.application_credential_secret }}
{{- else -}}
username={{ .Values.clouds.openstack.auth.username }}
password={{ .Values.clouds.openstack.auth.password }}
user-domain-name={{ .Values.clouds.openstack.auth.user_domain_name }}
tenant-id={{ .Values.clouds.openstack.auth.project_id }}
{{ end }}

[LoadBalancer]
manage-security-groups=true
use-octavia=true
enable-ingress-hostname=true
create-monitor=true
{{- end }}



{{/*
Templates the secret that contains cloud.conf as needed by the openstack CCM
*/}}
{{- define "cloud-config" -}}
apiVersion: v1
data:
  cloud.conf: {{ include "cloud.conf" . | b64enc }}
kind: Secret
metadata:
  name: cloud-config
  namespace: kube-system
type: Opaque
{{- end }}
