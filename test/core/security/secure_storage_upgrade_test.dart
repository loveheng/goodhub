/// 安全存储升级健康单测（2026-10-24 事故回归钉子）：unreadable/discarded 判
/// 丢失、ok/unknown 恒正常；裸环境（无平台通道）生产包装按正常降级不抛。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/security/secure_storage_upgrade.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('healthFromUpgradeStatus', () {
    test('legacyDataUnreadable / legacyDataDiscarded → legacyDataLost', () {
      expect(
        healthFromUpgradeStatus(const SecureStorageUpgradeStatus(
            state: SecureStorageUpgradeState.legacyDataUnreadable)),
        SecureStorageHealth.legacyDataLost,
      );
      expect(
        healthFromUpgradeStatus(const SecureStorageUpgradeStatus(
            state: SecureStorageUpgradeState.legacyDataDiscarded,
            reason: SecureStorageUpgradeReason.removedCipher)),
        SecureStorageHealth.legacyDataLost,
      );
    });

    test('ok / unknown → ok（unknown 仅生物识别命名空间，本宿主未启用）', () {
      expect(
        healthFromUpgradeStatus(const SecureStorageUpgradeStatus(
            state: SecureStorageUpgradeState.ok)),
        SecureStorageHealth.ok,
      );
      expect(
        healthFromUpgradeStatus(const SecureStorageUpgradeStatus(
            state: SecureStorageUpgradeState.unknown)),
        SecureStorageHealth.ok,
      );
    });
  });

  test('裸环境（无平台通道实现）检查按正常降级，不抛', () async {
    // 无 mock handler → MissingPluginException → 生产包装吞掉置 ok（DEGRADE
    // 留痕）——设置页初始化永不被检查失败打断。
    expect(await checkSecureStorageHealth(), SecureStorageHealth.ok);
  });
}
