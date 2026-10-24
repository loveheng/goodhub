/// 信任白名单单测：F7 写串行队列 + F13 签名指纹复核（review-fix-2026-10）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/trusted_plugins.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TrustedPlugins.resetForTest();
  });

  test('F13：包名命中且指纹一致 → 信任；异签名 → 不信任（冒名挂载防线）', () async {
    final t = await TrustedPlugins.instance;
    await t.add('com.good.plugin', 'sha-aaa', '好插件');

    expect(t.isTrusted('com.good.plugin', signatureSha256: 'sha-aaa'), isTrue);
    // 同包名不同签名（原插件卸载后恶意 App 冒名）→ 拒绝，走信任卡重确认。
    expect(t.isTrusted('com.good.plugin', signatureSha256: 'sha-evil'), isFalse,
        reason: 'F13：白名单不得只按包名放行（sha256 记录须有消费点）');
    // 无指纹调用面（渐进迁移）：维持包名口径。
    expect(t.isTrusted('com.good.plugin'), isTrue);
    expect(t.isTrusted('com.unknown'), isFalse);
  });

  test('F13：记录缺指纹（损坏条目）→ fail-closed 不信任', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'goodhub.trusted_plugins',
      '{"com.legacy": {"title": "旧条目"}}',
    );
    final t = await TrustedPlugins.instance;
    expect(t.isTrusted('com.legacy', signatureSha256: 'sha-x'), isFalse,
        reason: '无法复核的条目按不信任处理（重新过信任卡即修复）');
  });

  test('F7：写操作 FIFO 串行——remove 后 add 同包，终态以提交序为准', () async {
    final t = await TrustedPlugins.instance;
    await t.add('com.x', 'sha-1', 'X');
    // 并发提交：先撤销再重新信任 → 队列序生效，终态 = 信任（新指纹）。
    final ops = [
      t.remove('com.x'),
      t.add('com.x', 'sha-2', 'X2'),
    ];
    await Future.wait(ops);
    expect(t.isTrusted('com.x', signatureSha256: 'sha-2'), isTrue,
        reason: 'F7：按提交序串行，remove 不被旧快照复活/覆盖');
    // 反序：先 add 后 remove → 终态 = 已撤销。
    await t.add('com.y', 'sha-1', 'Y');
    await Future.wait([t.add('com.z', 'sha-1', 'Z'), t.remove('com.y')]);
    expect(t.isTrusted('com.y'), isFalse);
    expect(t.isTrusted('com.z', signatureSha256: 'sha-1'), isTrue);
  });

  test('F7：并发首访单例去重（future 缓存，双实例即红）', () async {
    final a = TrustedPlugins.instance;
    final b = TrustedPlugins.instance;
    expect(identical(a, b), isTrue, reason: '并发首访须命中同一 future');
    expect(identical(await a, await b), isTrue);
  });
}
