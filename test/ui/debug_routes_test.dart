/// debug 直达路由回归：命名空间判定 / 白名单 / query 兼容 / 未知页不静默。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/debug_routes.dart';
import 'package:goodhub/ui/log_viewer_page.dart';

void main() {
  group('parseDebugRoute', () {
    test('冷启动形式 /debug/<page> 三页全覆盖', () {
      expect(parseDebugRoute('/debug/logs'), DebugRoute.logs);
      expect(parseDebugRoute('/debug/gateway'), DebugRoute.gateway);
      expect(parseDebugRoute('/debug/settings'), DebugRoute.settings);
    });

    test('scheme 形式与 query 参数兼容', () {
      expect(parseDebugRoute('goodhub://debug/logs'), DebugRoute.logs);
      expect(parseDebugRoute('goodhub://debug/gateway?from=adb'),
          DebugRoute.gateway);
      expect(parseDebugRoute('/debug/settings?tab=nodes'),
          DebugRoute.settings);
    });

    test('未知页命中命名空间但解析为 null', () {
      expect(isDebugRouteName('/debug/nope'), isTrue);
      expect(parseDebugRoute('/debug/nope'), isNull);
      expect(parseDebugRoute('/debug'), isNull);
    });

    test('非 debug 命名空间与空值不接管', () {
      expect(isDebugRouteName('/'), isFalse);
      expect(isDebugRouteName(null), isFalse);
      expect(isDebugRouteName('https://example.com/debug/logs'), isFalse);
      expect(parseDebugRoute('/'), isNull);
      expect(parseDebugRoute(null), isNull);
    });
  });

  group('resolveDebugRoute', () {
    test('命中返回保留 settings 的 MaterialPageRoute', () {
      const settings = RouteSettings(name: '/debug/logs');
      final route = resolveDebugRoute(settings);
      expect(route, isA<MaterialPageRoute<dynamic>>());
      expect((route! as MaterialPageRoute<dynamic>).settings.name,
          '/debug/logs');
    });

    test('非 debug 命名空间返回 null（不劫持正常路由）', () {
      expect(resolveDebugRoute(const RouteSettings(name: '/')), isNull);
    });
  });

  group('generateDebugInitialRoutes', () {
    test('直达只生成目标页一条（无 /debug 中间段）', () {
      final routes = generateDebugInitialRoutes('/debug/logs',
          home: const SizedBox.shrink());
      expect(routes, hasLength(1));
      expect(routes.single.settings.name, '/debug/logs');
    });

    test('普通初始路由回落首页', () {
      final routes =
          generateDebugInitialRoutes('/', home: const SizedBox.shrink());
      expect(routes, hasLength(1));
      expect(routes.single.settings.name, '/');
    });
  });

  group('生产装配形状（home=null + 初始路由生成器）', () {
    Widget buildApp({String? initialRoute}) => MaterialApp(
          initialRoute: initialRoute,
          onGenerateRoute: resolveDebugRoute,
          onGenerateInitialRoutes: (route) => generateDebugInitialRoutes(
                route,
                home: const Text('home-page'),
              ),
        );

    testWidgets('普通启动出首页，不触发 WidgetsApp 断言', (tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('home-page'), findsOneWidget);
    });

    testWidgets('冷启动 /debug/logs 直达目标页且无中间段首页', (tester) async {
      await tester.pumpWidget(buildApp(initialRoute: '/debug/logs'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(LogViewerPage), findsOneWidget);
      expect(find.text('home-page'), findsNothing);
    });
  });
}
