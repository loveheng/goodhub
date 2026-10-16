/// 网关入站安全闭环（G3，thirdconnect.md §7）：Bearer（server 层已有）之上的
/// 三件套——L1/L2 权限卡片拦截、PII 出站过滤、ops.log 入站审计。
///
/// - **L1/L2 裁决复用宿主 SSOT**：`PermissionGateway.classify`（annotations
///   `readOnlyHint` + 本地只读白名单双源，双缺从严）；L2 走 `GateDelegate`
///   确认卡，显式 45s 超时主动拒绝（TC12：PC 立即停转不悬挂）；拒绝包装
///   `user_rejected` 正常结果回传（与宿主 §12 同口径：拒绝≠系统错误）；
/// - **会话豁免（C7 口径）**：确认卡「本网关会话记住」后该工具静默放行，
///   内存态，`resetSessionGrants` 供网关停服/重扫清空；
/// - **PII 出站过滤（fail-closed）**：工具结果回 PC 前过 `PiiRedactionSession`
///   四类遮蔽（手机号/邮箱/身份证/银行卡）；遮蔽失败**严禁明文出站**（D4
///   禁区）——整包转 isError 拦截帧。progress 帧 message 用 `redactSync`
///   同步遮蔽（瞬态帧不并会话映射，终局结果由本层会话级遮蔽兜一致性）；
/// - **ops.log 入站审计**：每次已路由的 tools/call（含拒绝/拦截/失败）落
///   `server='gateway'` 审计流水；审计失败 DEGRADE 留痕不阻断调用。
library;

import 'dart:async';
import 'dart:convert';

import '../coordinator/agent_loop.dart' show ToolExecutionResult, ToolExecutor;
import '../coordinator/permission_gateway.dart';
import '../coordinator/pii_fence.dart' show PiiMaskException, PiiRedactionSession;
import '../llm/cloud/cloud_llm.dart' show AssembledToolCall;
import '../sandbox/memory_store.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import 'mcp_gateway_handler.dart' show GatewayToolResult;

/// L2 确认时限（TC12 拍板：45s 超时未点即主动拒绝，PC 立即停转不悬挂）。
const kGatewayConsentTimeout = Duration(seconds: 45);

class GatewaySecurity {
  GatewaySecurity({
    this.delegate,
    this.opsLog,
    this.consentTimeout = kGatewayConsentTimeout,
  });

  /// 确认卡委托（生产 = [NativeConsentDelegate]；Flutter 弹层实现
  /// [DialogGateDelegate] 已迁 `ui/gateway_consent_dialog.dart`；测试注入假件）。
  /// null = 无确认界面（无人值守），L2 一律拒绝——保守缺省，严禁静默放行、
  /// 严禁悬挂等待（fail-closed 契约：桥缺位/超时/异常三路均恒 `approved: false`）。
  GateDelegate? delegate;

  /// ops.log 审计汇（GatewayController 装配期注入；审计失败 DEGRADE 不阻断）。
  MemoryStore? opsLog;

  /// L2 确认时限（TC12）。
  final Duration consentTimeout;

  /// 裁决矩阵 SSOT 复用（classify 为公开直测面；inner 永不触达）。
  static final PermissionGateway _classifier =
      PermissionGateway(inner: _NeverExecutor());

  /// 会话豁免集（C7：本**连接**生命周期内「记住」的 L2 工具）。
  ///
  /// 键为 [grantKey]（强制带服务维度）。逐连接独立——[forSession] 派生新实例，
  /// 绝不在多个 PC 会话间共享（2026-10-17 P0-B）。
  final Set<String> _sessionGrants = {};
  void resetSessionGrants() => _sessionGrants.clear();

  /// 豁免键：`<serverId>::<toolName>`。
  ///
  /// 只按 tool 名记录会让「A 服务获批」替「B 服务同名工具」开后门（不同服务的
  /// 同名工具语义与权限未必相同），故 serverId 是键的**强制**组成部分；无前缀
  /// 的本地/元工具归 `local` 命名空间。
  static String grantKey(String serverId, String tool) =>
      '${serverId.isEmpty ? 'local' : serverId}::$tool';

  /// 派生**每连接**安全上下文（阶段二 D-D 投影隔离的补完）。
  ///
  /// 共享的是**无状态**部分：裁决矩阵 `_classifier` 为 static、审计汇 `opsLog`
  /// 无状态——复用无安全风险；会话豁免集既是会话态，必须随连接独立。
  GatewaySecurity forSession() => GatewaySecurity(
        delegate: delegate,
        opsLog: opsLog,
        consentTimeout: consentTimeout,
      );

