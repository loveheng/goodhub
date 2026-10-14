import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodhub/main.dart';
import 'package:goodhub/ui/claim_loop_page.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';

void main() {
  testWidgets('首页冒烟（M4-T3/D9）：ChatPage 接管——标题/输入/发送存在', (tester) async {
    await tester.pumpWidget(const GoodHubApp());
    expect(find.text('GoodHub'), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget, reason: '输入栏发送按钮（图标形态，tooltip=发送）');
    expect(find.textContaining('配置服务端点'), findsOneWidget,
        reason: '空轨道提示（连接配置引导）');
  });

  testWidgets('M1 任务循环页冒烟：降级 debug 入口后页面本体不变', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Theme(
          data: ThemeData(extensions: const [ConsoleTokens.fallback]),
          child: const ClaimLoopPage(),
        ),
      ),
    );
    expect(find.text('GoodHub · M1 壳'), findsOneWidget);
    expect(find.text('Claim & Apply 一次'), findsOneWidget);
  });
}
