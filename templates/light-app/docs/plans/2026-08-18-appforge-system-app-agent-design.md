# AppForge —— 智能应用开发智能体 · 设计文档（v9.4 定稿）

> **本文档的性质**：面向**后续实现者**（可能是与当前对话完全无关的新模型/新工程师）的**完整前置说明书**。读完本文档，应能独立理解：要做什么、为什么这么做、在什么环境做、可继承什么、不可逾越什么。实现按第 13 章里程碑推进。

---

## 0. 文档导读（先读这段）

- **要做什么**：在 opencode 之上，设计并实现一个"智能应用开发智能体"（代号 **AppForge**）。它接收自然语言业务问题，产出**可自动部署的系统级智能应用**（FastAPI 后端 + Vue3 前端 + 前后端联动），不是单页 HTML。
- **为什么值得读**：本文档浓缩了多轮需求澄清后的定稿——完整需求（§1，含功能定稿 F1-F6）、项目前置信息（§2）、设计哲学（§3）、总体架构（§4-§11）、智能体本体（§14）、落地里程碑（§13）。
- **核心概念**：契约（§6）、分析范式 Archetype（§5）、共享前端壳 + frontend-config（§9）、门禁与降级语义（§8）、部署服务（§10）、需求深挖协议（§7）。
- **技术栈**：Python 3.12 + FastAPI + Vue3/Vite/TS + ECharts + Docker + 只读数据网关；全离线。
- **当前版本状态**：设计已定稿（v9.4）；实现尚未开始（M1 计划见 §13，任务清单见配套文档 `2026-08-18-appforge-m1-carrier-attribution.md`）。

---

## 1. 完整需求（定稿）

> 每条需求的写法：**原始诉求**（用户原意）→ **澄清结论**（多轮问答后定稿）→ **可验收约束**。

### R1 单体深度智能体
- **原始诉求**：完全自主设计一个智能应用开发智能体，不由现有"智能体生产线"生成。
- **澄清结论**：单体深度智能体（无子代理分派），系统提示手写精调；全流程自洽（理解→数据→分析→构建→验证→部署→汇报）。
- **可验收约束**：一个 agent 定义；不依赖现有 agent-generator/模板产线；冷启动面对新领域也由本智能体独立完成（受限上报兜底）。

### R2 产出系统级智能应用（远胜单页 HTML）
- **原始诉求**：应用必须远胜于当前的单 html 页面，是完整的前后端数据联动、系统级智能应用。
- **澄清结论**：产物 = 后端数据/计算服务 + 前端交互应用 + 前后端联动契约 + 参数化重算 + 可交互钻取 + 数据可溯源；单端口单进程，部署为独立 Docker 容器。
- **可验收约束**：改一个滑块/阈值 → 后端重算 → 所有视图联动刷新；每个展示数字可溯源到数据源/字段；空数据产出"无数据结论"而非编造。

### R3 交互式深挖用户需求
- **原始诉求**：智能体也要有和用户交互，交互是获取更多信息的入口，要深挖用户需求。
- **澄清结论**：交互是主信息通道，贯穿全流程（L1 澄清 → L2 数据确认 → L3 规则歧义 → L4 交互偏好 → L5 汇报后追问）；多轮有状态会话，每次问答写入任务契约 `qa_trail` 留痕；追问优先"影响正确性"（规则/阈值/数据源/边界），后"影响体验"。
- **可验收约束**：契约 `qa_trail` 非空且可回溯；信息不足时用合理默认并显式标注"假设"，绝不假装已确认。

### R4 Docker 化自动部署 + 返回链接
- **原始诉求**：部署那一刻要 docker 化；opencode 本身在 docker 内，需要部署流程/推送脚本。
- **澄清结论**：最终闭环 = 开发完成 → 门禁通过 → **自动提交独立部署服务** → **`docker run` app-runner + 卷挂载应用（无 build/push）** → 健康检查 → 返回访问链接（常态 ≤10s）。AppForge 容器不持有 docker 权限（安全）。
- **可验收约束**：部署后返回可访问链接 + 健康状态；`/api/health` 与首页 200；部署失败停机修正，不返回链接。

### R5 前端功能强大、强交互
- **原始诉求**：既然有前后端，前端功能一定要强大，交互性要求必须考虑。
- **澄清结论**：前端 = **共享交互式应用壳（App Shell）** + 每应用 `frontend-config.json` 配置驱动（见 §9.2）。交互能力一次性做进壳：钻取/筛选/时间轴/多视图联动/参数化重算/轮询/导出/URL 可分享状态/数据溯源角标/三态处理。
- **可验收约束**：壳本身是一个完整强交互应用；新应用只需提供配置即可复用全部交互能力。

### R6 高扩展性（众多问题之一）
- **原始诉求**：舰载机配属仅是众多问题之一，智能体必须有很大扩展性。
- **澄清结论**：扩展单位 = **分析范式 Archetype**（§5）：少量预实现的范式（时空归因/异常监控/状态评估…）× 领域规则库（来自现有知识库）→ 实例化为具体应用。新问题大多只需"范式归类 + 契约/配置"，无需写前端代码。
- **可验收约束**：新增一个同范式问题只改契约+配置；跨范式/新范式才写代码；M4 用"供应链缺货归因"验证换领域零改核心。

### R7 后端 API 混合策略 + 独立部署
- **原始诉求**：后端 API 是每个应用自开发一套，还是统一后端接口？
- **澄清结论**：混合——API 面各应用自有（契约驱动）；骨架运行时统一（**build-time 资产复用**，非 runtime 共享服务）；运行部署完全独立（独立容器/端口/URL/生命周期，**不设统一网关**，应用间无共享状态）。
- **可验收约束**：每个应用独立容器/端口/URL/生命周期（共享 app-runner 运行时镜像，应用代码卷隔离）；修改一个应用不影响其他；无共享运行时状态。

