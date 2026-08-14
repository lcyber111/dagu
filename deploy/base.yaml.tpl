# dagu configuration for dagu-gate.
# Rendered from this template by scripts/install.sh: every {{DAGU_ROOT}} is
# replaced with the deployment root (DAGU_ROOT from the env file, see
# deploy/env.example). The rendered file is written to
# $DAGU_ROOT/.config/dagu/base.yaml on the target host.
# NOTE: dagu's config schema is flat - host/port/auth/dags_dir are top-level keys.
host: 172.17.0.1
port: 18080
dags_dir: {{DAGU_ROOT}}/dags
data_dir: {{DAGU_ROOT}}/data
auth:
  mode: builtin
  builtin:
    token:
      secret: dagu-gate-webhook-jwt-secret
      ttl: 24h
webhooks:
  max_payload_size: 1048576
paths:
  base_config: {{DAGU_ROOT}}/base.dag.yaml
