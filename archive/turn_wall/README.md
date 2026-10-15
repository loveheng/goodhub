# archive/turn_wall —— 步数墙早期实现（已归档，被取代）

**归档日期**：2026-10-15 ｜ **依据**：SA-Q3 同口径（主代码库不留无接线/已被取代的半成品）
**原因**：`TurnWall`（`max_turns` 硬限保险丝）是 M1 落地的早期实现；现网步数墙实际由
`lib/coordinator/tool_breaker.dart` 的 `StepWallReport` + `agent_loop.maxTurns` 承担，
`lib/` 内对 `TurnWall` **零引用**，仅其单测引用它——属「被取代的死代码」而非「待接线需求」。

## 内容

| 文件 | 说明 |
|---|---|
| `turn_wall.dart` | `TurnWall` 类（`consume()` / `exhausted` / 超限抛 `TurnWallExceeded`） |
| `turn_wall_test.dart` | 对应单测 3 例（10 步耗尽 / 可配 maxTurns / 异常继承 McpException） |

## 与 `mcp/tool_router.dart` 的区别（勿混淆）

`lib/mcp/tool_router.dart` **也是未接线**，但它是 **F1.9 海关过滤的唯一实现**，属于
**待接线需求**，故**保留**在 `lib/`（文件头已标注未接线原因与启用前置条件）。
本目录的 `turn_wall` 属**已被取代**，故归档。两者处置不同，勿一律删。

## 复活条件

不建议复活——若需独立的步数墙保险丝（例如给网关长任务单独设限），优先扩展
`tool_breaker.StepWallReport`，而非回搬本实现。

## 复活步骤（若确需）

1. `git mv archive/turn_wall/turn_wall.dart lib/core/`、`turn_wall_test.dart` → `test/`；
2. 补接线：确认 `agent_loop` 或新调用点真的消费它（否则仍会被下次对账判为死代码）。