### R8 独立部署服务
- **原始诉求**：如果容器内部署有困难，可以单独起一个协助部署的服务，智能体聚焦代码与项目本身。
- **澄清结论**：独立常驻"部署助手"容器（唯一持 docker.sock + 共享工作区 `/workspace`）；AppForge 自测（门禁②③④⑤）通过后自动 `POST /api/deploy` 提交 → 轮询状态 → 返回链接（§10.2）。
- **可验收约束**：AppForge 永不接触 docker.sock；部署服务只有固定流水线、输入白名单、无任意命令入口；操作留日志。

### R9 数据与知识库驱动
- **原始诉求（澄清补充）**：问题基本都围绕**数据库内数据**与**现有知识库**的领域问题。
- **澄清结论**：每个应用 = 分析范式 × 数据库数据契约 × 从**现有知识库**（`rag/*.md`）提炼的规则契约；规则不凭空造，契约化装载现有 KB。
- **可验收约束**：规则契约的 `source` 字段指向知识库/用户显式；数据契约映射真实表字段。

### R10 交付可再实现（本文档的使命）
- **原始诉求**：最终开发可能由新的模型来做，需要前置信息理解设计意图。
- **澄清结论**：本文档自包含——完整需求 + 项目现状 + 架构 + 里程碑，实现者无需回看对话历史。

### F1-F6 功能/需求定稿（用户已确认默认）
> 以下六项为"使用者视角"的功能决策，用户已逐项确认默认值，视为定稿约束。

- **F1 交互入口**：AppForge 在 opencode 对话中以自然语言与用户交互，**不单独做可视化需求录入界面**；question 多轮澄清即交互主通道。
- **F2 应用定位：工具 + 报告都要**：应用既是分析师可操作探索的**工作台**（时间窗/阈值/钻取/重算），又能**一键导出正式报告**（CSV/PNG 起步，报告文档形态 M2+ 补充）；M1 先做工作台 + 导出。
- **F3 运行形态：先手动 + 轮询**：默认"手动刷新 + 参数重算 + 30s 轮询"；**周期性自动重算（每日定时）留后续**，M1 不做。
- **F4 误判容忍：默认偏精确**：置信度达标才标归属，低置信度目标**单独列为"待核实"**；置信度/高度/机型门槛全部开放给用户调节（默认偏精确，用户可自行放宽）。
- **F5 终端用户与鉴权：内网单角色无鉴权**：应用部署后内网直接访问，无登录/角色体系；后续如需再引入。
- **F6 数据源范围：以 DB 表为主**：数据源以数据库表（Doris/MySQL）为主，文件类（CSV/图片）作为旁路补充；实时流暂不考虑。

---

## 2. 项目现状与前置信息（实现者必读）

### 2.1 当前产线架构（参考，非 AppForge 本体）

`agents_gen` 是一套"智能体生产线"：
- **agent-generator**（`.opencode/agents/agent-generator.md`）：多轮对话 → 按模板生成领域分析智能体
- **模板** `templates/analysis-agent.md` + 运行时 SOP `shared/analysis-runtime.md`
- **确定性模块** `lib/analysis/`：ais_anomaly / spatial_association（舰载机归属/ha versine/高度分层）/ carrier_state / threat_assessment / ais_event_assembly
- **脚本** `scripts/`：`db_query.py`（只读数据网关）、`build_dashboard.py`（声明式 spec → HTML）、`validate_*.py`、`selftest.py`
- **能力矩阵** `config/capability-matrix.json`：资产化模式注册表 + 表路由规则

AppForge **不复用**产线本体（agent-generator/模板/SOP 机制），但应**继承其已验证的正确工程洞见**（见 §2.6）。

> **算法资产演进关系（已定）**：AppForge 与产线的**确定性算法收敛统一**——`lib/analysis/spatial_association.py` 等已实现 haversine/高度分层/机型谱系/距离配对/归属判定（规则来源同批 KB），AppForge 直接**复用/迁移**并补时间维度，**不平行维护两套**；二者同源同规则（交叉单测保证一致），避免漂移。

### 2.2 运行环境（实测事实）

| 项 | 值 |
|---|---|
| opencode 容器 | `opencode-clean`（镜像 `smanx/opencode:1.17.10-custom-nods-python-pandas`） |
| 容器 Python | 3.12.13；已装 pandas 2.3.3 / pymysql 1.4.6 / jsonschema 4.25.1 / PyYAML 6.0.3 / Pillow 11.3.0 / numpy 2.3.5 |
| 容器 node | node v24 已装；**npm 缺失**（实测） |
| 容器 fastapi | **无**（实测） |
| 宿主环境 | anaconda Python：fastapi / uvicorn / httpx / jsonschema 齐全；node + **npm 10.8.2** 齐全（实测） |
| 网络 | **严格离线**：禁 `pip install`/`npm install`/外网抓取；依赖须预装或 vendor 化（前端依赖策略：先联网开发 → package-lock + vendor/缓存达成离线可迁移） |
| 容器内 docker | **无 docker.sock、无 docker 命令**（实测）→ 部署走独立部署服务（宿主侧容器） |
| 端口 | 4096（opencode serve）；App Worker 大屏经 20000-29999 预留区间分配（workerd 统一管控） |
| 工作区 | 宿主 `./workspace` 绑挂为容器 `/workspace`；项目在 `/workspace/version0802/agents_gen` |

