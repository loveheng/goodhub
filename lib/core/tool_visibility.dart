/// 工具可见性范围（GoodHub 私有声明式标记，SDK 0.2.0 起随 `tools/list` 下发）。
///
/// **线级形态（唯一权威口径）**：`tools/list` 每个工具条目可携带
/// `_meta.goodhub.visibility`，取值 `"shared"` / `"private"`（小写短名）：
/// ```json
/// { "name": "echo", "annotations": { "readOnlyHint": true },
///   "_meta": { "goodhub": { "visibility": "shared" } } }
/// ```
///
/// **声明 ≠ 访问控制**（责任边界，勿越界）：SDK 永不因本标记剔除 `tools/list`
/// 条目（目录永远是能力全集）、永不拦截 `tools/call`；「要不要收进共享目录 /
/// 要不要向外部 Agent 暴露」**完全由本仓（client 端）判断**。真正的调用方可信性
/// （同签名 / 信任白名单）是另一条独立维度，不得与本标记合成一套安全边界。
///
/// 下落点：`core/`（跨域共享 DTO——`llm` 的 [CloudToolSchema]、`mcp` 的海关
/// 实现、`coordinator` 的聚合路由、`gateway` 的对外目录均消费；core 零出向）。
library;

/// 工具可见性范围。
enum ToolVisibility {
  /// 不对外暴露——本机链路照常发现与调用，但不进共享目录 / 不向外部 Agent 暴露。
  ///
  /// **缺省值（default-deny）**：标记字段缺失、形状异常或取值未知一律按此兜底。
  private,

  /// 可进共享目录 / 可向外部 Agent（如经网关接入的 PC 客户端）暴露。
  shared,
}

/// `_meta` 下 GoodHub 私有命名空间键（为 `hidden` 等正交维度预留位置，
/// 禁止到 `_meta` 顶层找 `visibility`）。
const String kToolMetaGoodhubNamespace = 'goodhub';

/// GoodHub 私有命名空间下的可见性键。
const String kToolVisibilityKey = 'visibility';

/// 解析工具条目的 `_meta` → [ToolVisibility]。
///
/// [meta] = `tools/list` 条目的 `_meta` 原文（可为 null / 任意形状）。
/// 缺失子树、`goodhub` 非对象、`visibility` 非字符串或取值未知 → [ToolVisibility.private]
/// （保守缺省；未知取值不为 `shared` 即不放大暴露面）。
ToolVisibility parseToolVisibility(Object? meta) {
  if (meta is! Map) return ToolVisibility.private;
  final goodhub = meta[kToolMetaGoodhubNamespace];
  if (goodhub is! Map) return ToolVisibility.private;
  final raw = goodhub[kToolVisibilityKey];
  if (raw is! String) return ToolVisibility.private;
  return switch (raw.trim().toLowerCase()) {
    'shared' => ToolVisibility.shared,
    _ => ToolVisibility.private,
  };
}
