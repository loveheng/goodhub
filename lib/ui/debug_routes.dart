/// debug/profile 直达路由（宿主白名单）。
///
/// 通用能力（命名空间判定、初始路由生成）在公共包 `app_debug_bridge`；本文件
/// 只持有**宿主页面清单**与 `MaterialApp.onGenerateRoute` 的接线。
library;

import 'package:app_debug_bridge/app_debug_bridge.dart' show DebugRouteRegistry;
import 'package:flutter/material.dart';

import 'gateway_loop_debug_page.dart';
import 'log_viewer_page.dart';
import 'settings_page.dart';

/// 可直达的 debug 页（宿主页面清单；公共包只认名字，不认业务）。
enum DebugRoute { logs, gateway, settings }

const Map<String, DebugRoute> kDebugRoutes = <String, DebugRoute>{
  'logs': DebugRoute.logs,
  'gateway': DebugRoute.gateway,
  'settings': DebugRoute.settings,
};

/// 宿主路由白名单注册表（供公共包动作面按名跳转）。
final DebugRouteRegistry debugRouteRegistry = DebugRouteRegistry(
  <String, WidgetBuilder>{
    for (final entry in kDebugRoutes.entries)
      entry.key: (_) => _pageFor(entry.value),
  },
);

Widget _pageFor(DebugRoute route) => switch (route) {
      DebugRoute.logs => const LogViewerPage(),
      DebugRoute.gateway => const GatewayLoopDebugPage(),
      DebugRoute.settings => const SettingsPage(),
    };

/// 是否属 debug 命名空间（`/debug/...` 或 `goodhub://debug/...`）。
bool isDebugRouteName(String? name) {
  if (name == null) return false;
  final uri = Uri.tryParse(name);
  if (uri == null) return false;
  if (uri.hasScheme) {
    return uri.scheme == 'goodhub' && uri.host == 'debug';
  }
  final segments = uri.path.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isNotEmpty && segments.first == 'debug';
}

/// 解析页面键；未知页 / 非 debug 命名空间一律 null。
DebugRoute? parseDebugRoute(String? name) {
  if (!isDebugRouteName(name)) return null;
  final uri = Uri.parse(name!);
  final segments = uri.path.split('/').where((s) => s.isNotEmpty).toList();
  final page = uri.hasScheme
      ? (segments.isEmpty ? '' : segments.last)
      : (segments.length >= 2 ? segments[1] : '');
  return kDebugRoutes[page];
}

/// `MaterialApp.onGenerateRoute` 的 debug 实现。
Route<dynamic>? resolveDebugRoute(RouteSettings settings) {
  if (!isDebugRouteName(settings.name)) return null;
  final route = parseDebugRoute(settings.name);
  if (route == null) {
    debugPrint('[debug-route] unknown "${settings.name}"，可用：'
        '${kDebugRoutes.keys.map((k) => '/debug/$k').join(' ')}');
    return null; // 交 onUnknownRoute 显式报错，禁静默回落首页
  }
  return MaterialPageRoute<dynamic>(
    settings: settings,
    builder: (_) => _pageFor(route),
  );
}

/// 覆盖 `Navigator.defaultGenerateInitialRoutes` 的按 `/` 分段行为：Flutter
/// 会把 `/debug/logs` 拆成 `/` → `/debug` → `/debug/logs`，中间段会额外触发
/// 一次 [resolveDebugRoute]（既污染日志又可能生成红屏错误页）。调试直达只应
/// 生成目标页一条路由；非 debug 初始路由回落 [home]。
List<Route<dynamic>> generateDebugInitialRoutes(
  String initialRoute, {
  required Widget home,
}) {
  final debug = resolveDebugRoute(RouteSettings(name: initialRoute));
  if (debug != null) return <Route<dynamic>>[debug];
  return <Route<dynamic>>[
    MaterialPageRoute<dynamic>(
      settings: const RouteSettings(name: '/'),
      builder: (_) => home,
    ),
  ];
}
