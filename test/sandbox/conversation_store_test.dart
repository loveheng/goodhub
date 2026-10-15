import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/sandbox/conversation_store.dart';

void main() {
  Future<Directory> tmpDir() =>
      Directory.systemTemp.createTemp('conversation_store_test').then((d) async {
        addTearDown(() async {
          if (await d.exists()) await d.delete(recursive: true);
        });
        return d;
      });

  group('ConversationStore CRUD（T3b）', () {
    test('create → save → 新实例 list/load：轨道与消息快照保真', () async {
      final dir = await tmpDir();
      final store = ConversationStore(dir: dir);
      final id = await store.create(title: '列出条目');

      await store.save(
        id: id,
        title: '列出条目',
        track: [
          {'type': 'user', 'text': '列出条目'},
          {'type': 'call', 'tool': 'list_items', 'phase': 'success', 'preview': 'r1'},
        ],
        messages: [
          {'type': 'user', 'content': '列出条目'},
          {
            'type': 'assistant',
            'toolCalls': [
              {'id': 'c1', 'name': 'list_items', 'argumentsJson': '{}'},
            ],
          },
          {'type': 'toolResult', 'toolCallId': 'c1', 'content': 'r1', 'isError': false},
        ],
        activePrivateServerId: null,
      );

      // 写 → 新实例 → 读回（lessons 装载坑对照形态）
      final store2 = ConversationStore(dir: dir);
      final metas = await store2.list();
      expect(metas, hasLength(1));
      expect(metas.single.id, id);
      expect(metas.single.title, '列出条目');

      final snap = await store2.load(id);
      expect(snap, isNotNull);
      expect(snap!.track, hasLength(2));
      expect(snap.track.first['type'], 'user');
      expect(snap.messages, hasLength(3));
      // 配对完整（恢复前提，§12）：assistant(toolCalls) 后随 toolResult。
      expect(snap.messages[1]['type'], 'assistant');
      expect(snap.messages[2]['type'], 'toolResult');
    });

    test('activePrivateServerId 随快照保真（绑定 / 显式公共）', () async {
      final dir = await tmpDir();
      final store = ConversationStore(dir: dir);
      final id = await store.create(title: '绑定', activePrivateServerId: 'srv_a');
      await store.save(
        id: id,
        title: '绑定',
        track: const [],
        messages: const [],
        activePrivateServerId: 'srv_a',
      );
      final snap = await ConversationStore(dir: dir).load(id);
      expect(snap?.activePrivateServerId, 'srv_a');

      // 显式公共（空串）也保真
      await store.save(
        id: id,
        title: '绑定',
        track: const [],
        messages: const [],
        activePrivateServerId: '',
      );
      final snap2 = await ConversationStore(dir: dir).load(id);
      expect(snap2?.activePrivateServerId, '');
    });

    test('私有域三态往返（B3）：null / \'\' / serverId 落盘反序列化原样无损', () async {
      // 防回归断言（window-kernel-split B3）：'' 被归并进 null 会让重启后
      // 「显式回公共」回跳成自动绑定私有（conversation_store.dart:61-63 注释 SSOT）。
      final dir = await tmpDir();
      final store = ConversationStore(dir: dir);
      final id = await store.create(title: '三态');

      // ① null（未设定，走回退链）——create 缺省即 null
      var snap = await ConversationStore(dir: dir).load(id);
      expect(snap?.activePrivateServerId, isNull);

      // ② ''（显式公共）
      await store.save(id: id, title: '三态', track: const [], messages: const [], activePrivateServerId: '');
      snap = await ConversationStore(dir: dir).load(id);
      expect(snap?.activePrivateServerId, '');

      // ③ serverId（锁定）
      await store.save(id: id, title: '三态', track: const [], messages: const [], activePrivateServerId: 'srv_x');
      snap = await ConversationStore(dir: dir).load(id);
      expect(snap?.activePrivateServerId, 'srv_x');

      // ④ 回 null（全量覆写路径同样无损）
      await store.save(id: id, title: '三态', track: const [], messages: const [], activePrivateServerId: null);
      snap = await ConversationStore(dir: dir).load(id);
      expect(snap?.activePrivateServerId, isNull);
    });

    test('updatedAt 倒序列表；delete 幂等；load 缺失返 null', () async {
      final dir = await tmpDir();
      final store = ConversationStore(dir: dir);
      final a = await store.create(title: 'A');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = await store.create(title: 'B');

      final metas = await store.list();
      expect(metas.map((m) => m.id), [b, a], reason: '新会话在前');

      await store.delete(a);
      expect(await store.load(a), isNull);
      await store.delete(a); // 幂等
      expect((await store.list()).map((m) => m.id), [b]);
    });

    test('损坏文件：list 跳过、load 返 null（禁静默吞会话——DEGRADE 留痕）', () async {
      final dir = await tmpDir();
      final store = ConversationStore(dir: dir);
      final good = await store.create(title: '正常');
      File('${dir.path}/conv_broken.json').writeAsStringSync('{"id": 截断');

      final metas = await store.list();
      expect(metas.map((m) => m.id), [good], reason: '损坏文件不进列表');

      expect(await store.load('conv_broken'), isNull);
      expect(await store.load(good), isNotNull);
    });

    test('save 空 id 拒绝（fail-fast）', () async {
      final store = ConversationStore(dir: await tmpDir());
      expect(
        () => store.save(id: '', title: 'x', track: const [], messages: const [], activePrivateServerId: null),
        throwsArgumentError,
      );
    });
  });

  group('CloudChatMessage 编解码（transcript 忠实序列化）', () {
    test('user/assistant(toolCalls)/toolResult 往返：配对与字段保真', () {
      final original = <CloudChatMessage>[
        const UserMessage('问A'),
        const AssistantMessage(content: '部分说明', toolCalls: [
          AssembledToolCall(id: 'c1', name: 'list_items', argumentsJson: '{"limit":2}'),
          AssembledToolCall(id: 'c2', name: 'query_memory', argumentsJson: '{}'),
        ]),
        const ToolResultMessage(toolCallId: 'c1', content: '结果一'),
        const ToolResultMessage(toolCallId: 'c2', content: '失败', isError: true),
        const AssistantMessage(content: '答A'),
      ];

      final decoded =
          ConversationStore.decodeMessages(ConversationStore.encodeMessages(original));

      expect(decoded, hasLength(original.length));
      final assistant = decoded[1] as AssistantMessage;
      expect(assistant.content, '部分说明');
      expect(assistant.toolCalls.map((c) => c.id), ['c1', 'c2']);
      expect(assistant.toolCalls.first.argumentsJson, '{"limit":2}');
      expect((decoded[2] as ToolResultMessage).isError, isFalse);
      expect((decoded[3] as ToolResultMessage).isError, isTrue);
      expect((decoded[4] as AssistantMessage).content, '答A');
    });

    test('未知类型/缺字段跳过不抛（DEGRADE 口径）；system 不入恢复序列', () {
      final decoded = ConversationStore.decodeMessages([
        {'type': 'user', 'content': 'ok'},
        {'type': 'mystery'},
        {'type': 'system'},
        {'type': 'toolResult', 'content': null}, // 缺 toolCallId → 缺省空串仍恢复
      ]);
      expect(decoded, hasLength(2));
      expect(decoded.first, isA<UserMessage>());
      expect(decoded.last, isA<ToolResultMessage>());
    });

    test('JSON 编码层稳定（save 落盘形状抽查）', () {
      final encoded = ConversationStore.encodeMessages([
        const UserMessage('hi'),
      ]);
      expect(jsonEncode(encoded), contains('"type":"user"'));
    });
  });
}
