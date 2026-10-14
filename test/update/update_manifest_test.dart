import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/update/update_manifest.dart';

void main() {
  group('UpdateManifest applicationId（串包防御字段）', () {
    test('解析带 applicationId 的清单', () {
      final m = UpdateManifest.parse('''
{
  "versionCode": 2003,
  "versionName": "1.0.1",
  "applicationId": "com.zzh.goodhub",
  "apkUrl": "https://example.com/updates/goodhub/app-release.apk",
  "sha256": "abc123",
  "changelog": "test"
}
''');
      expect(m.applicationId, 'com.zzh.goodhub');
      expect(m.versionCode, 2003);
      expect(m.isNewerThan(2002), isTrue);
    });

    test('旧清单无 applicationId 时为 null（宽容兼容）', () {
      final m = UpdateManifest.parse('''
{
  "versionCode": 2002,
  "versionName": "1.0.0",
  "apkUrl": "https://example.com/app-release.apk",
  "sha256": "abc123"
}
''');
      expect(m.applicationId, isNull);
      expect(m.isNewerThan(2002), isFalse);
    });
  });
}
