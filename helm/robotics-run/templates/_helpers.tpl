{{- define "roboticsRun.annotations" -}}
robotics-runtime.dev/run-id: {{ .Values.binding.runId | quote }}
robotics-runtime.dev/domain-id: {{ .Values.binding.domainId | quote }}
robotics-runtime.dev/profile-id: {{ .Values.binding.profileId | quote }}
robotics-runtime.dev/profile-sha256: {{ .Values.binding.profileSha256 | quote }}
robotics-runtime.dev/effect-lease-uid: {{ .Values.effectLease.uid | quote }}
robotics-runtime.dev/spool-uid: {{ .Values.spool.uid | quote }}
{{- end -}}

{{- define "roboticsRun.env" -}}
- name: ROBOTICS_RUN_ID
  value: {{ .Values.binding.runId | quote }}
- name: ROBOTICS_DOMAIN_ID
  value: {{ .Values.binding.domainId | quote }}
- name: ROBOTICS_PROFILE_ID
  value: {{ .Values.binding.profileId | quote }}
- name: ROBOTICS_PROFILE_SHA256
  value: {{ .Values.binding.profileSha256 | quote }}
- name: ROBOTICS_K8S_LEASE_NAME
  value: {{ .Values.effectLease.name | quote }}
- name: ROBOTICS_K8S_LEASE_UID
  value: {{ .Values.effectLease.uid | quote }}
- name: ROBOTICS_K8S_PVC_UID
  value: {{ .Values.spool.uid | quote }}
- name: ROBOTICS_K8S_POD_UID
  valueFrom: {fieldRef: {fieldPath: metadata.uid}}
- name: ROBOTICS_K8S_POD_NAME
  valueFrom: {fieldRef: {fieldPath: metadata.name}}
- name: ROBOTICS_K8S_NAMESPACE
  valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
- name: ROBOTICS_K8S_JOB_UID
  valueFrom:
    fieldRef:
      fieldPath: metadata.labels['batch.kubernetes.io/controller-uid']
{{- end -}}

{{- define "roboticsRun.mounts" -}}
- {name: retained, mountPath: /run/robotics}
- {name: ipc, mountPath: /run/robotics/ipc}
- {name: scratch, mountPath: /tmp}
{{- end -}}

{{- define "roboticsRun.sinkEnv" -}}
- {name: AWS_DEFAULT_REGION, value: {{ .Values.identity.region | quote }}}
- {name: EVIDENCE_BUCKET, value: {{ .Values.identity.bucket | quote }}}
- {name: EVIDENCE_PREFIX, value: {{ .Values.identity.prefix | quote }}}
- {name: RCLONE_S3_NO_CHECK_BUCKET, value: "true"}
- {name: RCLONE_CONFIG, value: /dev/null}
- {name: RCLONE_CONFIG_EVIDENCE_TYPE, value: s3}
- {name: RCLONE_CONFIG_EVIDENCE_ENV_AUTH, value: "true"}
- {name: RCLONE_CONFIG_EVIDENCE_REGION, value: {{ .Values.identity.region | quote }}}
- {name: RCLONE_CONFIG_EVIDENCE_PROVIDER, value: AWS}
- {name: RCLONE_CONFIG_EVIDENCE_FORCE_PATH_STYLE, value: "true"}
- {name: RCLONE_REMOTE, value: evidence}
{{- end -}}