> **开发/运行位置说明（实测事实）**：M1 阶段 AppForge 应用在**宿主**开发/构建/运行（宿主 npm + fastapi 齐全）；**容器缺 npm/fastapi** 不阻塞 M1，但 **M3 前必须重建镜像补装**（fastapi/uvicorn/pydantic + npm），否则智能体无法在容器内完成开发/自测。

### 2.3 数据资产（Doris，只读网关访问）

网关：`scripts/db_query.py --source doris --sql "..."`（只读，凭据仅网关持有，禁止直接写连接代码）。关键表（库 `standard`）：

| 表 | 含义 | 量级 | 关键点 |
|---|---|---|---|
| `ais_ship_track` | AIS 舰船轨迹（含航母） | 570 万行 | 含 MMSI/船名/位置/航速/航向；`hull_no` 关联航母 |
| `` `aircraft_ads-b_track` `` | 飞行器 ADS-B 轨迹 | 1.6 亿行 | **表名必须反引号**；坐标 `lat` 部分 NULL；全表取数不可行须过滤 |
| `carrier_attribution` | 航母属性 | 11 行 | hull_number/name/class/service_status |
| `kantian_aircraft_carrier_status` | 瞰天航母状态 | 156 行 | |
| `carrier_strike_track` | 航母编队组成 | 58 行 | |
| `carrier_homeport_info` | 母港信息 | 11 行 | |
| `event` / `alarm` | 事件/异动 | 3155/1369 行 | |
| 其他 | 装备/人员/基地/武器关系等 | | 共 24 张表 |

另有 MySQL 对伊情报侦察库（通信/信令/人员/车辆/机构/基站/邮件/联系人，11 表）。

**ADS-B 业务高度判读（来自 schema 档案）**：<200m 低空/起降、200-3000m 中低空巡航、3000-8000m 高空巡航、>8000m 高空战略巡航。

### 2.4 知识库资产（`rag/`，领域规则来源）

`carrier_aircraft_kb.md`（空间关联/高度分层/舰载机机型谱系）、`carrier_ais_kb.md`（AIS OFF/ON 异常）、`carrier_assessment_kb.md`（状态/威胁分级）、`carrier_intel_report.md`、`cvn73_2026_trajectory_kb.md`、`cvn73_washington_intel.md`。

AppForge 的领域规则库**契约化装载这些现有 KB**（§5.3），不重复造规则。

### 2.5 关键约束（不可逾越）

1. 严格离线：依赖预装/vendor，禁联网安装
2. 数据只读：一律经网关，禁止直接持凭据连接
3. 数据可溯源：每个展示数字必须来自真实查询/计算，空结果显式降级
4. LLM 容器不持 docker 权限；部署由独立服务执行
5. 禁止编造：无数据时产出"无可信结论 + 原因 + 建议"

### 2.6 可继承的工程洞见（跨架构成立，保留其精神）

- **只读数据网关**：凭据收敛、只读强制
- **声明式产出**：spec/config → 确定性 builder（产线的 build_dashboard 已验证）
- **机器验证门**：每阶段自动化校验，不过即停
- **可溯源/证据链**：结论回指数据来源与判据

---

## 3. 设计哲学

### 3.1 智能体是"系统架构师 + 编译器"，不是"代码生成器"
> **LLM 负责"决策"**（算什么/用什么数/什么阈值/怎么呈现/置信度多高/系统结构）；**确定性引擎负责"执行"**（取数/算法/构建/校验/部署产物）；决策与执行之间用**契约**隔开，缺契约即停机。

### 3.2 四条不可妥协
1. 智能花在决策上，不花在执行上
2. 契约即边界
3. 空结果也是结果
4. 交互即信息入口

---

## 4. 总体架构（三层分离 + 范式 + 壳）

```
┌─ 核心层（不随领域变，一次实现）──────────────────────────
│   契约 schema · 需求深挖协议 · 分析范式模板 · 门禁 · 部署服务对接
│   共享前端壳 · 构建/部署 · 环境资产
├─ 分析范式层（少量、预实现、可实例化）───────────────────
│   时空归因 / 异常监控 / 状态评估 …（每范式 = 通用后端路由 + 算法管道 + 壳视图集）
└─ 领域规则库（可插拔，契约化装载现有 KB）────────────────
   data-contract(DB 映射) + rule-contract(来自 rag/*.md 与用户) → 实例化范式
```

**新应用 = 范式实例化**：`问题 → 范式归类 → 填数据契约+规则契约+frontend-config → 后端薄层接线 + 共享壳渲染 → 门禁 → 部署`。

---

## 5. 分析范式 Archetype（核心章）

### 5.1 定义
范式 = 一类同构分析问题的**可复用实现骨架**：通用后端路由（参数化）+ 确定性算法管道 + 前端壳视图集 + 门禁模板。范式少而精，覆盖项目目标问题的绝大多数（分析类、DB+KB 驱动）。

### 5.2 首个范式：时空归因（spatio-temporal attribution）
用于"目标归属/归因"类问题（舰载机配属、供应链缺货归因同构）：
- 算法管道：`region_cluster`(历史→作业区) → `sortie_segment`(事件分段) → `spatio_temporal_pair`(时空双条件配对) → `attribution_score`(归属置信度+证据，可复算)
- 通用 API 形状：`entities` / `regions` / `events` / `attribution` / `recompute` / `track/{id}`（语义由契约参数化）
- 壳视图集（完整目标）：地图 + 时间滑窗 + 筛选面板 + 归属矩阵表 + 钻取抽屉（证据链）+ 溯源角标 + 导出；**M1 先做子集**（地图/归属表/筛选/钻取/溯源角标，时间滑窗与导出后置，见 §9.2）

