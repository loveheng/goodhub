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


  // F14（review-fix-2026-10）：完整性链收紧——http 明文源（非回环）与缺失
  // sha256 的清单一律拒绝（撤修复即红：此前 http 放行 + sha256 可空）。
  group('F14 完整性收紧：https 强制 + sha256 必填', () {
    test('http 明文 apkUrl（非回环）→ 拒绝', () {
      expect(
        () => UpdateManifest.parse('''
  {
    "versionCode": 2004,
    "versionName": "1.0.2",
    "apkUrl": "http://updates.example.com/app.apk",
    "sha256": "abc123"
  }
  '''),
        throwsA(isA<FormatException>()),
        reason: 'F14：明文源可被劫持投递任意包',
      );
    });
  
    test('缺失 sha256 → 拒绝（零完整性校验的清单不受信）', () {
      expect(
        () => UpdateManifest.parse('''
  {
    "versionCode": 2004,
    "versionName": "1.0.2",
    "apkUrl": "https://updates.example.com/app.apk"
  }
  '''),
        throwsA(isA<FormatException>()),
      );
    });
  
    test('回环 http 豁免（本地调试/单测地基，不可远程劫持）', () {
      final m = UpdateManifest.parse('''
  {
    "versionCode": 2004,
    "versionName": "1.0.2",
    "apkUrl": "http://127.0.0.1:8123/app.apk",
    "sha256": "abc123"
  }
  ''');
      expect(m.apkUrl, startsWith('http://127.0.0.1'));
    });
  });
}
