/// ConversationArchive 内核单测（archive-memory-claim 步 1，设计稿 §3 步 1）：
/// save 组装等价性 + 懒建/标题策略 + 失败不抛穿 + 删除/重置。
///
/// 往返等价性断言（session ↔ store）已在步 0
/// `conversation_session_archive_test.dart` 立门禁，本文件不重复——这里钉
/// Archive 门面自身的编排语义。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/conversation_archive.dart';
import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/core/security/secure_key_value.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/cloud/chat_message_codec.dart';
import 'package:goodhub/mcp/sampling.dart';
import 'package:goodhub/sandbox/conversation_store.dart';

/// save 抛异常的故障 store（DEGRADE 不抛穿口径的注入探针）。
class _FailingStore extends ConversationStore {
  _FailingStore(Directory dir) : super(dir: dir);

  @override
  Future<void> save({
    required String id,
    required String title,
    required List<Map<String, Object?>> track,
    required List<Map<String, Object?>> messages,
    required String? activePrivateServerId,
  }) async => throw const FileSystemException('模拟落盘失败');
}

void main() {
  Future<Directory> tmpDir() => Directory.systemTemp
      .createTemp('conversation_archive_test')
      .then((d) async {
        addTearDown(() async {
          if (await d.exists()) await d.delete(recursive: true);
        });
        return d;
      });

  group('标题截取策略', () {
    test('首行截取；超 20 字符加省略号', () {
      expect(ConversationArchive.titleFrom('列出条目\n第二行'), '列出条目');
      expect(ConversationArchive.titleFrom('a' * 21), '${'a' * 20}…');
      expect(ConversationArchive.titleFrom('a' * 20), 'a' * 20);
    });
  });

  group('重命名（ux-hardening P1-5）', () {
    test('当前会话重命名同步 currentTitle（防 saveCurrent 覆盖回旧标题）', () async {
      final archive = ConversationArchive(
        ConversationStore(dir: await tmpDir()),
      );
      await archive.ensureCurrent(prompt: '第一个问题');
      final id = archive.currentId!;

      expect(await archive.rename(id, '重命名后的标题'), isTrue);
      expect(
        archive.currentTitle,
        '重命名后的标题',
        reason: '当前会话同名——内核同步，防下次 saveCurrent 写回旧标题',
      );

      // 落一盘快照验证：标题应是新标题（不被覆盖）。
      await archive.saveCurrent(
        trackJson: const [],
        session: ConversationSession(),
      );
      final snap = await archive.load(id);
      expect(snap!.title, '重命名后的标题');
    });

    test('非当前会话重命名不动 currentTitle', () async {
      final archive = ConversationArchive(
        ConversationStore(dir: await tmpDir()),
      );
      await archive.ensureCurrent(prompt: '当前会话');
      // 目标缺失 → false，但 currentTitle 不受影响（不抛穿）。
      expect(await archive.rename('conv_missing', '别的标题'), isFalse);
      expect(archive.currentTitle, '当前会话');
    });
  });

  group('ensureCurrent 懒建', () {
    test('首个任务建会话；重复调用不新建；空标题采纳新 prompt', () async {
      final archive = ConversationArchive(
        ConversationStore(dir: await tmpDir()),
      );
      expect(archive.hasCurrent, isFalse);

      await archive.ensureCurrent(prompt: '第一个问题');
      final id1 = archive.currentId;
      expect(id1, isNotNull);
      expect(archive.currentTitle, '第一个问题');

      await archive.ensureCurrent(prompt: '第二个问题');
      expect(archive.currentId, id1, reason: '同会话内不重复懒建');
      expect(archive.currentTitle, '第一个问题', reason: '已有标题不覆盖');

      // 恢复态标题为空的兜底口径（adopt 后标题非空，reset 后重开）
      archive.resetCurrent();
      await archive.ensureCurrent(prompt: '新会话标题');
      expect(archive.currentId, isNot(id1));
      expect(archive.currentTitle, '新会话标题');
    });
  });

  group('saveCurrent 组装', () {
    test('session transcript 编码 + 绑定三态组装，经新实例回读等价', () async {
      final dir = await tmpDir();
      final archive = ConversationArchive(ConversationStore(dir: dir));
      await archive.ensureCurrent(prompt: '等价性');

      final session = ConversationSession()
        ..bindPrivateServer('srv_a')
        ..replaceTranscript([
          const UserMessage('问'),
          const AssistantMessage(
            content: '答',
            toolCalls: [
              AssembledToolCall(id: 'c1', name: 't', argumentsJson: '{}'),
            ],
          ),
          const ToolResultMessage(
            toolCallId: 'c1',
            content: 'r',
            isError: false,
          ),
        ]);

      final ok = await archive.saveCurrent(
        trackJson: [
          {'type': 'user', 'text': '问'},
        ],
        session: session,
      );
      expect(ok, isTrue);

      // 新实例回读：messages 已按 ConversationStore 格式编码，可直接 decode
      final snap = await ConversationArchive(ConversationStore(dir: dir))
          .load(archive.currentId!);
      expect(snap, isNotNull);
      expect(snap!.title, '等价性');
      expect(snap.activePrivateServerId, 'srv_a');
      expect(snap.track, hasLength(1));
      final messages = ChatMessageCodec.decodeCloud(snap.messages);
      expect(messages, hasLength(3));
      expect(messages.first, isA<UserMessage>());
    });

    test('无当前会话：no-op 返 true（原替身早退口径）', () async {
      final archive = ConversationArchive(
        ConversationStore(dir: await tmpDir()),
      );
      expect(
        await archive.saveCurrent(
          trackJson: const [],
          session: ConversationSession(),
        ),
        isTrue,
      );
    });

    test('落盘失败返 false 不抛穿（DEGRADE 口径）', () async {
      final archive = ConversationArchive(_FailingStore(await tmpDir()));
      await archive.ensureCurrent(prompt: '会失败');
      expect(
        await archive.saveCurrent(
          trackJson: const [],
          session: ConversationSession(),
        ),
        isFalse,
      );
    });
  });

  group('恢复/删除/重置', () {
    test('adoptSnapshot 设当前态；delete 幂等；load 缺失返 null', () async {
      final dir = await tmpDir();
      final archive = ConversationArchive(ConversationStore(dir: dir));
      await archive.ensureCurrent(prompt: '原会话');
      final id1 = archive.currentId!;

      archive.resetCurrent();
      expect(archive.hasCurrent, isFalse);
      expect(archive.currentTitle, '');

      final snap = await archive.load(id1);
      expect(snap, isNotNull);
      archive.adoptSnapshot(snap!);
      expect(archive.currentId, id1);
      expect(archive.currentTitle, '原会话');

      await archive.delete(id1);
      await archive.delete(id1); // 幂等
      expect(await archive.load(id1), isNull);
      expect(await archive.load('missing'), isNull);
    });
  });

  group('SamplingQuota 落盘（AM1：HMAC-SHA256 防篡改）', () {
    test('save → 新实例 load 往返：命中记录保真', () async {
      final dir = await tmpDir();
      final secure = InMemorySecureKeyValue();
      final archive = ConversationArchive(
        ConversationStore(dir: dir),
        secure: secure,
      );

      // 时刻相对 now 取（saveQuota 按真实时钟清窗，固定时刻午后跑会失效）；
      // 落盘只恢复命中记录，maxPerWindow/window 是应用级常量不随落盘走——
      // 故用默认配额扣满来验证拒绝态恢复。
      final t0 = DateTime.now();
      final quota = SamplingQuota();
      for (var i = 0; i < quota.maxPerWindow; i++) {
        expect(
          quota.tryConsume('srv_a', t0.add(Duration(minutes: i))),
          isNull,
          reason: '第 ${i + 1} 次在配额内',
        );
      }
      expect(
        quota.tryConsume('srv_a', t0.add(const Duration(minutes: 30))),
        isNotNull,
        reason: '超限被拒',
      );

      expect(await archive.saveQuota(quota), isTrue);

      final restored = await ConversationArchive(
        ConversationStore(dir: dir),
        secure: secure,
      ).loadQuota();
      expect(restored, isNotNull);
      // 配额内再扣应被拒——恢复的计数有效（杀进程重启不清零）
      expect(
        restored!.tryConsume('srv_a', t0.add(const Duration(minutes: 31))),
        isNotNull,
        reason: '杀进程重启不清零：窗口内计数恢复',
      );
    });

    test('篡改 hits 后签名不符 → null（宁可重置不信任被改数据）', () async {
      final dir = await tmpDir();
      final secure = InMemorySecureKeyValue();
      final archive = ConversationArchive(
        ConversationStore(dir: dir),
        secure: secure,
      );
      await archive.saveQuota(SamplingQuota());

      final f = File('${dir.path}/sampling_quota.json');
      final data = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      data['hits'] = <String, List<int>>{
        'srv_evil': [DateTime.now().millisecondsSinceEpoch],
      };
      await f.writeAsString(jsonEncode(data));

      expect(
        await ConversationArchive(
          ConversationStore(dir: dir),
          secure: secure,
        ).loadQuota(),
        isNull,
      );
    });

    test('换密钥（重装语义）→ 旧签名失配返 null', () async {
      final dir = await tmpDir();
      final s1 = InMemorySecureKeyValue();
      final archive = ConversationArchive(
        ConversationStore(dir: dir),
        secure: s1,
      );
      await archive.saveQuota(SamplingQuota());

      final s2 = InMemorySecureKeyValue(); // 全新密钥库
      expect(
        await ConversationArchive(
          ConversationStore(dir: dir),
          secure: s2,
        ).loadQuota(),
        isNull,
      );
    });

    test('文件缺失返 null；损坏文件返 null 不抛', () async {
      final dir = await tmpDir();
      final secure = InMemorySecureKeyValue();
      final archive = ConversationArchive(
        ConversationStore(dir: dir),
        secure: secure,
      );
      expect(await archive.loadQuota(), isNull);

      File('${dir.path}/sampling_quota.json').writeAsStringSync('{截断');
      expect(await archive.loadQuota(), isNull);
    });

    test('超窗条目不进快照', () {
      final quota = SamplingQuota(window: const Duration(minutes: 60));
      quota.tryConsume('srv', DateTime(2026, 10, 16, 10, 0));
      final snap = quota.snapshotHits(DateTime(2026, 10, 16, 11, 1)); // >60min
      expect(snap['srv'], isEmpty);
    });
  });

  group('配额文件损坏（P2-1：备份 + lastQuotaError，不再静默清零）', () {
    test('损坏 → loadQuota null + lastQuotaError + 原文件备份', () async {
      final dir = await tmpDir();
      final archive = ConversationArchive(ConversationStore(dir: dir));
      const garbage = '{ 坏掉的配额文件';
      await File('${dir.path}/sampling_quota.json').writeAsString(garbage);

      expect(await archive.loadQuota(), isNull);
      expect(archive.lastQuotaError, isNotNull);
      expect(archive.lastQuotaError, contains('损坏'));

      final backups = dir
          .listSync()
          .where((f) => f.path.contains('sampling_quota.json.corrupt-'))
          .toList();
      expect(backups, hasLength(1), reason: '损坏文件已备份——不被之后 saveQuota 无声覆盖');
      expect(await File(backups.single.path).readAsString(), garbage);
    });
  });
}
