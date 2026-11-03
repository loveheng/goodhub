import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/trusted_plugins.dart';

/// 信任判定单一入口门禁钉（task-capability W1-S03）。
///
/// 红线：本地插件挂载信任判定逻辑仅 trusted_plugins.dart 一处
/// （[localPluginTrustSatisfied]）；消费方（聊天页装配 / 网关装配 / 任务
/// 消费引导等一切挂载路径）禁再内联 `sameSignature` + `isTrusted` 组合——
/// S04 任务路径漏查信任校验即散落判定的实例。本钉机械扫描 lib/：
/// `isTrusted(` 调用只许出现在 trusted_plugins.dart（声明处 + 其实现）。
void main() {
  group('信任判定单一入口（S03 门禁扫描钉）', () {
    test('lib/ 内 isTrusted( 只许出现在 trusted_plugins.dart', () {
      final offenders = <String>[];
      final libDir = Directory('lib');
      for (final f in libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final inTrustedFile = f.path.replaceAll('\\', '/') ==
            'lib/mcp/trusted_plugins.dart';
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          if (line.startsWith('//') || line.startsWith('///')) continue;
          if (line.contains('isTrusted(') && !inTrustedFile) {
            offenders.add('${f.path}:${i + 1}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '信任判定已收口 localPluginTrustSatisfied 单一入口，'
              '禁在其他文件再调 isTrusted(：$offenders');
    });

    test('单一入口判定口径：同签名自动信任 / 第三方须白名单+指纹一致', () {
      final gate = _FakeGate();
      LocalPluginInfo info({required bool sameSig, required String pkg}) =>
          LocalPluginInfo(
            serverId: 'srv',
            serverTitle: 'Srv',
            serviceClassName: 'SrvService',
            packageName: pkg,
            signatureSha256: 'aa11',
            sameSignature: sameSig,
          );
      // 同签名私有生态：零弹窗自动信任（白名单未命中也信任）。
      expect(localPluginTrustSatisfied(info(sameSig: true, pkg: 'com.a'), gate),
          isTrue);
      // 第三方：白名单命中且指纹一致才信任。
      expect(localPluginTrustSatisfied(info(sameSig: false, pkg: 'com.b'), gate),
          isTrue);
      expect(localPluginTrustSatisfied(info(sameSig: false, pkg: 'com.c'), gate),
          isFalse);
    });
  });
}

class _FakeGate implements PluginTrustGate {
  @override
  bool isTrusted(String packageName, {String signatureSha256 = ''}) {
    // com.b 在白名单且指纹一致；com.c 在白名单但指纹不匹配。
    if (packageName == 'com.b') return signatureSha256 == 'aa11';
    if (packageName == 'com.c') return false;
    return false;
  }
}
