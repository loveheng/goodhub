/// 前台保活服务通道（G4，thirdconnect.md §7）：起停网关时联动 Android
/// ForegroundService（通知栏常驻 + WifiLock + WakeLock，息屏/Doze 不断连）。
///
/// 原生不可达（单测/无引擎环境）抛 MissingPluginException——捕获 DEGRADE 留痕
/// 不阻断网关起停（保活缺失仅影响息屏场景，前台网关照常工作）。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

class GatewayServiceChannel {
  GatewayServiceChannel._();

  static const MethodChannel _channel = MethodChannel('goodhub/gateway_service');

  static Future<void> start() => _invoke('start');

  static Future<void> stop() => _invoke('stop');

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException catch (e) {
      debugPrint('[DEGRADE] gateway-service: native bridge unavailable: $e');
    } on PlatformException catch (e) {
      debugPrint('[DEGRADE] gateway-service: $method failed: $e');
    } on Object catch (e) {
      // 兜底（2026-10-15 补）：绑定未初始化 / 非 Flutter 环境调用抛的不是
      // MissingPluginException，原二分支捕获会把异常穿透到 controller.stop()，
      // 与「绝不阻断网关起停」的注释不符。保活缺失只影响息屏场景——一律留痕。
      debugPrint('[DEGRADE] gateway-service: $method unexpected: $e');
    }
  }
}
