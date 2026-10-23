# 移交件 · goodTemplate 接入 drift-guard（契约面漂移机械护栏）

> 产出方：goodhub（meta-upgrade epic，2026-10-23）｜执行方：**用户**（跨仓只读纪律：AI 产移交件，目标仓写入由用户执行）
> 引擎已在全局池就位：`~/.agents/toolbox/scripts/drift-guard.sh`（`toolbox run drift-guard`），**无需**往目标仓复制引擎。

## 0. 目标仓现状勘察结论（2026-10-23 只读）

| 项 | 现状 | 对本次移交的意义 |
|---|---|---|
| `lib/` | 有（Flutter app 骨架） | Dart 镜像扫 `lib/` 可直接用 |
| `test/` | 只有 `smoke_test.dart` | 需新建 `test/architecture/` 目录 |
| `scripts/agent-tools/` | 有 pcg / arch-guard 等 9 个脚本 | pcg 需加分派块；**registry 是数据文件**，放此目录 |
| `docs/` | **无** | OVERSIZE 登记项暂不启用（无超标清单可指，见步骤 1 注） |
| `.agents/` | **无** | 跳过「standards §8.2 行 + workflow skill 命令面」两条登记（模板无该装置） |
| CI | 无 `.github/workflows/` | **无需改 CI**；镜像随既有 `flutter test` 全量自动进 CI（将来加 CI 时亦然） |
| pcg 既有传统 | 其 `docs-lint` 已走**全局池**（`toolbox run docs-lint`） | 与本方案「全局引擎 + 本仓数据」同构——drift-guard 落法顺既有传统，无新增模式 |
| `init-app.sh` | `toolbox init --project` 只建项目池目录 + README 占位，**不复制全局脚本** | 全局引擎不会被复制进新项目 → 「引擎不复制」成立；registry 骨架随模板目录走，新项目自动继承 |

## 1. 新建 registry 骨架（数据文件 · 落 `scripts/agent-tools/drift-registry.txt`）

```bash
cd /home/zzh/app/goodTemplate
cat > scripts/agent-tools/drift-registry.txt <<'REGEOF'
# drift-registry.txt — 契约面漂移登记（drift-guard 数据源）
#
# 维护纪律：契约面变更——对外工具改名 / 词表单轴化 / 新单源常量 / 新超标件——
# 须**同轮**登记对应行，缺登记即被 drift-guard 拦下。
# 格式：BANNED|token|scopes|reason ／ CONST|name|literal|declaring[,mirrors] ／ OVERSIZE|limit|listfile
# scope = 目录（递归 .dart/.md）或文件；.dart 整行注释不判；任意行内 drift:keep 显式豁免。
# 引擎：toolbox run drift-guard（全局池，零项目知识）；CI 镜像：test/architecture/drift_rules_test.dart
#
# —— 本项目待登记（按实际漂移事件逐条补，格式照抄上面的注释示例）——
# BANNED|<退役 token>|<lib/gateway,docs 等作用域>|<理由>
# CONST|<常量名>|<字面值>|<声明文件>[,<镜像文件>...]
# OVERSIZE|<行数上限>|<登记清单文件>   ← 须指向真实存在的清单文件；本仓暂无 docs/project/index.md，故暂不启用

REGEOF
```

> 注：`OVERSIZE` 行**暂不启用**——模板无 `docs/project/index.md`（超标清单落点），引擎与镜像对「清单文件不存在」均判红。待项目长出超标清单后再补这一行。

## 2. 新建 Dart 镜像（CI 侧 · 落 `test/architecture/drift_rules_test.dart`）

镜像零项目知识（只读 registry + 扫 `lib/`），**原样复制**即可：

```bash
cd /home/zzh/app/goodTemplate
mkdir -p test/architecture
cp /home/zzh/app/goodhub/test/architecture/drift_rules_test.dart test/architecture/
```

- 复制后唯一建议改动：文件头注释里的项目语境（当前写的是 goodhub 侧来源说明），**不影响行为**。
- 镜像与引擎**同读同一 registry**，规则数据零重复；两侧口径（token 固定串匹配 / .dart 整行注释剔除 / drift:keep 豁免 / CONST 只扫 lib/ / OVERSIZE 按 lib/ 前缀剥离形态核对）逐条对齐。

## 3. pre-commit-gate 分派块（落 `scripts/agent-tools/pre-commit-gate.sh`）

在既有 `ANDROID`/docs-lint 分派块**之后**、`if [ "$rc" -eq 0 ]` 判定**之前**插入：

