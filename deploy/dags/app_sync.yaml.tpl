description: Regenerate workerd config from all users' .apps registries (App Worker publish)
type: graph

# Rendered by scripts/install.sh: {{DAGU_ROOT}} is replaced with the deployment root.
steps:
  - id: app_sync
    run: bash {{DAGU_ROOT}}/scripts/app_sync.sh
