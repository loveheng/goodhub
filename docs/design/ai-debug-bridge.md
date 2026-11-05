---
status: draft
updated: 2026-11-05
---

# AI 真机调试桥（结构化观测替代截图猜测）

> 背景：真机调试靠「截图 → 视觉定位 → 坐标点击 → 再截图」逐轮推进，一轮数秒且受分辨率、显示缩放、IME 影响。`context/lessons.md` android-ops 实证 `uiautomator dump` 对 Flutter 页语义树残缺、缩放图坐标必错位、Gboard 下文本输入不可自驱。本仓无模拟器，真机侧载是 UI 唯一验证路径，故观测面须由 App 内的结构化通道承担，截图只留作视觉断言与现场取证。

## 1. 边界

- 与 `McpGatewayServer`（:8766/mcp）**完全独立**：不共享会话、不复用投影与权限网关、不暴露 MCP 工具面，也不进对外契约面。
- debug-only：`kReleaseMode` 启动硬拒；`main.dart` 以 `!kReleaseMode` 装配，release 编译期剔除，失败只留 DEGRADE 不阻断启动。
- 恒绑 `127.0.0.1`，默认端口 8767；PC 经 `adb forward tcp:8767 tcp:8767` 访问。
- 强制 `Bearer`：构造期 `Random.secure()` 生成 32B token，仅经 logcat 输出、每次启动轮换。Android loopback 对设备上其它 App 亦可见，回环本身不构成鉴权。

## 2. 端点契约

| 方法 | 路径 | 返回 | 端口未注入 |
| --- | --- | --- | --- |
| GET | `/debug/state` | 构建态 / 端口 / 端点清单 / 日志计数，附可选 `app` 快照 | `app` 字段缺席 |
| GET | `/debug/logs?since=<index>` | `total` / `revision` / `entries[{at,level,message}]` | 内置，恒可用 |
| GET | `/debug/ui-tree` | `nodes[{type,key,label,value,text,interactive,bounds}]` | 501 `not_configured` |
| POST | `/debug/action` | `{action,args}` → `{ok,action,result}` | 501 |
| POST | `/debug/reset` | 调用装配方注入的重置 | 501 |

约定：一律 JSON；未知路径 404、方法不匹配 405、坏载荷 400；未配置端口 501 并回注端口名，**严禁**返回空集合冒充「状态为空 / 动作已执行」。日志用 `since` 增量游标，单步只回差分而非全量重传。

## 3. 控件语义树

`uiautomator dump` 只看 Android view 树，Flutter 自绘内容近乎不可见。改由窗口层遍历 Element 树（`lib/ui/debug_ui_tree.dart`）：带 `ValueKey` / `Semantics label` / 文本 / 交互 widget 的节点导出纯 JSON，`bounds` 由 `RenderBox.localToGlobal` 现算逻辑像素；单次上限 400 节点、单条文本 120 字符。gateway 侧经装配期函数端口消费，不产生 gateway → ui 反向边。

零尺寸节点（组合 widget 自身 RenderObject 未参与最终布局）不返回 0 宽高坐标——按坐标点击会落空；改为借后代或祖先的可用矩形，并用 `boundsSource` 标注来源（`self` / `descendant` / `ancestor`），调用方据此区分「自己的矩形」与「借来的矩形」。祖先链须继续上溯：最近的 RenderBox 祖先自身也可能是零尺寸容器，只查一层会误判无处可借。

候选列表另做两层收敛：私有实现件（`_IconButtonM3` 一类展开件，无业务 Key）不进树，同位置重复节点只留首个（有 Key 的锚点永远保留，避免删掉可寻址目标）。

## 4. 状态与动作注入

调试桥不持有业务态：状态快照、动作执行、状态重置均为构造期注入端口。重置属破坏性动作，默认不提供实现，须由装配方显式注入并自行界定清理范围。真实交互动作（tap / set_text / navigate）由后续工具层注入；文本输入经 `set_text` 类动作绕过键盘，不再依赖 `adb input text`。

## 5. 与既有约束的关系

