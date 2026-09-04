# AppForge M1 —— 舰载机配属最小闭环（实现计划）

> **For agentic workers:** 按任务清单（`- [ ]`）顺序执行，每完成一项勾选并验证后再进入下一项。全部完成后按「验收标准」逐条自查。

**Goal:** 用真实/模拟海空数据跑通「任务契约 → 取数 → 作业区聚类 → 航次分段 → 时空配对 → 归属置信度 → FastAPI API → **共享前端壳 + frontend-config** 展示」**最小端到端闭环**。前端可交互（阈值/钻取），门禁②③④⑤自动化。**真实 Doris 最小冒烟（单航母/单日窗口）为 M1 必做**，让真数据量级/质量风险早暴露。部署用手动 uvicorn（Docker/部署服务归 M2）。

**Architecture:** 契约驱动 + **时空归因范式**（首个 Archetype，**扁平化实现**）+ 确定性算法库（**复用/迁移现有 `lib/analysis`，不平行新写**）+ FastAPI 薄层后端 + **共享前端壳（一次性构建，配置驱动）** + 四道门禁②③④⑤。智能体本体（M3）未介入前，M1 由**脚本 + 契约**直接驱动，验证范式、壳与门禁的正确性。

**Tech Stack:** Python 3.12 + FastAPI/uvicorn/pydantic/jsonschema + Vue3 + Vite + TypeScript + ECharts + npm（离线 vendor）。数据：**确定性模拟种子**（门禁/测试）+ **Doris 只读网关最小冒烟（M1 必做）**。

**范围决策（已确认）：**
- ✅ 门禁/测试用**确定性模拟数据**（离线可复现）；**真实 Doris 最小冒烟为 M1 必做**（单航母/单日窗口，验证 1.6 亿行量级下取数/聚类的可行性与数据质量），不堆到 M4
- ✅ **算法资产复用/迁移现有 `lib/analysis`**（spatial_association 已含 haversine/高度分层/机型谱系/距离配对/归属判定，规则来源同批 KB），M1 只补**时间维度**（region_cluster 时间连续性、spatio_temporal_pair 双条件含时段、attribution_score 置信度公式）；**AppForge 与产线算法收敛统一，不平行维护两套**（演进关系见设计文档 §5）
- ✅ **范式/契约装载器扁平化**：M1 用轻量 manifest 解析（不建泛化装载器/API 自动派生机制），第二个范式出现（M4）再重构——避免为不存在的未来提前建框架（呼应设计文档 §5.5）
- ✅ **门禁②（数据质量门）M1 实现**："空结果也是结果"哲学落地在此门，seed 下断言通过 + 人为破坏必 FAIL
- ✅ M1 部署用**宿主 uvicorn 直跑**（宿主已实测 fastapi/uvicorn/httpx/jsonschema 齐全）；Docker 化 + 部署服务归 M2
- ✅ M1 **不做智能体本体**（脚本+契约驱动），精调智能体归 M3
- ✅ 只实现 **1 个范式（时空归因）+ 算法管道（复用 lib/analysis + 时间维度）+ 共享前端壳（首版子集）**，用舰载机配属作为范式第一实例
- ✅ 前端 = **共享壳 + frontend-config.json**（不按应用独立脚手架 Vue 工程）
- ✅ **前端壳用 Vite+Vue3+TS，宿主 npm 构建**；**Task 6 开头先做半天级 spike** 验证离线 `npm ci` 可复现，结论决定前端技术路线是否需调整
- ✅ 容器缺 npm/fastapi 不阻塞 M1（M1 全程宿主跑）；M3 前重建镜像补装（已知风险，见设计文档 §2.2/§11）
- ❌ 暂不做：需求深挖协议完整版（先一次澄清）、多范式/跨领域、Docker/部署服务、壳后置项（时间滑窗/导出/URL 状态/轮询）

---

## 目录结构（新增总览）

