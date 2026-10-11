/// L1/L2 权限网关（M2-T4a）：[ToolExecutor] 装饰器——模型发起的 tools/call
/// 进入执行环前的唯一权限裁决点（architecture §六层 / §8 缺口1）。
///
/// - **L1（只读）**静默执行，[onNotice] 通告药丸反馈（UI T4c 挂接）；
/// - **L2（写操作）**经 [GateDelegate] 弹确认卡：每轮独立 engine.send，轮间
///   await 用户不占连接（§10 结算流原则天然兼容）；拒绝包装 user_rejected
///   Tool Result 原地回传（§12，isError=false：拒绝≠系统错误，T4b 熔断据此豁免）；
/// - **裁决双源（2026-10-11 拍板 C2）**：服务端 readOnlyHint 与本地只读白名单表
///   为两个建议值源——双源齐且冲突按更严格者；单源由该源裁决；双缺按 L2
///   （未知从严，堵表漂移洞：goodshare 新增未收录工具不可被静默放行）；
/// - **会话豁免（拍板 C7）**：确认卡勾选「本会话记住」后该工具会话内静默放行，
///   内存态不落盘、[resetSessionGrants] 供会话结束/Abort 调用；不旁路 N7 围栏；
/// - **管辖边界（拍板 C5）**：只管 AgentLoop 内模型发起的调用；TaskLoopService
///   的 claim/touch/apply 管道不经本网关（任务管道授权独立于模型裁决）。
library;

import 'dart:convert';

import 'tool_router.dart' show kToolNamespaceSep;

import 'package:flutter/foundation.dart';

import '../llm/cloud/cloud_llm.dart';
import 'agent_loop.dart';

/// 权限级：L1 只读（静默+药丸）/ L2 写操作（拦截+确认卡）。
enum GatewayLevel { l1ReadOnly, l2Write }

/// L1 静默执行 / 会话豁免放行的药丸通告（L2 确认卡不经此通道）。
class ToolNotice {
  const ToolNotice({required this.toolName, required this.viaSessionGrant});

  final String toolName;

  /// true = 凭会话豁免放行（非首次确认），UI 可弱化展示。
  final bool viaSessionGrant;
}

/// 提交用户确认的 L2 待决调用（确认卡参数区数据源）。
class ToolPendingConfirmation {
  const ToolPendingConfirmation({required this.toolName, required this.argumentsJson});

  final String toolName;
  final String argumentsJson;
}

/// L2 确认卡的裁决回执。
class GateDecision {
  const GateDecision({
    required this.approved,
    this.reason,
    this.rememberSession = false,
  });

  /// false 时 [reason] 为拒绝理由（Rejected(reason) 回传模型原地修正）。
  final bool approved;
  final String? reason;

  /// 拍板 C7：本会话记住该工具（仅 approved 时生效）。
  final bool rememberSession;
}

/// 确认卡委托（UI T4c 实现；测试注入假件）。
/// null delegate = 无确认界面（AI 入口/无人值守），L2 一律拒绝——保守缺省，
/// 严禁静默放行。
abstract interface class GateDelegate {
  Future<GateDecision> confirm(ToolPendingConfirmation pending);
}

class PermissionGateway implements ToolExecutor {
  PermissionGateway({
    required this.inner,
    this.delegate,
    this.onNotice,
  });

  /// 被装饰的真实执行环（McpToolFace）。
  final ToolExecutor inner;
  final GateDelegate? delegate;
  final void Function(ToolNotice notice)? onNotice;

  /// tools/list annotations 目录（[loadCatalog] 全量刷新，§8 缓存失效语义）。
  final Map<String, Map<String, Object?>?> _annotations = {};

  /// 会话豁免集（C7：内存态，会话结束/Abort 清空）。
  final Set<String> _sessionGrants = {};

  /// 本地只读白名单（goodshare 工具面 2026-10-11 核对：纯查询七项；
  /// 只列只读，其余一律落 L2 未命中从严）。annotations 就绪后降级为兜底源。
  static const Set<String> localReadOnlyTools = {
    'list_items',
    'get_item',
    'query_machine_data',
    'list_workspaces',
    'list_jobs',
    'get_job_status',
    'get_timeline_context',
  };

  /// tools/list 后全量刷新注解目录（§8：目录变更即全量重挂，不留旧能力）。
  void loadCatalog(List<CloudToolSchema> tools) {
    _annotations
      ..clear()
      ..addEntries([for (final t in tools) MapEntry(t.name, t.annotations)]);
  }

  /// 会话结束 / Abort 时清空豁免（C7：豁免不跨会话存活）。
  void resetSessionGrants() => _sessionGrants.clear();

  /// 裁决矩阵（拍板 C2 / §8 缺口1，公开供单测直测）：
  /// - hint 与表双源齐：一致取同值，冲突按更严格者；
  /// - 仅 hint：hint 裁决（hint 优先）；
  /// - 仅表：表裁决；
  /// - 双缺：L2（未知从严）。
  ///
  /// T6 多 Server：外部名 = `<serverId>__<toolName>`——白名单按裸名查
  /// （两段均不含 `__`，split 安全；宿主本地工具名无前缀原样）。
  GatewayLevel classify(String toolName, Map<String, Object?>? annotations) {
    final hint = annotations?['readOnlyHint'];
    final hintReadOnly = hint is bool ? hint : null;
    final bareName = toolName.contains(kToolNamespaceSep)
        ? toolName.split(kToolNamespaceSep).last
        : toolName;
    final inTable = localReadOnlyTools.contains(bareName);
    if (hintReadOnly != null && inTable) {
      return hintReadOnly ? GatewayLevel.l1ReadOnly : GatewayLevel.l2Write;
    }
    if (hintReadOnly != null) {
      return hintReadOnly ? GatewayLevel.l1ReadOnly : GatewayLevel.l2Write;
    }
    return inTable ? GatewayLevel.l1ReadOnly : GatewayLevel.l2Write;
  }

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    final level = classify(call.name, _annotations[call.name]);
    if (level == GatewayLevel.l1ReadOnly) {
      onNotice?.call(ToolNotice(toolName: call.name, viaSessionGrant: false));
      return inner.execute(call);
    }
    if (_sessionGrants.contains(call.name)) {
      onNotice?.call(ToolNotice(toolName: call.name, viaSessionGrant: true));
      return inner.execute(call);
    }
    final gate = delegate;
    if (gate == null) {
      return _rejected('宿主无确认界面（L2 写操作需人工确认，无人值守一律拒绝）');
    }
    final GateDecision decision;
    try {
      decision = await gate.confirm(ToolPendingConfirmation(
        toolName: call.name,
        argumentsJson: call.argumentsJson,
      ));
    } catch (e) {
      // DEGRADE: 确认界面异常按拒绝处理（保守缺省防静默放行），不留痕会丢现场。
      debugPrint('[DEGRADE] gateway-confirm: delegate 失败按拒绝: $e');
      return _rejected('确认界面异常: $e');
    }
    if (decision.approved) {
      if (decision.rememberSession) _sessionGrants.add(call.name);
      return inner.execute(call);
    }
    return _rejected(decision.reason);
  }

  /// §12 Rejected(reason)：user_rejected 包装为正常 Tool Result 原地回传——
  /// isError=false（拒绝非系统错误，模型读 status 自行修正重调，不计熔断）。
  ToolExecutionResult _rejected(String? reason) => ToolExecutionResult(
        content: jsonEncode({
          'status': 'user_rejected',
          'reason': reason ?? '用户拒绝',
        }),
        isError: false,
      );
}
