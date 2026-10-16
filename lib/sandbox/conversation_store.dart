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
///   UI 模型，沙盒层只存 JSON（层级纪律：④ 不 import ⑤）；消息编解码已迁
///   llm 域（`llm/cloud/chat_message_codec.dart`，arch-hardening ④）——存储
///   层只认 JSON Map 与 core 领域消息 DTO，不感知任何 LLM 类型；
/// - 损坏文件不抛穿：list 跳过 + load 返 null，[DEGRADE] 留痕（恢复失败
///   禁静默吞会话——至少日志可查）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/storage/sequential_file_writer.dart';

/// 会话列表项（侧边栏消费）。
class ConversationMeta {
  const ConversationMeta({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.messageCount = 0,
  });

  final String id;
  final String title;

  /// epoch 毫秒（侧边栏按此倒序）。
  final int updatedAt;

  /// transcript 消息条数（ux-hardening P1-5 侧边栏元信息；旧数据缺省 0）。
  final int messageCount;
}

/// 会话快照（恢复装配消费）。
class ConversationSnapshot {
  const ConversationSnapshot({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.track,
    required this.messages,
    required this.activePrivateServerId,
  });

  final String id;
  final String title;
  final int updatedAt;

  /// 轨道条目 JSON（解码在 UI 层 TrackEntry codec）。
  final List<Map<String, Object?>> track;

  /// AgentLoop transcript JSON（[decodeMessages] 还原）。
  final List<Map<String, Object?>> messages;

  /// 本会话锁定的私有 MCP 服务（v1 会话绑定）：null=未设定（按默认回退）/
  /// ''=显式纯公共 / 否则为 serverId。
  final String? activePrivateServerId;
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
  Future<String> create({
    required String title,
    String? activePrivateServerId,
  }) async {
    await dir.create(recursive: true);
    final id = 'conv_${DateTime.now().millisecondsSinceEpoch}';
    await _writer(id).write(jsonEncode(<String, Object?>{
      'id': id,
      'title': title,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'track': <Object?>[],
      'messages': <Object?>[],
      'activePrivateServerId': activePrivateServerId,
    }));
    return id;
  }

  /// 全量重写快照（temp+rename 原子替换；每次 Run 收尾调用一次）。
  Future<void> save({
    required String id,
    required String title,
    required List<Map<String, Object?>> track,
    required List<Map<String, Object?>> messages,
    required String? activePrivateServerId,
  }) async {
    if (id.isEmpty) throw ArgumentError('conversation id 不能为空');
    await dir.create(recursive: true);
    await _writer(id).write(jsonEncode(<String, Object?>{
      'id': id,
      'title': title,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'track': track,
      'messages': messages,
      'activePrivateServerId': activePrivateServerId,
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
          messageCount: (data['messages'] as List? ?? const []).length,
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
        activePrivateServerId: data['activePrivateServerId'] as String?,
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

  /// 重命名（ux-hardening P1-5）：**只改标题**——updatedAt 原样保留（重命名
  /// 不制造「最近活跃」假象、不打乱列表序），轨道/消息/绑定不动；temp+rename
  /// 原子重写。文件缺失/损坏 → false（DEGRADE 留痕，不抛穿）。
  Future<bool> rename(String id, String title) async {
    final f = _file(id);
    try {
      if (!await f.exists()) {
        debugPrint('[DEGRADE] conversation-store: rename 目标缺失 $id');
        return false;
      }
      final data =
          jsonDecode(await f.readAsString()) as Map<String, Object?>;
      data['title'] = title;
      await _writer(id).write(jsonEncode(data));
      return true;
    } on Object catch (e) {
      debugPrint('[DEGRADE] conversation-store: rename failed $id: $e');
      return false;
    }
  }
}
