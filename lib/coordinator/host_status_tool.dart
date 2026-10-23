/// 宿主环境事实只读工具（host-tools-gateway-export · Allowlist 首项）：
/// `get_host_status`——报宿主身份 / 协议 / 运行环境，供 PC 侧模型做
/// **协议兼容判断与时区/语言对齐**。
///
/// **为什么是它**（Allowlist 首项的选型依据，写死在此以免日后重蹈）：
/// - **零隐私**：全部字段是宿主自身的公开环境事实，不含用户数据、不含服务
///   清单、不含私有槽位/激活态（那属 `get_connected_apps` 控制面，已拉黑）；
/// - **有产品价值**：PC 模型据此对齐回答语言、时区与协议版本，是真实推理
///   增益——不是 `host_ping` 那类「为兼容性而存在的空操作工具」（设计稿禁令）；
/// - **schema 单点拥有**：`description`（§5.1 主动引导）与 `inputSchema` 住
///   本执行器，装配层经 `HostToolInvokerPort.schemaOf` 供给 `HostTransport`
///   合成面——Allowlist 只登记「导出什么」，**不复制 schema 文本**（禁双源）。
///
/// **位置纪律**：宿主执行链成员，由 `assembleHostToolInvoker` 装配；执行链
/// **无裁决**（L1/L2 已由网关 `GatewaySecurity.guard` 在 `toolsCall` 层完成，
/// 本工具 `readOnlyHint: true` → 那里落 L1 静默放行）。
library;

import 'dart:convert';
import 'dart:io' show Platform;

import '../llm/cloud/cloud_llm.dart';
import '../mcp/server_capabilities.dart' show kMcpProtocolVersion;
import 'agent_loop.dart';

/// 宿主环境事实只读工具执行器。
class HostStatusToolExecutor implements ToolExecutor {
  HostStatusToolExecutor({
    required this.inner,
    this.appVersion = 'unknown',
    this.timezone,
    this.locale,
  });

  /// 兜底执行面（本工具之外的裸名透传）。
  final ToolExecutor inner;

  /// 宿主应用版本（注入位：平台通道不可用时由装配层注入；缺省 `unknown`）。
  final String appVersion;

  /// 宿主时区（注入位；缺省取运行时的 `DateTime.now().timeZoneName`）。
  final String? timezone;

  /// 宿主语言区域（注入位；缺省取 `Platform.localeName`）。
  final String? locale;

  /// 工具名（裸名，与本机 executor 一致，不带 `host__` 前缀）。
  static const toolName = 'get_host_status';

  /// 工具声明（§5.1 描述主动引导：写「怎么用才对」+ 适用场景 + 反例）。
  static List<CloudToolSchema> toolSchemas() => [
        CloudToolSchema(
          name: toolName,
          description: '读取宿主（手机端 AI 宿主 App）的运行环境事实：'
              '应用版本、MCP 协议版本、平台、时区与语言区域。'
              '怎么用才对：回答涉及当前时间/日期的问题前先取本工具对齐宿主时区，'
              '不确定用户语言偏好时按 host.locale 组织回答语言，'
              '调试跨端协议兼容问题（如工具调用格式差异）时先看 host.version 与 '
              'host.protocol；只需这些事实，不要凭猜测假定宿主版本或本地时间。',
          parametersSchema: <String, Object?>{'type': 'object'},
          annotations: <String, Object?>{'readOnlyHint': true},
        ),
      ];

  /// schema 原文（供 `HostSchemaResolver` 透给合成面；JSON 形状，非 llm 类型——
  /// mcp 域禁反向 import llm）。
  static Map<String, Object?> schemaOf(String tool) => tool == toolName
      ? <String, Object?>{
          'description': toolSchemas().single.description,
          'inputSchema': toolSchemas().single.parametersSchema,
        }
      : const <String, Object?>{};

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    if (call.name != toolName) return inner.execute(call);
    // 无入参：入参非空不报错（模型偶发多传参数不该导致整次调用失败），
    // 但显式提示正确用法（§5.4 错误契约的可纠正分支带 hint）。
    if (call.argumentsJson.trim().isNotEmpty) {
      final decoded = _tryDecode(call.argumentsJson);
      if (decoded == null) {
        return const ToolExecutionResult(
          content: 'get_host_status 入参 JSON 损坏（本工具无需参数）'
              '——请改用空参数对象 {} 重试',
          isError: true,
        );
      }
      if (decoded.isNotEmpty) {
        return ToolExecutionResult(
          content: jsonEncode(<String, Object?>{
            'status': 'ok',
            'note': '本工具无需参数，已忽略传入的 ${decoded.keys.toList()}',
            'host': _hostFacts(),
          }),
        );
      }
    }
    return ToolExecutionResult(
      content: jsonEncode(<String, Object?>{
        'status': 'ok',
        'host': _hostFacts(),
      }),
    );
  }

  Map<String, Object?> _hostFacts() => <String, Object?>{
        'app': 'goodhub',
        'version': appVersion,
        'protocol': kMcpProtocolVersion,
        'platform': 'android',
        'timezone': timezone ?? DateTime.now().timeZoneName,
        'locale': locale ?? _platformLocale(),
      };

  /// 语言区域（`dart:io` 静态属性，失败不抛——环境事实拿不到就落 `unknown`）。
  static String _platformLocale() {
    try {
      return Platform.localeName;
    } on Object {
      return 'unknown';
    }
  }

  Map<String, Object?>? _tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }
}
