/// M4-T5 服务大厅 BYOK 云端引擎面板单测（ByokStore 注入假件）：
/// 空态/新增落库（密钥走安全存储）/ 列表渲染与生效中标注 / 编辑（密钥留空
/// 保持已存）/ 置顶切换生效 / 删除（确认弹卡 + 密钥连带清理）。
/// 纪律：同 services_hall_page_test——store 读写走真实异步，全部经
/// [WidgetTester.runAsync] 让路（settleIo 轮询），断言值先捕获再断言。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/core/security/secure_key_value.dart';
import 'package:goodhub/llm/cloud/byok_store.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/ui/services_hall_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;
  late CowOverridesStore cowStore;
  late InMemorySecureKeyValue secure;
  late ByokStore byokStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('hall_byok_t5');
    cowStore = CowOverridesStore(dir: tempDir);
    secure = InMemorySecureKeyValue();
    byokStore = ByokStore(secure: secure);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> pumpHall(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ServicesHallPage(
        storeOverride: cowStore,
        byokStoreOverride: byokStore,
      ),
    ));
    await settleIo(tester);
  }

  /// 表单较长，目标可能在视口外——先滚动到可见再点（否则 tap 落空仅告警）。
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  Future<void> fillForm(WidgetTester tester,
      {String name = 'DeepSeek 主力',
      String url = 'https://api.deepseek.com',
      String model = 'deepseek-chat',
      String temp = '0.2',
      String key = 'sk-secret-1'}) async {
    await tester.enterText(find.byKey(const Key('byok-field-name')), name);
    await tester.enterText(find.byKey(const Key('byok-field-url')), url);
    await tester.enterText(find.byKey(const Key('byok-field-model')), model);
    await tester.enterText(find.byKey(const Key('byok-field-temp')), temp);
    await tester.enterText(find.byKey(const Key('byok-field-key')), key);
  }

  testWidgets('空态渲染 + 新增模型（profile 落库 + 密钥走安全存储不入 profile）',
      (tester) async {
    await pumpHall(tester);
    expect(find.text('（暂无模型配置——云端引擎未装配，仅端侧路径）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('byok-new')));
    await tester.pumpAndSettle();
    await fillForm(tester);
    await tapVisible(tester, find.byKey(const Key('byok-create')));
    await settleIo(tester);

    expect(find.byKey(const Key('byok-item-byok-')), findsNothing,
        reason: 'id 动态生成，用文案断言');
    expect(find.text('DeepSeek 主力'), findsOneWidget,
        reason: 'SnackBar 反馈是「✓ 已添加 …」，与条目名精确区分');

    List<ByokProfile> saved = const [];
    String? storedKey;
    await tester.runAsync(() async {
      saved = await byokStore.load();
      storedKey = await byokStore.apiKey(saved.first.id);
    });
    expect(saved.single.model, 'deepseek-chat');
    expect(saved.single.temperature, 0.2);
    expect(storedKey, 'sk-secret-1', reason: '密钥进安全存储');
    expect(saved.single.toJson().toString(), isNot(contains('sk-secret')),
        reason: '密钥纪律：profile 明文不含密钥');
  });

  testWidgets('生效中标注首位 + 置顶切换（装配取首位的 UI 对齐）', (tester) async {
    await tester.runAsync(() async {
      final a = const ByokProfile(
          id: 'p_a',
          name: 'A',
          protocol: CloudProtocol.openaiCompatible,
          baseUrl: 'https://a',
          model: 'm-a');
      final b = const ByokProfile(
          id: 'p_b',
          name: 'B',
          protocol: CloudProtocol.anthropic,
          baseUrl: 'https://b',
          model: 'm-b');
      await byokStore.save([a, b]);
      await byokStore.setApiKey('p_a', 'sk-a');
    });
    await pumpHall(tester);

    expect(find.byKey(const Key('byok-item-p_a')), findsOneWidget);
    expect(find.byKey(const Key('byok-item-p_b')), findsOneWidget);
    expect(find.text('生效中'), findsOneWidget, reason: '仅首位标注');
    expect(find.byKey(const Key('byok-top-p_a')), findsNothing,
        reason: '首位无置顶钮');
    expect(find.textContaining('已存密钥'), findsOneWidget);
    expect(find.textContaining('未存密钥'), findsOneWidget,
        reason: 'p_b 无密钥给警示');

    await tapVisible(tester, find.byKey(const Key('byok-top-p_b')));
    await settleIo(tester);

    List<ByokProfile> saved = const [];
    await tester.runAsync(() async => saved = await byokStore.load());
    expect(saved.map((p) => p.id).toList(), ['p_b', 'p_a'],
        reason: '置顶即切换生效配置');
  });

  testWidgets('编辑保存：字段更新 + 密钥留空保持已存（不误清）', (tester) async {
    await tester.runAsync(() async {
      await byokStore.save([const ByokProfile(
          id: 'p_a',
          name: 'A',
          protocol: CloudProtocol.openaiCompatible,
          baseUrl: 'https://a',
          model: 'm-a')]);
      await byokStore.setApiKey('p_a', 'sk-keep');
    });
    await pumpHall(tester);

    await tester.tap(find.byKey(const Key('byok-edit-p_a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('byok-edit-form')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('byok-field-model')), 'm-a2');
    // byok-field-key 留空 = 保持已存密钥
    await tapVisible(tester, find.byKey(const Key('byok-save')));
    await settleIo(tester);

    List<ByokProfile> saved = const [];
    String? key;
    await tester.runAsync(() async {
      saved = await byokStore.load();
      key = await byokStore.apiKey('p_a');
    });
    expect(saved.single.model, 'm-a2');
    expect(key, 'sk-keep', reason: '留空不误清已存密钥');
  });

  testWidgets('删除：确认弹卡 → 落库移除 + 孤儿密钥连带清理', (tester) async {
    await tester.runAsync(() async {
      await byokStore.save([const ByokProfile(
          id: 'p_a',
          name: 'A',
          protocol: CloudProtocol.openaiCompatible,
          baseUrl: 'https://a',
          model: 'm-a')]);
      await byokStore.setApiKey('p_a', 'sk-doomed');
    });
    await pumpHall(tester);

    await tester.tap(find.byKey(const Key('byok-del-p_a')));
    await tester.pumpAndSettle();
    expect(find.textContaining('其已存密钥将一并清除'), findsOneWidget);
    await tapVisible(tester, find.widgetWithText(FilledButton, '删除'));
    await settleIo(tester);

    List<ByokProfile> saved = const [];
    String? orphanKey;
    await tester.runAsync(() async {
      saved = await byokStore.load();
      orphanKey = await byokStore.apiKey('p_a');
    });
    expect(saved, isEmpty);
    expect(orphanKey, isNull, reason: 'save 连带清理防孤儿密钥');
  });

  testWidgets('防呆：Base URL 缺失不落库', (tester) async {
    await pumpHall(tester);
    await tester.tap(find.byKey(const Key('byok-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('byok-field-name')), '残缺');
    await tester.enterText(find.byKey(const Key('byok-field-model')), 'm');
    await tester.enterText(find.byKey(const Key('byok-field-key')), 'sk-x');
    await tester.tap(find.byKey(const Key('byok-create')));
    await settleIo(tester);

    List<ByokProfile> saved = const [];
    await tester.runAsync(() async => saved = await byokStore.load());
    expect(saved, isEmpty);
  });
}
