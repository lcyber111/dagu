# AGENTS.md

## Git workflow (user convention)

- 本地提交（commit）照常进行，但**不要频繁推送（push）到 GitHub**。
- 改动攒一批后，主动询问用户；用户明确同意后，才执行 `git push`。
- 未推送的提交继续留在本地分支，不重复推送或擅自推送。

## Reference docs

- `CONTEXT.md` — domain terms and conventions for dagu-gate.
- `docs/adr/0001-caddy-gateway-plus-dagu.md` — architecture decision record.
- `deploy/MIGRATION.md` — how to deploy to a new server.
- `deploy/env.example` — per-machine configuration (single source of truth).