### 5.3 范式 × 领域规则库 = 具体应用
- 舰载机配属：时空归因范式 + `ais_ship_track`/`aircraft_ads-b_track` 数据契约 + 规则契约（alt<200m，规则来源 `carrier_aircraft_kb.md`）
- 供应链归因：时空归因范式 + 库存/订单/物流数据契约 + 缺货归因规则（新 KB/用户给定）
- 核心层、壳、范式零改动，只换契约与配置 → 即 §R6 扩展性

### 5.4 范式注册表
- 注册表存"范式模板"（少量）+ 已实例化应用记录
- 新问题 → 归类到范式（AppForge 决策）；无匹配范式 → 受限上报，或新建范式（需核心层变更，走评审）

### 5.5 范式归类（当前仅 1 范式，保持最简）
当前只有时空归因一个范式，归类**不做复杂机制**：问题含"目标归属/归因 + 时空结构 + 关联置信度"即归入时空归因实例化；否则**受限上报**。
> **≥2 范式时才展开**：维度签名匹配、多范式竞争排序、误归类兜底、新建范式评审（§5.6）等完整归类机制，待出现第二个范式时再设计，避免为不存在的未来提前建框架。

### 5.6 新建范式流程（后置，暂不实现）
> 标注"≥2 范式时启用"：新范式需满足①可复用通用算法管道；②清晰 API 形状与壳视图集；③预计覆盖 ≥2 个问题。评审通过后注册进核心层。

---

## 6. 四份契约 schema

契约是"把理解变可执行"的载体，也是前后端/门禁自动化的依据。契约之间**存在派生链**：任务契约定"做什么" → 数据/规则契约定"用什么数、怎么判" → API 契约定"前端怎么拿"，三者的字段级映射是门禁④⑤与前端绑定的依据。**规则只承载于规则契约**，任务契约通过 `rule_refs` 引用，避免同一信息两处承载（防漂移）。

### 6.1 任务契约 `task-contract.json`
```jsonc
{
  "problem": "业务问题陈述",
  "archetype_hint": "范式归类结果（AppForge 决策，5.5）",
  "rule_refs": ["R1", "R2"],            // 引用 rule-contract 中的规则 id，不重复定义
  "outputs": [{ "kind": "app|report", "desc": "预期输出" }],
  "constraints": ["离线", "时效", "异常策略", "假设（信息不足时显式标注）"],
  "qa_trail": [{ "question", "answer", "contract_field", "timestamp" }]
}
```

### 6.2 数据契约 `data-contract.json`
```jsonc
{
  "sources": [{ "name": "表/源名", "type": "doris|mysql|csv", "access": "网关名" }],
  "mapping": [{
    "task_term": "业务概念（如'舰载机'）",
    "table": "`standard.aircraft_ads-b_track`",
    "field": "altitude_m",
    "semantic": "字段语义（含单位/判读规则）",
    "entity_role": "entity|region|event|track"   // 范式槽位角色，驱动 API 绑定
  }],
  "quality_gate": { "time_coverage", "min_rows", "coord_check", "null_ok", "range_check" }
}
```
> `mapping[].entity_role` 是关键：它把业务字段对齐到范式槽位（实体/区域/事件/轨迹），API 契约据此派生，前端据此绑定。

### 6.3 规则契约 `rule-contract.json`（规则唯一承载）
```jsonc
{
  "rules": [{
    "rule_id": "R1",
    "text": "规则原文",
    "expr": "alt_m < 200 AND dist_km < R AND time_overlap",
    "threshold": { "alt_m": 200, "R": "聚类分布分位数(留痕)" },
    "source": "业务给定 | 知识库(rag/xxx.md) | 推导"
  }],
  "confidence_formula": {
    "rule_main": 0.4, "coupling": 0.2, "type_match": 0.2,
    "alt_profile": 0.1, "time_overlap": 0.1
  },
  "negative_suppression": "反例抑制规则（显式标注非目标）"
}
```

### 6.4 API 契约 `api-contract.json`（由范式 API 模板 × 数据/规则契约派生）
```jsonc
{
  "endpoints": [{
    "method": "GET|POST",
    "path": "/api/regions",
    "params_schema": { "window": "iso8601 范围", "entity": "实体 id" },
    "response_schema": { "items": [{ "region_id", "center", "radius_km", "active_window", "quality" }] },
    "bindings": { "data_field": "data-contract.mapping 对应的字段", "rule_field": "rule-contract 对应规则" }
  }],
  "interaction": { "filters", "drilldowns", "recompute", "exports" },
  "refresh": { "strategy": "poll", "interval_s": 30 },
  "state": { "frontend_state": { "timeWindow", "thresholds", "selected" }, "url_shareable": true },
  "session": "single"
}
```
> API 契约**由范式 API 模板 × 数据契约（entity_role）派生**，前端 client 与门禁④⑤都以它为准——实现时先有契约，后有代码。

> 例：`alt<200m 且 距区域中心<R 且 时段重叠`，`R` 由聚类分布分位数得出并留痕，不 runtime 拍脑袋。

---

## 7. 交互式需求深挖协议

### 7.1 会话模型
- 多轮有状态会话（`question` 工具），会话状态 = 任务契约；每轮回答写入对应字段 + `qa_trail`
- 分层澄清：目标 → 数据 → 规则/阈值 → 输出形态 → 交互偏好 → 边界案例

