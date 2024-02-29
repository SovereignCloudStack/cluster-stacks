{{/*
Templates the cloud.conf as needed by the openstack CCM
*/}}
{{- define "cloud.conf" -}}
[Global]
auth-url={{ .Values.clouds.openstack.auth.auth_url }}
region={{ .Values.clouds.openstack.region_name }}
username={{ .Values.clouds.openstack.auth.username }}
password={{ .Values.clouds.openstack.auth.password }}
user-domain-name={{ .Values.clouds.openstack.auth.user_domain_name }}
tenant-id={{ .Values.clouds.openstack.auth.project_id }}

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
