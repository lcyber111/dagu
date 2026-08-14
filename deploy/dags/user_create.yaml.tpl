description: Create a user environment container from the webhook payload
type: graph

# Rendered by scripts/install.sh: {{DAGU_ROOT}} is replaced with the
# deployment root (DAGU_ROOT from the env file). An absolute path is required
# because dagu resolves step working directories against the per-run work
# directory in server mode, not against the DAG file location.
steps:
  - id: create_user
    run: bash {{DAGU_ROOT}}/scripts/create_user.sh
