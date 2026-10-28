---
dev-loop: memory
format: v1
epic: arch-review-2026-10
kind: temporary-review
---

# arch-review-2026-10 · 扫描问题定性：架构缺陷 vs 规范成熟度缺陷

> 临时 epic（2026-10-28 立）：承接「大型功能开工前架构核查」扫出的 10 项，做**三分定性**——哪些必须改代码（架构设计本身），哪些是 `docs/project/coding-standards.md` 体系**表达力不足**导致的伪执行，哪些是**文档维护一致性**问题。

## 挂载

- 排查对象：本仓 `lib/`（160 文件 / 37036 行）、`docs/`（36 篇）、`context/`（90 篇）
- 主要 doc 面：`docs/project/coding-standards.md`、`docs/project/index.md`、`docs/product/architecture.md`、`docs/product/requirements.md`
- 证据面：静态扫描（本机无 Flutter SDK，`analyze` / `flutter test` **未实跑**——见结论 §5 局限）

## 结论 1 · 三分类判据（先立法，后分类）

不用「架构问题 / 文档问题」二分——会漏掉最重要的一类。按**处置手段**分三类：

| 类 | 定义 | 收口方式 | 判据样例 |
|---|---|---|---|
| **A · 架构设计缺陷** | 代码的结构事实违背设计意图；文档改对了也消不掉 | 改代码（补抽象 / 收 owner / 合并路径） | 三套并行装配、消费点就地构造、455 行单体方法 |
| **B · 规范表达力缺陷** | 规则**写成口号、无法机械判定** → 退化为靠人自觉 → 必然漂移 | 改写为可判定谓词 + 上机控 | 「勿复制第二套」「CPU 密集须离主线程」「单一 owner」均无阈值与判定式 |
| **C · 规范维护一致性缺陷** | 规则本身没错，但多处副本互相打架 / 历史口径未退役 / 数据账与规则账错位 | 修文档 + 扩 drift 登记 + 收敛单一落点 | §5.6 与 §1.1 互斥、白名单表 ≠ 分层矩阵 |

## 结论 2 · 10 项扫描问题定性总表

| # | 问题 | 定性 | 主证 |
|---|---|---|---|
| P0-1 | 共享内核在消费点就地构造（8+ 类 store） | **A 为主 + B 加成** | `app/service_directory.dart` 仅 3 个构件；`settings_page.dart:225`、`cow_section.dart:91`、`prompts_overview_section.dart:139,142`、`user_prompts_section.dart:87`、`chat_page.dart:868` |
| P0-2 | Run 装配三路并行（ui / gateway / task + debug 红线不并回） | **纯 A** | `McpRuntime().assemble` 全仓仅 `chat_page.dart:885` 一处调用；`gateway_controller.dart:367,382` 自组装 |
| P0-3 | 窗口层内联 Run 编排，455 行单体方法 + 1568 行渲染件 | **A 为主 + B 加成** | `chat_page.dart:740–1195`、`_resetSessionState:257`；§8.3 软红线无 CI 镜像 |
| P0-4 | SSOT 自身互斥（`x-mcp-export-to-shared` / `$/cancelRequest`） | **纯 C** | `coding-standards.md` §1.1 规则 7 vs §5.6；`requirements.md` F1.13 vs §2.3 |
| P1-5 | 原子写第二实现 ×5（绕过 `SequentialFileWriter`） | **A 为主 + B 加成** | `cow_sync.dart:108`、`user_prompt_store.dart:166`、`conversation_archive.dart:86`、`ref_store.dart:230`、`resource_store.dart:293` |
| P1-6 | 装配容器 / 发送链路缺保护网（`app` 域 1 测试 / 3 文件） | **纯 A**（质量工程） | 域/测试比：`app` 1/3、`core` 4/15、`ui` 27/48 |
| P1-7 | CPU 卸载纪律覆盖不足（`Isolate.run` 仅 2 处实调用） | **A 为主 + B 加成**（「重」无阈值） | `pii_fence.dart:85`（唯一带 3s 看门狗的范本）、`resource_store.dart:225` |
| P1-8 | §6.2「主体 × 工具矩阵」无代码落点 | **A + C 交织** | 网关仅 Bearer 常量时间比较（`gateway_server.dart:149,153`）；矩阵无可在仓 Bacterial 到的一级抽象 |
| P2-9 | 白名单表（`index.md`）≠ 分层矩阵（§1.0） | **纯 C** | `task_ledger_section.dart:13`→`task`、`resource_center_section.dart:25`→`resources` 已入白名单，矩阵未授权该出向 |
| P2-10 | 释放卫生无统一清单（21 处 Timer / 9 处 `.listen(` / 8 处 StreamSubscription） | **B 为主** | §7 只有「范式 + 基准件」，无常设机械清单 |