### 7.2 问题模板库（按阶段组织，每个模板带"写入的契约字段"）
| 阶段 | 代表问题模板 | 写入契约字段 |
|---|---|---|
| 目标 | "你要解决什么问题？产出给谁看？" | `problem`, `outputs` |
| 数据 | "涉及哪些数据？大概时间范围？" | `sources`, `quality_gate.time_coverage` |
| 规则 | "判定'XX'的具体规则是什么？阈值多少？依据在哪（KB/你给定）？" | `rules[].formal/threshold/source` |
| 歧义 | "这个'高度'是 MSL 还是 AGL？区域内驻留多久算？" | `rules[].formal`, `constraints` |
| 边界 | "数据没有/为空时怎么算？极端情况呢？" | `constraints` |
| 交互 | "默认视图？哪些可调参数？要导出吗？" | `interaction`, `refresh`, `outputs` |
| 确认 | "我理解你要的是……对吗？" | 对齐检查（不改字段，仅确认） |

### 7.3 追问状态机（先正确性，后体验）
1. **规则/阈值未形式化** → 必须追问（否则门禁①不过）
2. **数据源/字段语义存疑** → 追问或探查后确认
3. **边界/空数据策略未定** → 追问；用户不答 → 合理默认 + 显式"假设"
4. **交互/呈现偏好** → 有默认即可，不问满，L4 再确认
5. **闭环判定**：四契约可填、规则已形式化、假设已标注 → 停止追问，过门禁①

### 7.4 对齐检查与留痕
- 关键决策后复述"我理解你要的是……对吗？"，用户确认后才继续
- 每轮问答 → `{question, answer, contract_field, timestamp}` 写入 `qa_trail`；契约 = 需求基线，产出可回溯

### 7.5 信息不足降级
- 用户不回应/信息不足 → 合理默认 + 契约 `constraints` 显式"假设：…"，门禁①复核；绝不假装已确认
- 默认值沉淀为模板默认库（如默认时间窗、默认轮询 30s、F4 默认偏精确）

---

## 8. 流水线与门禁

```
L1 任务理解 → L2 数据层 → L3 分析引擎 → L4 构建验证 → L5 汇报/部署
     │①            │②             │              │③④⑤       │⑥
```
| 门禁 | 触发点 | 校验 | 不过则 |
|---|---|---|---|
| ① 契约闭环 | L1 后 | 四契约齐、规则形式化、qa_trail 可回溯、假设显式 | 不取数 |
| ② 数据质量 | L2 后 | 覆盖/量级/坐标/空值率 | 产出无数据结论 |
| ③ 构建门 | L4 | config schema 校验 + 后端可启动 + `/api/health` + 首页 200（壳预验一次） | 停机 |
| ④ API 契约门 | L4 | httpx TestClient 逐 endpoint（含空/非法参数负例） | 停机 |
| ⑤ 联动闭环门 | L4 | 模拟调用序列（选对象→改阈值→重算→断言一致） | 停机 |
| ⑥ 部署门 | L5 前 | 部署服务 `docker run` app-runner + 卷挂载 → `/api/health`+首页 200，AppForge 轮询到 `ready`；**常态 ≤10s** | 不返回链接 |

### 8.1 错误/降级语义统一（所有层共用同一套）

| 场景 | 状态码/语义 | 前端呈现 | 汇报措辞 |
|---|---|---|---|
| 数据质量门不过 | `200` 空结果 + `meta.data_quality: fail` | 空态 + "数据不足"说明 | "无法得出可信结论 + 原因（覆盖/量级/空值）+ 建议" |
| 合法空结果（如窗口内无舰载机） | `200` 空结果 + `meta: {empty_reason}` | 空态 + 原因角标 | "窗口内无满足条件的对象（原因）" |
| 参数非法（范围/类型） | `400` + `error_code` | 输入态提示 | 指明参数与合法范围 |
| 资源过大（窗口超限） | `400`（约束性）或 `413` | 提示缩小范围 | "窗口过大，请缩小范围" |
| 后端异常 | `500` + `request_id` | 错误态 + 重试 | 报错 + 日志引用，不编造结果 |
| 范式不匹配 | 门禁①拦截 | — | 受限上报："该问题不匹配现有范式，需领域专家/新建范式" |
| 部署失败 | 部署门拦截 | — | 部署日志 + 原因，不返回链接 |
| 置信度不足 | 结果单独列为"待核实"分组 | 专属分组/角标 | "低置信度，待核实" |

> 原则：**空结果也是结果**——空/低质一律显式说明原因与建议，绝不硬编；所有降级可回溯到门禁/契约。

---

## 9. 交付物：范式实例化产物 + 共享前端壳

### 9.1 应用目录（范式实例化产物，无 Dockerfile）

> 应用**不构建独立镜像**：纯代码 + 配置，由 `app-runner` 镜像卷挂载运行（§10.5）。

```
app/<app-name>/
├─ backend/          FastAPI 薄层接线（绑定范式通用路由 + 本应用契约/规则）
├─ frontend-config.json   壳配置（视图/图表类型/筛选/钻取/数据绑定，由 API 契约派生）
├─ contracts/        四契约（task/data/rule/api）
├─ rules.py          本应用规则接线（阈值/权重/知识库来源标注）
├─ tests/            API 契约测试 + 联动闭环测试
└─ README.md         运行前提（端口/数据网关/代理基址环境变量）
```

