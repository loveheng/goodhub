/// ChatComposer Enter 键平台语义锚（page-beautify B1，2026-10-17）：
/// 移动端软键盘 Enter=换行（不触发发送）、桌面端 Enter=发送。
///
/// SDK 语义依据（editable_text.dart）：
/// - multiline 字段收到 `TextInputAction.newline` 时**空操作**——换行字符
///   已由平台直接插入，不回调 onSubmitted（:3740-3746）；
/// - `TextInputAction.send` 走 _finalizeEditing → onSubmitted（:3752/:3963）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/components/chat_composer.dart';
import 'package:goodhub/ui/components/status_capsule.dart';
import 'package:goodhub/ui/components/status_strip.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';

void main() {
  // 注意：debugDefaultTargetPlatformOverride 须在**用例体内**复位——binding 在
  // test body 结束时即校验 foundation 调试变量（debugAssertAllFoundationVarsUnset），
  // tearDown 晚于该校验。

  /// 最小装配：ChatComposer 零依赖页面私有态，直接喂数据 + 计数回调。
  /// Theme 注入 ConsoleTokens.fallback——C3 边框色断言须与 token 同源
  /// （consoleTokens 未注入时落 fallback，与注入值一致，避免双份真相）。
  Widget harness({
    required VoidCallback onSend,
    required VoidCallback onAbort,
    bool running = false,
    bool hasContext = false,
    bool hasEndpoints = false,
  }) {
    return MaterialApp(
      home: Theme(
        data: ThemeData(extensions: [ConsoleTokens.fallback]),
        child: Scaffold(
          body: ChatComposer(
            inputCtrl: TextEditingController(),
            running: running,
            hasContext: hasContext,
            contextId: null,
            endpointName: (_) => '',
            hasEndpoints: hasEndpoints,
            localPluginCount: 0,
            pillTone: CapsuleTone.idle,
            pillLabel: 'idle',
            runStartedAt: null,
            onOpenMenu: () {},
            onSend: onSend,
            onAbort: onAbort,
          ),
        ),
      ),
    );
  }

  testWidgets('移动端（默认 android）：Enter 动作=换行，performAction(newline) 不触发发送',
      (tester) async {
    debugDefaultTargetPlatformOverride = null; // 测试环境默认 = android
    var sends = 0;
    await tester.pumpWidget(
      harness(onSend: () => sends++, onAbort: () {}),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);
    expect(find.textContaining('Enter 换行'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.binding.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    expect(sends, 0); // 换行 ≠ 发送（SDK：multiline newline 空操作）
    debugDefaultTargetPlatformOverride = null; // 体内复位（见 main 头注）
  });

  testWidgets('桌面端：Enter 动作=发送，performAction(send) 触发 onSend', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var sends = 0;
    await tester.pumpWidget(
      harness(onSend: () => sends++, onAbort: () {}),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.send);
    expect(find.textContaining('Enter 发送'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.binding.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(sends, 1); // SDK：send → _finalizeEditing → onSubmitted
    debugDefaultTargetPlatformOverride = null; // 体内复位（见 main 头注）
  });

  testWidgets('B3：+ 钮触达区 48×48（原 36dp 低于推荐误触率高）', (tester) async {
    await tester.pumpWidget(
      harness(onSend: () {}, onAbort: () {}),
    );
    // 2026-10-18 融合药丸后主操作钮也是 IconButton——按图标定位「+」钮。
    final addBtn = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.add),
    );
    expect(addBtn.constraints, const BoxConstraints(minWidth: 48, minHeight: 48));
  });

  testWidgets('三态换色（融入药丸，2026-10-18）：空输入灰 / 有输入 l1Info / 运行 danger',
      (tester) async {
    final t = ConsoleTokens.fallback;
    await tester.pumpWidget(harness(onSend: () {}, onAbort: () {}));

    Color sendIconColor() => tester
        .widget<Icon>(find.byIcon(Icons.arrow_upward))
        .color!;
    expect(sendIconColor(), t.terminalMuted, reason: '空输入=禁用置灰');

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pumpAndSettle();
    expect(sendIconColor(), t.l1Info, reason: '有输入=可发送强调');

    // 清空回灰（跟随输入双向）。
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(sendIconColor(), t.terminalMuted);

    // running 态：glyph 换 stop、色转 danger。
    await tester.pumpWidget(harness(onSend: () {}, onAbort: () {}, running: true));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<Icon>(find.byIcon(Icons.stop)).color!,
      t.danger,
      reason: '运行=中止警示色',
    );
  });

  testWidgets('B4：主操作钮单槽形变——idle 发送 / running 中止，图标随相位切换',
      (tester) async {
    var sends = 0;
    var aborts = 0;
    await tester.pumpWidget(
      harness(onSend: () => sends++, onAbort: () => aborts++),
    );
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(sends, 1);

    // running 态：AnimatedSwitcher 过渡（180ms）后仅存 stop，点击走中止。
    // （过渡期中新旧图标并存于树——入场缩放淡入，不在此期间断言。）
    await tester.pumpWidget(
      harness(onSend: () => sends++, onAbort: () => aborts++, running: true),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();
    expect(aborts, 1);
    expect(sends, 1); // 运行态不再触发发送
  });

  // P0-2（2026-10-22）：状态带不再因「配置过端点」而常驻——原条件下绝大多数用户
  // 永远挂着一行零信息量的「空闲 · 公共」，白占 30dp 且与 ui-design §3.1
  // 「空闲态收 0」抵触。回归钉子：hasEndpoints=true 而 idle ⇒ 高度必须 0。
  testWidgets('状态带展开条件：running/hasContext 才 30dp，有端点但空闲=0',
      (tester) async {
    // 直接量渲染后的实际占高——「不占面积」才是要钉的语义（读目标字段会漏掉
    // 动画/裁决滞后导致的常驻）。每轮先 pump 满 180ms 过渡，避免量到中间帧。
    Future<double> stripHeight() async {
      await tester.pump(const Duration(milliseconds: 200));
      return tester.getSize(find.byType(StatusStrip)).height;
    }

    await tester.pumpWidget(harness(onSend: () {}, onAbort: () {}));
    expect(await stripHeight(), 0, reason: '纯空闲：状态带收 0');

    await tester.pumpWidget(
        harness(onSend: () {}, onAbort: () {}, hasEndpoints: true));
    expect(await stripHeight(), 0,
        reason: '配置过端点但未运行未绑定：不得常驻「空闲 · 公共」');

    await tester
        .pumpWidget(harness(onSend: () {}, onAbort: () {}, hasContext: true));
    expect(await stripHeight(), 30, reason: '绑定私有域：状态带承载上下文胶囊');

    await tester
        .pumpWidget(harness(onSend: () {}, onAbort: () {}, running: true));
    expect(await stripHeight(), 30, reason: '运行态：相位 + 已耗时');
  });

  testWidgets('C3：聚焦时药丸边框 hairline → l1Info，失焦即回', (tester) async {
    await tester.pumpWidget(
      harness(onSend: () {}, onAbort: () {}),
    );

    // 药丸 = TextField 的 AnimatedContainer 祖先（唯一——状态带那条是
    // Column 的兄弟分支，非祖先）。decoration 为目标色（180ms 平滑由
    // AnimatedContainer 内部完成，视觉项真机走查）。
    Color pillBorder() {
      final pill = tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.byType(TextField),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      // 药丸恒定带边框（见 composer 实现），无条件解包安全。
      return (pill.decoration as BoxDecoration).border!.top.color;
    }

    expect(pillBorder(), ConsoleTokens.fallback.hairline, reason: '失焦态细边框');
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 200));
    expect(pillBorder(), ConsoleTokens.fallback.l1Info, reason: '聚焦态 L1 强调');

    // 失焦回退（键盘收起/点他处）——锚住可逆性。
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
    expect(pillBorder(), ConsoleTokens.fallback.hairline);
  });
}
