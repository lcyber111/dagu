# 业务领域解耦——能力矩阵化（最小版）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把生成器第5轮决策表（领域→表/模式映射）从提示词硬编码抽成 `config/capability-matrix.json`，让生成器机制层与领域数据分离。"多领域平台"是解耦之后的自然结果，**不是本计划的目标**。

**Architecture:** 三层解耦：① 新增 `config/capability-matrix.json`（领域配置，承载决策表核心映射数据）＋ `scripts/render_matrix.py` 把矩阵渲染成 markdown 供生成器 LLM 读取；② 生成器提示词改为"读矩阵 markdown 查行"，删掉内联决策表正文；③ `scripts/test_capability_matrix.py` 交叉引用一致性测试（保底）。矩阵最小版只含 `patterns{}`（资产化模式注册表）+ `table_rules[]`（表路由）——这两个是真正领域化的。

**Tech Stack:** Python (json/jsonschema) + markdown（渲染给 LLM）+ 现有 selftest.py 框架。

**范围（已按反馈裁剪）：**
- ✅ 保留：矩阵本体（最小版）/ 一致性测试 / render_matrix
- ⚠️ 降级可选：契约散文迁移（`pattern-contracts.md`，第一版不迁，矩阵存指针指向生成器内部段落）
- ❌ 砍掉：x-generation 元数据 / 语义校验器 / 冻结语料（这些是多领域平台配套，对当前解耦非必需）

---

## 一、设计决策

| # | 决策 | 选择 | 理由 |
|---|------|------|------|
| 1 | 矩阵粒度 | **稀疏特征规则**（when→inject 列表，贴近现有决策表结构） | 现有决策本就是特征规则；48 格全组合僵化 |
| 2 | 矩阵范围 | **最小版：只 patterns{} + table_rules[]** | pattern_rules（模式选择）偏机制层、colors 已独立主题文件，暂不抽 |
| 3 | 契约散文 | **第一版不迁移**，矩阵 `contract_ref` 存指针指向生成器段落 | 降低改动面；后续需要再抽 pattern-contracts.md |
| 4 | 生成器读法 | **读 render_matrix 输出的 markdown** | LLM 读 markdown 比读 JSON 稳；JSON 是校验/测试的规范源 |
| 5 | 回归方式 | **矩阵一致性测试（纯 CI）** | 生成靠 LLM 非确定性，语义校验/语料属多领域配套，本版不做 |

---

## 二、现状盘点：领域耦合点全清单

### 本计划抽走（最小版）

| 位置 | 内容 | 抽到哪 |
|------|------|--------|
| `agent-generator.md:320-328` 资产化模式注册表 | id→规则源/CLI/用途 | `matrix.patterns{}` |
| `agent-generator.md:349-357` Doris 表匹配 | 用户特征→Doris 表 | `matrix.table_rules[]` |
| `agent-generator.md:360-366` MySQL 关键词路由 | 关键词→MySQL 表 | `matrix.table_rules[]` |

### 本计划保留（机制层 / 非必需）

| 位置 | 内容 | 为何保留 |
|------|------|---------|
| `:312-318` 模式选择表 | 答案特征→注入模式 | 偏机制层（任务类型→能力是通用映射），暂不抽 |
| `:333-336` 输入契约要点 | 叙事散文 | 契约迁移降级为可选，本版不迁 |
| `:375`/`:393` 颜色 | 领域色 | 已在 shared/viz-dark-theme.md 独立，无需抽 |
| `:368-387` 占位符填充规则 | 结构 | 通用 |

---

## 三、文件结构

```
新增：
  config/capability-matrix.json        # 领域能力矩阵（patterns + table_rules）
  config/capability-matrix.schema.json # 矩阵结构校验
  scripts/render_matrix.py             # matrix JSON → markdown（供生成器 LLM 读）
  scripts/test_capability_matrix.py    # 矩阵一致性测试

修改：
  .opencode/agents/agent-generator.md  # 第5轮决策表 → "读 matrix markdown 查行"
  scripts/selftest.py                  # 加矩阵一致性测试
```