```
appforge/
├─ contracts/
│   ├─ task-contract.schema.json       任务契约
│   ├─ data-contract.schema.json       数据契约
│   ├─ rule-contract.schema.json       规则契约
│   ├─ api-contract.schema.json        API 契约
│   └─ validate.py                     契约校验器（jsonschema）
├─ archetype/
│   ├─ manifest.schema.json            范式 manifest schema（扁平，M1 不建泛化装载器）
│   ├─ registry.py                     轻量解析（读 manifest→算法管道/API/壳视图；M4 再泛化）
│   └─ spatio-temporal-attribution/    时空归因范式（首个）
│       ├─ manifest.json               范式声明（算法管道/通用 API/壳视图集）
│       └─ routes.py                   范式通用路由模板（按契约参数化）
├─ algorithms/                         ★ 复用/迁移 lib/analysis，补时间维度（不平行新写）
│   ├─ geo.py                          haversine/高度分层/机型谱系 ← 迁移自 lib/analysis.spatial_association
│   ├─ region_cluster.py               作业区聚类（新增：时间连续性）
│   ├─ sortie_segment.py               航次分段（进区-驻留-离区，含高度剖面）
│   ├─ spatio_temporal_pair.py         时空配对（复用距离配对 + 新增时段重叠）
│   └─ attribution_score.py            归属置信度（复用机型/剖面判定 + 新增权重公式与反例抑制）
├─ data/
│   ├─ seed.py                         确定性模拟数据生成器（固定种子）
│   ├─ seed_output/                    生成产物（JSON，可 gitignore）
│   └─ adapter.py                      数据访问层（seed | doris 网关）
├─ backend/
│   ├─ app.py                          FastAPI 入口（/api/* + /api/health + 托管壳 dist）
│   ├─ app_instance.py                 应用实例装配（范式路由 × 本应用契约/规则绑定）
│   ├─ schemas.py                      pydantic 请求/响应模型（由 api-contract 对齐）
│   ├─ engine.py                       算法编排（按范式 manifest 调用算子）
│   ├─ cache.py                        参数 hash LRU 缓存
│   └─ config.py                       运行配置（数据源/端口/代理基址）
├─ shell/                              ★ 共享前端壳（一次性构建，所有应用复用）
│   ├─ package.json / vite.config.ts / tsconfig.json / index.html
│   ├─ src/
│   │   ├─ main.ts / App.vue / router.ts
│   │   ├─ api/client.ts               类型化 API client（按 api-contract 配置化）
│   │   ├─ state/store.ts              单会话状态（Pinia）：窗口/阈值/选中（URL 同步后置）
│   │   ├─ views/Overview.vue          地图+阈值面板+归属表（配置驱动，时间滑窗后置）
│   │   ├─ views/DrilldownDrawer.vue   对象详情/证据链（配置驱动）
│   │   ├─ components/                 地图(ECharts)/归属表/筛选面板/溯源角标
│   │   └─ config-loader.ts            加载 frontend-config.json 渲染应用
│   └─ dist/                           构建产物（gate3 产出，可预构建进基础镜像）
├─ apps/
│   └─ carrier-attribution/
│       ├─ frontend-config.json        ★ 本应用壳配置（视图/图表/筛选/钻取/数据绑定）
│       ├─ contracts/                  本应用四契约（task/data/rule/api）
│       └─ rules.py                    本应用规则接线（阈值/权重/知识库来源标注）
├─ gates/
│   ├─ gate2_data_quality_test.py      门禁②：quality_gate 检查（覆盖/量级/坐标/空值/范围）
│   ├─ gate3_build.sh                  shell build + uvicorn + /api/health + 首页 200
│   ├─ gate4_api_contract_test.py      httpx TestClient 逐 endpoint（含负例）
│   └─ gate5_linkage_test.py           模拟前端调用序列断言
└─ tests/
    └─ e2e.py                          端到端验收（真实数据或 seed）
```

---

## Task 1：四份契约 schema + 校验器

- [ ] `contracts/task-contract.schema.json`：`problem` / `rules[]`(id,text,formal) / `outputs[]` / `constraints[]` / `qa_trail[]`
- [ ] `contracts/data-contract.schema.json`：`sources[]`(name,type) / `mapping[]`(task_term,table,field,semantic) / `quality_gate`(time_coverage,min_rows,coord_check,null_ok)
- [ ] `contracts/rule-contract.schema.json`：`rules[]`(rule_id,expr,threshold,source) / `confidence_formula`
- [ ] `contracts/api-contract.schema.json`：`endpoints[]`(method,path,params_schema,response_schema) / `interaction` / `refresh` / `state` / `session`
- [ ] `contracts/validate.py`：`validate_contract(cpath)` → 校验通过 OK / 失败逐项报错（exit 1）
- [ ] 样例契约：为舰载机配属生成一份完整 `task/data/rule/api` 契约 JSON（放 `appforge/example/contracts/`），作为算法/后端/前端对齐的规范源

**验证：** `python appforge/contracts/validate.py appforge/example/contracts/*.json` 全 OK；篡改一个字段必报错。

## Task 2：时空归因范式 manifest（扁平实现，不做泛化装载器）

