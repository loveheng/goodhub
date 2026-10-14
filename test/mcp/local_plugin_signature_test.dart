// §5 同签名门禁 · Dart 侧指纹/信任桥（thirdconnect §1.2.6 / #9 D.1 → Dart）：
// 宿主 Kotlin 提取插件证书 SHA-256 填入 [LocalPluginInfo.signatureSha256]，并与宿主
// 自身签名集比对得出 [LocalPluginInfo.sameSignature]（同签名=零弹窗自动信任，否则走
// 信任卡片）。本测试锁 Dart 侧对这两个字段的解析与 transportId 派生，防指纹字段被
// 误改/丢弃导致同签名信任判定静默失效（§5 D.2 前置）。
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';

void main() {
  group('LocalPluginInfo 指纹字段解析（§5 D.1 → Dart）', () {
    test('全字段解析', () {
      final info = LocalPluginInfo.fromJson(<String, Object?>{
        'serverId': 'goodshare',
        'serverTitle': 'GoodShare',
        'packageName': 'com.zzh.goodshare',
        'serviceClassName': 'com.zzh.goodshare.sample.dummy.DummyPluginService',
        'signatureSha256': 'a1b2c3d4',
        'sameSignature': true,
      });
      expect(info.serverId, 'goodshare');
      expect(info.serverTitle, 'GoodShare');
      expect(info.packageName, 'com.zzh.goodshare');
      expect(info.serviceClassName,
          'com.zzh.goodshare.sample.dummy.DummyPluginService');
      expect(info.signatureSha256, 'a1b2c3d4');
      expect(info.sameSignature, isTrue);
    });

    test('缺省容错：signatureSha256→空串 / sameSignature→false', () {
      final info = LocalPluginInfo.fromJson(<String, Object?>{
        'serverId': 'x',
        'packageName': 'com.zzh.x',
        'serviceClassName': 'com.zzh.x.Svc',
      });
      // 未取到签名的插件不得被误判为同签名（否则绕过信任卡片，安全回归）。
      expect(info.signatureSha256, '');
      expect(info.sameSignature, isFalse);
      expect(info.serverTitle, ''); // 缺省展示名
    });

    test('sameSignature 仅布尔 true 生效（脏数据不得假阳）', () {
      final dirty = LocalPluginInfo.fromJson(<String, Object?>{
        'serverId': 'x',
        'packageName': 'com.zzh.x',
        'serviceClassName': 'com.zzh.x.Svc',
        'sameSignature': 'true', // 字符串而非 bool：不得当作同签名
      });
      expect(dirty.sameSignature, isFalse);
    });

    test('transportId = local:<pkg>_<serverId>（与宿主 transports Map key 对齐）', () {
      final info = LocalPluginInfo.fromJson(<String, Object?>{
        'serverId': 'goodshare',
        'packageName': 'com.zzh.goodshare',
        'serviceClassName': 'com.zzh.goodshare.Svc',
      });
      expect(info.transportId, 'local:com.zzh.goodshare_goodshare');
    });
  });
}
