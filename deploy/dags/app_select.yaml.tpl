description: Record the currently selected artifact for the agent context
type: graph

# Rendered by scripts/install.sh: {{DAGU_ROOT}} is replaced.
steps:
  - id: app_select
    run: bash {{DAGU_ROOT}}/scripts/app_select.sh