> 单范式单应用阶段**不做抽象税**：不建泛化装载器/API 自动派生机制，第二个范式出现（M4）再重构（呼应设计文档 §5.5）。

- [ ] `archetype/manifest.schema.json`：`id` / `algorithm_pipeline[]` / `api_template[]`（通用路由形状）/ `shell_views[]`（壳视图集）/ `data_source_adapters[]`
- [ ] `archetype/registry.py`（轻量）：`load_manifest(path)` → 读 manifest.json + import 算法模块 + 解析 API 模板/壳视图（**不做 schema 校验器之外的泛化装载机制**）；`matches(problem)` → 简单判断"含目标归属/归因 + 时空结构 → 归入时空归因"，否则受限上报
- [ ] `archetype/spatio-temporal-attribution/manifest.json`：算法管道=[region_cluster, sortie_segment, spatio_temporal_pair, attribution_score]；API 模板=[entities, regions, events, attribution, recompute, track/{id}]；壳视图=[map, matrix-table, evidence-panel]；data_source_adapters=[seed, doris]
- [ ] `apps/carrier-attribution/rules.py`：本应用规则接线——阈值/权重/知识库来源标注（如 alt<200m 来源 `rag/carrier_aircraft_kb.md`）

**验证：** `registry.load_manifest` 能装载并成功 import 4 个算法模块（Task 3 完成后）；`matches` 能把舰载机配属归入时空归因、把"无时空结构问题"判为不匹配。

## Task 3：算法管道（复用 lib/analysis + 补时间维度）

> **不平行造轮子**：`lib/analysis/spatial_association.py` 已实现 haversine、高度分层(<200ft)、机型谱系匹配（F/A-18/F-35C/EA-18G/E-2D/MH-60/CMV-22B）、距离配对、`is_carrier_aircraft` 判定，规则来源正是 `rag/carrier_aircraft_kb.md`。M1 **复用/迁移**这些函数到 `appforge/algorithms/`（或 import 引用），只补时间维度；AppForge 与产线算法**收敛统一，不平行维护**。

- [ ] `algorithms/geo.py`：`haversine_km` / `alt_layer`（<200ft 分层）/ `is_carrier_type`（机型前缀匹配）← **迁移自 `lib/analysis/spatial_association.py`**（同名等价，规则不变）
- [ ] `algorithms/region_cluster.py`：输入近 3 月航母轨迹点 `[{hull, t, lat, lon}]` → **网格密度 + 时间连续性**聚类 → `[{hull, region_id, center, radius_km(分布分位数), t_start, t_end, point_count, quality}]`；`--radius-quantile 0.95`（**新增：时间连续约束**，空间聚类复用既有思路）
- [ ] `algorithms/sortie_segment.py`：输入区域 + 轨迹点 → 按进区-驻留-离区切分航次 → `[{flight, t_in, t_out, dwell_min, alt_profile:[{t,alt_m}], min_alt_m, max_alt_m}]`
- [ ] `algorithms/spatio_temporal_pair.py`：输入区域/航次 → 双条件（最小距离 < R **且 时段重叠**）→ `[{flight, hull, overlap_min, min_dist_km, alt_layer_dist}]`（**距离部分复用** spatial_association，**新增时段重叠**）
- [ ] `algorithms/attribution_score.py`：主规则(区域内 alt<200m, 40%) + 多航次起降耦合(20%) + 机型谱系(20%) + 高度剖面<200m 占比(10%) + 时空重叠(10%) → `[{flight, hull, score, evidence:{...}, verdict: attributed|待核实|排除, reason}]`；公式固定、可复算；**复用机型/剖面判定**，反例抑制（非舰载机机型/剖面不符 → 显式标注"排除"）
- [ ] 每个模块 CLI 化（argparse：`--input/--output/参数`），可独立重跑；纯函数核心（可被单测 import）；**迁移函数与 lib/analysis 保持同规则**（交叉单测：同一输入两种实现输出一致）

**验证：** 用 Task 4 的 seed 数据跑通管道，输出含正向命中的舰载机（attributed）+ 待核实 + 排除（反例抑制）；迁移函数与 `lib/analysis` 输出一致。

## Task 4：确定性模拟数据（门禁/测试依赖）

- [ ] `data/seed.py`：固定随机种子生成海空数据，**确定性可复现**：
  - 2 艘航母（CVN-73/CVN-72），各含近 3 月轨迹（含作业区聚集 + 机动段）
  - ≥6 架飞机：**3 架舰载机**（F/A-18E/F 谱系，区域内 alt<200m 起降 + 多航次 + 高度剖面）＋ **2 架区域外低空**（反例：非舰载机）＋ **1 架区域内高空通航**（反例：alt>200m）
  - 含少量静默期（航母 AIS OFF，位置取最后已知点）