- `get_host_status` 的零隐私约束约束的是 **MCP 对外工具面**；本桥为 debug-only + loopback + token，不进该面，但业务快照仍须装配方自行裁剪，不默认回传用户数据。
- 不新增 `lib/` 一级域：桥落 `gateway/`（允许 `core` 出向）、树导出落 `ui/`（禁 `dart:io`）、装配在 `main.dart`。
- 回归钉：`test/gateway/debug_bridge_test.dart`（鉴权 / 回环 / 端点 / 501 / 释放）+ `test/ui/debug_ui_tree_test.dart`（key / label / text / bounds）。

## 6. 诚实边界

- 交互动作与按 Key 稳定寻址的覆盖率取决于关键控件是否补 `ValueKey`，当前树导出只保证「有标记的节点」可见。
- 直达页面的 Deep Link 涉及 debug/profile Manifest 与路由入口，须与 native 侧改动协调，不属本桥范围。

## 7. 真机实证（PLQ110 / Android 17，2026-11-05）

`build-apk --install` 装机 → `adb forward tcp:8767 tcp:8767` → logcat 取 token 后逐端点验证：

- `/debug/state` 200（结构化元信息 + 端点清单）、无 token 401、`/debug/logs?since=0` 增量游标生效；`/debug/action` 与 `/debug/reset` 在端口未注入时 501 并回注端口名。
- 同屏对照：`uiautomator dump` 16 节点；`/debug/ui-tree` 34 节点，34 个带 `bounds`、11 个带 `key`、19 个 `interactive`。结构化观测面成立。
- 收敛后（首页，2026-11-05 第 6 轮优化）：24 节点 / 11 interactive / **零尺寸 0**（收敛前 34 节点含 7 零尺寸）/ `boundsSource` = self 21 + ancestor 3 / 私有实现件泄漏 0；补锚点 `chat-round-record` 经 `tap_node` 点按成功并打开「本轮记录」面板。
- 仍存缺口：`Semantics label` 近乎缺席——项目不建 Semantics 语义层，AI 定位依赖 `key` / `text` / `type` 三类锚点；未带 Key 的控件只能按文本或类型定位。

## 8. 直达路由（省掉前置点击链）

- debug/profile `AndroidManifest.xml` 声明 `goodhub://debug/<page>` 的 VIEW intent-filter；release 无该入口。
- `MainActivity.getInitialRoute()` 把冷启动 intent 翻成 `/debug/<page>`；`onNewIntent()` 在 `singleTop` 热启动经 `NavigationChannel.pushRoute` 推给 Dart。
- `lib/ui/debug_routes.dart` 白名单映射 `logs` / `gateway` / `settings` 到既有页面。非白名单不建页：交 `onUnknownRoute` 显式报错，并在 `/debug/logs` 留一条可用页清单，不静默回落首页。
- `onGenerateInitialRoutes` 覆盖 Flutter 默认按 `/` 分段的行为，只生成目标页一条；否则中间段 `/debug` 会额外生成错误页并污染日志。
- `WidgetsApp` 断言禁 `home` 与 `onGenerateInitialRoutes` 并存：debug 的首页由初始路由生成器产出，release 才用 `home`，路由面编译期剔除。
- 真机实证（PLQ110）：冷启动 `am start -a VIEW -d goodhub://debug/logs` → 语义树 14 节点且只含日志页；热启动切 `/debug/gateway` 生效；未知页留 `[debug-route] unknown` 与可用页清单；普通启动仍回首页。回归钉 = `test/ui/debug_routes_test.dart`（10 例，含装配形状与冷启动直达 widget 测试）。

## 9. AI 可调用工具（[4/5]）

- App 侧 `lib/ui/debug_actions.dart` 实现 `DebugBridge.actionHandler`：`tap_node` / `set_text` / `navigate` / `ping`。按 `key` / `label` / `text` / `type` 在 Element 树定位；优先调用控件自身点击回调（`via: callback`），无回调才按最近有效 RenderBox 中心派发指针事件（`via: pointer`）；`set_text` 经 `EditableText.controller` 注入，绕过 `adb input text` 的 IME 全角化。
- 失败一律结构化：`node_not_found` 回带 12 个候选节点，`unknown_action` / `unknown_page` 回带可用项，不静默回落首页或假装成功。
- 工具面 `scripts/agent-tools/debug-bridge.sh`（`toolbox run debug-bridge`，别名 `dbg`）：薄 CLI，只做 `adb forward` + logcat token 提取 + HTTP 透传，返回端点原始 JSON；`--json` 预检、`--self-test` 参数校验金丝雀。
- `navigate` 显式丢弃 `pushNamed` 的结果 Future（该 Future 在路由 pop 才完成，等待会让 `/debug/action` 永不返回）。
- 真机实证（PLQ110）：`ping` contextReady=true；`tap_node` 按 key 命中 `composer-attach` 且 `via=callback`；`set_text` 按 `type=EditableText` 注入成功；`navigate logs` 15s 内返回且语义树出现日志页；未命中与未知动作回带候选 / 可用项。回归钉 `test/ui/debug_actions_test.dart`（7 例）。

