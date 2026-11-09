/// `ai_complete` 网关投影执行器（ai-capability-export M-D §3.3）。
///
/// **定位**：`complete` 原语按 host-tools-gateway-export 模式登记进 `host__`
/// 导出面（`host__ai__complete`）——非 Android 调用方（PC / 跨设备）经聚合网关
/// 使用宿主 AI 原语的标准通道。语义与 Binder 反向请求 `ai/complete` 完全同源
/// （§3.2 禁两条推理转发路径）：路由随设备主（D1）、K22 per-caller 配额、
/// 违规冻结、ops 审计全部在 [AiCompleteService.completeCore] 单源承载，本执行
/// 器只做「参数解析 + 网关工具面形状适配」，零裁决。
///
/// **网关面同步语义**：单 JSON 响应无 progressToken ——零等待通道；引擎冷态
/// 直接结构化失败（`MODEL_COLD` 话术透出，诚实降级），与 `completeSync` 同口径。
///
/// 破层红线不适用本件（本件住 coordinator，网关经 HostToolInvoker 端口调用）；
/// schema 单源 = 本执行器（owner = 执行面，禁 Allowlist 复制）。
library;

import 'dart:convert';

import '../llm/cloud/cloud_llm.dart';
import 'agent_loop.dart';
import 'ai_complete_service.dart';

/// `ai_complete` 导出执行器（网关投影；`host__` 前缀由合成面附加）。
class HostAiCompleteExecutor implements ToolExecutor {
  HostAiCompleteExecutor({required this.inner});

  /// 链语义：非本工具名透传内层（composeToolExecutorChain 折叠约定——
  /// 禁「未知名本地拒绝」截断链，否则兜底层永不触达）。
  final ToolExecutor inner;

  /// 工具名（裸名；网关合成面自动加 `host__` 前缀）。
  static const toolName = 'ai_complete';

  /// schema 单源（§5.1 描述主动引导：怎么用才对 + 降级语义显式声明）。
  static Map<String, Object?> schemaOf(String tool) {
    if (tool != toolName) return const <String, Object?>{};
    return {
      'description': '使用 GoodHub 的 AI 算力完成一次单发推理（complete 原语：'
          'instruction + input → 聚合文本）。怎么用才对：instruction 写清任务与'
          '输出要求（负向硬约束 + 分隔符定界，如「从下文提取地点列表，仅输出 '
          'JSON 数组，无解释」），input 放待处理原文；任务语义（摘要/翻译/打标签）'
          '由调用方编排，宿主不内置任务模板。路由（端侧/云端）由设备主在 GoodHub '
          '设置里选择，本工具无路由参数。降级语义（调用前须知）：受 per-caller '
          '配额与内容围栏约束——失败返回结构化状态（MODEL_COLD/RESOURCE_BUSY/'
          'RATE_LIMIT/BUDGET_EXCEEDED 等），建议退避值仅提示非承诺；引擎冷态'
          '（网关同步通道）直接结构化失败，请稍后重试或走调用方自有降级。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'instruction': {
            'type': 'string',
            'description': '任务指令（做什么、输出什么形状）',
          },
          'input': {
            'type': 'string',
            'description': '待处理的原文（合法 UTF-8 纯文本，超 128KB 拒收）',
          },
          'config': {
            'type': 'object',
            'description': '可选声明字段（未声明取宿主默认）',
            'properties': {
              'maxTokens': {'type': 'integer', 'description': '输出预算'},
              'temperature': {'type': 'number', 'description': '采样温度'},
              'responseFormat': {
                'type': 'object',
                'description': '约束解码规格 {type: json|regex, value}；'
                    '云端路由下声明即显式拒服务',
              },
            },
          },
        },
        'required': ['instruction', 'input'],
      },
    };
  }

  @override
  Future<ToolExecutionResult> execute(
    AssembledToolCall call, {
    String? callerKeyOverride,
  }) async {
    if (call.name != toolName) return inner.execute(call);
    final Object? args;
    try {
      args = jsonDecode(call.argumentsJson);
    } on FormatException catch (e) {
      return ToolExecutionResult(content: '参数不是合法 JSON: $e', isError: true);
    }
    if (args is! Map) {
      return const ToolExecutionResult(content: '参数必须是 JSON 对象', isError: true);
    }
    final instruction = args['instruction'];
    final input = args['input'];
    if (instruction is! String || instruction.trim().isEmpty) {
      return const ToolExecutionResult(content: '缺少 instruction（任务指令）', isError: true);
    }
    if (input is! String) {
      return const ToolExecutionResult(content: '缺少 input（待处理文本）', isError: true);
    }
    final cfg = AiCompleteConfig.fromParams(args['config']);
    try {
      final out = await AiCompleteService.instance.completeCore(
        instruction: instruction,
        input: input,
        maxTokens: cfg.maxTokens,
        temperature: cfg.temperature,
      );
      return ToolExecutionResult(
          content: jsonEncode({'text': out.text, 'model': out.model}));
    } on AiCompleteFailure catch (e) {
      // 结构化失败透出（十二码 + 建议退避）——网关调用方升阶/退避自决。
      return ToolExecutionResult(
        content: jsonEncode({
          'status': e.status,
          'message': e.message,
          if (e.retryAfterMs != null) 'retry_after_ms': e.retryAfterMs,
        }),
        isError: true,
      );
    }
  }
}
