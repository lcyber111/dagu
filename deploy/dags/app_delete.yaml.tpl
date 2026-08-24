description: Remove an App Worker from registry and archive it
type: graph

# Rendered by scripts/install.sh: {{DAGU_ROOT}} is replaced.
steps:
  - id: app_delete
    run: bash {{DAGU_ROOT}}/scripts/app_delete.sh
