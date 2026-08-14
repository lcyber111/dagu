description: Start a stopped user environment container
type: graph

# Rendered by scripts/install.sh: {{DAGU_ROOT}} is replaced with the
# deployment root (DAGU_ROOT from the env file). An absolute path is required
# because dagu resolves step working directories against the per-run work
# directory in server mode, not against the DAG file location.
steps:
  - id: user_start
    run: bash {{DAGU_ROOT}}/scripts/start_user.sh
