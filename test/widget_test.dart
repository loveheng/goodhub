import 'package:flutter_test/flutter_test.dart';

import 'package:goodhub/main.dart';

void main() {
  testWidgets('首页冒烟（M4-T3/D9）：ChatPage 接管——标题/输入/发送存在', (tester) async {
    await tester.pumpWidget(const GoodHubApp());
    expect(find.text('GoodHub'), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget, reason: '输入栏发送按钮（图标形态，tooltip=发送）');
    expect(find.textContaining('下达自然语言任务'), findsOneWidget,
        reason: '空轨道提示（已配置用户的首次指引；未配置时的可操作引导在轨道内'
            '引导卡，由 chat_page_smoke_test 覆盖——ux-hardening P0-1）');
  });
}
