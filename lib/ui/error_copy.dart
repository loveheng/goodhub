/// 错误文案白话翻译（ux-hardening P0-2）：领域异常 → 用户可读的「标题 +
/// 建议」。纯函数集中收敛 UI copy——单测直测映射，页面只负责渲染；
/// 原始异常始终随错误卡留痕（可复制），翻译不吞信息。
///
/// 覆盖 lib/core/errors/ 三族（inference / cloud_llm / mcp）+ 传输层超时
/// 与网络异常；未命中走通用兜底。文案口径：标题说清「发生了什么」，建议
/// 只给「下一步做什么」，不暴露引擎/端点/协议内部名词。
library;

import 'package:flutter/services.dart' show PlatformException;

import '../core/errors/cloud_llm_error.dart';
import '../core/errors/inference_error.dart';
import '../core/errors/mcp_error.dart';
import '../core/errors/transport_error_kind.dart';
import '../coordinator/context_governor.dart';
import '../coordinator/fenced_cloud_engine.dart';
import '../coordinator/pii_fence.dart';

/// 翻译产物：标题（一句话）+ 建议（下一步）。
class ErrorCopy {
  const ErrorCopy(this.title, this.advice);

  final String title;
  final String advice;
}

/// 异常 → 白话文案。类型未命中时兜底（保原始异常留痕由调用方负责）。
ErrorCopy humanizeError(Object error) {
  switch (error) {
    // —— 云端推理（CloudLlmException 族，lib/core/errors/cloud_llm_error.dart）——
    case CloudHttpException(:final statusCode):
      // 流内 error 事件无状态码（null）→ 通用云端错误；有码才谈分流。
      if (statusCode == null) {
        return const ErrorCopy(
            '推理服务返回了错误', '重试；持续失败可到设置页检查端点配置');
      }
      return switch (statusCode) {
        401 || 403 => const ErrorCopy('推理服务拒绝了访问凭证',
            '到设置页检查该端点的 API Key 是否有效，然后重试'),
        429 => const ErrorCopy(
            '请求太频繁，被服务方限流', '等一分钟左右再重试'),
        >= 500 => ErrorCopy(
            '推理服务暂时不可用（$statusCode）', '对方服务在故障中，稍后重试；持续失败可在设置页换一个端点'),
        _ => const ErrorCopy(
            '推理服务返回了错误', '重试；持续失败可到设置页检查端点配置'),
      };
    case CloudNetworkException():
      return const ErrorCopy(
          '连不上推理服务', '检查网络连接与端点地址是否可达，然后重试');
    case CloudProtocolException():
      return const ErrorCopy(
          '推理服务的响应不符合协议', '重试；持续失败请更新应用或联系服务提供方');

    // —— 端侧/混合推理（inference_error.dart）——
    case InferenceException(:final message):
      // 步数墙两条路径的文案来自 agent_loop 自身抛出点（精确子串匹配自有
      // 代码，非猜测）；其余推理异常统一兜底。
      if (message.contains('用户选择终止')) {
        return const ErrorCopy('任务已在步数墙处终止', '可重新发送任务继续；把任务拆小更易一次完成');
      }
      if (message.contains('步数墙触发')) {
        return const ErrorCopy(
            '工具调用步数已达上限', '重试，或把任务拆成更小的几步');
      }
      return const ErrorCopy('模型推理中断', '重试；换个更明确的说法通常有效');

    // —— 安全与摘要管线（coordinator 抛出，UI 消费）——
    case PiiSendBlockedException():
      return const ErrorCopy(
          '含敏感信息的发送已被拦截', '按围栏拦截卡的选择操作，或修改内容后重试');
    case PiiMaskException():
      return const ErrorCopy('敏感信息处理失败', '重试；持续失败可新建会话避开当前上下文');
    case SummarizeException():
      return const ErrorCopy('上下文摘要失败', '重试；可新建会话减轻上下文负担');

    // —— MCP 协议层（mcp_error.dart）——
    case TurnWallExceeded():
      return const ErrorCopy(
          '工具调用步数已达上限', '重试，或把任务拆成更小的几步');
    case McpException():
      return const ErrorCopy(
          'MCP 服务通信失败', '到设置页检查服务端点状态，然后重试');

    // —— 平台通道（flutter/services，非平台污染）——
    case PlatformException():
      return const ErrorCopy('系统功能调用失败', '重试；持续失败可重启应用');

    // —— 传输层：dart:io 具名类型由 core 判定（UI 禁 dart:io），本层只认枚举 ——
    // —— 兜底：不猜，交给留痕的原始异常 ——
    default:
      return switch (classifyTransportError(error)) {
        TransportErrorKind.timeout =>
          const ErrorCopy('等待响应超时', '检查网络后重试'),
        TransportErrorKind.socket =>
          const ErrorCopy('网络不通', '检查网络连接后重试'),
        TransportErrorKind.http =>
          const ErrorCopy('网络请求失败', '检查网络后重试'),
        _ => const ErrorCopy(
            '任务意外中断', '重试；若反复出现可反馈（错误详情可复制）'),
      };
  }
}
