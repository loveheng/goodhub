/// M2.5-T6 CoW 继承单测：版本比较 / 覆写持久化 / 同步六态（导入/保留本地/
/// 重置回服务端/兼容闸跳过/major 告警 delegate 三分支）。
/// 规格 = architecture.md §3 CoW 合并策略（major 跃迁强制告警、否决三路合并）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/coordinator/skill_registry.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object result) => http.Response(
      '{"jsonrpc":"2.0","id":1,"result":${jsonEncode(result)}}',
      200,
      headers: {'content-type': 'application/json'},
    );

/// Mock server：prompts 清单（可配版本/minHub）+ 原文回包。
({McpClient client, List<String> rawRequested}) cowClient({
  required String templateVersion,
  String? minHub,
  String template = '模板正文 {id} 尾部',
}) {
  final rawRequested = <String>[];
  final client = McpClient.http(
    baseUrl: 'http://127.0.0.1:8765/mcp',
    httpClient: MockClient((req) async {
      final body = req.body;
      if (body.contains('"prompts/list"')) {
        return _json({
          'prompts': [
            {
              'name': 'item_digest',
              'description': '摘要模板',
              'arguments': [
                {'name': 'id', 'required': true},
              ],
              '_meta': {
                'template_version': templateVersion,
                'min_hub_version': ?minHub,
              },
            },
          ],
        });
      }
      if (body.contains('"prompts/get"')) {
        rawRequested.add(body);
        return _json({
          'messages': [
            {
              'role': 'user',
              'content': {'type': 'text', 'text': template},
            },
          ],
        });
      }
      fail('意外请求: $body');
    }),
  );
  return (client: client, rawRequested: rawRequested);
}

