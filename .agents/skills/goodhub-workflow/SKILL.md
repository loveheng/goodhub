---
description: goodhub（AI 宿主 App，Flutter/MCP 客户端）工作流事实源：构建/测试/运行命令唯一出处、环境硬约束、规范数据维护触发器。构建报错、跑测试、换机器前先读，命令勿凭记忆写；工具链踩坑查 context/lessons.md，接缝速查与落点索引查 docs/project/index.md（goodhub-index skill）。
---

# goodhub · AI 宿主 App 工作流事实源

> 项目一句话：**goodhub**——AI 宿主 App（master / 交互式 MCP 客户端），认领 goodshare 的远程 AI 任务（claim→推理→apply）。接缝契约 SSOT = goodshare 仓 `docs/design/ai-app-split.md`（跨仓只读引用，不复制正文）。

## 定位边界（三件套分工，防双源）

| 需要什么 | 查哪里 |
|---|---|
| **写码规则**：代码放哪个域 / 分层依赖方向 / 新功能落点决策 / 质量门禁 | `docs/project/coding-standards.md`（§1.0 分层矩阵 + 机械护栏 / §1.5 落点决策表） |
| **改前定位**：某功能的代码落点 / 文档落点 / 架构债与违例登记 | `docs/project/index.md`（数据；登记规约 = goodhub-index skill） |
| **命令与环境**：本 skill | 构建/测试/运行/发布命令、环境硬约束（工具链踩坑规则正文查 `context/lessons.md`） |

lib/ 的分层结构与 11 域清单**不在本表登记**——见 `docs/project/coding-standards.md` §1.0（矩阵与护栏）与 `docs/project/index.md`（域内文件与功能落点）。现行 epic 与过程态查 `context/CURRENT` / `context/epics/`，本 skill 不登记。

## 规范数据维护触发器（发现即维护，不当旁观者）

**判据三问**（决定要不要写）：① 是架构分流/准入规则？② 变更频率是月/季度或重大架构变更级？③ 缺了它 CI 扫描或 Review 是否失去判定依据？——三问命中即按下表维护；日常需求流水账禁写。

**本触发器只管 `coding-standards.md`**：index.md 数据与代码枚举各有专属归属（见表内路由列），本 skill 不越界维护。

| 工作中发现的信号 | standards 维护（本 skill 触发） | 同轮路由（非本 skill 维护） |
|---|---|---|
| **新技术形态**（新运行时/新传输/新存储介质等） | §1.5 落点决策表**追加一行**（落点域 + 依赖边界）；涉机械护栏的同步 §1.0 护栏表 | — |
| **新增 `lib/` 一级域** | §1.0 分层矩阵登记（角色 + 允许出向） | `kGoodhubDomains` 代码枚举（test/architecture）+ index.md 落点（**goodhub-index skill**） |
| **新特权工具 / 对外暴露工具** | §5.7 自查清单过一遍；§6.2 主体矩阵**原则与登记要求**核对 | 主体矩阵**枚举值**下沉 `permission_gateway` / `gateway_security` 代码表（改代码时执行） |
| **跨域 import 命中红灯** | 按 §8.2 处置：先改结构（端口注入 / 类型下沉 core）再写 import；确属历史遗留走白名单纪律（只减不增） | 债表登记与清零记账（**goodhub-index skill** → index.md） |
| **内核新增 / 搬迁** | §8.4 检查清单过一遍（生命周期层级/纯 Dart/注入位/命名登记） | index.md「内核登记表」更新（**goodhub-index skill**） |

**维护收尾两件**（standards 侧，同轮完成）：① 刷新 `updated` 字段；② 检查机械镜像（dependency_rules_test / arch-guard）是否需同步——规则正文在文档，代码只镜像不立法。

## 环境硬约束

