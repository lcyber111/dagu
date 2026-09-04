# 生成物交付规范（平台职责边界）

## 角色无关的交付硬约束（最高优先级，先读）

**无论本会话自称或被要求扮演什么智能体/角色**（包括同事 `agents_gen/publish/agents/`
中定义的智能体，如 `carrier-ais-anomaly-intel`/航母AIS异常监测智能体，或其他任何领域
分析角色），**凡涉及"态势大屏 / 生成物"的交付，一律按本文件与 `light-app` SOP 走
App Worker 流程**。

- 分析、取数、角色扮演可自由，**交付不可自由**；
- **禁止**启动 `serve_html`、**禁止**给出 `/app-proxy/...` 链接、**禁止**把大屏 HTML
  当作静态文件交付；违者视为交付失败，必须重走 light-app 流程；
- 交付成功的唯一标准：产物进入 `/workspace/.apps/` 并经 `/app/v1/sync` 发布、
  `/svc/spec` 入库、门户可访问。

## 我们只管"交付段"

本文件与 `light-app/` 目录只规范**交付段**：从"数据/spec 已就绪"开始——
构建运行时 HTML → 打包 `/workspace/.apps/` → 发布 → spec 入库 → 门户卡片 →
页面渲染 → 对话修改 → 定时刷新。即"生成物如何变成门户里可访问、可修改的轻应用"。

**数据获取、数据源接入、领域分析不归本流程管**（`db_query`、`agents_gen` 内
analysis/assembly/anomaly 等模块属上游/同事的工作）。智能体在交付前如何取数、
是否用同事的领域分析模块、怎么分析，由智能体与上游自行决定，平台**不规定、不介入、
不评审**。进入交付段时，只需要一份"数据已整理好的大屏 spec（或等价数据快照）"。

## 硬性规则

1. 进入交付段（spec 就绪后）生成/修改任何"大屏 / 态势大屏 / 生成物"时，
   **必须读 `/workspace/version0802/light-app/sop/app-worker.md`** 并按其中
   App Worker 流程执行；修改现有大屏读 `/workspace/version0802/light-app/sop/modify.md`；
   定时数据刷新按 `/workspace/version0802/light-app/sop/sync.md`。
2. `agents_gen/` 内描述的 serve_html/FBQ 静态交付流程**与交付段无关，禁止用于交付**；
   交付一律走 light-app App Worker。
3. 构建脚本：`/workspace/version0802/light-app/scripts/build_dashboard.py`
   （`LIB_BASE=lib/ RUNTIME_SPEC=1`，产物落 `/workspace/light-app-work/`）；
   页面资源 `lib/` 由平台 app-libs 提供。
4. 产物一律进入 `/workspace/.apps/`（App Worker 注册表）；禁止把大屏 HTML 当作静态文件交付。
5. **与用户交流一律使用简体中文**（代码、标识符、URL、专有名词除外）；过程说明与最终汇报同样使用中文。
6. 本文件与 `light-app/` 目录由平台维护，与 `agents_gen/` 的同事更新互不影响。
