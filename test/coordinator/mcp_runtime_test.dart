/// B2 基线测试（window-kernel-split 步 0）：会话绑定默认回退链纯函数。
///
/// 回退链（plan.md §2.1 B2，「最易改错的一段」）：
/// 已显式绑定直接用（'' → null = 显式公共）→ 全局钉选 isDefault →
/// 首个 private → null。与 `chat_page._resolveBinding` 逐行同构（步 3 接线
/// 替换，等价性由此钉住）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/mcp/server_endpoints.dart';

ServerEndpoint ep(
  String id, {
  ServerPrivacyTier tier = ServerPrivacyTier.private,
  bool isDefault = false,
}) =>
    ServerEndpoint(id: id, name: id, endpoint: 'http://x/mcp', tier: tier, isDefault: isDefault);

void main() {
  group('resolveBinding 回退链（B2）', () {
    test('已显式绑定 serverId：直接锁定，无视 isDefault 与顺序', () {
      final eps = [ep('a', isDefault: true), ep('b')];
      expect(resolveBinding(eps, bound: 'b'), 'b');
    });

    test('显式公共（''）→ null（不再回退私有——三态语义防回跳）', () {
      final eps = [ep('a', isDefault: true)];
      expect(resolveBinding(eps, bound: ''), isNull);
    });

    test('未绑定 + 全局钉选：isDefault 优先，与排列顺序无关', () {
      expect(resolveBinding([ep('a'), ep('d', isDefault: true)]), 'd');
      expect(resolveBinding([ep('d', isDefault: true), ep('a')]), 'd');
    });

    test('未绑定 + 无钉选：首个 private（保持列表序）', () {
      expect(resolveBinding([ep('p2'), ep('p1')]), 'p2');
    });

    test('public 端点不参与回退', () {
      expect(
        resolveBinding([
          ep('pub', tier: ServerPrivacyTier.public),
          ep('pub2', tier: ServerPrivacyTier.public, isDefault: true),
        ]),
        isNull,
        reason: 'public（含 isDefault）不得进私有槽位回退链',
      );
    });

    test('无 private 端点 → null（纯公共）', () {
      expect(resolveBinding(const <ServerEndpoint>[]), isNull);
    });

    test('钉选优先于首个 private（同列表两私有）', () {
      expect(resolveBinding([ep('first'), ep('pinned', isDefault: true)]), 'pinned');
    });
  });
}
