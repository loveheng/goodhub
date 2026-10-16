/// ux-hardening P1-5：会话侧边栏——标题搜索 / 重命名对话框 / 列表元信息。
/// 纯视图件：交互经回调外抛，测试捕获回调参数即可，不触内核。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/sandbox/conversation_store.dart';
import 'package:goodhub/ui/components/conversation_drawer.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';

void main() {
  // DateTime 构造非 const——列表元素去 const（值仍不可变）。
  //
  // **相对「今天」构造，禁止硬编码绝对日期**：被测件 fmtTime 拿真实
  // DateTime.now() 比日历日（components/conversation_drawer.dart），写死日期的
  // fixture 隔夜即腐——2026-10-17 实测：原写死 2026-10-16 的样本在次日全红，
  // 而本仓长期不跑测试故一直没暴露。跨天样本用 `day - 2`（DateTime 自动跨月规范化）。
  final now = DateTime.now();
  final metas = <ConversationMeta>[
    ConversationMeta(
      id: 'conv_1',
      title: '列出今天的待办',
      updatedAt: DateTime(now.year, now.month, now.day, 9, 30)
          .millisecondsSinceEpoch,
      messageCount: 6,
    ),
    ConversationMeta(
      id: 'conv_2',
      title: '周报摘要',
      updatedAt: DateTime(now.year, now.month, now.day - 2, 20, 5)
          .millisecondsSinceEpoch,
      messageCount: 0, // 旧数据缺省 0：只显时间不显条数
    ),
  ];

  Widget host(Widget child) => MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          extensions: const [ConsoleTokens.fallback],
        ),
        home: Scaffold(body: child),
      );

  ConversationMeta? renamed;
  String? renamedTitle;

  setUp(() {
    renamed = null;
    renamedTitle = null;
  });

  testWidgets('列表元信息：更新时间 · 条数（0 条旧数据只显时间）', (tester) async {
    await tester.pumpWidget(host(ConversationDrawer(
      conversations: metas,
      currentId: 'conv_1',
      onNew: () {},
      onLoad: (_) {},
      onDelete: (_) {},
      onRename: (m, t) {},
    )));

    expect(find.text('列出今天的待办'), findsOneWidget);
    expect(find.text('09:30 · 6 条'), findsOneWidget);
    expect(find.text('周报摘要'), findsOneWidget);
    // 0 条：只显时间（跨天 → M/d HH:mm），不编造条数（期望值随 fixture 推导，
    // 不写死日期——否则与上面「相对今天」的构造脱钩，隔夜再腐）。
    final crossDay = DateTime.fromMillisecondsSinceEpoch(metas[1].updatedAt);
    expect(
      find.text('${crossDay.month}/${crossDay.day} '
          '${crossDay.hour.toString().padLeft(2, '0')}:'
          '${crossDay.minute.toString().padLeft(2, '0')}'),
      findsOneWidget,
    );
    expect(find.textContaining('0 条'), findsNothing);
  });

  testWidgets('标题搜索：本地过滤 + 无匹配空态 + 清空恢复', (tester) async {
    await tester.pumpWidget(host(ConversationDrawer(
      conversations: metas,
      currentId: 'conv_1',
      onNew: () {},
      onLoad: (_) {},
      onDelete: (_) {},
      onRename: (m, t) {},
    )));

    await tester.enterText(find.byType(TextField), '周报');
    await tester.pump();
    expect(find.text('周报摘要'), findsOneWidget);
    expect(find.text('列出今天的待办'), findsNothing, reason: '不匹配项被过滤');

    await tester.enterText(find.byType(TextField), '不存在的标题');
    await tester.pump();
    expect(find.textContaining('无匹配'), findsOneWidget);

    // 清空钮（Query 非空时才出现）→ 全量恢复。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('列出今天的待办'), findsOneWidget);
    expect(find.text('周报摘要'), findsOneWidget);
  });

  testWidgets('重命名：对话框预填旧标题 → 保存回抛 (meta, 新标题)', (tester) async {
    await tester.pumpWidget(host(ConversationDrawer(
      conversations: metas,
      currentId: 'conv_1',
      onNew: () {},
      onLoad: (_) {},
      onDelete: (_) {},
      onRename: (m, t) {
        renamed = m;
        renamedTitle = t;
      },
    )));

    await tester.tap(find.byTooltip('重命名').first);
    await tester.pumpAndSettle();
    expect(find.text('重命名会话'), findsOneWidget);
    expect(find.text('列出今天的待办'), findsNWidgets(2),
        reason: '列表项 + 对话框预填各一处');

    // 清空预填 → 「保存」禁用（空标题禁存）。
    await tester.enterText(find.byKey(const Key('rename-field')), '');
    await tester.pump();
    final save = find.widgetWithText(FilledButton, '保存');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('rename-field')), '今天的待办清单');
    await tester.pump(); // 重建后按钮才脱离禁用态（tap 命中当前树）
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(renamed?.id, 'conv_1');
    expect(renamedTitle, '今天的待办清单');
  });

  testWidgets('重命名取消：不回抛回调', (tester) async {
    await tester.pumpWidget(host(ConversationDrawer(
      conversations: metas,
      currentId: 'conv_1',
      onNew: () {},
      onLoad: (_) {},
      onDelete: (_) {},
      onRename: (m, t) {
        renamed = m;
        renamedTitle = t;
      },
    )));

    await tester.tap(find.byTooltip('重命名').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(renamed, isNull);
    expect(renamedTitle, isNull);
  });
}