void main() {
  late Directory tmpDir;
  late CowOverridesStore store;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('cow_test_');
    store = CowOverridesStore(dir: tmpDir);
  });

  tearDown(() async => tmpDir.delete(recursive: true));

  group('版本比较', () {
    test('major 跃迁判定：仅 to.major > from.major', () {
      expect(isMajorJump('1.0.0', '2.0.0'), isTrue);
      expect(isMajorJump('1.9.9', '2.0.0'), isTrue);
      expect(isMajorJump('1.0.0', '1.9.0'), isFalse, reason: 'minor 静默');
      expect(isMajorJump('1.0.0', '1.0.1'), isFalse, reason: 'patch 静默');
      expect(isMajorJump('2.0.0', '1.0.0'), isFalse, reason: '降版不告警');
    });

    test('compareVersions 三段逐位 + 非数字段防御', () {
      expect(compareVersions('1.2.3', '1.2.3'), 0);
      expect(compareVersions('1.2.3', '1.10.0'), isNegative);
      expect(compareVersions('', '1.0.0'), isNegative);
    });
  });

  group('CowOverridesStore 持久化', () {
    test('覆写写入 → 新实例读回；reset 后消失；known_versions 独立记录', () async {
      await store.setOverride('p1', '本地覆写正文');
      await store.setKnownVersion('p1', '1.0.0');
      final reopened = CowOverridesStore(dir: tmpDir);
      // ignore: avoid_print
      print('COW-FILE=${await File('${tmpDir.path}/cow_overrides.json').readAsString()}');
      // ignore: avoid_print
      print('KNOWN=${await reopened.knownVersion('p1')}');
      // ignore: avoid_print
      print('OVR=${await reopened.overrideOf('p1')}');
      expect(await reopened.overrideOf('p1'), '本地覆写正文');
      expect(await reopened.knownVersion('p1'), '1.0.0');
      await reopened.reset('p1');
      expect(await reopened.overrideOf('p1'), isNull);
      expect(await reopened.knownVersion('p1'), '1.0.0', reason: '重置只删覆写不删基线');
    });

    test('损坏 JSON → 按空库起步不抛（DEGRADE 留痕）', () async {
      await File('${tmpDir.path}/cow_overrides.json')
          .writeAsString('{broken');
      final reopened = CowOverridesStore(dir: tmpDir);
      expect(await reopened.overrideOf('p1'), isNull);
    });
  });

  group('CowSyncService.sync 六态', () {
    test('无覆写 → imported（content 为 server 原文，known 记录）', () async {
      final (client: client, rawRequested: _) = cowClient(templateVersion: '1.0.0');
      final items = await CowSyncService(store: store).sync(client, serverId: 'goodshare');
      expect(items.single.action, CowSyncAction.imported);
      expect(items.single.content, contains('模板正文'));
      expect(await store.knownVersion('item_digest'), '1.0.0');
    });

    test('min_hub_version 高于宿主 → skippedIncompatible（不拉原文）', () async {
      final (client: client, rawRequested: raw) =
          cowClient(templateVersion: '1.0.0', minHub: '99.0.0');
      final items = await CowSyncService(store: store)
          .sync(client, serverId: 'goodshare', hostVersion: '0.1.0');
      expect(items.single.action, CowSyncAction.skippedIncompatible);
      expect(raw, isEmpty);
    });

    test('有覆写无跃迁 → keptLocal（本地副本不回传，基线刷新防累积告警）', () async {
      final (client: client, rawRequested: raw) = cowClient(templateVersion: '1.0.0');
      await store.setOverride('item_digest', '我的本地版');
      await store.setKnownVersion('item_digest', '1.0.0');
      final items = await CowSyncService(store: store).sync(client, serverId: 'goodshare');
      expect(items.single.action, CowSyncAction.keptLocal);
      expect(items.single.content, isNull);
      expect(raw, isEmpty, reason: '本地版生效时不拉原文');
    });

    test('有覆写 + major 跃迁 + delegate 重置 → resetToServer（覆写删除回 server 版）', () async {
      final (client: client, rawRequested: raw) = cowClient(templateVersion: '2.0.0');
      await store.setOverride('item_digest', '旧本地版');
      await store.setKnownVersion('item_digest', '1.0.0');
      final items = await CowSyncService(
        store: store,
        onMajorJump: (_, _, _) async => true,
      ).sync(client, serverId: 'goodshare');
      expect(items.single.action, CowSyncAction.resetToServer);
      expect(items.single.content, contains('模板正文'));
      expect(await store.overrideOf('item_digest'), isNull);
      expect(raw, isNotEmpty);
    });

    test('有覆写 + major 跃迁 + delegate 保留 → keptLocal 且基线刷新（不重复告警）', () async {
      final (client: client, rawRequested: raw) = cowClient(templateVersion: '2.0.0');
      await store.setOverride('item_digest', '旧本地版');
      await store.setKnownVersion('item_digest', '1.0.0');
      final svc = CowSyncService(
        store: store,
        onMajorJump: (_, _, _) async => false,
      );
      final items = await svc.sync(client, serverId: 'goodshare');
      expect(items.single.action, CowSyncAction.keptLocal);
      expect(await store.overrideOf('item_digest'), '旧本地版');
      expect(await store.knownVersion('item_digest'), '2.0.0');
      final again = await svc.sync(client, serverId: 'goodshare');
      expect(again.single.action, CowSyncAction.keptLocal, reason: '基线已刷新，二次同步不再触发告警');
      expect(raw, isEmpty);
    });

    test('有覆写 + major 跃迁 + delegate 缺省 → 保留本地（保守默认）', () async {
      final (client: client, rawRequested: _) = cowClient(templateVersion: '3.0.0');
      await store.setOverride('item_digest', '旧本地版');
      await store.setKnownVersion('item_digest', '1.0.0');
      final items = await CowSyncService(store: store).sync(client, serverId: 'goodshare');
      expect(items.single.action, CowSyncAction.keptLocal);
      expect(await store.overrideOf('item_digest'), '旧本地版');
    });
  });

  group('toSkill 与注册合流', () {
    test('cow/<name> 命名 + appScoped 绑 server + source=cow（name 唯一闸防撞）', () async {
      final (client: client, rawRequested: _) = cowClient(templateVersion: '1.0.0');
      final items = await CowSyncService(store: store).sync(client, serverId: 'goodshare');
      final skill = CowSyncService.toSkill(items.single, 'goodshare');
      expect(skill.name, 'cow/item_digest');
      expect(skill.scope, SkillScope.appScoped);
      expect(skill.serverId, 'goodshare');
      expect(skill.source, SkillSource.cow);

      final registry = SkillRegistry()..registerAll(builtinSkills());
      registry.register(skill);
      final out = registry.composeSystemPrompt('base', connectedServerIds: const ['goodshare']);
      expect(out, contains('模板正文'));
    });
  });
}
