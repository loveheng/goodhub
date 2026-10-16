/// 审计日志汇抽象（arch-hardening ②/④：域间解耦的最小端口）。
///
/// 生产实现 = `sandbox/memory_store.dart` 的 [MemoryStore]（ops.log 流水）。
/// mcp/gateway 等域经本接口注入审计汇，不再反向 import sandbox。
library;

/// 追加式审计日志汇（实现须自行保证失败不抛穿调用方主路径）。
abstract interface class AuditSink {
  Future<void> audit({
    required String server,
    required String tool,
    required bool ok,
    int? durationMs,
    String? error,
  });
}
