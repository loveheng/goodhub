/// 安全存储升级健康检查（2026-10-24 事故显性化）：flutter_secure_storage 自
/// 9.2.2 直升 11.2.0，v11 移除了 v9 默认算法（RSA_ECB_PKCS1Padding /
/// AES_CBC_PKCS7Padding），旧密文不可解——MCP 服务令牌、BYOK 云端密钥静默
/// 失效（读出空按无令牌，UI 仍显示「已存令牌」，用户对 403 一头雾水）。
///
/// 本件经插件 `checkUpgradeStatus()`（只读：不迁移、不删除）收窄为宿主侧两态
/// 结论，供设置页顶部提示行，把「已存令牌却 403」变成可操作提示。
/// 消费方仅 settings_page（注入位 `secureHealthOverride`）。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 宿主侧结论（收窄插件四态）：[legacyDataLost] = 存在旧版本写入且当前版本
/// 无法解密的数据（含已被读路径删除的 discarded），对应密钥须重新录入。
enum SecureStorageHealth { ok, legacyDataLost }

/// 纯映射：插件升级状态 → 宿主结论。unreadable / discarded 皆判丢失；
/// ok / unknown / 非 Android unsupported 恒正常（unknown 仅见于需生物识别
/// 解锁的命名空间，本宿主未启用；误报提示比静默丢钥代价低，不单列提示态）。
SecureStorageHealth healthFromUpgradeStatus(SecureStorageUpgradeStatus status) =>
    switch (status.state) {
      SecureStorageUpgradeState.legacyDataUnreadable ||
      SecureStorageUpgradeState.legacyDataDiscarded =>
        SecureStorageHealth.legacyDataLost,
      _ => SecureStorageHealth.ok,
    };

/// 生产检查（Android only；其他平台插件回 unsupported → 正常）。检查失败按
/// 正常降级留痕——本件只做提示，严禁因检查失败打断设置页初始化。
Future<SecureStorageHealth> checkSecureStorageHealth() async {
  try {
    final status = await const FlutterSecureStorage().checkUpgradeStatus();
    return healthFromUpgradeStatus(status);
  } on Object catch (e) {
    debugPrint('[DEGRADE] secure-storage-health: 升级状态检查失败按正常: $e');
    return SecureStorageHealth.ok;
  }
}

/// 检查注入口签名（测试传假件；null = 生产直调 [checkSecureStorageHealth]）。
typedef SecureStorageHealthCheck = Future<SecureStorageHealth> Function();
