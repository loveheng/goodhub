/// 状态带（StatusStrip）切片 A 回归：运行态「已耗时」mm:ss 由内嵌 _ElapsedText
/// 自管 1s 定时器局部刷新，不再依赖 ChatPage 每秒整页 setState（反模式已消除——
/// 运行态逐秒重建含 TextField 的整页有丢光标/焦点风险）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/components/status_capsule.dart';
import 'package:goodhub/ui/components/status_strip.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';

void main() {
  testWidgets('已耗时自管件：运行态每秒自刷，无需整页重建', (tester) async {
    // 可控时钟：初始 0 秒，推进 1 秒——避免 fake-timer 与真实时钟错位。
    final base = DateTime(2026, 1, 1);
    var elapsedSeconds = 0;
    DateTime now() => base.add(Duration(seconds: elapsedSeconds));
    await tester.pumpWidget(
      MaterialApp(
        home: Theme(
          data: ThemeData(extensions: [ConsoleTokens.fallback]),
          child: ElapsedText(
            start: base,
            t: ConsoleTokens.fallback,
            color: ConsoleTokens.fallback.l1Info,
            now: now,
          ),
        ),
      ),
    );
    final before = _parseElapsedSeconds(tester);
    // 推进 fake 时钟 1 秒：ElapsedText 自管定时器触发；同时把可控时钟 +1s，
    // 验证其「仅自身重建、按已耗时自刷」（不依赖 ChatPage 每秒整页 setState）。
    elapsedSeconds = 1;
    await tester.pump(const Duration(seconds: 1));
    final after = _parseElapsedSeconds(tester);
    expect(before, 0, reason: '初值 0 秒');
    expect(after, 1, reason: 'ElapsedText 自管定时器每秒推进 1 秒（切片 A）');
  });

  testWidgets('非运行态不渲染已耗时', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Theme(
          data: ThemeData(extensions: [ConsoleTokens.fallback]),
          child: StatusStrip(
            t: ConsoleTokens.fallback,
            pillTone: CapsuleTone.idle,
            pillLabel: 'idle',
            running: false,
            runStartedAt: null,
            contextId: null,
            localPluginCount: 0,
            hasEndpoints: false,
            endpointName: (_) => '',
            onOpenMenu: () {},
          ),
        ),
      ),
    );
    expect(find.text('00:00'), findsNothing);
  });

  // A2（page-beautify）：工具名人话化纯函数——状态带/CallCard 共用同源。
  group('A2 工具名人话化（toolAction/shortClause）', () {
    test('description 首子句截断（中文分号 / 左括号均切）', () {
      expect(
        StatusStrip.toolAction('goodshare__get_item', const {
          'goodshare__get_item': '读取单个收集条目的完整内容（原文 + 人类态/机器态）；'
              '图片条目小图返回 base64 图像块',
        }),
        '读取单个收集条目的完整内容',
      );
      expect(
        StatusStrip.shortClause('把一段文本或链接存入「拾贝」收集器（例如用户说"帮我存一下"时使用）。'),
        '把一段文本或链接存入「拾贝」收集器',
      );
    });

    test('无标点长句 16 字硬截 + 省略号；短文本原样', () {
      expect(
        StatusStrip.shortClause('这是一段没有任何标点的超长工具描述文本需要硬截断'),
        '这是一段没有任何标点的超长工具描…',
      );
      expect(StatusStrip.shortClause('列出最近的收集条目'), '列出最近的收集条目');
    });

    test('无描述回退裸工具名（剥 serverId__ 前缀）', () {
      expect(StatusStrip.toolAction('goodshare__list_items', const {}), 'list_items');
    });

    // P0-4（2026-10-22）：前缀剥离抽为共用件——状态带与 CallCard 摘要必须同口径
    // （历史坑：CallCard 直吃 `tool`，`<serverId>__<tool>` 遥测串直出阅读轨）。
    test('plainToolName：剥前缀与本地工具透传（CallCard 摘要同源）', () {
      expect(StatusStrip.plainToolName('goodshare__list_items'), 'list_items');
      expect(StatusStrip.plainToolName('update_memory'), 'update_memory',
          reason: '无分隔符（宿主本地工具）原名透传');
    });

    test('无前缀宿主本地工具原名透传；空描述同样回退裸名', () {
      expect(StatusStrip.toolAction('update_memory', const {}), 'update_memory');
      expect(StatusStrip.toolAction('goodshare__add_item', const {'goodshare__add_item': '  '}),
          'add_item');
    });
  });
}

/// 从 StatusStrip 渲染出的文本中解析「已耗时」秒数：状态带内唯一形如 mm:ss 的
/// 文本即 _ElapsedText（时钟无关，避免 fake-clock 起点差异造成的精确串脆弱）。
int _parseElapsedSeconds(WidgetTester tester) {
  final texts = tester.widgetList<Text>(find.byType(Text));
  for (final w in texts) {
    final s = w.data;
    if (s != null && RegExp(r'^\d{2}:\d{2}$').hasMatch(s)) {
      final parts = s.split(':');
      return int.parse(parts[0]) * 60 + int.parse(parts[1]);
    }
  }
  throw StateError('StatusStrip 未渲染已耗时 mm:ss 文本');
}
