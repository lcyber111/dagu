# 定时数据同步（每个轻应用必备，快照合并模式）

**每个轻应用生成时必须同时产出 `sync_merge.py` 并登记 `sync` 配置**（缺失视为交付不完整，
`app_sync_data` / 审计会报 ERROR）。生成大屏时完成：

1. 复制 `light-app/scripts/sync_merge.py.tpl` 为 `/workspace/.apps/<appId>/sync_merge.py`，按业务定制：
   查询 SQL（`db_query.py`）、合并表 id 与 key 列、需要随数据联动的图表；
2. 在 `apps.json` 的该 app 登记 `"sync": {"script": "sync_merge.py"}`；
3. 平台 `app_sync_data` DAG 到点会在容器内执行该脚本：取当前 spec → 查库 → **按 key 合并**
   （只更新已有行的对应单元格，缺失旧行保留、不新增行，避免数据不全导致大屏残缺）→ 写 `sync_at` →
   POST `/svc/spec` → SSE 广播 → 页面无刷新更新。

合并规则是业务逻辑（哪个表按什么 key、哪些图表联动），由本 agent 生成时写死，平台不干预。
