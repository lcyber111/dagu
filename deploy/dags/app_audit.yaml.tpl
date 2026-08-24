description: Aggregate App Worker lifecycle operations into audit log
type: graph
schedule: "{{AUDIT_CRON}}"

# Rendered by scripts/install.sh: {{DAGU_ROOT}}/{{AUDIT_CRON}} are replaced.
steps:
  - id: app_audit
    run: bash {{DAGU_ROOT}}/scripts/app_audit.sh
