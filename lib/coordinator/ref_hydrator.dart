/// $ref 注水拦截（M2.5-T4）：ToolExecutor 装饰器——tools/call 分发前扫描入参，
/// 把 `$ref:<server>:<id>` 句柄替换为 RefStore 真实载荷。
/// 规格 SSOT：architecture.md §9（注水时序与语义写死）+ M2.5 施工设计 §1.3。
///
/// - **语义写死**：句柄是模型侧行话，翻译责任在网关——目标 Server 永只见真实
///   数据、永不见 `$ref` 字符串（注水在内存内完成，重编码后的 JSON 零句柄残留）；
/// - 同源（载荷来源 = 目标 Server）：静默注水（数据回到它来的 server，零外泄面）；
/// - 跨源：挂起下发，走 [CrossSourceDelegate] 联合授权（展示注水后摘要，
///   **禁盲签**）——delegate 缺省或拒绝一律 fail-closed 不执行；授权卡 UI 随
///   T7 多 Server 接线（单 Server 阶段跨源不可达，语义由单测钉死）；
/// - 查无/过期/伪造句柄：**立即 isError 回填不执行**（C-2 定案：禁挂起等待）；
/// - 整值匹配口径：参数值 trim 后恰为句柄才注水——描述性文本内嵌 `$ref:` 子串
///   不触发（误注水防线）。
/// 装配序：AgentLoop → HydratingExecutor → PermissionGateway → McpToolFace
/// （先注水再网关——L1/L2 矩阵按注水后的真实入参裁决）。
library;

import 'dart:convert';

import '../llm/cloud/cloud_llm.dart';
import 'agent_loop.dart';
import 'ref_store.dart';

/// 跨源注水授权回调：true = 放行注水；false = 拒绝（isError 回填不执行）。
/// [preview] = 注水后载荷摘要（RefEntry.preview：标题+前 N 行封顶，禁盲签）。
typedef CrossSourceDelegate = Future<bool> Function(
  String handle,
  String fromServerId,
  String toServerId,
  String preview,
);

class HydratingExecutor implements ToolExecutor {
  HydratingExecutor({
    required this.inner,
    required this.refStore,
    this.targetServerId = 'goodshare',
    this.targetResolver,
    this.crossSourceDelegate,
  });

  final ToolExecutor inner;
  final RefStore refStore;

  /// 目标 Server 缺省值（单 Server 阶段口径；多 Server 下仅作
  /// [targetResolver] 缺席/宿主本地工具的兜底）。
  final String targetServerId;

  /// 前缀工具名 → 调用目标 serverId（M4-T6：装配层接 ToolRouter.serverFor）
  /// ——注水跨源校验按调用目标判定；null = 落 [targetServerId]。
  final String Function(String toolName)? targetResolver;

  /// 跨源授权面；null = 无人值守 fail-closed（跨源一律拒绝——D4 同构口径）。
  final CrossSourceDelegate? crossSourceDelegate;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    final Object? decoded;
    try {
      decoded = call.argumentsJson.trim().isEmpty
          ? const <String, Object?>{}
          : jsonDecode(call.argumentsJson);
    } on FormatException {
      return inner.execute(call); // JSON 损坏交 inner 既有轨（face isError 回填）
    }
    if (decoded is! Map) return inner.execute(call);

    final handles = <String>{};
    _collectHandles(decoded, handles);
    if (handles.isEmpty) return inner.execute(call);

    final payloads = <String, String>{};
    final targetId = targetResolver?.call(call.name) ?? targetServerId;
    for (final handle in handles) {
      final payload = await refStore.read(handle);
      if (payload == null) {
        return ToolExecutionResult(
          content:
              '引用 $handle 不存在或已过期（TTL 30 分钟或来源会话已结束）。请重新获取数据后再调用，勿复用旧引用。',
          isError: true,
        );
      }
      final parsed = parseRefHandle(handle)!;
      if (parsed.serverId != targetId) {
        final delegate = crossSourceDelegate;
        if (delegate == null) {
          return ToolExecutionResult(
            content: '跨源引用 $handle（${parsed.serverId} → $targetId）需要用户确认，'
                '当前无授权面板——拒绝注水。',
            isError: true,
          );
        }
        final preview = _previewOf(handle);
        final allowed =
            await delegate(handle, parsed.serverId, targetId, preview);
        if (!allowed) {
          return ToolExecutionResult(
            content: '用户拒绝把 $handle 的数据注水外发给 $targetId。',
            isError: true,
          );
        }
      }
      payloads[handle] = payload;
    }

    final hydrated = _replaceHandles(decoded, payloads);
    return inner.execute(AssembledToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: jsonEncode(hydrated),
    ));
  }

  String _previewOf(String handle) {
    final parsed = parseRefHandle(handle)!;
    for (final e in refStore.list()) {
      if (e.id == parsed.id) return e.preview;
    }
    return '';
  }

  /// 第一遍：深度收集整值句柄（只读不改树）。
  void _collectHandles(Object? node, Set<String> out) {
    if (node is String) {
      final t = node.trim();
      if (parseRefHandle(t) != null) out.add(t);
      return;
    }
    if (node is Map) {
      for (final v in node.values) {
        _collectHandles(v, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collectHandles(v, out);
      }
    }
  }

  /// 第二遍：整值句柄 → 真实载荷；其余原样（encode 后零 `$ref` 残留）。
  Object? _replaceHandles(Object? node, Map<String, String> payloads) {
    if (node is String) {
      final t = node.trim();
      return payloads[t] ?? node;
    }
    if (node is Map) {
      return {
        for (final e in node.entries) e.key: _replaceHandles(e.value, payloads),
      };
    }
    if (node is List) {
      return [for (final v in node) _replaceHandles(v, payloads)];
    }
    return node;
  }
}
