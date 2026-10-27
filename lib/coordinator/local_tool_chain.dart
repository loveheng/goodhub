/// 本机工具执行链组装（T6 链路序的唯一 owner）。
///
/// **独立成件（架构债 #18 体量治理续）**：该链原寄生在 `McpRuntime.assemble`
/// （「只减不增」超标清单件，2026-10-23 审查轮实测净增 +9）→ 抽出后 assemble
/// 只留一行调用，链路序与守卫语义有独立 owner：路由守卫（离线窗口整体丢弃）、
/// JIT 两级发现、Skill 激活、`$ref` 注水、L1/L2 网关（**裁决先于执行**）、
/// 本地资源 / 记忆工具面、ToolRouter 兜底。
///
/// **链序（T6 设计）**：Loop → Guarded → Discovery → SkillActivation →
/// Hydration → Gateway(PermissionGateway) → LocalResource → MemoryTool →
/// ToolRouter(fallback)。
///
/// **链构造经唯一装配器** `composeToolExecutorChain`（架构债 #19 根治）：
/// 层按「优先级高 → 低」给出、折叠方向固定逐层向外——调用点无法再写出
/// 「inner 指向链中段」的丢层形态（该形态曾致 status 层整层丢弃：目录可见
/// 而调用全败）。
library;

import '../llm/cloud/cloud_llm.dart' show AssembledToolCall;
import '../mcp/connection_manager.dart';
import '../resources/resource_store.dart';
import '../sandbox/memory_store.dart';
import 'agent_loop.dart';
import 'discovery_executor.dart';
import 'local_resource_tool_executor.dart';
import 'memory_tool_executor.dart';
import 'permission_gateway.dart'
    show GateDelegate, GatewayLevel, PermissionGateway, ToolNotice;
import 'plan_guard.dart';
import 'plan_proposal_tool.dart' show PlanProposalDelegate, PlanProposalTool;
import 'task_plan.dart';
import 'ref_hydrator.dart' show CrossSourceDelegate, HydratingExecutor;
import 'ref_store.dart';
import 'skill_activation_executor.dart';
import 'skill_registry.dart';
import 'tool_executor_chain.dart';
import 'tool_router.dart';

/// 步 1-T3 自 `chat_page._GuardedExecutor` 迁入（纯 Dart coordinator 件，
/// 原住 UI 文件；2026-10-23 随链路抽取移至本件）：工具执行按 server 路由到
/// 对应 [McpConnection.guardExecute]（离线窗口整体丢弃、不重放）；无 server
/// 前缀的工具（JIT 元工具/本地工具）透传。
class GuardedExecutor implements ToolExecutor {
  GuardedExecutor(this.connections, this.router, this.inner);

  final Map<String, McpConnection> connections;
  final ToolRouter router;
  final ToolExecutor inner;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) {
    final sid = router.serverFor(call.name);
    final conn = sid != null ? connections[sid] : null;
    if (conn != null) return conn.guardExecute(() => inner.execute(call));
    return inner.execute(call);
  }
}

/// 本机工具链装配产物（类型别名须在顶层，不可嵌套类内）。
typedef LocalToolChain = ({
  ToolExecutor executor,
  PermissionGateway gateway,

  /// 计划围栏（编排 B1；planState == null 时为 null）——toolsProvider 据此
  /// 对冻结集写工具注入 step-id Schema。
  PlanGuard? planGuard,
});

/// 组装本机工具执行链（T6 链路序唯一 owner）。
///
/// - [resourceStore] 可空：非空才挂本地资源工具面（M1-T3，L2 裁决先于执行，
///   对齐记忆工具面——故挂在 Gateway 内侧而非外侧）；
/// - [gateDelegate] null = headless fail-closed（§8.1-2：L2 恒
///   `user_rejected`，模型可自纠）；
/// - [onNote] / [onNotice]：广播端口（JIT 激活注记 / L1 放行与会话豁免通告）。
LocalToolChain composeLocalToolChain({
  required Map<String, McpConnection> connections,
  required ToolRouter router,
  required Map<String, String> summaries,
  required SkillRegistry skills,
  required MemoryStore memoryStore,
  required RefStore refStore,
  required ResourceStore? resourceStore,
  required GateDelegate? gateDelegate,
  required CrossSourceDelegate? consentDelegate,
  required void Function(ToolNotice)? onNotice,
  required void Function(String message, {bool danger})? onNote,
  PlanRunState? planState,
  PlanProposalDelegate? planDelegate,
  void Function(String message)? onPlanEcho,
}) {
  PermissionGateway? gatewayRef;
  PlanGuard? guardRef;
  bool planIsWriteTool(String name, Map<String, Object?>? annotations) =>
      gatewayRef!.classify(name, annotations) == GatewayLevel.l2Write;

  final executor = composeToolExecutorChain([
    (inner) => GuardedExecutor(connections, router, inner),
    // T6-3 JIT 两级发现：DiscoveryExecutor 挂最外层（SkillActivation 之前），
    // 拦截 get_connected_apps / activate_server_tools（L1 本地，不走确认卡）。
    (inner) => DiscoveryExecutor(
      router: router,
      inner: inner,
      serverSummaries: summaries,
      onActivation: (id) => onNote?.call('✓ 已激活 $id 的工具', danger: false),
    ),
    (inner) => SkillActivationExecutor(
      inner: inner,
      registry: skills,
      opsLog: memoryStore,
    ),
    (inner) => HydratingExecutor(
      inner: inner,
      refStore: refStore,
      targetResolver: router.serverFor,
      crossSourceDelegate: consentDelegate,
    ),
    // 计划围栏（编排 B1）：PlanProposalTool → PlanGuard → Gateway（铁律链序
    // ——围栏在网关之前，阶段外写不产生确认卡）。planState == null = 不挂
    // （网关 headless 装配无编排语义，二者仅共享 faces）。
    if (planState != null)
      (inner) {
        final guard = PlanGuard(
          inner: inner,
          state: planState,
          isWriteTool: planIsWriteTool,
          annotationsFor: gatewayRef!.annotationsFor,
          onStepEcho: onPlanEcho,
        );
        guardRef = guard;
        return guard;
      },
    if (planState != null)
      (inner) => PlanProposalTool(
            inner: inner,
            router: router,
            state: planState,
            isWriteTool: planIsWriteTool,
            delegate: planDelegate,
            // 起草期预检（R6）：连接缺失 = 服务已离线（卡面置灰口径）。
            availabilityIssue: (id) =>
                connections.containsKey(id) ? null : '服务已离线',
          ),
    (inner) {
      final g = PermissionGateway(
        inner: inner,
        delegate: gateDelegate, // null = headless fail-closed（§8.1-2）
        onNotice: onNotice,
        planGrants: planState,
      );
      gatewayRef = g;
      return g;
    },
    if (resourceStore != null)
      (inner) => LocalResourceToolExecutor(inner: inner, store: resourceStore),
    (inner) => MemoryToolExecutor(inner: inner, store: memoryStore),
  ], fallback: router);
  return (
    executor: executor,
    gateway: gatewayRef!,
    planGuard: guardRef,
  );
}