```sh
  # drift-guard：契约面漂移（退役词表 / 单源常量 / 超标登记）。引擎在**全局**
  # toolbox 池（跨项目共用一份），数据在本仓 scripts/agent-tools/drift-registry.txt。
  # toolbox 缺失 → fail-open + 明示兜底路径（CI 侧 Dart 镜像仍把关）。
  if [ "$LIB_TOUCHED" -gt 0 ] || [ "$DOC_TOUCHED" -gt 0 ]; then
    echo "==> pre-commit-gate: 有 lib/docs 改动，跑 drift-guard（契约面漂移）"
    if command -v toolbox >/dev/null 2>&1; then
      toolbox run drift-guard --root "$ROOT" || { rc=1; agg=$((agg+1)); }
    else
      echo "⚠ toolbox 不可用，drift-guard 跳过（fail-open：CI 侧 test/architecture/drift_rules_test.dart 仍把关）"
    fi
  fi
```

同步两处说明行（保持头部元数据与 usage 与实际行为一致）：

| 位置 | 改动 |
|---|---|
| 头部 `# summary:` 行 | 追加「、drift-guard（lib/ 或 docs/ 改动）」 |
| 头部 `# after:` 行 | 追加 `,drift-guard` |
| usage 正文 | 追加一句：「涉及 lib/ 或 docs/ 跑 drift-guard（契约面漂移：退役词表 / 单源常量 / 超标登记，数据 = scripts/agent-tools/drift-registry.txt，引擎在全局 toolbox 池）」 |

## 4. 校验命令（执行方逐条跑）

```bash
cd /home/zzh/app/goodTemplate

# ① 引擎自检（金丝雀：坏样本取自真实历史现场）→ 期望 PASS
toolbox run drift-guard --self-test

# ② 项目级扫描 → 期望「OK: 契约面漂移扫描通过」
toolbox run drift-guard --root /home/zzh/app/goodTemplate

# ③ CI 镜像（flutter test 侧）→ 期望 All tests passed
flutter test test/architecture/drift_rules_test.dart

# ④ pcg 自检 → 期望 self-test PASS
bash scripts/agent-tools/pre-commit-gate.sh --self-test

# ⑤ 变异探针（证明真能咬人，验完还原）
printf 'const x = 1;\n' > /tmp/probe.dart
sed -i "s|const x = 1;|const x = '?strategy=full';|" /tmp/probe.dart
cp /tmp/probe.dart lib/probe_tmp.dart
toolbox run drift-guard --root /home/zzh/app/goodTemplate | head -4   # 期望 FAIL（抓到 lib/probe_tmp.dart）
rm -f lib/probe_tmp.dart
toolbox run drift-guard --root /home/zzh/app/goodTemplate          # 期望 OK（还原后）
```

> ⑤ 需要 registry 里已启用对应 `BANNED` 行才红；模板骨架阶段 BANNED 全为注释态，则该探针应放**goodhub 仓**跑（那里已启用 `?strategy=` 登记项），或先在模板 registry 里启用一条示例 BANNED 行再探。

## 5. 可选登记（仅当模板后续补上 AI 协作装置时）

模板现无 `docs/` 与 `.agents/`；将来若补齐，再加这两条（goodhub 已落，可照抄）：

- `docs/project/coding-standards.md` §8.2 门禁矩阵：加「契约面漂移」两行（flutter test 版镜像 + 全局 `toolbox run drift-guard`）与 §8.3「超标登记的机械核对」一句
- `.agents/skills/goodhub-workflow/SKILL.md`：质检流水线加 `toolbox run drift-guard # dg`（排在 arch-guard 之后、analyze 之前）+ 维护触发器加「契约面变更 → registry 同轮登记」一行

## 6. 验收标准

- [ ] `toolbox run drift-guard --self-test` → PASS
- [ ] `toolbox run drift-guard --root <goodTemplate>` → OK
- [ ] `flutter test test/architecture/drift_rules_test.dart` → 全绿（镜像读到 registry；registry 无规则时亦绿）
- [ ] `bash scripts/agent-tools/pre-commit-gate.sh --self-test` → PASS
- [ ] 手动跑一次 pcg，确认输出含「跑 drift-guard（契约面漂移）」且 registry 缺失时只提示不拦

## 7. 回滚

- 删 `scripts/agent-tools/drift-registry.txt` + `test/architecture/drift_rules_test.dart` + pcg 分派块 → 即刻回到接入前行为（引擎在全局池，删除项目侧文件不影响其他项目）
- 引擎本身可留用（全局资产，不影响任何未接入项目——registry 缺失即放行）

## 附：goodhub 首版 registry（真实内容，供对照格式）

见 `/home/zzh/app/goodhub/scripts/agent-tools/drift-registry.txt`（6 条：退役词条 ×3 + 单源常量 ×2 + 超标登记 ×1）。
