/// 会话历史持久化（M4-T3b，D10/D13 拍板）：每会话一 JSON（应用支持目录
/// `conversations/`），双轨轨道条目 + AgentLoop 会话消息同存——恢复时轨道按
/// 终态锁定呈现、messages 作 D11 `run(history:)` 续接。
///
/// - **配对完整是恢复前提**（architecture §12：assistant(tool_calls) 与
///   ToolResult 拆对即协议 400）——transcript 在 AgentLoop 出口已由
///   `_sessionTranscript` 保证配对，本存储只做忠实序列化、不再裁剪；
/// - 介质口径同记忆沙盒：SequentialFileWriter 全量重写（temp+rename 原子
///   替换）；列表 = 扫目录逐文件解析（会话数小，读放大可忽略）；
/// - 轨道条目编解码住 UI 层（dual_track_stream 静态方法）——TrackEntry 是
///   UI 模型，沙盒层只存 JSON（层级纪律：④ 不 import ⑤）；消息编解码在此
///   （CloudChatMessage 为核心纯模型）；
/// - 损坏文件不抛穿：list 跳过 + load 返 null，[DEGRADE] 留痕（恢复失败
///   禁静默吞会话——至少日志可查）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../llm/cloud/cloud_llm.dart';
import '../core/storage/sequential_file_writer.dart';

/// 会话列表项（侧边栏消费）。
class ConversationMeta {
  const ConversationMeta({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  final String id;
  final String title;

  /// epoch 毫秒（侧边栏按此倒序）。
  final int updatedAt;
}

/// 会话快照（恢复装配消费）。
class ConversationSnapshot {
  const ConversationSnapshot({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.track,
    required this.messages,
  });

  final String id;
  final String title;
  final int updatedAt;

  /// 轨道条目 JSON（解码在 UI 层 TrackEntry codec）。
  final List<Map<String, Object?>> track;

  /// AgentLoop transcript JSON（[decodeMessages] 还原）。
  final List<Map<String, Object?>> messages;
}

class ConversationStore {
  ConversationStore({required this.dir});

  /// 会话落盘目录（注入：生产 = 应用支持目录/conversations；测试 = 临时目录）。
  final Directory dir;

  static const _suffix = '.json';

  /// 生产装配入口：应用支持目录下的 `conversations` 子目录（UI 层禁 dart:io，
  /// Directory 构造收在本层——与 MemoryStore.underSupportDir 同口径）。
  factory ConversationStore.underSupportDir(String supportPath) =>
      ConversationStore(dir: Directory('$supportPath/conversations'));

  SequentialFileWriter _writer(String id) =>
      SequentialFileWriter(File('${dir.path}/$id$_suffix'));

  File _file(String id) => File('${dir.path}/$id$_suffix');

  /// 新建空会话，返回 id（epoch 毫秒锚点；同毫秒并发由目录内文件名唯一性
  /// 承担——单页会话操作串行，不构成现实竞态）。
  Future<String> create({required String title}) async {
    await dir.create(recursive: true);
    final id = 'conv_${DateTime.now().millisecondsSinceEpoch}';
    await _writer(id).write(jsonEncode(<String, Object?>{
      'id': id,
      'title': title,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'track': <Object?>[],
      'messages': <Object?>[],
    }));
    return id;
  }

  /// 全量重写快照（temp+rename 原子替换；每次 Run 收尾调用一次）。
  Future<void> save({
    required String id,
    required String title,
    required List<Map<String, Object?>> track,
    required List<Map<String, Object?>> messages,
  }) async {
    if (id.isEmpty) throw ArgumentError('conversation id 不能为空');
    await dir.create(recursive: true);
    await _writer(id).write(jsonEncode(<String, Object?>{
      'id': id,
      'title': title,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'track': track,
      'messages': messages,
    }));
  }

  /// 会话列表（updatedAt 倒序；损坏文件跳过留痕）。
  Future<List<ConversationMeta>> list() async {
    if (!await dir.exists()) return [];
    final metas = <ConversationMeta>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith(_suffix)) continue;
      try {
        final data =
            jsonDecode(await entity.readAsString()) as Map<String, Object?>;
        metas.add(ConversationMeta(
          id: data['id'] as String,
          title: data['title'] as String? ?? '（无标题）',
          updatedAt: data['updatedAt'] as int? ?? 0,
        ));
      } on Object catch (e) {
        debugPrint('[DEGRADE] conversation-store: 列表解析失败 '
            '${entity.uri.pathSegments.last}: $e');
      }
    }
    metas.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return metas;
  }

