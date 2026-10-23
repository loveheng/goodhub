/// 宿主工具执行端口适配器（host-tools-gateway-export PR1-3）：把 coordinator 的
/// 宿主执行面适配成 mcp 域的 [HostToolInvoker]，供网关装配 `HostTransport`。
///
/// **存在理由（依赖倒置）**：`HostTransport` 住 `mcp/` 域，不得反向 import
/// coordinator（arch-guard R5）；而宿主工具执行器（`MemoryToolExecutor` /
/// `LocalResourceToolExecutor`）与 `ResourceStore` 都住 coordinator / resources
/// 域。故「组装宿主工具面并暴露为端口」这件事的 owner 住 coordinator，网关只调
/// [assembleHostToolInvoker] 一行——「谁拥有执行面谁组装」（§1.1 规则 2/6）。
///
/// **无裁决铁律**：网关入站链路的 L1/L2 裁决**已**由 `gateway_security.guard`
/// 在 `GatewayHandler.toolsCall` 层完成（annotations 取自 host 合成面，门禁 1
/// 的强置正是在此生效）——本端口**严禁**再挂 `PermissionGateway`，否则 PC 侧
/// 会看到两次确认卡。同理本端口不做审计：`McpToolFace` 已按 `serverId=host`
/// 自审计（设计稿「按 serverId=host 记账」的落点）。
///
/// **生命周期 Owner 契约**：本适配器无独立 dispose（每次网关装配新建一个轻量
/// 门面，随 `faces['host']` 释放即弃）；其内部 store 由 owner（网关装配层 /
/// `ServiceDirectory`）持有，本类**不得**关闭它们。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import '../llm/cloud/cloud_llm.dart' show AssembledToolCall;
import '../mcp/transport/host_transport.dart' show HostToolInvoker;
import '../resources/resource_store.dart';
import '../sandbox/memory_store.dart';
import 'agent_loop.dart';
import 'host_status_tool.dart';
import 'tool_executor_chain.dart';
import 'local_resource_tool_executor.dart';
import 'memory_tool_executor.dart';

/// 宿主工具 schema 的提供方（执行面实现本接口即成 schema 单点 owner）。
abstract interface class HostSchemaOwner {
  /// 按裸工具名回 `{'description': String, 'inputSchema': Map}` 原文；
  /// 非本工具面成员返回 null。
  Map<String, Object?>? schemaOf(String toolName);
}

/// 宿主工具执行端口适配器（供 `HostTransport` 以 `invoke` tearoff 注入）。
class HostToolInvokerPort {
  HostToolInvokerPort({required this.executor, this.schemaOwner});

  /// 宿主工具执行面（无裁决版，见文件头铁律）。
  final ToolExecutor executor;

  /// 宿主工具 schema 的**单点拥有者**（缺省 = 仅执行面自带 schema 的工具，
  /// 如 `HostStatusToolExecutor`；未提供者回落 Allowlist 内联 schema）。
  final HostSchemaOwner? schemaOwner;

  int _seq = 0;

  /// 执行一次宿主工具：裸工具名 + 原始入参 JSON → core 通用货币。
  ///
  /// 幂等边界：到达本方法的名字**必**已在 `kHostExportAllowlist` 登记（未登记
  /// 与控制面原语在 `HostTransport` 层即被拒），本层只做「装配调用 + 兜底」。
  Future<ToolExecutionResult> invoke({
    required String name,
    required String argumentsJson,
  }) =>
      executor.execute(AssembledToolCall(
        id: 'host-${_seq++}',
        name: name,
        argumentsJson: argumentsJson,
      ));

  /// schema 原文解析（供 `HostTransport` 合成 `tools/list` 用；**owner = 执行
  /// 面**，Allowlist 不复制 schema 文本，见 `HostSchemaResolver` 注释）。
  Map<String, Object?>? schemaOf(String toolName) =>
      schemaOwner?.schemaOf(toolName);
}

/// 组装宿主工具执行面并暴露为 mcp 域端口（网关装配层的唯一入口）。
///
/// - [memoryStore]：必填——记忆读写工具面的存储与审计落点（同时承担网关
///   既有 ops.log 汇）；
/// - [resourceStoreResolver]：可空解析位（非空且解析成功才挂本地资源读取工具
///   面；解析失败/不可用 → 降级为「无资源工具」，不阻断 host 面装配）。
///
/// 刻意**不挂** `DiscoveryExecutor`（控制面原语，已由 `HostTransport` 黑名单
/// 双层拦截：列不出 + 调用拒绝）。
Future<HostToolInvokerPort> assembleHostToolInvoker({
  required MemoryStore memoryStore,
  Future<ResourceStore?> Function()? resourceStoreResolver,
  String appVersion = 'unknown',
}) async {
  // 链路序（与 `McpRuntime.assemble` 同构思路）：宿主状态面 → 记忆面 → 资源面，
  // 三者互不重叠，命中即执行、未命中透传 inner。
  //
  // 链构造经**唯一装配器** composeToolExecutorChain（架构债 #19 根治）：层按
  // 「优先级高 → 低」给出，折叠方向固定逐层向外——调用点无法再写出「inner 指向
  // 链中段」的丢层形态（该形态曾致 status 层整层丢弃：目录可见而调用全败）。
  // 装配器单测见 `test/coordinator/tool_executor_chain_test.dart`；
  // 等价性钉子见 `test/coordinator/host_tool_invoker_test.dart`「装配等价性」组。
  ResourceStore? resources;
  if (resourceStoreResolver != null) {
    // 资源面不可用（平台通道缺失 / 目录不可写）属非数据面降级：host 面照常
    // 装配（记忆工具面不受影响），仅少一类本地资源读取工具。
    try {
      resources = await resourceStoreResolver();
    } on Object catch (e) {
      debugPrint('[DEGRADE] host-tool-invoker: 资源面解析失败（无资源工具）: $e');
      resources = null;
    }
  }

  final resourceToolStore = resources;
  final executor = composeToolExecutorChain([
    if (resourceToolStore != null)
      (inner) =>
          LocalResourceToolExecutor(inner: inner, store: resourceToolStore),
    (inner) => HostStatusToolExecutor(inner: inner, appVersion: appVersion),
    (inner) => MemoryToolExecutor(inner: inner, store: memoryStore),
  ], fallback: const _NoHostToolExecutor());
  return HostToolInvokerPort(
    executor: executor,
    schemaOwner: const _StatusSchemaOwner(),
  );
}

/// `get_host_status` 的 schema owner 适配（静态 schema 挂在执行器类上，
/// 经本薄适配转成 `HostSchemaResolver` 所需的 JSON 形状）。
class _StatusSchemaOwner implements HostSchemaOwner {
  const _StatusSchemaOwner();

  @override
  Map<String, Object?>? schemaOf(String toolName) {
    final raw = HostStatusToolExecutor.schemaOf(toolName);
    return raw.isEmpty ? null : raw;
  }
}

/// 兜底执行面：Allowlist 之外的裸名（`HostTransport` 已先行拦截，理论不可达）
/// 一律显式拒绝——**绝不静默透传**（透传会让未登记工具绕过 Allowlist 复活）。
class _NoHostToolExecutor implements ToolExecutor {
  const _NoHostToolExecutor();

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async =>
      ToolExecutionResult(
        content: '宿主工具 ${call.name} 未接入执行面（未在导出 Allowlist 登记）',
        isError: true,
      );
}