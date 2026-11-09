/// ai/complete 家族线级件（ai-capability-export M-B · 从受理链拆出的纯值层）。
///
/// 内容：[AiWire] 跨语言线级常量（冻结 = 契约仓 McpContract.AI_*，测试钉死）、
/// [AiCompleteFailure] 结构化失败、[AiCompleteConfig] config 声明字段、
/// D1 路由腿与设置存取、预算/退避常量。无行为逻辑——行为在
/// `ai_complete_service.dart`（统一受理链），本件零状态。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/llm.dart' show LlmResponseFormat;
import '../mcp/sampling.dart' show kSamplingMaxTokensCap;

/// ai/complete 家族线级常量（Dart 侧单点；值冻结 = 契约仓 `McpContract.AI_*`，
/// `test/coordinator/ai_complete_service_test.dart` 钉死——跨语言字面量禁漂移）。
abstract final class AiWire {
  static const methodComplete = 'ai/complete';
  static const methodCancel = 'ai/cancel';
  static const failureRpcCode = -32000;
  static const keyRetryAfterMs = 'retry_after_ms';
  static const keyCancelId = 'cancel_id';
  static const progressMetaPhase = 'phase';

  // —— 生成阶段四值（params._meta.phase）——
  static const phaseStartingHost = 'STARTING_HOST';
  static const phaseLoadingModel = 'LOADING_MODEL';
  static const phaseQueuing = 'QUEUING';
  static const phaseGenerating = 'GENERATING';

  // —— 结构化失败十二码（error.data.status）——
  static const failModelCold = 'MODEL_COLD';
  static const failResourceBusy = 'RESOURCE_BUSY';
  static const failHostOffline = 'HOST_OFFLINE';
  static const failHostTerminated = 'HOST_TERMINATED';
  static const failBudgetExceeded = 'BUDGET_EXCEEDED';
  static const failUnauthorized = 'UNAUTHORIZED';
  static const failRateLimit = 'RATE_LIMIT';
  static const failCallerNotInForeground = 'CALLER_NOT_IN_FOREGROUND';
  static const failUserRejected = 'USER_REJECTED';
  static const failEngineFailed = 'ENGINE_FAILED';
  static const failDeviceThrottled = 'DEVICE_THROTTLED';
  static const failPreemptedByHost = 'PREEMPTED_BY_HOST';
}

/// 输入预算线（设计稿 §3.1/§6.3：超 128KB 线诚实降级 `BUDGET_EXCEEDED`——
/// 中文 128KB ≈ 4~6 万字本就击穿 2B 模型 KV Cache 物理极限；`mcp-blob://`
/// 留真实撞线后二期）。
const int kAiInputMaxBytes = 128 * 1024;

/// QoS 抢占 / 并发满载的建议退避缺省（毫秒；仅提示非承诺）。
const int kAiDefaultRetryAfterMs = 3000;

/// 结构化失败（受理链唯一异常出口；[status] = 十二码之一）。
class AiCompleteFailure implements Exception {
  const AiCompleteFailure(this.status, this.message, {this.retryAfterMs});

  final String status;
  final String message;
  final int? retryAfterMs;

  @override
  String toString() => 'AiCompleteFailure($status): $message';
}

/// ai/complete config 声明字段（契约 api.md §8.1；未声明字段取宿主默认）。
class AiCompleteConfig {
  const AiCompleteConfig({this.maxTokens, this.temperature, this.responseFormat});

  factory AiCompleteConfig.fromParams(Object? raw) {
    if (raw is! Map) return const AiCompleteConfig();
    final max = raw['maxTokens'];
    final temp = raw['temperature'];
    final rf = raw['responseFormat'];
    return AiCompleteConfig(
      maxTokens: max is num && max.toInt() > 0 ? max.toInt() : null,
      temperature: temp is num ? temp.toDouble() : null,
      responseFormat: _parseResponseFormat(rf),
    );
  }

  /// S17b 键集（`{type: 'json'|'regex', value}`）；形状违规 = null（无约束），
  /// 由调用方决定是否按「声明了但形状坏」拒收——本解析只做类型归一。
  static LlmResponseFormat? _parseResponseFormat(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    final value = raw['value'];
    if (type is! String || value is! String || value.isEmpty) return null;
    return switch (type) {
      'json' => LlmResponseFormat.jsonSchema(value),
      'regex' => LlmResponseFormat.regex(value),
      _ => null,
    };
  }

  final int? maxTokens;
  final double? temperature;
  final LlmResponseFormat? responseFormat;

  /// 输出预算（缺省 = sampling D3 硬顶口径；恒 clamp 到 [kSamplingMaxTokensCap]）。
  int get effectiveMaxTokens {
    final raw = maxTokens ?? kSamplingMaxTokensCap;
    return raw > kSamplingMaxTokensCap ? kSamplingMaxTokensCap : raw;
  }
}

/// 路由腿（D1：端侧 / 云端由设备主在 goodhub 设置里选择，调用方 config 无路由
/// 字段；`completeSync` 便捷壳固定端侧属 SDK 形态语义，不进协议）。
enum AiRouteLeg { onDevice, cloud }

typedef AiRouteResolver = Future<AiRouteLeg> Function();

/// 路由设置键（SharedPreferences；缺省端侧——零成本零云延迟，D1 成本裁决
/// 归设备主，UI 开关随 M-C 用户主权面落地，本键即其存储）。
const String kPrefAiExportRouteLeg = 'ai_export.route_leg';

/// 读取路由设置（缺省端侧；脏值归一端侧）。
Future<AiRouteLeg> readAiExportRouteLeg() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(kPrefAiExportRouteLeg) == 'cloud'
        ? AiRouteLeg.cloud
        : AiRouteLeg.onDevice;
  } on Object catch (e) {
    debugPrint('[DEGRADE] ai-export route read: $e');
    return AiRouteLeg.onDevice;
  }
}

/// 写入路由设置（设置面 toggle 调用，M-C 接线）。
Future<void> setAiExportRouteLeg(AiRouteLeg leg) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        kPrefAiExportRouteLeg, leg == AiRouteLeg.cloud ? 'cloud' : 'on_device');
  } on Object catch (e) {
    debugPrint('[DEGRADE] ai-export route write: $e');
  }
}

/// ops.log 审计口（§4 `audit` 恒开；生产实现 = MemoryStore.audit 适配——
/// 网关审计件同汇 ops.log，受理/路由/拒绝全记）。
typedef AiAuditSink = Future<void> Function({
  required String caller,
  required String method,
  required String route,
  required bool ok,
  required int durationMs,
  String? note,
});

/// 内容违规分类（§5 安全防火墙的判定注入）：命中即计入该调用方连续违规
/// （3 次冻结）。缺省启发式 = 围栏/内容过滤特征词；生产可换精确分类器。
bool aiContentViolationDefault(String status, String message) {
  final m = '$status $message'.toLowerCase();
  return m.contains('pii') ||
      m.contains('content_filter') ||
      m.contains('内容违规');
}

