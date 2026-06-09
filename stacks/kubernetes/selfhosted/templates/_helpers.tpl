{{/*
Derive the in-cluster MinIO S3 endpoint. When the bundled MinIO subchart is
enabled we pin its fullname to "minio" (see values.yaml), so the service is
predictable. Otherwise fall back to the user-provided endpoint.
*/}}
{{- define "spacelift.minioEndpoint" -}}
{{- if .Values.minio.enabled -}}
minio.{{ .Release.Namespace }}.svc.cluster.local:9000
{{- else -}}
{{- required "objectStorage.endpoint is required when minio.enabled=false" .Values.objectStorage.endpoint -}}
{{- end -}}
{{- end -}}

{{/*
Dedicated MinIO access key for Spacelift (first entry of minio.users).
*/}}
{{- define "spacelift.minioAccessKey" -}}
{{- if .Values.minio.enabled -}}
{{- (index .Values.minio.users 0).accessKey -}}
{{- else -}}
{{- required "objectStorage.accessKeyId is required when minio.enabled=false" .Values.objectStorage.accessKeyId -}}
{{- end -}}
{{- end -}}

{{- define "spacelift.minioSecretKey" -}}
{{- if .Values.minio.enabled -}}
{{- (index .Values.minio.users 0).secretKey -}}
{{- else -}}
{{- required "objectStorage.secretAccessKey is required when minio.enabled=false" .Values.objectStorage.secretAccessKey -}}
{{- end -}}
{{- end -}}

{{/*
Database connection string. Built from the bundled postgres subchart values, or
taken verbatim from database.url when postgres is disabled.
*/}}
{{- define "spacelift.databaseUrl" -}}
{{- if .Values.postgres.enabled -}}
{{- $a := .Values.postgres.auth -}}
{{- printf "postgres://%s:%s@spacelift-postgres.%s.svc.cluster.local:5432/%s?statement_cache_capacity=0" $a.username $a.password .Release.Namespace $a.database -}}
{{- else -}}
{{- required "database.url is required when postgres.enabled=false" .Values.database.url -}}
{{- end -}}
{{- end -}}