- [ ] `data/adapter.py`：`load(task_contract)` → 按 `sources[].type` 分派 seed/doris；统一输出 `{carriers:[], tracks:[{hull,..}], aircraft_tracks:[{flight_id, t, lat, lon, alt_m, speed, aircraft_type, callsign}]}`；doris 分支调只读网关 `scripts/db_query.py`（沿现状）

**验证：** seed 输出可重复（两次运行 diff 为空）；adapter seed 分支返回结构完整。

## Task 5：FastAPI 薄层后端（范式路由 × 本应用契约绑定）

- [ ] `backend/config.py`：端口 / 数据源(seed|doris) / 代理基址 / 缓存容量（环境变量可覆盖）
- [ ] `backend/engine.py`：按范式 manifest 编排 `adapter.load → region_cluster → sortie_segment → spatio_temporal_pair → attribution_score`，产出结构化结果
- [ ] `backend/cache.py`：按参数 hash 的 LRU（`recompute` 命中不重跑）
- [ ] `backend/schemas.py`：pydantic 请求/响应模型（与 api-contract 对齐）
- [ ] `archetype/.../routes.py`（范式通用路由模板）+ `backend/app_instance.py`（应用实例装配）：
  - `GET /api/entities` → 航母列表+状态（语义由数据契约映射，如 carriers）
  - `GET /api/regions?entity&window` → 作业区（窗口参数化）
  - `GET /api/events?region_id&alt_max` → 区域航次/事件（高度过滤）
  - `GET /api/attribution?entity&conf_min&alt_max` → 配属+证据
  - `POST /api/attribution/recompute` → 参数化重算（缓存）
  - `GET /api/track/{id}` → 单对象轨迹/证据链
  - `GET /api/health` → `{ok:true}`
- [ ] `backend/app.py`：FastAPI 实例装配 + 托管 `shell/dist`（静态）+ `/api/health`

**验证：** `uvicorn appforge.backend.app:app` 启动；curl 每个 endpoint 返回符合响应 schema；非法参数/空数据返回 400/200 空结果（不 500）。

## Task 6：共享前端壳（首版，一次性构建）+ 舰载机配属 frontend-config

### 6.0 前置 spike（半天级，先做——决定 M1 前端技术路线）
- [ ] **spike：验证宿主 `npm ci` 离线可复现**——联网装依赖 → package-lock 固化 → 清空 node_modules → 用 npm cache/离线源 `npm ci` 重建成功 → 记录可行做法与依赖体积
- [ ] **spike 结论判定**：离线可复现 → 按 Vite+Vue3+TS 正式开发；不可复现 → 调整方案（如实上报，如改用预打包 dist 直接 vendor 进仓库），**不硬着头皮继续**
- [ ] 该结论写入运行说明 README（离线构建步骤）

### 6.1 壳开发（spike 通过后进行）

- [ ] `shell/`：Vite+Vue3+TS+Pinia+ECharts 工程；**宿主 npm 构建**（按 spike 结论的离线可复现做法执行）
- [ ] `shell/src/config-loader.ts`：加载 `frontend-config.json` → 渲染视图（视图类型/图表配置/筛选/钻取/数据绑定均配置驱动）
- [ ] `shell/src/api/client.ts`：按 config 中的 API 契约生成类型化 client，统一错误/加载处理
- [ ] `shell/src/state/store.ts`：单会话状态 `{window, thresholds, selectedEntity, selectedEvent}`（URL 同步后置）
- [ ] `shell/src/views/Overview.vue`（配置驱动）：
  - 地图（ECharts + 区域多边形/热区 + 轨迹 + 归属连线 + 高度着色）
  - 阈值面板（高度/置信度下限/机型）→ 触发 `recompute` → 地图/归属表联动
  - 归属矩阵表（实体×事件：置信度/重叠时长/频次/类型/剖面）+ 溯源角标（hover 显示来源/时效）
- [ ] `shell/src/views/DrilldownDrawer.vue`（配置驱动）：点实体 → 区域+事件时间线；点事件 → 证据链面板（每项证据值来自后端响应）
- [ ] 加载骨架屏 / 空 / 错三态
- [ ] **后置（M1 不做）**：时间滑窗拖动 / 导出(CSV/PNG) / URL 可分享状态 / 轮询(30s)——避免首版一次做满，M2+ 迭代
- [ ] `apps/carrier-attribution/frontend-config.json`：本应用壳配置（视图布局/图表绑定到 /api/regions /api/events /api/attribution 等；筛选与钻取定义）

