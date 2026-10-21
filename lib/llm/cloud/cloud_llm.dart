/// 云端 BYOK LLM 引擎契约与数据模型（M2-T1，architecture §2 混合推理编排）。
///
/// 与端侧 OnDeviceLlmEngine（lib/llm/llm.dart，单发提取式）相对：
/// 云端引擎承担 Agent Loop 主环的对话式推理——多轮消息、工具 Schema 下发、
/// 流式产出（正文 token 与 tool_calls 分离）、finish_reason 结算
/// （§10「L2 拦截即结算流」的地基）。
///
/// 流式契约（实现必须满足）：
/// - 每个 send 流**恰好产出一个** [CloudDone]；
/// - 协议/传输失败以 [CloudLlmException] 子类作为流的错误终止，禁裸异常穿透；
/// - 取消 = 调用方 cancel 流订阅（§10 Abort 级联①步的云端路径，T2 接线）。
library;

import '../../core/tool_visibility.dart';

/// BYOK 协议族。openaiCompatible 一套覆盖 OpenAI / DeepSeek / Qwen
/// （DashScope compatible-mode）——差异仅 BaseURL 与模型名。
enum CloudProtocol { openaiCompatible, anthropic }

/// 结算原因（跨协议归一）。
enum CloudFinishReason {
  /// 自然结束（OpenAI 'stop' / Anthropic 'end_turn'/'stop_sequence'）。
  stop,

  /// 要求执行工具后继续（OpenAI 'tool_calls' / Anthropic 'tool_use'）。
  toolCalls,

  /// 输出触达 token 上限。
  length,

  /// 内容安全拦截（OpenAI 'content_filter'）。
  contentFilter,

  /// 未识别的收尾原因（原样保底，禁丢弃——审计可见）。
  other;

  static CloudFinishReason fromOpenAi(String raw) => switch (raw) {
        'stop' => stop,
        'tool_calls' => toolCalls,
        'length' => length,
        'content_filter' => contentFilter,
        _ => other,
      };

  static CloudFinishReason fromAnthropic(String raw) => switch (raw) {
        'end_turn' || 'stop_sequence' => stop,
        'tool_use' => toolCalls,
        'max_tokens' => length,
        _ => other,
      };
}

/// 完整工具调用（流式 delta 拼接后的成品，见 tool_call_accumulator.dart）。
class AssembledToolCall {
  const AssembledToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;

  /// 工具入参原文（JSON 字符串）。解码交由 T2 执行环——网关校验在前，decode 在后。
  final String argumentsJson;
}

/// Token 用量（可缺省：部分兼容端不下发 usage）。
class CloudUsage {
  const CloudUsage({required this.promptTokens, required this.completionTokens});

  final int promptTokens;
  final int completionTokens;
}

/// Prompt Caching 断点标记（P1-3 / SSOT §8.1）：Anthropic 显式
/// `cache_control:{"type":"ephemeral"}`；OpenAI / DeepSeek 等自动前缀命中
/// 的 provider 忽略该字段（发字段会 400，客户端不得序列化）。
enum CacheControl { ephemeral }

/// 会话消息（协议无关形状，各客户端自行映射到 OpenAI/Anthropic 线格式）。
sealed class CloudChatMessage {
  const CloudChatMessage({this.cacheControl});

  /// 缓存断点标记（null = 无断点）。Anthropic：挂到该消息对应内容块；
  /// 单请求断点总数硬性 ≤3（护栏见 anthropic_chat_client）。
  final CacheControl? cacheControl;
}

class SystemMessage extends CloudChatMessage {
  const SystemMessage(this.content, {super.cacheControl});

  final String content;
}

class UserMessage extends CloudChatMessage {
  const UserMessage(this.content, {super.cacheControl});

  final String content;
}

/// 助手消息：纯文本，或（Agent Loop 多轮态）带成品 tool_calls 的结算消息。
class AssistantMessage extends CloudChatMessage {
  const AssistantMessage({this.content, this.toolCalls = const [], super.cacheControl});

  final String? content;
  final List<AssembledToolCall> toolCalls;
}

/// 工具执行结果回传（OpenAI role=tool / Anthropic tool_result 块）。
class ToolResultMessage extends CloudChatMessage {
  const ToolResultMessage({
    required this.toolCallId,
    required this.content,
    this.isError = false,
  });

  final String toolCallId;
  final String content;

  /// Anthropic 专用标记（is_error）；OpenAI 侧错误以 content 文本表达。
  final bool isError;
}

/// 下发给模型的工具声明（MCP tools/list Schema 直通形状）。
class CloudToolSchema {
  const CloudToolSchema({
    required this.name,
    required this.description,
    required this.parametersSchema,
    this.annotations,
    this.meta,
    this.visibility = ToolVisibility.private,
  });

  final String name;
  final String description;

  /// JSON Schema 对象（`{"type":"object","properties":{...}}`）。
  final Map<String, Object?> parametersSchema;

  /// MCP annotations 原文（如 readOnlyHint）——客户端权限网关的建议值源，
  /// 不进云端请求序列化（客户端本地裁决用，见 coordinator/permission_gateway）。
  /// **可能整体缺席**：hints 是选择性下发（SDK 0.2.0），缺席 ≠ 有副作用，
  /// 严禁拿「有没有 annotations / 里面有没有字段」当判据。
  final Map<String, Object?>? annotations;