  /// 加载快照；文件缺失/损坏 → null（损坏 DEGRADE 留痕，调用方出可观测提示）。
  Future<ConversationSnapshot?> load(String id) async {
    final f = _file(id);
    if (!await f.exists()) return null;
    try {
      final data = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      return ConversationSnapshot(
        id: data['id'] as String? ?? id,
        title: data['title'] as String? ?? '（无标题）',
        updatedAt: data['updatedAt'] as int? ?? 0,
        track: [
          for (final e in data['track'] as List? ?? const [])
            if (e is Map) Map<String, Object?>.from(e),
        ],
        messages: [
          for (final m in data['messages'] as List? ?? const [])
            if (m is Map) Map<String, Object?>.from(m),
        ],
      );
    } on Object catch (e) {
      debugPrint('[DEGRADE] conversation-store: 会话损坏无法恢复 $id: $e');
      return null;
    }
  }

  /// 删除会话（文件缺失幂等）。
  Future<void> delete(String id) async {
    final f = _file(id);
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      // DEGRADE: 单文件删除失败不阻断列表刷新（下次删除重试），留痕。
      debugPrint('[DEGRADE] conversation-store: delete failed $id: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // CloudChatMessage 编解码（transcript 忠实序列化；System 不入 transcript）
  // ---------------------------------------------------------------------------

  static List<Map<String, Object?>> encodeMessages(
          List<CloudChatMessage> messages) =>
      [
        for (final m in messages)
          switch (m) {
            UserMessage(:final content) =>
              <String, Object?>{'type': 'user', 'content': content},
            AssistantMessage(:final content, :final toolCalls) =>
              <String, Object?>{
                'type': 'assistant',
                'content': ?content,
                'toolCalls': [
                  for (final c in toolCalls)
                    <String, Object?>{
                      'id': c.id,
                      'name': c.name,
                      'argumentsJson': c.argumentsJson,
                    },
                ],
              },
            ToolResultMessage(:final toolCallId, :final content, :final isError) =>
              <String, Object?>{
                'type': 'toolResult',
                'toolCallId': toolCallId,
                'content': content,
                'isError': isError,
              },
            SystemMessage() => const <String, Object?>{
                'type': 'system',
              }, // transcript 口径不含 System——防御编码，恢复侧跳过
          },
      ];

  /// 恢复消息序列：未知类型/缺字段跳过并 DEGRADE 留痕（禁静默吞——计数可观测
  /// 由调用方对账）；恢复后 assistant/toolCalls 配对由 AgentLoop 出口保证，
  /// 此处不重排。
  static List<CloudChatMessage> decodeMessages(List<Map<String, Object?>> raw) {
    final out = <CloudChatMessage>[];
    var skipped = 0;
    for (final m in raw) {
      try {
        switch (m['type']) {
          case 'user':
            out.add(UserMessage(m['content'] as String? ?? ''));
          case 'assistant':
            out.add(AssistantMessage(
              content: m['content'] as String?,
              toolCalls: [
                for (final c in m['toolCalls'] as List? ?? const [])
                  if (c is Map)
                    AssembledToolCall(
                      id: c['id'] as String? ?? '',
                      name: c['name'] as String? ?? '',
                      argumentsJson: c['argumentsJson'] as String? ?? '{}',
                    ),
              ],
            ));
          case 'toolResult':
            out.add(ToolResultMessage(
              toolCallId: m['toolCallId'] as String? ?? '',
              content: m['content'] as String? ?? '',
              isError: m['isError'] as bool? ?? false,
            ));
          case 'system':
            break; // transcript 口径不含 System
          default:
            skipped++;
        }
      } on Object {
        skipped++;
      }
    }
    if (skipped > 0) {
      debugPrint('[DEGRADE] conversation-store: 消息恢复跳过 $skipped 条（类型未知/缺字段）');
    }
    return out;
  }
}
