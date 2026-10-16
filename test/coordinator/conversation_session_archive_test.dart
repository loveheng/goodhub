/// 步 0 · 单测前移（archive-memory-claim，设计稿 §3）：**先断言后实现**——
/// ConversationArchive 立核前，先钉住「Session 态 → ConversationStore 落盘 →
/// 回读 → Session 恢复」的等价性，防步 1 落盘返工。
///
/// 口径（评估裁决）：`ConversationSession.toJson/fromJson` 保持只立签名，
/// **不做**全量 session 持久化——落盘格式由 `ConversationStore` 定义（§7.5），
/// 激活集跨会话重开（§15）。故本文件的等价性断言走持久化真实路径：
/// `encodeMessages` + `save` → `load` + `decodeMessages`。
///
/// 三态绑定 SSOT：null=未绑定 / ''=显式公共 / id=锁定
/// （`conversation_store.dart:61-63` 注释，'' 被归并进 null 即回归）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/cloud/chat_message_codec.dart';
import 'package:goodhub/sandbox/conversation_store.dart';

void main() {
  Future<Directory> tmpDir() =>
      Directory.systemTemp.createTemp('session_archive_equiv_test').then((d) async {
        addTearDown(() async {
          if (await d.exists()) await d.delete(recursive: true);
        });
        return d;
      });

  group('Session ↔ Archive 持久化路径等价（步 0）', () {
    test('transcript + 绑定：session 落盘 → 新 store 回读 → 新 session 恢复逐字段一致', () async {
      final store = ConversationStore(dir: await tmpDir());
      final id = await store.create(title: '等价性', activePrivateServerId: 'srv_a');

      final session = ConversationSession()
        ..bindPrivateServer('srv_a')
        ..replaceTranscript([
          const UserMessage('列出条目'),
          const AssistantMessage(content: '好的，调用工具', toolCalls: [
            AssembledToolCall(id: 'c1', name: 'list_items', argumentsJson: '{"limit":2}'),
          ]),
          const ToolResultMessage(toolCallId: 'c1', content: 'r1', isError: false),
          const AssistantMessage(content: '共 2 条'),
        ]);

      // 落盘（Run 收尾语义：encodeMessages + save）
      await store.save(
        id: id,
        title: '等价性',
        track: const [],
        messages: ChatMessageCodec.encodeCloud(session.transcript),
        activePrivateServerId: session.activePrivateServerId,
      );

      // 恢复（新实例新 session：切换/重启语义）
      final restored = ConversationSession();
      final snap = await ConversationStore(dir: store.dir).load(id);
      expect(snap, isNotNull);
      restored
        ..bindPrivateServer(snap!.activePrivateServerId)
        ..replaceTranscript(ChatMessageCodec.decodeCloud(snap.messages));

      // 等价断言：绑定三态值一致
      expect(restored.activePrivateServerId, session.activePrivateServerId);
      // 等价断言：transcript 逐条逐字段（CloudChatMessage 无值等价 ==，按字段比）
      expect(restored.transcript, hasLength(session.transcript.length));
      final orig = session.transcript.toList();
      final back = restored.transcript.toList();
      expect(back[0] as UserMessage, isA<UserMessage>());
      expect((back[0] as UserMessage).content, (orig[0] as UserMessage).content);
      final oa = orig[1] as AssistantMessage;
      final ba = back[1] as AssistantMessage;
      expect(ba.content, oa.content);
      expect(ba.toolCalls.map((c) => c.id), oa.toolCalls.map((c) => c.id));
      expect(ba.toolCalls.map((c) => c.name), oa.toolCalls.map((c) => c.name));
      expect(ba.toolCalls.map((c) => c.argumentsJson),
          oa.toolCalls.map((c) => c.argumentsJson));
      final ot = orig[2] as ToolResultMessage;
      final bt = back[2] as ToolResultMessage;
      expect(bt.toolCallId, ot.toolCallId);
      expect(bt.content, ot.content);
      expect(bt.isError, ot.isError);
      expect((back[3] as AssistantMessage).content, (orig[3] as AssistantMessage).content);
    });

    test('绑定三态经 session 往返无损（null / \'\' / serverId）', () async {
      final store = ConversationStore(dir: await tmpDir());
      final id = await store.create(title: '三态·session');

      Future<String?> roundtrip(String? bound) async {
        final session = ConversationSession()..bindPrivateServer(bound);
        await store.save(
          id: id,
          title: '三态·session',
          track: const [],
          messages: ChatMessageCodec.encodeCloud(session.transcript),
          activePrivateServerId: session.activePrivateServerId,
        );
        final snap = await ConversationStore(dir: store.dir).load(id);
        return snap?.activePrivateServerId;
      }

      expect(await roundtrip(null), isNull, reason: '未绑定走回退链');
      expect(await roundtrip(''), '', reason: '显式公共不得归并进 null（SSOT）');
      expect(await roundtrip('srv_x'), 'srv_x');
    });

    test('空 transcript 新会话往返：恢复为空而非 null/异常', () async {
      final store = ConversationStore(dir: await tmpDir());
      final id = await store.create(title: '空会话');

      final session = ConversationSession(); // 未绑私有、无 transcript
      await store.save(
        id: id,
        title: '空会话',
        track: const [],
        messages: ChatMessageCodec.encodeCloud(session.transcript),
        activePrivateServerId: session.activePrivateServerId,
      );

      final restored = ConversationSession();
      final snap = await ConversationStore(dir: store.dir).load(id);
      expect(snap, isNotNull);
      restored
        ..bindPrivateServer(snap!.activePrivateServerId)
        ..replaceTranscript(ChatMessageCodec.decodeCloud(snap.messages));
      expect(restored.transcript, isEmpty);
      expect(restored.activePrivateServerId, isNull);
    });

    test('恢复侧跳过 system/未知类型（防御编码口径），不破坏配对恢复', () async {
      final decoded = ChatMessageCodec.decodeCloud([
        {'type': 'system'},
        {'type': 'user', 'content': '问'},
        {'type': 'assistant', 'toolCalls': [
          {'id': 'c1', 'name': 't', 'argumentsJson': '{}'},
        ]},
        {'type': 'toolResult', 'toolCallId': 'c1', 'content': 'r', 'isError': false},
        {'type': 'mystery'},
      ]);
      expect(decoded, hasLength(3));
      expect(decoded.first, isA<UserMessage>());
      final assistant = decoded[1] as AssistantMessage;
      expect(assistant.toolCalls.single.id, 'c1');
      expect((decoded.last as ToolResultMessage).toolCallId, 'c1');
    });
  });
}
