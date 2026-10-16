/// 连接面抽象（arch-hardening ②：斩断 `mcp → coordinator` 反向边）。
///
/// `McpConnection`（传输/韧性层）不再感知 `coordinator/mcp_tool_face.dart` 的
/// 具体类型——它只需要「列工具名 + 在途计数 + 取消在途」三个协议能力，经
/// [ConnectionFace] 注入；生产实现 [McpToolFace] 在 coordinator 域 `implements`
/// 本接口（编排 → 传输 = 合法方向）。
///
/// **生命周期 Owner 契约（谁创建谁销毁）**：
/// - face 实例由装配方（`McpRuntime` / 测试）创建并注入，**没有独立 dispose**——
///   它是 client 的薄包装，资源释放唯一入口 = owner 调 `client.close()`
///   （`McpAssembly.close()` 级联：abort 全部 face → `connections.stop()` →
///   `client.close()`），不存在也不会出现 face 级二次 close；
/// - 注入形态二选一：`McpConnection(face: …)` 直传实例，或
///   `McpConnection(faceFactory: (client) => …)` 由连接自建（重连重握手场景
///   复用同一 face，仅 client 重协商，face 不重建）；**双缺 = ArgumentError
///   快速失败**，禁止隐式回退到 coordinator 具体类型；
/// - face 不得在 owner 释放前被外部持有引用后自行关闭——窗口层拿到的
///   `McpAssembly.router` 等 Run 焚后引用悬空，契约同 window-kernel-split §7.5。
library;

/// 工具执行进度通告（M2.5-T7，自 coordinator/mcp_tool_face.dart 迁入）：
/// progress/total 为 server 声明的绝对值（起始帧 0/1）；message 可空。
typedef ToolProgressCallback = void Function(
  String toolName,
  num progress,
  num? total,
  String? message,
);

/// 连接持有的协议工具面最小能力集（传输/韧性层唯一感知的 face 形态）。
abstract interface class ConnectionFace {
  /// 列出 server 当前工具名（重连后差分清洗 D17 的输入；不暴露 schema 类型，
  /// 避免 llm 域类型经本接口渗入 mcp）。
  Future<List<String>> listToolNames();

  /// 在途（已发出未终局）请求数（D18 断连回告）。
  int get inFlightCount;

  /// 取消全部在途流式请求（Abort 级联 ③；无在途为 no-op）。
  void cancelActiveRequest({String? reason});
}
