import 'package:flutter/services.dart';

/// 应用设置直达（ux-hardening P0-3 收尾）：更新页安装失败时引导用户到
/// 「安装未知应用」授权页。原生侧 = `AppSettingsBridge.kt`，零状态直通。
abstract final class AppSettings {
  static const MethodChannel _channel = MethodChannel('goodhub/app_settings');

  /// 打开本包的「安装未知应用」授权页（Android 8+）；<8 退化为应用详情页。
  /// 失败（通道未就绪/设置页不可达）静默返回 false——仅引导性动作，不抛穿。
  static Future<bool> openUnknownAppSourceSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openUnknownAppSources') ?? false;
    } on PlatformException {
      return false;
    }
  }
}
