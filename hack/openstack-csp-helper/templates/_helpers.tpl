{{/*
Checks whether we have a regular clouds.yaml or one with application credentials.
*/}}

{{- define "cloud_name" -}}
{{- if ne
    ( keys .Values.clouds | len )
     1
-}}
{{ fail "please provide values.yaml/clouds.yaml with exactly one cloud beneath the \".clouds\" key." }}
{{- end -}}
{{ keys .Values.clouds | first }}
{{- end }}

{{- define "auth_auth_url" -}}
{{ get (get (get .Values.clouds (include "cloud_name" .)) "auth") "auth_url" }}
{{- end }}

{{- define "auth_username" -}}
{{ get (get (get .Values.clouds (include "cloud_name" .)) "auth") "username" }}
{{- end }}

{{- define "auth_password" -}}
{{ get (get (get .Values.clouds (include "cloud_name" .)) "auth") "password" }}
{{- end }}

{{- define "auth_project_id" -}}
{{ get (get (get .Values.clouds (include "cloud_name" .)) "auth") "project_id" }}
{{- end }}

{{- define "auth_project_name" -}}
{{ get (get (get .Values.clouds (include "cloud_name" .)) "auth") "project_name" }}
{{- end }}

{{- define "auth_user_domain_name" -}}
{{ get (get (get .Values.clouds (include "cloud_name" .)) "auth") "user_domain_name" }}
{{- end }}

{{- define "auth_domain_name" -}}
{{ get (get (get .Values.clouds (include "cloud_name" .)) "auth") "domain_name" }}
{{- end }}

{{- define "auth_application_credential_id" -}}
{{ get (get (get .Values.clouds (include "cloud_name" .)) "auth") "application_credential_id" }}
{{- end }}

{{- define "auth_application_credential_secret" -}}
{{ get (get (get .Values.clouds (include "cloud_name" .)) "auth") "application_credential_secret" }}
{{- end }}

{{- define "region_name" -}}
{{ get (get .Values.clouds (include "cloud_name" .)) "region_name"  }}
{{- end }}

{{- define "isAppCredential" -}}
{{- if and
    ( include "auth_username" .)
    (not ( include "auth_application_credential_id" . ))
-}}
{{- else if and
    ( not ( include "auth_username" . ))
    ( include "auth_application_credential_id" . )
-}}
true
{{- else }}
{{ fail "please provide either username or application_credential_id, not both, not none" }}
{{- end }}
{{- end }}

{{/*
Templates the cloud.conf as needed by the openstack CCM
*/}}
{{- define "cloud.conf" -}}
[Global]
auth-url={{ include "auth_auth_url" . }}
region={{ include "region_name" . }}
{{ if include "isAppCredential" . }}
application-credential-id={{ include "auth_application_credential_id" . }}
application-credential-secret={{ include "auth_application_credential_secret" . }}
{{- else -}}
username={{ include "auth_username" . }}
password={{ include "auth_password" . }}
user-domain-name={{ include "auth_user_domain_name" . }}
domain-name={{ default (include "auth_user_domain_name" .) (include "auth_domain_name" .) }}
tenant-id={{ include "auth_project_id" . }}
project-id={{ include "auth_project_id" . }}
{{ end }}

[LoadBalancer]
enabled={{ not (.Values.yawol | default false) }}
manage-security-groups=true
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
{{- if .Values.yawol }}
  cloudprovider.conf: {{ include "cloud.conf" . | b64enc }}
{{- end }}
kind: Secret
metadata:
  name: cloud-config
  namespace: kube-system
type: Opaque
{{- end }}
