# AGENTS.md

## Git workflow (user convention)

- 平时只修改文件，**不 `git add`、不 `git commit`**（改动频繁，避免频繁暂存）。
- 一天工作结束时，统一 `git add` + `git commit` + `git push`（push 按用户指示执行）。
- 未推送的内容继续留在本地，不擅自推送。

## Reference docs

- `CONTEXT.md` — domain terms and conventions for dagu-gate.
- `docs/adr/0001-caddy-gateway-plus-dagu.md` — architecture decision record.
- `deploy/MIGRATION.md` — how to deploy to a new server.
- `deploy/env.example` — per-machine configuration (single source of truth).
