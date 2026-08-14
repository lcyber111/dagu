description: Delete a user environment container and reclaim resources
type: graph

# Rendered by scripts/install.sh: {{DAGU_ROOT}} is replaced with the
# deployment root (DAGU_ROOT from the env file).
steps:
  - id: delete_user
    run: bash {{DAGU_ROOT}}/scripts/delete_user.sh