  /// 安全管线：裁决 → 执行 → PII 过滤 → 审计。[run] 为真实工具执行。
  ///
  /// [serverId] 是豁免键的强制维度（见 [grantKey]），由调用方从工具前缀解析。
  Future<GatewayToolResult> guard({
    required String serverId,
    required String tool,
    required Map<String, Object?>? annotations,
    required String argumentsJson,
    required Future<GatewayToolResult> Function() run,
  }) async {
    final sw = Stopwatch()..start();
    final level = _classifier.classify(tool, annotations);
    final key = grantKey(serverId, tool);
    if (level == GatewayLevel.l1ReadOnly || _sessionGrants.contains(key)) {
      return _finish(await run(), sw, tool);
    }
    final gate = delegate;
    if (gate == null) {
      return _finish(
        _rejected('headless_no_ui_prompt：PC 触发写操作需手机屏人工确认；无确认界面（无人值守）一律拒绝'),
        sw,
        tool,
        rejected: true,
      );
    }
    GateDecision decision;
    try {
      decision = await gate
          .confirm(ToolPendingConfirmation(
            toolName: tool,
            argumentsJson: argumentsJson,
          ))
          .timeout(
            consentTimeout,
            onTimeout: () => const GateDecision(
              approved: false,
              reason: '确认超时（45s），已主动拒绝（TC12）',
            ),
          );
    } on Object catch (e) {
      decision = GateDecision(approved: false, reason: '确认界面异常: $e');
    }
    if (!decision.approved) {
      return _finish(_rejected(decision.reason), sw, tool, rejected: true);
    }
    if (decision.rememberSession) _sessionGrants.add(key);
    return _finish(await run(), sw, tool);
  }

  /// PII 出站过滤（fail-closed）+ ops.log 审计。
  Future<GatewayToolResult> _finish(
    GatewayToolResult r,
    Stopwatch sw,
    String tool, {
    bool rejected = false,
  }) async {
    var out = r;
    try {
      final masked = await PiiRedactionSession().mask(r.content);
      if (masked.maskedCount > 0) {
        out = GatewayToolResult(content: masked.text, isError: r.isError);
      }
    } on PiiMaskException catch (e) {
      out = GatewayToolResult(
        content: '结果含 PII 且遮蔽失败，已按 fail-closed 拦截明文出站: $e',
        isError: true,
      );
    }
    final log = opsLog;
    if (log != null) {
      try {
        await log.audit(
          server: 'gateway',
          tool: tool,
          ok: !out.isError,
          durationMs: sw.elapsedMilliseconds,
          error: (out.isError || rejected) ? _clip(out.content) : null,
        );
      } on Object catch (e) {
        debugPrint('[DEGRADE] gateway-security: ops audit failed: $e');
      }
    }
    return out;
  }

  /// §12 同口径：user_rejected 包装为正常结果（isError=false，拒绝≠系统错误）。
  GatewayToolResult _rejected(String? reason) => GatewayToolResult(
        content: jsonEncode({
          'status': 'user_rejected',
          'reason': reason ?? '用户拒绝',
        }),
        isError: false,
      );

  static const _clipLen = 200;
  String _clip(String text) =>
      text.length <= _clipLen ? text : '${text.substring(0, _clipLen)}…';
}

/// [GatewaySecurity._classifier] 占位执行环（仅复用 classify，永不触达）。
class _NeverExecutor implements ToolExecutor {
  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) =>
      throw UnimplementedError('classifier-only executor');
}

/// 网关 L2 确认委托（TC12）：经原生 `goodhub/gateway_consent` 通道触发全屏醒目呼叫
/// （[L2AlertActivity]：亮屏 + 震动 + 45s 倒计时），PC 触发写操作时即便息屏也能
/// 弹卡确认。与原生端 [DialogGateDelegate] 不同——不依赖 Flutter Navigator 是否在
/// 前台，息屏/后台场景由原生全屏通知兜底（更符合"醒目呼叫"语义）。
///
/// 通道不可达（单测/无引擎）时捕获 [PlatformException] 按拒绝处理（保守缺省），
/// 与 [GatewaySecurity.guard] 的 [consentTimeout] 双保险。
class NativeConsentDelegate implements GateDelegate {
  const NativeConsentDelegate();

  static const MethodChannel _ch = MethodChannel('goodhub/gateway_consent');

  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) async {
    try {
      final Map<Object?, Object?>? r =
          await _ch.invokeMethod<Map<Object?, Object?>>(
        'requestConsent',
        <String, Object?>{
          'toolName': pending.toolName,
          'argumentsJson': pending.argumentsJson,
        },
      );
      if (r == null) {
        return const GateDecision(approved: false, reason: '确认界面不可用');
      }
      return GateDecision(
        approved: r['approved'] == true,
        rememberSession: r['rememberSession'] == true,
        reason: r['reason'] as String?,
      );
    } on PlatformException catch (e) {
      return GateDecision(approved: false, reason: '确认界面异常: $e');
    }
  }
}
