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
    return UpdateManifest(
      versionCode: versionCode,
      versionName: versionName,
      apkUrl: apkUrl,
      sha256: json['sha256'] as String?,
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
