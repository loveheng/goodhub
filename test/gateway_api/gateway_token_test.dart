/// 网关配对 Token 决策单测（`lib/gateway_api/gateway_token.dart`）。
///
/// 钉住「消除默认无鉴权」这一产品裁决的口径：
/// - 输入框有值 → 用户值优先（不被自动生成覆盖）；
/// - 留空 + 自动生成开 → 生成 Token（**默认安全路径**，起服必带 Bearer）；
/// - 留空 + 自动生成关 → 免鉴权（用户**显式**选择的逃生口）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/gateway_api/gateway_token.dart';

void main() {
  group('起服 Token 决策', () {
    test('输入框有值 → 用用户值（显式指定优先，自动生成不覆盖）', () {
      expect(
        resolveGatewayToken(input: '  my-token  ', autoGenerate: true),
        'my-token',
        reason: '用户手填的 Token 不得被自动生成覆盖',
      );
      expect(resolveGatewayToken(input: 'my-token', autoGenerate: false),
          'my-token');
    });

    test('留空 + 自动生成开 → 生成非空 Token（默认安全：不再默认免鉴权）', () {
      final t = resolveGatewayToken(input: '   ', autoGenerate: true);
      expect(t, isNotEmpty, reason: '默认路径必须带 Bearer，不得静默免鉴权');
      expect(t.length, greaterThanOrEqualTo(32));
    });

    test('留空 + 自动生成关 → 空串（用户显式免鉴权，逃生口保留）', () {
      expect(resolveGatewayToken(input: '', autoGenerate: false), '');
      expect(resolveGatewayToken(input: '  ', autoGenerate: false), '');
    });

    test('生成器注入位生效（单测可固定）', () {
      expect(
        resolveGatewayToken(
          input: '',
          autoGenerate: true,
          generator: () => 'FIXED-TOKEN',
        ),
        'FIXED-TOKEN',
      );
    });
  });

  group('Token 生成', () {
    test('长度与字符集达标（URL-safe，便于手抄进 PC 端）', () {
      final t = generateGatewayToken();
      expect(t.length, greaterThanOrEqualTo(40));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(t), isTrue,
          reason: 'base64url 无填充——不得含 + / = 等易抄错字符');
    });

    test('每次生成互不相同（随机源有效）', () {
      final tokens = {for (var i = 0; i < 20; i++) generateGatewayToken()};
      expect(tokens.length, 20, reason: '20 次生成须全异——重复即随机源失效');
    });
  });
}
