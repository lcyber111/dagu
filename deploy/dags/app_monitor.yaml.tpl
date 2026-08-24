description: Periodic App Worker health/quota/sync monitor
type: graph
schedule: "{{MONITOR_CRON}}"

# Rendered by scripts/install.sh: {{DAGU_ROOT}}/{{MONITOR_CRON}} are replaced.
steps:
  - id: app_monitor
    run: bash {{DAGU_ROOT}}/scripts/app_status.sh