**不动**：validate_agent.py、模板、README、shared/（除 agent-generator 引用调整）。

---

## 四、任务分解

### Task 1: capability-matrix.json（领域决策矩阵，最小版）

**Files:**
- Create: `config/capability-matrix.json`
- Create: `config/capability-matrix.schema.json`

- [ ] **Step 1: 创建 `config/capability-matrix.json`**（从 `agent-generator.md:320-366` 逐行迁移）

```json
{
  "version": 1,
  "domain": "military-intel",
  "description": "军事情报领域能力矩阵（航母+伊朗）。换领域新建 matrix-<domain>.json 即可，生成器机制层不动",
  "patterns": {
    "ais-anomaly": {
      "module": "lib.analysis.ais_anomaly",
      "rule_source": "rag/carrier_ais_kb.md",
      "cli": "python -m lib.analysis.ais_anomaly --input ... --output ...",
      "contract_ref": "见生成器第5轮 资产化模式输入契约",
      "purpose": "AIS OFF/ON 异常与等级"
    },
    "spatial-association": {
      "module": "lib.analysis.spatial_association",
      "rule_source": "rag/carrier_aircraft_kb.md",
      "cli": "python -m lib.analysis.spatial_association --input ... --output ...",
      "contract_ref": "见生成器第5轮 资产化模式输入契约",
      "purpose": "Haversine 距离、舰载机归属、高度分层"
    },
    "threat-assessment": {
      "module": "lib.analysis.threat_assessment",
      "rule_source": "rag/carrier_assessment_kb.md",
      "cli": "python -m lib.analysis.threat_assessment --input ... --output ...",
      "contract_ref": "见生成器第5轮 资产化模式输入契约",
      "purpose": "威胁 4 级分级"
    },
    "carrier-state": {
      "module": "lib.analysis.carrier_state",
      "rule_source": "rag/carrier_assessment_kb.md",
      "cli": "python -m lib.analysis.carrier_state --input ... --output ...",
      "contract_ref": "见生成器第5轮 资产化模式输入契约",
      "purpose": "状态判定（休整/维修/训练/警戒/演习/作战/补给）"
    }
  },
  "table_rules": [
    { "when": { "task": ["态势监控"] },
      "tables": ["standard.ais_ship_track", "standard.kantian_aircraft_carrier_status", "standard.carrier_attribution"] },
    { "when": { "task": ["规律挖掘"] },
      "tables": ["standard.ais_ship_track", "standard.event", "standard.alarm"] },
    { "when": { "task": ["综合评估"] },
      "tables": ["standard.ais_ship_track", "standard.carrier_attribution", "standard.carrier_strike_track",
                 "standard.kantian_aircraft_carrier_status", "standard.event", "standard.alarm",
                 "standard.person_carrier_relation"] },
    { "when": { "task": ["专项检测"], "keyword": ["AIS异常"] },
      "tables": ["standard.ais_ship_track", "standard.alarm", "standard.satellite_roll_call"] },
    { "when": { "task": ["专项检测"], "keyword": ["舰载机"] },
      "tables": ["standard.aircraft_ads-b_track", "standard.aircraft_attribution", "standard.aircraft_focus_targets"] },
    { "when": { "keyword": ["哈梅内伊", "Khamenei", "伊朗"], "source": "mysql_gf" },
      "tables": ["attribution_person", "key_area", "contact"] },
    { "when": { "keyword": ["击杀", "刺杀", "位置", "轨迹"], "source": "mysql_gf" },
      "tables": ["signaling", "traffic_camera_pictures", "communication"] },
    { "when": { "keyword": ["通联", "通信", "邮件", "关系"], "source": "mysql_gf" },
      "tables": ["communication", "email", "contact"] }
  ]
}
```

