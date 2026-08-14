description: Stop user environment containers idle longer than the configured timeout
type: graph
schedule: "{{REAP_CRON}}"

# Rendered by scripts/install.sh: the deployment root and the cron schedule
# (REAP_CRON from the env file, default every minute) are substituted here.
# Dagu v2 parses standard 5-field cron (no seconds field).
steps:
  - id: reap_idle
    run: bash {{DAGU_ROOT}}/scripts/reap_idle.sh