### 9.2 共享前端壳（App Shell，一次性构建）
- 一个 Vue3+Vite+TS+Pinia+ECharts 工程，由 `frontend-config.json` 渲染任意同范式应用
- **首版范围（M1）**：地图(作业区/轨迹/连线/热区) / 归属矩阵表 / 筛选面板(高度/置信度/机型→recompute) / 钻取抽屉(证据链) / 数据溯源角标(hover 来源·时效·字段) / 加载·空·错三态
- **后置（M2+ 迭代）**：时间滑窗拖动 / 导出(CSV/PNG) / URL 可分享状态 / 轮询(30s) / 更多视图——避免首版一次做满（见 §13 M1 范围）
- **覆盖边界**：覆盖分析类应用（90%+）；非常规交互走**壳扩展点**（注册式自定义组件），或退回范式外自研（受限上报评审）
- **预构建**：壳 dist 构建一次，编入 `app-runner` 镜像（§10.5），所有应用共享；应用自身零前端构建

### 9.3 骨架-槽位的演变
v9 把"每应用写 Vue 槽位"收缩为**壳扩展点**（注册式、少数）；LLM 的"执行代码"进一步下降为"契约+配置+薄层接线"，质量由 config schema + 门禁兜底。

### 9.4 frontend-config.json schema（壳的配置契约）
```jsonc
{
  "app_name": "carrier-attribution",
  "title": "舰载机配属研判",
  "api_contract_ref": "apps/<name>/contracts/api-contract.json",
  "layout": [{ "grid": "1fr 1fr", "panels": ["map", "timeline"] }],
  "panels": [{
    "id": "map",
    "type": "map",                       // 壳内置视图组件
    "data": { "endpoint": "/api/regions", "series_field": "items", "bind": { "center": "center", "radius": "radius_km", "color_by": "quality" } },
    "interactions": ["select→drilldown"]
  }, {
    "id": "attribution_table",
    "type": "matrix-table",
    "data": { "endpoint": "/api/attribution", "columns": ["entity","event","score","evidence_count"] },
    "filter_link": "thresholds.alt_max → /api/attribution?alt_max="
  }],
  "filters": [{ "key": "alt_max", "label": "高度上限(m)", "default": 200, "min": 0, "max": 1000, "bind_to": "alt_max" }],
  "drilldowns": [{
    "panel": "map", "trigger": "click-entity",
    "target": { "type": "drawer", "content": "entity-detail",
      "data": { "endpoint": "/api/track/{id}", "param_from": "selected.entity" } }
  }],
  "evidence": { "panel": "evidence-drawer", "endpoint": "/api/attribution/{flight}/evidence" },
  "refresh": { "strategy": "poll", "interval_s": 30, "endpoints": ["/api/events"] },
  "exports": ["csv", "png"]
}
```
> 约束：壳只消费 config 中**已声明的 endpoint**（与 api-contract 一一对应），前端零编造；config 由 AppForge 从 API 契约派生并过 schema 校验（门禁③）。

### 9.5 壳视图组件清单与数据绑定模型
| 组件 | 数据绑定 | 交互 |
|---|---|---|
| `map`（ECharts 地理） | 区域/轨迹/连线/热区 series ← 各 endpoint | 点击实体/事件 → 钻取 |
| `timeline` | 双轨时间线（实体位置 vs 事件时段） | 拖动滑窗 → 全局联动 |
| `matrix-table` | 归属矩阵（实体×事件） | 排序/筛选/点行钻取 |
| `filters-panel` | 各阈值 ↔ API 查询参数 | 变更 → recompute |
| `evidence-drawer` | 证据链（§9.6） | 展示每条证据值/来源/规则 |
| `trace-legend` | 溯源角标（数据来源/时效/字段） | hover 显示 |
| `export` | 当前视图导出 CSV/PNG | 一键导出 |
- **联动模型**：全局状态（时间窗/阈值/选中）是唯一真源 → 变更触发 `recompute`（POST）→ 所有绑定该状态面板刷新 → URL 同步
- **扩展点**：config 无法表达的交互 → 注册自定义组件（壳内置注册表），AppForge 只在必要时写该组件

### 9.6 证据链数据结构（归属结论的证明）
```jsonc
{
  "flight": "…", "entity": "CVN-73",
  "confidence": 0.82,
  "verdict": "attributed|待核实|排除",
  "evidence": [{
    "rule_id": "R1",
    "fact": "窗口内 6 个航次高度全部 <200m",
    "value": { "min_alt_m": 58, "count": 6 },
    "source": "`standard.aircraft_ads-b_track`(altitude_m) 2026-05~08",
    "contribution": 0.4
  }],
  "recompute_signature": "参数+数据源 hash（后置：需跨环境复现验证时再加，M1 确定性 seed 已保证可复算）"
}
```
> 门禁⑤"断言一致" = 前端展示的每个证据 `value` 与后端响应逐字段相等（M1 确定性数据下即可断言）。

---

## 10. Docker 化部署 + 部署服务

### 10.1 闭环
开发完成 → 门禁②③④⑤ → AppForge 写产物到共享工作区 `apps/<name>/` → `POST /api/deploy` → 部署服务 **`docker run` app-runner + 卷挂载应用** → 健康检查 → 返回链接 → AppForge **同轮向用户汇报总结**。

