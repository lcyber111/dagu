description: Scheduled sync of upstream DB data into App Worker SQLite (minute-level)
type: graph
schedule: "{{SYNC_CRON}}"

# Rendered by scripts/install.sh: {{DAGU_ROOT}}/{{SYNC_CRON}} are replaced.
steps:
  - id: app_sync_data
    run: bash {{DAGU_ROOT}}/scripts/app_sync_data.sh