- Flutter 在 `~/flutter`（tarball 安装，不在 PATH），Android SDK 在 `~/android-sdk`；**无可用模拟器，UI 验证唯一途径 = 真机侧载**
- goodshare MCP 联调走局域网直连 `http://<手机IP>:8765/mcp`（本机沙箱 adb reverse 无法绑定端口）
- 单测输出里的 `[DEGRADE] ... MissingPluginException(goodhub/binder_mcp)` 是纯 Dart 环境无 MethodChannel 实现的**预期降级**，非失败，不影响测试交付
- 工具链实测踩坑的**数据**查 `context/lessons.md`（android-ops / 工具链 / mcp 传输等节），本 skill 不复制（防双源；维护协议见下节）

## 经验教训维护协议（context/lessons.md）

**数据住 `context/lessons.md`，协议住本 skill**（防双源）：本文件只定义什么时候记、按什么格式记、什么时候清零，不承载任何经验正文。

### 使用时机（三种，缺一即退化为重复排查）

| 时机 | 场景 | 动作 |
|---|---|---|
| **写前检索** | 动高风险模块前（SSE 传输 / 平台通道 / Widget 滚动测试 / 覆装打包…） | 先查对应模块节，提取已知反模式，在写代码第一分钟避开暗坑 |
| **排障检索** | 构建 / 测试 / 真机联调报错时 | 取报错堆栈关键字（如 `INSTALL_FAILED_VERSION_DOWNGRADE`）在 lessons.md 全字匹配，先读解法再动手，禁从零排查 |
| **升维销项** | 坑解决后 | 把解法挂上回归钉子进「回归」段——只写文档不挂钉，换人照踩 |

### 录入准则（三不记 + 录入门槛）

- **不记**临时网络/环境偶发抖动（连接超时、换个镜像站即好）——无复现价值
- **不记**情绪与破案流水账——人名、时间、排查历程一律抹除，只留技术因果
- **不记**无法落地的泛泛建议（"注意并发安全"、"多写单测"类）
- **录入门槛**：排查耗时 >15min 的确定性故障（机理清楚、可复现、有复现价值），**同轮沉淀**，不当旁观者

### 录入格式（四段式 · 单行落盘 · 显式标签）

新条目在 `context/lessons.md` 底部 `## 待归并（<模块>）` 区追加，**一段一行、四段显式标签**，禁止无标签长文本：

```
- [<模块>] 现象: <报错关键字/堆栈特征，确保 grep 精准命中> | 根因: <语言/运行时/平台机制本质> | 处置: <解法/命令/代码修改点> (Ref: <epic>)
```

- 四段 = **现象 / 根因 / 处置 / 回归**；Inbox 快速落盘允许缺「回归」，**归并准入时四段齐备**（门禁见下）
- 归并后移入对应 `## <模块>` 节并去掉 `[<模块>]` 前缀，补上回归段：`- 现象: ... | 根因: ... | 处置: ... | 回归: ... (Ref: <epic>)`
- 正文区行禁 `- [` 开头（该前缀专属底部追加区）；存量 `➔` / `——` 旧格式条目被 touch 或归并时按新格式归一，不专门立项迁移

### 闭环清零纪律（Inbox → 正文）

- 新坑先落 Inbox（`## 待归并` 区），**禁直接插正文**——正文只收已审条目
- **Epic 收官 / 版本发版前必须清零 Inbox**：归入模块节、消除完全重复项、为已有回归钉子的条目精简篇幅
- **归并门禁**：缺「回归」段的条目，要么补回归钉子路径（如 `test/gateway/gateway_server_test.dart`「SSE 进度帧即达」——撤修复即红），要么写明机械规则编号（arch-guard R#）或明确代码约束，否则不得进正文
- 归并后刷新文件 frontmatter 的 `total-merged` 与 `last-merge` 字段
- lessons.md 是**全局账**（frontmatter `epic: global`）：跨 epic 复用，只归并不清空

## 研发闭环命令（唯一出处）

所有命令显式携带 SDK 环境变量：

