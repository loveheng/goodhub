import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/geniex_runtime_binding.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GenieXRuntimeControl 通道绑定测试（P2 验收 #6 的断源/通道异常面）：
/// mock 通道模拟 设备不支持/受理成功/通道异常 三态；镜像列表持久化往返。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('goodhub/geniex_runtime');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('status：正常返回投影', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'status');
      return {'supported': true, 'installed': false, 'installing': false, 'version': '0.10.0', 'arch': 79};
    });
    final st = await GenieXRuntimeControl.status();
    expect(st.supported, isTrue);
    expect(st.installed, isFalse);
    expect(st.arch, 79);
  });

  test('status：通道异常降级为不支持（不炸 UI）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    final st = await GenieXRuntimeControl.status();
    expect(st.supported, isFalse);
  });

  test('install：受理 true / 通道异常 false（断源面）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
    expect(await GenieXRuntimeControl.install(const []), isTrue);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable'); // 断源/进程不可达
    });
    expect(await GenieXRuntimeControl.install(const []), isFalse);
  });

  test('uninstall：透传布尔', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
    expect(await GenieXRuntimeControl.uninstall(), isTrue);
  });

  test('镜像列表：持久化往返 + 非法项过滤', () async {
    await GenieXRuntimeControl.saveMirrors([
      'https://mirror.example.com/a.aar',
      '  ',
      'not-a-url',
      'https://mirror2.example.com/b.aar',
    ]);
    final loaded = await GenieXRuntimeControl.loadMirrors();
    expect(loaded, ['https://mirror.example.com/a.aar', 'https://mirror2.example.com/b.aar']);
  });

  test('镜像列表：空 = 走内置双源默认（Kotlin DEFAULT_URLS 兜底）', () async {
    expect(await GenieXRuntimeControl.loadMirrors(), isEmpty);
  });
}
