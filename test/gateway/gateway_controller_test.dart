/// 网关装配控制器单测（此前零覆盖）：初始态、stop 幂等与安全、LAN 地址枚举
/// 的 DEGRADE 口径。
///
/// 覆盖边界说明：`start()` 依赖平台侧装配（path_provider / 本地插件扫描 /
/// 端点存储），需真机或完整平台 mock，故本文件只覆盖**无平台依赖**的面；
/// 起服全链由 `integration_test/` 与真机联调承担。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/gateway/gateway_controller.dart';

void main() {
  group('GatewayController', () {
    test('初始未起服，face 集为空（装配独立于会话生命周期）', () {
      expect(GatewayController.shared.running, isFalse);
      expect(GatewayController.shared.faces, isEmpty);
    });

    test('stop 在未起服时安全（幂等；C7 会话豁免复位不抛）', () async {
      await GatewayController.shared.stop();
      expect(GatewayController.shared.running, isFalse);
    });

    test('lanAddresses：不抛且仅回 IPv4 点分地址（失败 DEGRADE 返空）', () async {
      final addrs = await GatewayController.lanAddresses();
      expect(addrs, isA<List<String>>());
      for (final a in addrs) {
        expect(InternetAddress.tryParse(a), isNotNull);
        expect(InternetAddress(a).type, InternetAddressType.IPv4);
      }
    });
  });
}