**计数**：纯 A ≈ 3 项；A 为主带 B 加成 ≈ 4 项；A/C 交织 ≈ 1 项；纯 C ≈ 2 项；B 为主 ≈ 1 项。
即 **约 7 项需靠改代码收口，其中 4 项的根因进一步滑向「规则不可判定」**。

## 结论 3 · 根因四条（按杠杆排序）

- **RC1 装配面缺「能力 profile」抽象** → UI / 网关 / 任务管道各拼各的（P0-2）。不引入 profile，任何新能力都要写三份接线，且三份必然不等价。
- **RC2 应用级 owner 缺注册中心** → `ServiceDirectory` 只收敛 3 件，其余退化为「谁用谁 new」（P0-1）；叠加「全量 cache 写回」形态，即使用上看得见的串行队列也消不掉陈旧内存态覆盖。
- **RC3 规则不可判定 → 退化为人治** → §1.4 白名单自认「文档态基线，机械镜像待立项」、§8.3 软红线只核对「有没有登记」而不核对行为、§3.2「勿复制第二套」无可检测形态、§3.1「CPU 密集」无阈值。**本次所有偏差全部落在这些条款上**，没有一条落在已有机械镜像（R1~R9 / dependency_rules / drift）的条款上——这条对照是本轮最有价值的证据。
- **RC4 文档 SSOT 链过长且退役不全局** → `window-kernel-split.md` §5 → `coding-standards.md` → 两套脚本 + `index.md` 数据账；同一概念（工具可见性）散在 **7 篇 docs + 6 处 lib**；术语退役只 cleanup 了 `lib/gateway` 一处，docs 域未登记进 drift → 扫不到（P0-4 的成因）。

## 结论 4 · 「规范成熟度」体检清单（可逐项验收）

1. **规则无可判定语义**：大量祈使句（「严禁 / 必须 / 收敛」）未给出对应机械谓词，也没有「怎么算违规」的样本 → 不可判定。
2. **规则与其数据账分离且不同步**：规则在 standards，数据在 `index.md`；现已出现 15 行 `index.md` 携带日期与过程叙事，违背其自我声明的「日期叙事 / 即时行数不入表」。
3. **同一事实三处登记**（内核登记表 / 直连白名单 / 超标清单），缺 single-writer → 必有一处漏改。
4. **软约束没有 compromised 机制**：800 行软红线、白名单「只减不增」都只由人评审把关，CI 未覆盖。
5. **历史口径退役不彻底**：退役靠人记得改，而不是 `BANNED` 行驱动；docs 域基本未进 drift 扫描面。
6. **例外与豁免无到期机制**：「红线：不并回 `assemble`」「白名单机械镜像待立项」等词条无限期悬挂。

## 结论 5 · 局限与诚实边界

- 本机无 Flutter SDK：`flutter analyze` / 全量 `flutter test` **未实跑**；分层与平台类结论基于静态 grep（`core` 零出向、`mcp` 无反向边、`gateway→coordinator` 恰为白名单 9 件、`ui` 无 `dart:io` / `Platform.isX` / `MethodChannel`、空 catch = 0），这些是可复现事实，但不能替代 CI 绿灯。
- 「文档散乱度 / 表达力」属散文级判断，机械不可靠；按 §8.2「诚实边界」归入人判，不做扫描冒充门禁。

## 断点

- [断点] 已完结（2026-10-28 ::done）：三分定性 + 施工稿 S0–S6 全交付（1300 全绿，见 done.md）+ #27 裁决归档；本目录归档 context/archive/arch-review-2026-10/；恢复流程永不再读本文件。

## 副作用账

- UNCERTAIN: 「8+ 类 store 在消费点构造」为静态 grep 结论；**运行期是否真的同时存在两个实例**尚未取证（需真机 / 集成用例）
- UNCERTAIN: `grep -cE "拟|待立项|待接|待补|建议" coding-standards.md` = 3，仅反映有限词面，结论 4-6 为抽样人判，非全量统计
