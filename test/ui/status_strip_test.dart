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