## 10. 公共包抽取（多 App 复用）

- 实现已抽为**同级独立仓** `../app_debug_bridge`（仓内物理单副本，与 `rich_text` 同范式，消除双副本分叉），宿主 goodhub 以 path 依赖消费；仓内自带 analyze + test 的 CI 门禁（Flutter 3.47.5 与本仓基线对齐）。抽取时因零宿主耦合，源码零改动即完成迁移。
- 抽取的硬约束是**零宿主耦合**：日志源（`AppLog`）、导航句柄（`appNavigatorKey`）、路由白名单（`logs`/`gateway`/`settings`）三个宿主专有件全部改为注入端口——`DebugLogSink` / `debugContextProvider` + `debugNavigatorProvider` / `DebugRouteRegistry`；公共包不含任何业务页面、业务状态与持久化。
- 宿主侧只留薄适配层：`lib/gateway/debug_bridge.dart`、`lib/ui/debug_ui_tree.dart` 为 re-export（保留原 import 路径），`lib/ui/debug_actions.dart` 映射宿主注入位，`lib/ui/debug_wiring.dart` 汇合装配（AppLog sink + navigator + 白名单）。既有 import 路径与测试断言零改动。
- **测试重接线说明**：契约端口化后，`test/gateway/debug_bridge_test.dart` 的日志源由直连 AppLog 改为注入内存 sink，`test/ui/debug_actions_test.dart` 的路由白名单改为注入注册表——**断言语义未变**（仍验证结构化日志 + since 游标、navigate 直达、未命中回候选）。公共包内自带同构测试 20 例（`../app_debug_bridge/test/`）。
- 真机实证（PLQ110，抽取与迁仓后行为不变）：`ping` contextReady、`logs` 有内容（logSink 端口生效）、`ui-tree` 24 节点零尺寸 0、`tap_node` via=callback、`navigate /debug/logs` 全部照旧。

## 11. 其他 App 接入清单

1. **依赖**：`app_debug_bridge: {path: ../app_debug_bridge}`（或 git 依赖，仓根即包根）。
2. **日志源**：实现 `DebugLogSink`（`length` / `revision` / `entries`）接到宿主自己的日志内核；不实现则 `/debug/logs` 回 501，其余端点不受影响。
3. **装配**：设 `debugContextProvider` / `debugNavigatorProvider`（宿主 navigatorKey），建 `DebugRouteRegistry` 登记要直达的页面，`DebugBridge(logSink:, uiTreeProvider:, actionHandler: executeDebugAction)`，`if (!kReleaseMode)` 启动（失败只留痕，不阻断 App 启动）。
4. **Deep Link**（可选）：宿主自定义 scheme（如 `<app>://debug/<page>`）+ Android 侧 `MainActivity.getInitialRoute()` / `onNewIntent` 翻成 `/debug/<page>`，`MaterialApp` 配 `onGenerateRoute` 映射同一批页面；冷启动与热启动两条路径都要验。
5. **CLI**：把 `scripts/agent-tools/debug-bridge.sh`（或包内等价件）放进消费仓工具池，端口与 token 约定与本仓一致（8767 + logcat 取 token）。
6. **验收**：真机跑一轮「`state` → `ui-tree` → `action tap_node`（带 Key 的控件）→ `action set_text`（`type=EditableText`）→ `navigate` → `logs --since`」全链路，六步全绿才算接入完成。
7. **不做**：不要在消费仓再复制一份实现（双副本分叉）——本仓 `rich_text` 的教训即此。