### 10.2 部署服务（唯一持 docker 权限）
- 宿主侧独立常驻容器：挂 `/var/run/docker.sock` + 共享工作区 `/workspace`；AppForge 容器**不挂**
- API：`POST /api/deploy`（应用目录+配置→job_id）/ `GET /api/deploy/{id}`（状态/日志/链接）/ `GET /api/deploy/{id}/logs`
- **动作（固定，无 LLM，无 build/push）**：输入白名单校验 → 分配端口 → `docker run -d --name app-<name> -v <host>/workspace/apps/<name>:/app:ro -p <port>:8000 --env DATA_GATEWAY=... --env APP_PROXY=... app-runner` → `/api/health`+首页 200 → 产出链接
- 安全：只跑固定动作、输入白名单（应用名/目录/端口/环境变量）、应用目录须在共享工作区白名单路径内、端口未占用校验、**卷只读挂载（`:ro`）**、操作留日志
- 独立部署：每应用独立容器/端口/URL/生命周期，无统一网关、无共享状态（§R7）

### 10.3 部署状态机（无构建阶段）
```
validating → running → healthcheck → ready | failed
```
- `validating`：请求白名单校验（应用目录存在/端口空闲/env 白名单）→ 分配端口
- `running`：`docker run` 拉起容器（app-runner + 卷挂载）
- `healthcheck`：连续重试 `/api/health` + 首页 200（默认 3×2s）
- `ready`：产出 `{url, elapsed_s, container_id}`；`failed`：`{error, logs_url}`

### 10.4 部署服务细节（多应用并存）
- **端口分配**：端口池（如 8100-8999），自动分配空闲端口并记录；应用名→端口映射持久化（重启恢复）
- **核心 API（M2 范围）**：`POST /api/deploy` / `GET /api/deploy/{id}` / `GET /api/deploy/{id}/logs` / `POST /api/deploy/{id}/restart`（升级=改卷内代码+restart，保留端口/URL；回滚=还原代码+restart）
- **健康检查失败**：连续失败 → 标记 `degraded`，返回日志与错误，不产出链接（部署门不过）
- **后置（暂不做）**：`stop`/`remove`/`GET /api/apps` 等生命周期管理 API、滚动升级——单用户内网场景暂无需要，按需再加

### 10.5 app-runner 镜像（共享运行时，一次构建）
- **内容**：python 3.12 运行时 + fastapi/uvicorn/pydantic + **壳 dist（前端）** + 范式/引擎代码 + 数据网关适配器 + 启动入口（uvicorn 从卷内 `/app/backend` 启动，加载 `/app/frontend-config.json` 与契约）
- **关键**：应用**不构建独立镜像**，部署 = 卷挂载 `docker run`；**应用构建禁止 pip/npm**——新后端依赖 = 重建 app-runner（慢路径，明确告知时长，罕见）
- **镜像预拉取/常驻**：部署服务启动时预热本机，避免首次部署撞拉取
- **升级**：壳/引擎/范式更新 → 重建 app-runner → 重启各应用容器

### 10.6 部署服务 API 契约
| 接口 | 请求 | 响应 |
|---|---|---|
| `POST /api/deploy` | `{app_dir, app_name, port?, env{}, health{path,timeout_s,retries}}` | `{job_id, eta_s, status_url}` |
| `GET /api/deploy/{id}` | — | `{state, phase, elapsed_s, url?, container_id?, error?, logs_url}` |
| `GET /api/deploy/{id}/logs?offset=` | — | `{lines[], next_offset}` |
| `POST /api/deploy/{id}/restart` | — | `{ok, state}`（升级/回滚 = 改卷内代码 + restart） |
| ~~`stop`/`remove`/`GET /api/apps`~~ | 后置 | 单用户内网暂无需要，按需再加（§10.4） |

### 10.7 两模块协作时序与等待体验（≤10s 目标）
```
AppForge                                  部署服务(宿主容器)
 门禁②③④⑤过，产物写 apps/<name>/
 │──POST /api/deploy─────────────────────→ 校验+分配端口
 │←──{job_id, eta_s:≈8}───────────────────
 │ 轮询 1-2s（validating→running→healthcheck）
 │←──{url, elapsed_s, container_id}─────── ready
 │ 同轮汇报：链接 + 健康状态 + 结论总结
```
- **等待体验三层**：
  1. **架构层（保证 ≤10s）**：app-runner 卷挂载 run + 本机预热 → 常态 5-10s
  2. **交互层（即时反馈）**：AppForge 提交后立即反馈"部署已提交，预计约 N 秒"，轮询在轮内进行，不静默
  3. **极端层（>15s 兜底）**：交付 `job_id + 状态 URL`，明确"部署中，可稍后让我确认链接"——慢路径（重建 app-runner 等）预先告知时长

---

## 11. 环境资产清单（离线可部署的前提）

| 资产 | 内容 | 准备 |
|---|---|---|
| 后端依赖 | fastapi/uvicorn/pydantic/pydantic-settings | 编入 **app-runner 镜像**（重建时 pip 预装一次；宿主 anaconda 已齐，可先行开发） |
| 前端依赖 | Vue3/Vite/TS/Pinia/ECharts + 共享壳构建产物 | **宿主 npm 构建**：先联网开发，package-lock 固化 + vendor/缓存达成离线 `npm ci` 可复现；**壳 dist 编入 app-runner 镜像** |
| app-runner 镜像 | python 运行时 + fastapi + 壳 dist + 范式/引擎 + 网关适配器 + 启动入口 | 一次构建、宿主预热常驻；应用卷挂载运行，**不做每应用镜像** |
| 部署服务 | 部署助手镜像(含 docker CLI) + docker.sock 挂载 + 共享工作区 + 端口池 | 宿主侧常驻 |
| 数据网关 | 只读 SQL 网关（凭据仅网关） | 部署时环境变量注入地址 |

---

## 12. 与现有产线对比

