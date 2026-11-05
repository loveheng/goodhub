/// 调试桥装配：把宿主专有件接到公共包 `app_debug_bridge` 的注入端口上。
///
/// 宿主专有三件——日志源（AppLog）、导航句柄（appNavigatorKey）、路由白名单
/// （debug_routes）——在此汇合；公共包本身不含任何宿主业务。
library;

import 'package:app_debug_bridge/app_debug_bridge.dart' as kit;
import 'package:app_debug_bridge/app_debug_bridge.dart' show DebugBridge;

import '../core/app_log.dart';
import 'debug_actions.dart';
import 'debug_routes.dart';
import 'debug_ui_tree.dart';
import 'navigator_key.dart';

/// AppLog → 公共包日志源端口的适配器（宿主唯一的日志实现）。
class _AppLogSink implements kit.DebugLogSink {
  @override
  int get length => AppLog.instance.length;

  @override
  int get revision => AppLog.instance.revision.value;

  @override
  List<kit.DebugLogEntry> entries() => AppLog.instance.entries
      .map((e) => kit.DebugLogEntry(
            timestamp: e.timestamp,
            level: e.level.name,
            message: e.message,
          ))
      .toList();
}

/// 宿主调试桥实例（仅 debug 装配；release 由 `main.dart` 编译期剔除）。
DebugBridge buildDebugBridge() {
  bindDebugNavigator();
  bindDebugRoutes(debugRouteRegistry);
  return DebugBridge(
    logSink: _AppLogSink(),
    uiTreeProvider: () => collectDebugUiTree(appNavigatorKey.currentContext),
    actionHandler: executeDebugAction,
  );
}
