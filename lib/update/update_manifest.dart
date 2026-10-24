import 'dart:convert';

/// 更新清单（应用内自更新，self-update epic）。
/// 托管格式见 docs/design/self-update.md；发布由 scripts/release-r2.sh 生成上传。
class UpdateManifest {
  const UpdateManifest({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    this.sha256,
    this.changelog,
    this.applicationId,
  });

  factory UpdateManifest.fromJson(Map<String, Object?> json) {
    final versionCode = json['versionCode'];
    final versionName = json['versionName'];
    final apkUrl = json['apkUrl'];
    if (versionCode is! int) {
      throw const FormatException('versionCode 必须是整数');
    }
    if (versionName is! String || apkUrl is! String) {
      throw const FormatException('versionName / apkUrl 缺失或类型错误');
    }
    // F14（review-fix-2026-10）：完整性链收紧——apkUrl 强制 https（明文源可被
    // 中间人替换整包）+ sha256 必填（缺失即零完整性校验，仅剩安装器签名一致性
    // 兜底）。控制/劫持更新源即可投递任意 APK 的面就此关闭。回环 http 豁免
    // （127.0.0.1/localhost 不可被远程劫持；本地调试与单测地基）。
    final apkUri = Uri.tryParse(apkUrl);
    final loopbackHttp = apkUri != null &&
        apkUri.isScheme('http') &&
        (apkUri.host == '127.0.0.1' || apkUri.host == 'localhost');
    if (apkUri == null || (!apkUri.isScheme('https') && !loopbackHttp)) {
      throw const FormatException('apkUrl 必须为 https 源（明文源拒绝：可被劫持投递任意包）');
    }
    final sha256 = json['sha256'];
    if (sha256 is! String || sha256.isEmpty) {
      throw const FormatException('sha256 必填（缺失即无完整性校验，拒绝该清单）');
    }
    return UpdateManifest(
      versionCode: versionCode,
      versionName: versionName,
      apkUrl: apkUrl,
      sha256: sha256,
      changelog: json['changelog'] as String?,
      applicationId: json['applicationId'] as String?,
    );
  }

  factory UpdateManifest.parse(String raw) =>
      UpdateManifest.fromJson(jsonDecode(raw) as Map<String, Object?>);

  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String? sha256;
  final String? changelog;

  /// 发布侧写入的包名（applicationId）：多 app 共用更新源时供客户端比对身份，
  /// 不一致即拒更，防串包（装到别人的包/拉到别人的配置）。旧清单无此字段时为 null。
  final String? applicationId;

  bool isNewerThan(int currentVersionCode) => versionCode > currentVersionCode;
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 下载被用户主动取消（ux-hardening P0-3）：区别于失败——页面以中性语气
/// 呈现，不计错误。extends [UpdateException] 保证既有 catch 路径兼容。
class UpdateCancelled extends UpdateException {
  const UpdateCancelled() : super('下载已取消');
}