- [ ] **Step 2: 创建 `config/capability-matrix.schema.json`**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["version", "domain", "patterns", "table_rules"],
  "properties": {
    "version": { "type": "integer" },
    "domain": { "type": "string" },
    "patterns": {
      "type": "object",
      "additionalProperties": {
        "type": "object",
        "required": ["module", "rule_source", "cli", "contract_ref", "purpose"],
        "properties": {
          "module": { "type": "string" },
          "rule_source": { "type": "string" },
          "cli": { "type": "string" },
          "contract_ref": { "type": "string" },
          "purpose": { "type": "string" }
        }
      }
    },
    "table_rules": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["when", "tables"],
        "properties": {
          "when": { "type": "object" },
          "tables": { "type": "array", "minItems": 1, "items": { "type": "string" } }
        }
      }
    }
  },
  "additionalProperties": true
}
```

- [ ] **Step 3: 验证矩阵合法**

Run: `python3 -c "import json,jsonschema; m=json.load(open('config/capability-matrix.json')); s=json.load(open('config/capability-matrix.schema.json')); jsonschema.validate(m,s); print('MATRIX OK')"`
Expected: `MATRIX OK`

- [ ] **Step 4: 提交**

```bash
git add config/capability-matrix.json config/capability-matrix.schema.json
git commit -m "feat(capability): 领域能力矩阵 JSON（最小版：patterns 注册表 + 表路由）"
```

---

### Task 2: 矩阵一致性测试（交叉引用完整性）

**Files:**
- Create: `scripts/test_capability_matrix.py`
- Modify: `scripts/selftest.py`

- [ ] **Step 1: 写测试**

```python
"""test_capability_matrix.py — 能力矩阵交叉引用一致性测试
用法: python scripts/test_capability_matrix.py
校验:
  1. patterns[].module 对应 lib/analysis/ 模块文件存在
  2. patterns[].rule_source 文件存在于 rag/
  3. table_rules[].tables 的表名存在于 config/db_sources.json 对应源
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..'))

failures = []


def load(p):
    with open(p, encoding='utf-8') as f:
        return json.load(f)


def main():
    matrix = load(os.path.join(ROOT, 'config', 'capability-matrix.json'))
    cfg = load(os.path.join(ROOT, 'config', 'db_sources.json'))

    # 1. patterns module / rule_source 文件存在
    for pid, p in matrix.get('patterns', {}).items():
        mod = p['module'].replace('.', os.sep) + '.py'
        if not os.path.exists(os.path.join(ROOT, mod)):
            failures.append(f'patterns[{pid}].module 文件不存在: {mod}')
        if not os.path.exists(os.path.join(ROOT, p['rule_source'])):
            failures.append(f'patterns[{pid}].rule_source 文件不存在: {p["rule_source"]}')

    # 2. table_rules[].tables 存在（按 source 查对应源的表清单）
    for i, r in enumerate(matrix.get('table_rules', [])):
        source = r.get('when', {}).get('source', 'doris')
        tbls = cfg.get(source, {}).get('tables', {})
        for t in r.get('tables', []):
            bare = t.split('.')[-1]
            if bare not in tbls:
                failures.append(f'table_rules[{i}] 表不存在于 {source}: {t}')

    if failures:
        print('[FAIL] capability-matrix 一致性')
        for f in failures:
            print(f'  - {f}')
        sys.exit(1)
    print('OK capability-matrix: patterns={} table_rules={}'.format(
        len(matrix.get('patterns', {})), len(matrix.get('table_rules', []))))
    sys.exit(0)


if __name__ == '__main__':
    main()
```

- [ ] **Step 2: 运行确认通过**

Run: `python scripts/test_capability_matrix.py`
Expected: `OK capability-matrix: patterns=4 table_rules=8`

- [ ] **Step 3: 纳入 selftest**

在 `scripts/selftest.py` 的 `unit_tests` 列表追加：

```python
        os.path.join(HERE, 'test_capability_matrix.py'),
```

Run: `python scripts/selftest.py 2>&1 | tail -2`
Expected: `SELFTEST OK`

- [ ] **Step 4: 提交**

```bash
git add scripts/test_capability_matrix.py scripts/selftest.py
git commit -m "feat(capability): 矩阵交叉引用一致性测试（patterns/table_rules 引用不悬空）"
```

---

### Task 3: render_matrix.py（矩阵 JSON → markdown，供生成器 LLM 读）

**Files:**
- Create: `scripts/render_matrix.py`

- [ ] **Step 1: 写渲染脚本**

```python
"""render_matrix.py — capability-matrix.json → markdown（供生成器 LLM 读取）

