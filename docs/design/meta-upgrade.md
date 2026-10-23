---
status: draft
updated: 2026-10-23
---

# 元体系升舱：契约面漂移机械护栏（drift-guard）

> 本文是 goodhub 侧「契约面漂移」防护的设计 SSOT：引擎落全局 toolbox 池（多项目共用），registry 数据留本仓，CI 门禁走 Dart 镜像。背景与准入判定见 `context/pending-confirm.md` meta-upgrade 节（U1~U8）。

## 结论（已拍板）

- **三层分离**：① 引擎 `~/.agents/toolbox/scripts/drift-guard.sh`（零项目知识，6 个同框架项目共用一份）② registry 数据 `<repo>/scripts/agent-tools/drift-registry.txt`（随代码同批版本化）③ CI 门禁 `test/architecture/drift_rules_test.dart`（Dart 镜像读同一 registry——CI 无 toolbox，对齐 `dependency_rules_test.dart` 先例）。
- **三类可机械判定**（token 级 / 字面量级 / 行数级）：BANNED 退役词条、CONST 单源常量、OVERSIZE 超标登记核对。
- **诚实边界**：docs 与代码的「集合描述一致性」（如三档 vs 四档的散文表述）机械不可靠，不做扫描，归 `::audit` 人判。
- **数据与规则分离**：新规则只加 registry 数据行，不改引擎代码——规则膨胀从「改代码 + 抄断言」降为「加一行数据」。

## registry 格式

```
# 注释行（# 开头）与空行忽略
BANNED|<token>|<scope,...>|<理由>
CONST|<常量名>|<字面值>|<声明文件>[,<镜像文件>...]
OVERSIZE|<行数上限>|<登记清单文件>
```

- scope = 目录（递归 .dart/.md）或文件路径；`.dart` 自动剥整行注释（`//` / `*` 开头），任意文件行内 `drift:keep` 显式豁免（历史留档显式豁免，禁静默）。
- BANNED 的 token 必须带足够上下文防误伤（如 `strategy=` 带等号，不误伤兼容别名代码 `query['strategy']`）。
- CONST 只收非平凡字面量（`__` / `host` 这类遍地出现的值不登记——同步断言已在单测）；**搜索面 = lib/ 生产代码**（test/ 不扫：测试字面量是有意的独立钉子，常量变更经测试失败自曝；docs 散文提及不判）。
- OVERSIZE 按 lib/ 前缀剥离形态核对（`ui/chat_page.dart`）；清单内件的行数基线跟踪留 `git diff --numstat` 人判，机械只堵「新增超标件未登记」。
- **实现要点（踩坑修正）**：所有 grep 必须带 `-H`——GNU grep 单文件操作数时 `-n` 只输出 `lineno:code`（多文件/目录才输出文件名），解析按多文件形态取值会把行号当路径，注释过滤随之失效。

## 跨项目传播（框架级落法）

| 层 | 位置 | 覆盖 |
|---|---|---|
| 引擎 | `~/.agents/toolbox/scripts/drift-guard.sh`（全局 toolbox 池，`toolbox run drift-guard`） | 6 个同框架项目共用一份 |
| 数据 | 各仓 `scripts/agent-tools/drift-registry.txt` | 随代码同批版本化 |
| CI 镜像 | 各仓 `test/architecture/drift_rules_test.dart` | 读同一 registry；CI 无 toolbox 故走镜像（随既有 `flutter test` 全量，无需加 CI 步骤） |
| 新项目 | `goodTemplate` 脚手架加「registry 骨架 + Dart 镜像 + pre-commit-gate 分派块」 | `init-app.sh` 起底即继承 |

存量项目按需采纳：各仓 registry 从空/小起步合法——引擎与纪律是共享资产，数据随各自漂移事件增长。

> **goodTemplate 落地移交件**（跨仓写入由用户执行）：`context/epics/meta-upgrade/handoff-goodtemplate.md` —— 含目标仓现状勘察结论、registry 骨架全文、Dart 镜像 cp 命令、pcg 分派块全文与三处同步行、校验命令 5 条、验收标准与回滚路径。

## 维护纪律（同轮登记）

契约面变更（工具改名 / 词表单轴化 / 新单源常量 / 新超标件）须**同轮**更新 registry，缺登记即被 drift-guard 拦下。规则 SSOT = `docs/project/coding-standards.md` §8（门禁矩阵 + §8.3 超标登记核对 + 维护触发器）。
