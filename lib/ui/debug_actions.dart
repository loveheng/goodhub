/// 动作执行面适配（实现已迁至公共包 `app_debug_bridge`）。
///
/// 宿主保留两处**测试注入位**并映射进公共包入口，因此既有 import 路径与测试
/// 断言零改动；公共包侧的遍历起点 / 导航句柄 / 路由白名单由装配期设置
/// （见 `lib/ui/debug_wiring.dart`）。
library;

import 'package:app_debug_bridge/app_debug_bridge.dart' as kit;
import 'package:flutter/widgets.dart';

import 'navigator_key.dart';

export 'package:app_debug_bridge/app_debug_bridge.dart' show kDebugActions;

/// 测试注入位：非空时替代宿主 navigator 的遍历起点。
BuildContext? debugActionContextOverride;

/// 测试注入位：非空时替代宿主 navigator。
NavigatorState? debugActionNavigatorOverride;

/// 宿主动作面入口（供 `DebugBridge.actionHandler` 装配）。
Future<Object?> executeDebugAction(
        String action, Map<String, Object?> args) =>
    kit.executeDebugAction(
      action,
      args,
      contextOverride: debugActionContextOverride,
      navigatorOverride: debugActionNavigatorOverride,
    );

/// 装配期把宿主 navigator 接到公共包的遍历起点 / 导航句柄。
void bindDebugNavigator() {
  kit.debugContextProvider = () => appNavigatorKey.currentContext;
  kit.debugNavigatorProvider = () => appNavigatorKey.currentState;
}

/// 装配期（或测试）设置公共包的路由白名单（宿主页面清单）。
void bindDebugRoutes(kit.DebugRouteRegistry registry) {
  kit.debugRouteRegistry = registry;
}