生成器在生成期运行: python scripts/render_matrix.py
输出: temp/capability-matrix.md（生成器直接读这份 markdown 做决策）

理由: LLM 读 markdown 表格比读 JSON 稳；JSON 是校验/测试的规范源，
markdown 由 JSON 派生，两者永不漂移。
"""
import argparse
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..'))


def render(matrix):
    lines = []
    lines.append('# 领域能力矩阵（capability-matrix，机器生成勿手改）')
    lines.append(f'> domain: {matrix.get("domain")} | version: {matrix.get("version")}')
    lines.append('')

    patterns = matrix.get('patterns', {})
    if patterns:
        lines.append('## 资产化模式注册表')
        lines.append('| 模式 id | 规则源 | 调用方式 | 用途 | 契约 |')
        lines.append('|---------|--------|---------|------|------|')
        for pid, p in patterns.items():
            lines.append(f'| `{pid}` | `{p["rule_source"]}` | `{p["cli"]}` | {p["purpose"]} | {p.get("contract_ref","")} |')
        lines.append('')

    trules = matrix.get('table_rules', [])
    if trules:
        lines.append('## 数据库表匹配规则（特征 → 表）')
        lines.append('| 特征 | 注入的表 |')
        lines.append('|------|---------|')
        for r in trules:
            when = ' / '.join(f'{k}={v}' for k, v in r.get('when', {}).items())
            lines.append(f'| {when} | `{"` + `".join(r["tables"])}` |')
        lines.append('')

    return '\n'.join(lines)


def main():
    p = argparse.ArgumentParser(description='能力矩阵 JSON → markdown')
    p.add_argument('--matrix', default=os.path.join(ROOT, 'config', 'capability-matrix.json'))
    p.add_argument('--out', default=os.path.join(ROOT, 'temp', 'capability-matrix.md'))
    args = p.parse_args()

    with open(args.matrix, encoding='utf-8') as f:
        matrix = json.load(f)
    md = render(matrix)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        f.write(md)
    print(f'OK {args.out} ({len(md)} chars)')


if __name__ == '__main__':
    main()
```

- [ ] **Step 2: 运行验证输出**

Run: `python scripts/render_matrix.py && head -30 temp/capability-matrix.md`
Expected: 输出含"资产化模式注册表 / 数据库表匹配规则"两个 markdown 表格，内容与现有决策表一致

- [ ] **Step 3: 提交**

```bash
git add scripts/render_matrix.py
git commit -m "feat(capability): 矩阵 JSON → markdown 渲染脚本（生成器 LLM 读 markdown，JSON 为规范源）"
```

---

### Task 4: 生成器决策表替换为"读矩阵"

**Files:**
- Modify: `.opencode/agents/agent-generator.md`

- [ ] **Step 1: Boot Sequence 加矩阵 markdown 读取说明**

在 `agent-generator.md` 的 Boot Sequence（第18-26行）追加：

```markdown
- `bash python scripts/render_matrix.py` — 生成能力矩阵 markdown（决策依据，第5轮用）
```

- [ ] **Step 2: 第5轮"资产化模式注册表"替换为指针**

把 `:320-328` 的资产化模式表格整体替换为：

```markdown
**资产化模式注册表（单一来源）**：读取 `temp/capability-matrix.md`（由 `python scripts/render_matrix.py` 生成）的「资产化模式注册表」段落，按模式 id 取 `module/cli/rule_source/purpose` 注入生成的 agent。

生成时：命中资产化模式 → 注入模块 id + CLI 契约 **+ 输入契约要点**（见下方"资产化模式输入契约"段落，写入 agent 的"专用分析模式"段落）；未资产化模式 → 保持提示词描述。同一模式被多画像引用即走同一模块（闭环验证）。
```

- [ ] **Step 3: 第5轮"数据库表匹配规则"替换为指针**

把 `:349-366` 的 Doris/MySQL 表匹配表格整体替换为：

```markdown
**数据库表匹配规则（单一来源）**：读取 `temp/capability-matrix.md` 的「数据库表匹配规则」段落，按 `when` 特征匹配注入对应表。Doris 表匹配特征（态势监控/规律挖掘/综合评估/专项检测）与 MySQL 关键词路由（哈梅内伊/击杀/通联/车队等）均以矩阵为准。
```

> 注：matrix 的 table_rules 已完整承载原两张表的内容，此处仅留指针。

- [ ] **Step 4: 验证——生成器读矩阵后决策信息不缺失**

Run: `python scripts/render_matrix.py && python -c "
import re
md = open('temp/capability-matrix.md', encoding='utf-8').read()
for key in ['ais-anomaly','spatial-association','threat-assessment','carrier-state','ais_ship_track','attribution_person','哈梅内伊']:
    assert key in md, f'缺失: {key}'
print('矩阵 markdown 覆盖全部关键决策项')
"`
Expected: `矩阵 markdown 覆盖全部关键决策项`

- [ ] **Step 5: 提交**

```bash
git add .opencode/agents/agent-generator.md
git commit -m "feat(capability): 生成器第5轮决策表改为读矩阵 markdown（资产化模式+表路由单一来源）"
```

---

### Task 5: 文档同步 + 全量回归

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README 加"领域决策矩阵"说明**（快速参考表后追加）

```markdown
| 领域决策矩阵 | 生成器第5轮决策（资产化模式/表路由）由 `config/capability-matrix.json` 承载，运行 `python scripts/render_matrix.py` 生成 markdown 供生成器读取；一致性校验 `python scripts/test_capability_matrix.py` |
```

- [ ] **Step 2: 全量回归**

Run: `python scripts/selftest.py 2>&1 | tail -2`
Expected: `SELFTEST OK`

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "docs: 领域决策矩阵说明（capability-matrix.json + render_matrix + 一致性校验）"
```

---

## 五、Self-Review（计划自检）

**1. Spec 覆盖：**
- ✅ 矩阵本体（最小版：patterns + table_rules）→ Task 1
- ✅ 一致性测试 → Task 2
- ✅ markdown 渲染给 LLM → Task 3
- ✅ 生成器决策表替换为读矩阵 → Task 4
- ✅ 文档 → Task 5
- ❌ 已裁剪：契约迁移（可选）、x-generation、语义校验器、冻结语料、迁移验证

**2. 占位符扫描：** 无 TBD/TODO；所有函数（`render`/`main`/`load`/`test_capability_matrix`）在定义处完整。

**3. 类型一致性：**
- `matrix.table_rules[].tables` 裸表名/qualified 表名在 test 用 `split('.')[-1]` 归一化 ✅
- `matrix.patterns[].module` 用点分（`lib.analysis.ais_anomaly`），test 用 `replace('.', os.sep)` 转路径 ✅
- 生成器指针（"读取 temp/capability-matrix.md 的「资产化模式注册表」段落"）与 render_matrix 输出的段落标题一致 ✅
- selftest 新增 `test_capability_matrix.py` 到 unit_tests 列表 ✅