**验证：** `npm run build`（shell）通过；`frontend-config.json` 校验通过；页面加载后地图/表格有数据，改阈值触发重算且视图同步。

## Task 7：门禁②③④⑤自动化

- [ ] `gates/gate2_data_quality_test.py`（门禁②）：实现 `quality_gate` 检查——time_coverage / min_rows / coord_check / null_ok / range_check，输入不达标 → 显式"数据不足"结论（空结果也是结果）；seed 下断言通过 + 人为破坏（空库/全 NULL 坐标/窗口无覆盖）必 FAIL
- [ ] `gates/gate3_build.sh`：`npm run build` 成功 + 启动 uvicorn + `curl /api/health`=200 + 首页 200 → OK/FAIL
- [ ] `gates/gate4_api_contract_test.py`：httpx TestClient 逐 endpoint，断言参数→响应 schema；含负例（非法参数 400、空数据 200 空结果、超大窗口 400）
- [ ] `gates/gate5_linkage_test.py`：模拟前端调用序列（选航母→改 alt_max→recompute→断言归属数变化、响应与契约一致）
- [ ] 纳入统一入口 `gates/run_all.sh`（任一 FAIL 停机，输出可读）

**验证：** `run_all.sh` 全绿；人为引入缺陷（空库→门禁②必 FAIL、路由缺失→④必 FAIL、阈值错→⑤必 FAIL）。

## Task 8：端到端验收 + 真实数据最小冒烟（M1 必做）

- [ ] `tests/e2e.py`：跑完整流水线（seed 数据）→ 断言：每航母有作业区证据、每配属飞机有 alt<200m 记录、置信度按公式可复算、反例被抑制
- [ ] **真实数据最小冒烟（M1 必做）**：`--source doris` 取**单航母 + 单日窗口**（规避全表 1.6 亿行），跑通 adapter→region_cluster→sortie_segment→spatio_temporal_pair→attribution_score：
  - 验证真数据量级下取数（SQL 过滤/limit）可行、lat NULL 等质量问题被门禁②如实标注
  - 输出与 seed 同构；数据时效/量级如实标注；不达标如实降级（"无法得出可信结论 + 原因"）
  - **结论记录**：真数据可行性结论写回 README（风险早暴露，不堆到 M4）
- [ ] 运行说明 README（启动/契约/门禁/数据源切换/参数/前端构建与离线迁移说明/真数据冒烟结论）

**验证：** e2e 全绿；doris 最小冒烟跑通且与 seed 同构；真数据风险（量级/NULL/静默期）有明确记录。

---

## 验收标准（M1 完成定义）

- [ ] 四契约校验通过；**时空归因范式 manifest** 装载成功（管道模块可复算、有单测断言）；**装载器扁平化**（无泛化机制，M4 再重构）
- [ ] **算法复用 lib/analysis**：迁移函数与 `lib/analysis` 输出一致（交叉单测）；仅新增时间维度与置信度公式
- [ ] seed 数据确定性可复现；**门禁②③④⑤**全部自动化且全绿（门禁②空库必 FAIL）
- [ ] **共享前端壳**由 `frontend-config.json` 驱动渲染；阈值 → recompute → 地图/归属表联动刷新；钻取与证据链可看
- [ ] 端到端：每航母有区域证据、每配属飞机有 alt<200m 记录、置信度可复算、反例显式抑制
- [ ] **真实 Doris 最小冒烟通过**（单航母/单日窗口，取数可行、质量门如实、输出与 seed 同构、风险记录在 README）
- [ ] 宿主 `uvicorn` 直跑可访问（M1 部署形态）；运行说明文档齐全
- [ ] **范式可复用性预告验证**：`frontend-config.json` + 契约与范式代码分离，M4 换领域只需新增 config/契约（本里程碑确认该边界成立即可）

## M1 之后（不在本期）

- M2：**app-runner 镜像**（python+fastapi+壳 dist+范式/引擎）+ 独立部署服务（**卷挂载 `docker run`，无 build/push，≤10s 返回链接**，同轮汇报）
- M3：AppForge 智能体本体精调 + 交互式需求深挖协议 + 范式归类决策 + 冷启动
- M4：跨领域验证（供应链缺货归因 = 时空归因范式第二实例），证明换领域零改核心/壳/范式
