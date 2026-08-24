description: Ensure host workerd is running and listening on 9090
type: graph
schedule: "{{GUARD_CRON}}"

# Rendered by scripts/install.sh: {{DAGU_ROOT}}/{{GUARD_CRON}} are replaced.
steps:
  - id: workerd_guard
    run: bash {{DAGU_ROOT}}/scripts/workerd_guard.sh
