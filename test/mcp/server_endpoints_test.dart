import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/security/secure_key_value.dart';
import 'package:goodhub/mcp/server_endpoints.dart';

/// 测试用 SharedPreferencesLike 假件（内存 Map，模拟旧单端点键位）。
class _FakePrefs implements SharedPreferencesLike {
  _FakePrefs([Map<String, String>? initial]) : _map = initial ?? {};

  final Map<String, String> _map;

  @override
  Future<String?> read(String key) async => _map[key];
}

void main() {
  late Directory tmp;
  late File file;
  late InMemorySecureKeyValue secure;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('server_endpoints_test');
    file = File('${tmp.path}/mcp_servers.json');
    secure = InMemorySecureKeyValue();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  ServerEndpointStore buildStore({SharedPreferencesLike? prefs}) =>
      ServerEndpointStore(file: file, secure: secure, prefs: prefs);

  const ep1 = ServerEndpoint(
    id: 'srv_a',
    name: 'goodshare',
    endpoint: 'http://10.0.2.2:8000/mcp',
    hasKey: true,
  );
  const ep2 = ServerEndpoint(
    id: 'srv_b',
    name: 'shuguang',
    endpoint: 'https://example.com/mcp',
  );

  test('save/load 多端点 round-trip（含 apiKey 独立安全存储）', () async {
    final store = buildStore();
    await store.save([ep1, ep2]);
    await store.setApiKey('srv_a', 'sk-secret');

    final loaded = await buildStore().load();
    expect(loaded.map((e) => e.id), ['srv_a', 'srv_b']);
    expect(loaded[0].name, 'goodshare');
    expect(loaded[0].endpoint, 'http://10.0.2.2:8000/mcp');
    expect(loaded[0].hasKey, isTrue);
    expect(loaded[1].hasKey, isFalse);

    // 密钥纪律（F1.12）：JSON 文件不含明文密钥，经 SecureKeyValue 取回。
    final raw = await file.readAsString();
    expect(raw, isNot(contains('sk-secret')));
    expect(await store.apiKey('srv_a'), 'sk-secret');
    expect(await store.apiKey('srv_b'), isNull);
  });

  test('文件缺失且无旧键 → 空目录（首启形态）', () async {
    final store = buildStore(prefs: _FakePrefs());
    expect(await store.load(), isEmpty);
    expect(await file.exists(), isFalse, reason: '不应无谓落盘');
  });

  test('旧单端点迁移：文件缺失 + chat.mcp.* 在位 → 迁为 goodshare 一条', () async {
    final store = buildStore(
      prefs: _FakePrefs({
        'chat.mcp.endpoint': 'http://10.0.2.2:8000/mcp',
        'chat.mcp.apiKey': 'legacy-token',
      }),
    );

    final loaded = await store.load();
    expect(loaded.single.id, 'goodshare');
    expect(loaded.single.endpoint, 'http://10.0.2.2:8000/mcp');
    expect(loaded.single.hasKey, isTrue);
    expect(await store.apiKey('goodshare'), 'legacy-token',
        reason: '旧令牌写入安全存储');
    expect(await file.exists(), isTrue, reason: '迁移即落盘，后续 load 不再走迁移');

    // 旧键保留不删（回滚无损，双写一个版本期）——假件无删除口，且二次 load
    // 不再触发迁移（文件已在位）。
    final again = await store.load();
    expect(again.single.id, 'goodshare');
  });

  test('文件在位时不触发旧迁移（文件优先）', () async {
    final store = buildStore();
    await store.save([ep2]);
    final loaded = await buildStore(prefs: _FakePrefs({
      'chat.mcp.endpoint': 'http://legacy/mcp',
      'chat.mcp.apiKey': 'legacy-token',
    })).load();
    expect(loaded.single.id, 'srv_b', reason: '配置文件已在位，旧键忽略');
  });

  test('损坏文件 → 空目录（宁空勿炸，可重新添加）', () async {
    await file.writeAsString('{not-a-json-list');
    expect(await buildStore().load(), isEmpty);
  });

  test('坏条目跳过不拖垮整表（id/endpoint 缺失过滤）', () async {
    await file.writeAsString('''
[
  {"id": "srv_ok", "name": "ok", "endpoint": "http://x/mcp", "hasKey": false},
  {"id": "", "name": "no-id", "endpoint": "http://x/mcp"},
  {"id": "srv_noep", "name": "no-endpoint"},
  "not-a-map",
  {"id": "srv_ok2", "name": "ok2", "endpoint": "http://y/mcp", "hasKey": true}
]
''');
    final loaded = await buildStore().load();
    expect(loaded.map((e) => e.id), ['srv_ok', 'srv_ok2']);
  });

  test('enabled 挂载位 round-trip（缺省 true，显式 false 落盘）', () async {
    final store = buildStore();
    await store.save([
      ep1,
      ep2.copyWith(enabled: false), // T5 节点卡卸载态
    ]);
    final loaded = await buildStore().load();
    expect(loaded[0].enabled, isTrue, reason: '缺省 = 挂载');
    expect(loaded[1].enabled, isFalse);

    // 旧版 JSON 无 enabled 字段 → 解析缺省 true（零迁移兼容）。
    await file.writeAsString('''
[{"id": "srv_old", "name": "old", "endpoint": "http://x/mcp", "hasKey": false}]
''');
    final legacy = await buildStore().load();
    expect(legacy.single.enabled, isTrue);
  });

  test('旧单端点迁移产物 enabled=true（迁移即挂载）', () async {
    final store = buildStore(
      prefs: _FakePrefs({'chat.mcp.endpoint': 'http://10.0.2.2:8000/mcp'}),
    );
    final loaded = await store.load();
    expect(loaded.single.enabled, isTrue);
  });

  test('setApiKey 空串/null 即删除密钥（防孤儿）', () async {
    final store = buildStore();
    await store.setApiKey('srv_a', 'sk-secret');
    expect(await store.apiKey('srv_a'), 'sk-secret');
    await store.setApiKey('srv_a', '');
    expect(await store.apiKey('srv_a'), isNull);
    await store.setApiKey('srv_a', 'sk-again');
    await store.setApiKey('srv_a', null);
    expect(await store.apiKey('srv_a'), isNull);
  });

  test('save 原子性：.tmp 残留不污染 load', () async {
    final store = buildStore();
    await store.save([ep1]);
    File('${file.path}.tmp').writeAsStringSync('[]'); // 模拟历史残留
    expect(await store.load().then((l) => l.single.id), 'srv_a');
  });
}
