import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/actor.dart';

/// 调用主体值对象测试（task-capability W1-S06）：
/// App 身份档（包名 + 签名指纹）——字段判据与信任白名单同源；主体只在
/// 鉴权层推导、禁从载荷读（推导纪律是调用方纪律，此处钉值对象形状）。
void main() {
  group('Actor.app 身份档（W1-S06）', () {
    test('构造与展示标签：app:<packageName>', () {
      const a = Actor.app(
        packageName: 'com.example.app',
        signatureSha256: 'aa11',
      );
      expect(a.label, 'app:com.example.app');
      expect(a.toString(), 'Actor(app:com.example.app)');
    });

    test('签名指纹缺省为空（鉴权层无指纹数据 → 信任按包名口径）', () {
      const a = Actor.app(packageName: 'com.example.app');
      expect(a.label, 'app:com.example.app');
    });

    test('相等性：包名 + 指纹全同才相等（不同指纹不冒充）', () {
      expect(
        const Actor.app(packageName: 'com.a', signatureSha256: 'x'),
        const Actor.app(packageName: 'com.a', signatureSha256: 'x'),
      );
      expect(
        const Actor.app(packageName: 'com.a', signatureSha256: 'x'),
        isNot(const Actor.app(packageName: 'com.a', signatureSha256: 'y')),
      );
      expect(
        const Actor.app(packageName: 'com.a'),
        isNot(const Actor.app(packageName: 'com.b')),
      );
    });

    test('三档互异：app ≠ owner ≠ external（权限裁决分支不串档）', () {
      const app = Actor.app(packageName: 'com.a', signatureSha256: 'x');
      expect(app, isNot(Actor.owner));
      expect(app, isNot(const Actor.external('com.a')));
    });

    test('既有两档语义不变：owner / external 的 label 与相等性', () {
      expect(Actor.owner.label, 'owner');
      expect(const Actor.external('gateway').label, 'external:gateway');
      expect(const Actor.external('gateway'),
          const Actor.external('gateway'));
      expect(const Actor.external('gateway'), isNot(Actor.owner));
    });
  });
}