| 维度 | 现有产线 | AppForge |
|---|---|---|
| 目标 | 批量生产分析 agent + 单页大屏 | 一个智能体锻造系统级应用 |
| 产物 | 静态离线单页 HTML | FastAPI+Vue 联动系统 + Docker 自动部署 |
| 需求理解 | 一次性 SOP 澄清 | 交互式需求深挖（多轮·留痕·贯穿全流程） |
| 前端 | 静态大屏 | 共享交互壳（配置驱动，强交互） |
| 扩展 | 每换领域改矩阵/参考库 | 范式实例化（契约+配置），壳与核心零改动 |
| 部署 | 静态文件 + serve 进程（单进程多应用复用） | **app-runner 镜像卷挂载 `docker run`**（无 build/push，≤10s 返回链接），容器/端口/URL 自治，无统一网关 |
| 抗幻觉 | SOP 约束 | 契约 + 六道门禁 + 证据链 |

---

## 13. 落地路线（里程碑）

### M1 最小闭环：舰载机配属（本轮目标）
- 范围：四契约+校验 · **时空归因范式（扁平化实现）** · **算法管道（复用 `lib/analysis` + 补时间维度，不平行新写）** · seed 确定性数据 · **门禁②③④⑤（含数据质量门）** · FastAPI 薄层后端 · **共享前端壳(首版子集，Task 6 先做离线 npm spike)** + frontend-config · 宿主 uvicorn 直跑（Docker 归 M2）
- **真实 Doris 最小冒烟为 M1 必做**（单航母/单日窗口，规避 1.6 亿行全表；验证量级取数与 lat NULL 等质量风险早暴露），不堆到 M4
- 壳首版子集：地图/归属表/筛选(recompute)/钻取(证据链)/溯源角标；**时间滑窗/导出/URL状态/轮询后置**
- 详单：见配套文档 `docs/superpowers/plans/2026-08-18-appforge-m1-carrier-attribution.md`
- 验收：门禁全绿（含空库→②FAIL）；前端可交互联动；证据可溯源；置信度可复算；反例显式抑制；**真数据冒烟通过且风险记录在 README**

### M2 部署闭环
- **app-runner 镜像**构建（python 运行时 + fastapi + 壳 dist + 范式/引擎 + 网关适配器 + 启动入口）· 宿主预热
- **部署服务**（API/校验白名单/端口池/卷挂载只读运行）· **核心 API：deploy/status/logs/restart**（stop/remove/apps 后置）· 无 build/push
- **协作契约**：提交→轮询→同轮汇报链接；**部署端到端耗时 <10s 自动化断言**
- AppForge 对接：门禁⑥ → 提交 → 轮询 → 链接 + 结论总结汇报

### M3 智能体本体
- AppForge 智能体定义（系统提示精调）· 交互式需求深挖协议 · 范式归类决策 · 冷启动流程 · 受限上报
- 本体规格草案见 §14

### M4 跨领域验证
- 供应链缺货归因（时空归因范式第二实例）——验证"换领域零改核心/壳/范式"

---

## 14. AppForge 智能体本体设计（M3 规格草案）

> M3 目标：把"脚本+契约驱动"上升为**精调的单体智能体**。本节是系统提示与行为的规格草案，M3 实现时细化。

### 14.1 系统提示骨架
```
身份：智能应用开发智能体（AppForge）——把业务问题编译成系统级智能应用。
纪律（不可违反）：
  1. LLM 只做决策（算什么/用什么数/什么阈值/怎么呈现/置信度/系统结构），
     执行一律走确定性引擎（取数/算法/构建/门禁/部署服务）。
  2. 契约即边界：先填契约，后写代码；门禁不过即停机修正。
  3. 空结果也是结果：空/低质结论显式说明原因与建议，绝不编造。
  4. 交互即信息入口：多轮澄清贯穿全流程，每轮问答留痕。
  5. 离线约束：禁联网安装；数据只读经网关；不接触 docker（部署走部署服务）。
能力边界：
  - 已实现范式（当前：时空归因）→ 实例化
  - 无匹配范式 → 受限上报，不硬套
  - 数据质量/规则歧义/结果为空 → 如实降级
```
### 14.2 行为流水线（对应 §8）
L1 需求深挖（§7 协议）→ 门禁① → L2 数据探查/质量（门禁②）→ L3 范式编排/算法 → L4 装配+门禁③④⑤ → L5 提交部署服务+轮询+汇报链接（门禁⑥）。

### 14.3 范式归类（§5.5 落地）
- 当前仅 1 范式：问题含"目标归属/归因 + 时空结构"即归入时空归因实例化；否则受限上报
- ≥2 范式时才展开完整归类机制（维度签名匹配等，见 §5.5 标注）

### 14.4 冷启动与受限上报
- 时空归因可覆盖的问题：实例化并沉淀规则库（规则来源现有 KB）
- 不可覆盖 → 受限上报请求领域专家/用户补充；新建范式流程后置（§5.6）

### 14.5 工具权限（opencode agent 定义）
- `question`（多轮需求会话）· `bash`（只跑引擎/门禁/构建/部署提交）· `read/glob/grep`（勘查契约/数据/产物）· `edit`（只写契约/config/薄层接线/报告）
- 权限：allow read/glob/grep/bash/edit/question；deny webfetch/websearch（离线）
- **无 docker 权限**（部署经部署服务）；不直接持数据库凭据（经网关）

### 14.6 验收基线（M3）
- 端到端：给一个问题 → 交互澄清 → 契约 → 应用 → 门禁 → 部署 → 返回链接
- 抗幻觉：空数据/低质量/范式不匹配均被显式处理，无编造
- 复现：同参数重算结果一致（recompute_signature）
