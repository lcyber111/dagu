description: Apply a modification (page or metadata) to the currently selected artifact (platform-enforced target)
type: graph

# Rendered by scripts/install.sh: {{DAGU_ROOT}} is replaced with the deployment root.
steps:
  - id: app_apply
    run: bash {{DAGU_ROOT}}/scripts/app_apply.sh
