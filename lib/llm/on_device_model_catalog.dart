/// 端侧模型目录与用户选择（on-device S2-5 起正式功能化，替代 S2-2 时期的
/// dart-define 资产指向 PATCH）。
///
/// 目录项 = 「可下载的端侧模型」：manifest 基址 + 本地落盘目录名。base 现走
/// 内网 adb reverse 回环（S2-2 通路实证：`adb reverse tcp:8090 tcp:8090`，
/// PC 侧 `python3 -m http.server 8090` 于资产根目录）——正式分发换远端对象
/// 存储时只改 [OnDeviceModelOption.base]，面不变（NPU 稿 §4.5 分发键口径）。
///
/// 用户选择持久化于 shared_preferences（跨启动生效，启动引导据此装载）；
/// 测量期可用 dart-define `ON_DEVICE_MODEL_ID` 覆盖默认选择（bench 构建
/// 免 UI 操作），优先级：用户选择 > dart-define > 目录首位。
library;

import 'package:shared_preferences/shared_preferences.dart';

class OnDeviceModelOption {
  const OnDeviceModelOption({
    required this.id,
    required this.displayName,
    required this.base,
    required this.dirName,
  });

  final String id;
  final String displayName;

  /// manifest.json 所在基址（OTA 通道 §4.5）。
  final String base;

  /// 应用内部 `supportDir/models/` 落盘目录名。
  final String dirName;
}

const List<OnDeviceModelOption> kOnDeviceModelCatalog = [
  OnDeviceModelOption(
    id: 'qwen3-1.7b',
    displayName: 'Qwen3-1.7B（NPU）',
    base:
        'http://127.0.0.1:8090/qwen3_1_7b-geniex_qairt-w4a16-qualcomm_snapdragon_8_elite_for_galaxy',
    dirName: 'qwen3_1_7b-geniex_qairt-w4a16',
  ),
  OnDeviceModelOption(
    id: 'qwen3-4b',
    displayName: 'Qwen3-4B（NPU）',
    base: 'http://127.0.0.1:8090/ota4b',
    dirName: 'qwen3-4b-w4a16',
  ),
];

OnDeviceModelOption? optionById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final o in kOnDeviceModelCatalog) {
    if (o.id == id) return o;
  }
  return null;
}

/// 选择持久化（shared_preferences 单键；读取失败按未选择处理，调用方落
/// 目录首位——宁默认勿炸）。
abstract final class OnDeviceModelSelection {
  static const String _key = 'on_device.model.selected_id';

  /// 测量期构建覆盖（bench 免 UI 操作）：`--dart-define=ON_DEVICE_MODEL_ID=<id>`。
  static const String _envModelId =
      String.fromEnvironment('ON_DEVICE_MODEL_ID');

  static Future<OnDeviceModelOption?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      return optionById(saved ?? _envModelId);
    } catch (_) {
      return optionById(_envModelId);
    }
  }

  static Future<void> write(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, id);
  }
}
