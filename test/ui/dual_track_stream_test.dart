import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/tool_breaker.dart';
import 'package:goodhub/ui/components/breaker_card.dart';
import 'package:goodhub/ui/components/call_card.dart';
import 'package:goodhub/ui/components/dual_track_stream.dart';
import 'package:goodhub/ui/rich_text_view.dart';

void main() {
  Future<void> pump(WidgetTester tester, List<TrackEntry> entries,
          {String emptyHint = ''}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DualTrackStream(entries: entries, emptyHint: emptyHint),
        ),
      ));

  testWidgets('事件→轨道映射：用户轮/执行卡终态/通告/空提示缺席', (tester) async {
    await pump(tester, [
      const TrackUser('把行动项写进 todo'),
      TrackCall(tool: 'list_items')
        ..phase = CallCardPhase.success
        ..preview = 'r1 ⏎ r2',
      const TrackNote('✓ 收尾（1 轮）', danger: false),
    ]);

    expect(find.text('把行动项写进 todo'), findsOneWidget);
    expect(find.text('你'), findsOneWidget, reason: '用户轮次标签（D9 同轴卡片族）');
    expect(find.byType(CallCard), findsOneWidget);
    // 2026-10-18 终态压缩单行：默认只见「✓ + 人话摘要」，结果预览点开才见。
    expect(find.text('✓'), findsOneWidget, reason: '终态状态符号（双通道之一）');
    expect(find.text('r1 ⏎ r2'), findsNothing, reason: '终态默认收起，不直出结果 JSON');
    expect(find.text('✓ 收尾（1 轮）'), findsOneWidget);
  });

  testWidgets('Abort 终态：cancelled 相位呈现（区别 Failed，architecture §10）',
      (tester) async {
    await pump(tester, [
      // CallCard 口径：progressNote 仅 running/stuck 有意义，cancelled 走
      // 终态 preview（在途调用真实完成后由页面回填真结果）。
      TrackCall(tool: 'add_item')..phase = CallCardPhase.cancelled,
    ]);
    // 终态压缩单行：⊘ + 工具名摘要；详情（(无文本返回)）展开后可见。
    expect(find.text('⊘'), findsOneWidget);
    expect(find.text('add_item'), findsOneWidget, reason: '无描述回退裸工具名');
    expect(find.text('(无文本返回)'), findsNothing);
    await tester.tap(find.text('add_item'));
    await tester.pump();
    expect(find.text('(无文本返回)'), findsOneWidget,
        reason: '展开详情：cancelled 中间态渲染终态灰阶；真结果到达后换 preview');
  });

  testWidgets('终态压缩单行（2026-10-18）：默认一行摘要，展开见详情可收回',
      (tester) async {
    await pump(tester, [
      TrackCall(tool: 'list_items')
        ..phase = CallCardPhase.success
        ..description = '列出全部条目；返回 JSON 数组'
        ..preview = 'r1 ⏎ r2'
        ..resultText = 'r1 ⏎ r2',
    ]);
    // 默认：✓ + 描述首子句；工具名遥测与结果预览均不可见。
    expect(find.text('✓'), findsOneWidget);
    expect(find.text('列出全部条目'), findsOneWidget, reason: '单行 = 描述首子句');
    expect(find.text('list_items'), findsNothing);
    expect(find.text('r1 ⏎ r2'), findsNothing);

    // 点击单行 → 展开详情（工具名遥测轨 + 描述行 + 结果预览 + 收起）。
    await tester.tap(find.text('列出全部条目'));
    await tester.pump();
    expect(find.text('list_items'), findsOneWidget, reason: '原始前缀名归详情遥测轨');
    expect(find.text('r1 ⏎ r2'), findsOneWidget, reason: '终态预览（详情态）');

    // 再点头部 = 全收起 → 回单行（整卡单一开关，无独立「收起」按钮）。
    expect(find.text('收起'), findsNothing);
    await tester.tap(find.text('list_items'));
    await tester.pump();
    expect(find.text('r1 ⏎ r2'), findsNothing);
    expect(find.text('列出全部条目'), findsOneWidget);
  });

  testWidgets('A2：CallCard 人话描述行——原名遥测轨在位 + 首子句 + 可展开全文',
      (tester) async {
    await pump(tester, [
      TrackCall(tool: 'goodshare__get_item')
        ..phase = CallCardPhase.success
        ..description = '读取单个收集条目的完整内容（原文 + 人类态/机器态）；图片小图返回 base64',
    ]);

    // 终态压缩单行（2026-10-18）：单行摘要 = 描述首子句；点击展开进详情。
    expect(find.text('读取单个收集条目的完整内容'), findsOneWidget,
        reason: '单行摘要 = description 首子句');
    await tester.tap(find.text('读取单个收集条目的完整内容'));
    await tester.pump();

    expect(find.text('goodshare__get_item'), findsOneWidget,
        reason: '原始前缀名留遥测轨（CallCard 头部等宽）');
    // 整卡单一开关（2026-10-18）：展开态全文直出，不再有分段「展开/收起」按钮。
    expect(
      find.text('读取单个收集条目的完整内容（原文 + 人类态/机器态）；图片小图返回 base64'),
      findsOneWidget,
      reason: '展开态描述全文直出（SelectableText 便于复制）',
    );
    expect(find.text('展开'), findsNothing, reason: '整卡单一开关，无分段展开按钮');

    // 再点头部 = 全收起，回单行摘要。
    await tester.tap(find.text('goodshare__get_item'));
    await tester.pump();
    expect(find.text('读取单个收集条目的完整内容'), findsOneWidget);
    expect(
      find.text('读取单个收集条目的完整内容（原文 + 人类态/机器态）；图片小图返回 base64'),
      findsNothing,
    );
  });

  testWidgets('A2：无描述的 CallCard 不渲染人话行（旧数据零痕迹）', (tester) async {
    await pump(tester, [
      TrackCall(tool: 'list_items')..phase = CallCardPhase.success,
    ]);
    expect(find.text('list_items'), findsOneWidget);
    expect(find.text('展开'), findsNothing);
  });

  testWidgets('表格渲染：列宽按内容自适应（防 FlexColumnWidth 塌缩错乱）',
      (tester) async {
    const md = '| 名称 | 端口 | 状态 |\n'
        '| --- | :---: | ---: |\n'
        '| goodshare | 8765 | 已挂载 |\n'
        '| shuguang | 8766 | 已挂载 |';
    await pump(tester, [TrackText(md)]);

    final table = tester.widget<Table>(find.byType(Table));
    expect(table.defaultColumnWidth, isA<IntrinsicColumnWidth>(),
        reason: '横向滚动无限宽约束下列宽须按内容自适应，否则单元格重叠错乱');
    // 表头 + 两行数据 = 3 行（TableRow 非 Widget，按 children 长度断言）。
    expect(table.children.length, 3);
    // 单元格对齐透传：中间列居中、末列右对齐（markdown `:---:` / `---:`）。
    expect(find.text('端口'), findsOneWidget);
    expect(find.text('已挂载'), findsNWidgets(2));
  });

  testWidgets('阅读轨经 RichTextView 渲染 Markdown（D12 自写方案）', (tester) async {
    final text = TrackText('');
    text.text.write('# 结论\n\n**要点** 与 `code`');
    await pump(tester, [text]);
    // P1（stream-perf §4）：空行切点把标题段稳入稳定前缀，正文为活跃尾块——
    // 单条目 = 稳定 + 尾块两个 RichTextView（隔离重绘）。
    expect(find.byType(RichTextView), findsNWidgets(2));
    // 嵌套 TextSpan 用 findRichText 匹配（Text.rich 叶子）。
    expect(find.textContaining('结论', findRichText: true), findsOneWidget);
    expect(find.textContaining('要点', findRichText: true), findsOneWidget);
    expect(find.textContaining('code', findRichText: true), findsOneWidget);
  });

  testWidgets('空轨道出提示；流式追加复用同一条目（不碎卡）', (tester) async {
    await pump(tester, const [], emptyHint: '下达任务');
    expect(find.text('下达任务'), findsOneWidget);

    final text = TrackText('');
    final entries = <TrackEntry>[text];
    await pump(tester, entries);
    text.text.write('第一段 ');
    await pump(tester, entries);
    expect(find.text('第一段 '), findsOneWidget);
    expect(find.byType(RichTextView), findsOneWidget,
        reason: '同一 TrackText 重建单组件——流式不新增轨道条目');
  });

  testWidgets('TrackBreaker/TrackFence 渲染（排查卡/围栏卡内嵌）', (tester) async {
    await pump(tester, [
      TrackBreaker.breaker(BreakerReport(
        toolName: 'add_item',
        consecutiveFailures: 2,
        lastError: 'boom',
        argumentsJson: '{}',
      )),
    ]);
    expect(find.byType(BreakerCard), findsOneWidget);
    expect(find.textContaining('add_item'), findsWidgets);
  });

  testWidgets('TrackGuide 引导卡：正文 + 动作钮 + 回调（P0-1 冷启动）', (tester) async {
    var opened = 0;
    await pump(tester, [
      TrackGuide(
        text: '尚未配置任何 MCP 服务，也未发现本地插件。',
        actionLabel: '去配置',
        onAction: () => opened++,
      ),
    ]);
    expect(find.textContaining('尚未配置'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);

    await tester.tap(find.text('去配置'));
    expect(opened, 1);
  });

  testWidgets('TrackError 错误行动卡：白话标题/建议/可复制异常 + 重试后锁定',
      (tester) async {
    var retried = 0;
    final card = TrackError(
      title: '连不上推理服务',
      advice: '检查网络连接与端点地址是否可达，然后重试',
      detail: 'CloudNetworkException: connection reset',
    );
    card.onAction = () => retried++;
    await pump(tester, [card]);

    expect(find.text('✕ 连不上推理服务'), findsOneWidget);
    expect(find.textContaining('检查网络连接'), findsOneWidget);
    expect(find.text('CloudNetworkException: connection reset'), findsOneWidget,
        reason: '原始异常留痕可复制（排障）');
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    expect(retried, 1);
    card.retried = true; // 页面侧锁定（终态锁定，ui-design §3.2）
    await pump(tester, [card]);
    expect(find.text('↻ 已重试'), findsOneWidget);
    expect(find.text('重试'), findsNothing, reason: '锁定后重试钮消失');
  });

  testWidgets('TrackError 恢复态（onAction=null）：无重试钮（历史无可重跑任务）',
      (tester) async {
    await pump(tester, [
      TrackError(
        title: '任务意外中断',
        advice: '稍后可重新发送任务继续',
        detail: 'Exception: boom',
      ),
    ]);
    expect(find.textContaining('任务意外中断'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.textContaining('Exception: boom'), findsOneWidget);
  });

  testWidgets('归因条降噪（P1-6）：仅服务无记忆 → 不渲染（遥测噪音收敛）',
      (tester) async {
    await pump(tester, [
      TrackContextAttribution(
        memories: const [],
        services: const [
          ContextAttributionItem(source: 'goodshare', text: 'goodshare Tier 2'),
        ],
      ),
    ]);
    expect(find.textContaining('本轮上下文'), findsNothing,
        reason: '服务数与状态带上下文胶囊重复——不重复遥测');
  });

  testWidgets('归因条呈现（P1-6）：携带记忆注入才出现 + 点开详情',
      (tester) async {
    await pump(tester, [
      TrackContextAttribution(
        memories: const [
          ContextAttributionItem(source: 'user', text: '偏好 Dart 强类型'),
        ],
        services: const [
          ContextAttributionItem(source: 'goodshare', text: 'goodshare Tier 2'),
        ],
      ),
    ]);
    expect(find.textContaining('本轮上下文：记忆 1 条'), findsOneWidget);

    await tester.tap(find.textContaining('本轮上下文'));
    await tester.pumpAndSettle();
    expect(find.text('本轮携带上下文'), findsOneWidget);
    expect(find.text('宿主记忆（1）'), findsOneWidget);
    expect(find.text('已挂载服务（1）'), findsOneWidget);
  });

  testWidgets('C4：助手文本轮次带「GoodHub」轻标（与用户轮「你」对称）', (tester) async {
    await pump(tester, [TrackText('回答正文')]);
    expect(find.text('GoodHub'), findsOneWidget,
        reason: 'microSm 灰阶等宽轮次标——长会话回看时轮次边界不再融化');
  });

  testWidgets('C6：「✓ 任务完成」脱离 Run 概要折叠，遥测通告仍折叠', (tester) async {
    await pump(tester, [
      const TrackNote(kTaskDoneNote, danger: false),
      const TrackNote('⊘ 有 2 个服务已卸载', danger: false),
      const TrackNote('✓ 已激活 goodshare 的工具', danger: false),
    ]);
    // 完成行独立在（不被折叠、不被隐藏）。
    expect(find.text(kTaskDoneNote), findsOneWidget);
    // 两条遥测通告照旧折叠为概要（降噪不回归）。
    expect(find.text('Run 概要（2 条通告）'), findsOneWidget);
    expect(find.text('⊘ 有 2 个服务已卸载'), findsNothing,
        reason: '遥测通告在折叠概要内，默认不展开');
  });
}