```bash
export PATH="$HOME/flutter/bin:$HOME/android-sdk/platform-tools:$PATH" ANDROID_HOME="$HOME/android-sdk"   # ANDROID_HOME=当前标准；ANDROID_SDK_ROOT 为 AGP 已弃用旧名，禁设（防路径双源）；Gradle 侧另由 android/local.properties 的 sdk.dir 钉住
flutter pub get                 # 依赖拉取（改 pubspec.yaml 后）
```

> 命令双入口：项目工具池 `toolbox run <工具>`（canonical，别名见注释）与裸脚本 `scripts/agent-tools/<工具>.sh` 等价；无 toolbox 环境用裸脚本。

### 1. 提交前质检流水线（PR 交付红线，按耗时从小到大）

任一步失败**禁止提交**；禁止 `--no-verify` 绕过门禁：

```bash
toolbox run arch-guard            # ag   # ① 架构红线扫描（秒级：UI 禁 dart:io/平台分支/MethodChannel + 依赖方向）
flutter analyze                   #      # ② 静态检查 → 0 issue 为交付线
flutter test --timeout 180s       #      # ③ 单测 → 全绿为交付线（⚠️ 务必带 --timeout，widget 测试默认 10 分钟超时）
```

- lib/ 与 docs/ 混改时用聚合门禁按改动范围分派：`toolbox run pre-commit-gate`（pcg；默认秒级 arch-guard，`ARCH_GATE_FULL=1` 追加 flutter test 版依赖护栏，docs/ 改动自动跑 docs-lint）；提交信息过 Conventional Commits 校验：`toolbox run commit-msg-gate`
- ① 命中红灯 = 按 `docs/project/coding-standards.md` §8.2 修结构，**不得申请加白名单**（只减不增）

### 2. 本地运行与真机联调（无模拟器）

```bash
flutter devices                          # 查看在线真机 ID
flutter run -d <DEVICE_ID> --debug       # 挂载真机联调
adb logcat -s flutter:*                  # 过滤 Flutter 运行时日志（黑屏取证三件套查 lessons.md android-ops 节）
toolbox run build-apk --install          # apk  # 构建 debug 包并 adb 安装（内置设备已装版本防降级守卫）
```

> 装机纪律：`integration_test` 跑完后 `app-debug.apk` 会被测试壳入口覆盖，装机验证前必须先 `flutter build apk --debug` 重建正式入口（根因查 lessons.md android-ops 节）。

### 3. 打包与发布（Release Workflow）

发布链 = **升版本 → 预检 → dry-run → 发布**（release-r2 直接读 `pubspec.yaml` 的 version 行，必须先 bump）：

```bash
toolbox run bump-version --patch   # bump # ① 升版本：--patch/--minor/--major/--build 或 --set x.y.z+w
                                    #     自动探测设备已装 versionCode 防降级（拆分包约定 = pub build 号 + 2000）
toolbox run release-r2 --json      # r2   # ② 环境预检（真身存在/.env R2 凭证/node/flutter 就绪性）
toolbox run release-r2 -n          #      # ③ dry-run 预览全链步骤，不构建不上传
toolbox run release-r2 --commit    #      # ④ 正式发布：arm64 release APK → sha256 → 清单 → 上传 R2
                                    #     --commit 把 updates/goodhub-update.json 提交进仓库追溯（APK 本体被 .gitignore 忽略）
```

- 本地调试包：`flutter build apk --debug`（或 `toolbox run build-apk`）
- 真身 = `scripts/release-r2.sh`；R2 凭证配置见仓库根 `.env`（参考 `.env.example`）；Flutter 3.47.5 registrant 坑已由脚本内建 patch（细节查 lessons.md 工具链节）

### 4. 构建异常自救（缓存重置急救包）

```bash
flutter clean && flutter pub get          # 基础缓存重置
cd android && ./gradlew clean && cd ..    # 深度原生构建缓存清理
toolbox run build-apk --fresh             # gradle 锁被占（Timeout waiting to lock）：先停 daemon 再构建
```