  /// MCP `_meta` 原文（GoodHub 私有子树 `goodhub` 等）——客户端本地消费
  /// （可见性标记与后续正交维度的唯一来源），不进云端请求序列化。
  final Map<String, Object?>? meta;

  /// 工具可见性范围（SDK 0.2.0 声明式标记）：由 `meta["goodhub"]["visibility"]`
  /// 解析；缺失 / 形状异常 / 取值未知 = [ToolVisibility.private]（default-deny）。
  ///
  /// **声明而非访问控制**：private 工具在本机链路照常发现与调用，只是不进
  /// 共享目录 / 不向外部 Agent 暴露。
  final ToolVisibility visibility;

  /// 可否进共享目录 / 对外暴露（[ToolVisibility.shared]）。
  bool get isShared => visibility == ToolVisibility.shared;

  /// 规范云端序列化（G5 / SSOT §8.2，前缀缓存命中的隐藏前提）：
  /// ① 一级键插入序固定 `name → description → input_schema`（Dart jsonEncode
  ///    保 Map 插入序，装配序固定即字节稳定）；
  /// ② `parametersSchema` 经 [canonicalParameters] 递归字典序归一——上游 MCP
  ///    返回的 Map 键序不可控，不归一则单条 schema 字节流不恒定、工具缓存即碎；
  /// ③ [annotations] 不进云端序列化（仅本地裁决用）；
  /// ④ [meta] / [visibility] 同 ③——纯客户端组织依据，不下发给模型。
  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'description': description,
        'input_schema': canonicalParameters(parametersSchema),
      };

  /// 递归按 key 字典序归一 JSON Schema（Map 键全排序；List 保序——
  /// `required` / `enum` 等数组语义有序，不可乱序）。
  static Map<String, Object?> canonicalParameters(Map<String, Object?> schema) =>
      _sortDeep(schema) as Map<String, Object?>;

  static Object? _sortDeep(Object? v) => switch (v) {
        final Map m => <String, Object?>{
            for (final k in m.keys.map((k) => k as String).toList()..sort())
              k: _sortDeep(m[k]),
          },
        final List l => [for (final e in l) _sortDeep(e)],
        _ => v,
      };
}

/// 一次对话推理请求。
class CloudChatRequest {
  const CloudChatRequest({
    required this.messages,
    this.tools = const [],
    this.temperature,
    this.maxTokens,
  });

  final List<CloudChatMessage> messages;
  final List<CloudToolSchema> tools;
  final double? temperature;

  /// 输出上限 token。OpenAI 可省略；Anthropic 必填（客户端兜协议缺省）。
  final int? maxTokens;
}

/// 流式事件：正文 token 与 tool_calls 分离（architecture §2）。
sealed class CloudStreamEvent {
  const CloudStreamEvent();
}

class CloudTextDelta extends CloudStreamEvent {
  const CloudTextDelta(this.text);

  final String text;
}

/// 思考过程增量（2026-10-21，M1：OpenAI 兼容侧 `reasoning_content`）。
///
/// **展示 only 契约**：只透传至 UI 思考轨（默认收起），四不——
/// ① 不进 [CloudStreamAccumulator]（不入历史/不参与空产出判定）；
/// ② 不过 [WorkspaceStreamFilter]（In-band 提取 FSM 只解析正文）；
/// ③ 不进 transcript（下轮发送不回放思考——多数 API 不接受且烧 token）；
/// ④ 不置 `sawOutput`（「思维链烧光预算零正文」的空产出防护不被打穿）。
/// 端侧引擎与 Anthropic 侧（M2）暂不产出本事件，UI 须容忍缺席。
class CloudThinkingDelta extends CloudStreamEvent {
  const CloudThinkingDelta(this.text);

  final String text;
}

/// 工具调用增量：按 [index] 拼接；id/name 仅在首个增量出现，
/// [argumentsDelta] 逐片追加（JSON 字符串片段）。
class CloudToolCallDelta extends CloudStreamEvent {
  const CloudToolCallDelta({
    required this.index,
    this.id,
    this.name,
    this.argumentsDelta = '',
  });

  final int index;
  final String? id;
  final String? name;
  final String argumentsDelta;
}

/// 结算事件：finish_reason 落定，每流恰好一次（缺失 = 协议违规）。
class CloudDone extends CloudStreamEvent {
  const CloudDone({required this.finishReason, this.usage});

  final CloudFinishReason finishReason;
  final CloudUsage? usage;
}

/// 云端引擎接口（协议无关）。实现见 openai_chat_client.dart /
/// anthropic_chat_client.dart；装配入口 byok_store.dart [engineFor]。
abstract interface class CloudLlmEngine {
  /// 实现名（日志 / 设置页展示）。
  String get name;

  /// 流式对话推理。懒执行：监听时才发起请求。
  ///
  /// [onActivity]：可选的传输层活体回调——底层每收到一帧字节（含 SSE 心跳
  /// 注释帧）即触发，用于流健康判定（连接是否还活着），不参与工作推进语义
  /// （D2 正交：心跳 ≠ 进度证据）。
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  });
}
