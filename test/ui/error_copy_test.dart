/// ux-hardening P0-2：异常 → 白话文案映射（纯函数，不触 Flutter 绑定）。
/// 口径：标题说清「发生了什么」，建议只给「下一步做什么」，不暴露引擎/
/// 端点/协议内部名词；未命中类型走兜底。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/cloud_llm_error.dart';
import 'package:goodhub/core/errors/inference_error.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/coordinator/context_governor.dart';
import 'package:goodhub/coordinator/fenced_cloud_engine.dart';
import 'package:goodhub/coordinator/pii_fence.dart';
import 'package:goodhub/ui/error_copy.dart';

void main() {
  test('CloudHttpException 按状态码分流：401 指向密钥、429 限流、5xx 服务故障',
      () {
    expect(
      humanizeError(const CloudHttpException('x', statusCode: 401)).title,
      '推理服务拒绝了访问凭证',
    );
    expect(
      humanizeError(const CloudHttpException('x', statusCode: 403)).advice,
      contains('API Key'),
      reason: '客户端侧鉴权错误：建议落在密钥可自查的落点',
    );
    expect(
      humanizeError(const CloudHttpException('x', statusCode: 429)).title,
      '请求太频繁，被服务方限流',
    );
    final s5 = humanizeError(const CloudHttpException('x', statusCode: 503));
    expect(s5.title, contains('503'));
    expect(s5.advice, contains('换一个端点'));
    expect(
      humanizeError(const CloudHttpException('x')).title,
      '推理服务返回了错误',
      reason: '流内 error 事件无状态码 → 通用云端错误',
    );
  });

  test('传输层：网络/超时各有白话；未命中走兜底且仍指重试', () {
    expect(
      humanizeError(const CloudNetworkException('reset')).title,
      '连不上推理服务',
    );
    expect(humanizeError(TimeoutException('t')).title, '等待响应超时');
    expect(humanizeError(const SocketException('refused')).title, '网络不通');
    expect(humanizeError(const HttpException('bad')).title, '网络请求失败');
    final unknown = humanizeError(Exception('boom'));
    expect(unknown.title, '任务意外中断');
    expect(unknown.advice, contains('重试'));
  });

  test('InferenceException：步数墙两路径特判 + 通用推理中断', () {
    expect(
      humanizeError(const InferenceException('步数墙触发：连续 12 轮工具调用未收尾'))
          .title,
      '工具调用步数已达上限',
    );
    expect(
      humanizeError(const InferenceException('步数墙终止：12 轮未收尾，用户选择终止'))
          .title,
      '任务已在步数墙处终止',
      reason: '用户主动终止不是故障——标题不得呈现为错误',
    );
    expect(
      humanizeError(const InferenceException('推理产出为空（引擎：qwen）')).title,
      '模型推理中断',
    );
  });

  test('步数墙（MCP 层 TurnWallExceeded）与通信失败分流', () {
    expect(
      humanizeError(const TurnWallExceeded('超限')).title,
      '工具调用步数已达上限',
    );
    expect(
      humanizeError(const McpNetworkException('refused')).title,
      'MCP 服务通信失败',
    );
  });

  test('安全管线与 MCP 层各有归因（标题不暴露内部名词）', () {
    expect(
      humanizeError(const PiiSendBlockedException('用户取消发送')).title,
      contains('敏感信息'),
    );
    expect(
      humanizeError(const PiiMaskException('遮蔽超时')).title,
      '敏感信息处理失败',
    );
    expect(
      humanizeError(const SummarizeException('产出为空')).title,
      '上下文摘要失败',
    );
  });
}
