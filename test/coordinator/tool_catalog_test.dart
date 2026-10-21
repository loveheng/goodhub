/// `lib/coordinator/tool_catalog.dart` 单测：三态可见性投影 + 注册清单合并/过滤。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/tool_catalog.dart';
import 'package:goodhub/core/security/secure_key_value.dart';
import 'package:goodhub/core/tool_visibility.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_endpoints.dart';

/// 三态投影（MC3-a）：显式 shared / 显式 private / 未声明兜底 private。
void main() {
  group('McpCatalogTool.fromSchema 三态', () {
    test('显式 shared → declared + shared', () {
      final s = CloudToolSchema(
        name: 'echo',
        description: '',
        parametersSchema: const {},
        annotations: null,
        meta: const {'goodhub': {'visibility': 'shared'}},
        visibility: ToolVisibility.shared,
      );
      final t = McpCatalogTool.fromSchema(s);
      expect(t.declared, isTrue);
      expect(t.visibility, ToolVisibility.shared);
    });

    test('显式 private → declared=true', () {
      final s = CloudToolSchema(
        name: 'p',
        description: '',
        parametersSchema: const {},
        annotations: null,
        meta: const {'goodhub': {'visibility': 'private'}},
        visibility: ToolVisibility.private,
      );
      final t = McpCatalogTool.fromSchema(s);
      expect(t.declared, isTrue);
      expect(t.visibility, ToolVisibility.private);
    });

    test('未声明（缺 goodhub.visibility）→ declared=false，兜底 private', () {
      final s = CloudToolSchema(
        name: 'legacy',
        description: '',
        parametersSchema: const {},
        annotations: null,
        meta: null,
        visibility: ToolVisibility.private, // parseToolVisibility 兜底
      );
      final t = McpCatalogTool.fromSchema(s);
      expect(t.declared, isFalse);
      expect(t.visibility, ToolVisibility.private);
    });

    test('声明形状异常（goodhub 非对象）→ declared=false', () {
      final s = CloudToolSchema(
        name: 'x',
        description: '',
        parametersSchema: const {},
        annotations: null,
        meta: const {'goodhub': 'not-an-object'},
        visibility: ToolVisibility.private,
      );
      final t = McpCatalogTool.fromSchema(s);
      expect(t.declared, isFalse);
    });
  });

  group('McpCatalog.loadRegisteredServices 合并/过滤', () {
    test('合并本地+远端，过滤空 id / 未启用，label 回退 serverId', () async {
      final disc = _FakeDiscovery([
        LocalPluginInfo(
          serverId: 'plug1',
          serverTitle: 'Plug One',
          packageName: 'p',
          serviceClassName: 's',
          sameSignature: true,
        ),
        LocalPluginInfo(
          serverId: '',
          serverTitle: 'bad',
          packageName: 'p',
          serviceClassName: 's',
        ),
      ]);
      final store = _FakeStore([
        ServerEndpoint(id: 'ep1', name: 'Remote A', endpoint: 'http://x/mcp'),
        ServerEndpoint(
          id: 'ep2',
          name: 'Disabled',
          endpoint: 'http://y/mcp',
          enabled: false,
        ),
        ServerEndpoint(id: '', name: 'bad', endpoint: ''),
      ]);
      final cat = McpCatalog(
        discovery: disc,
        endpointStore: ({String? supportPath}) async => store,
      );

      final services = await cat.loadRegisteredServices();

      expect(services.length, 2);
      expect(
        services.any((s) =>
            s.serverId == 'plug1' &&
            s.label == 'Plug One' &&
            s.source == CatalogSource.localPlugin &&
            s.trusted),
        isTrue,
      );
      expect(
        services.any((s) =>
            s.serverId == 'ep1' &&
            s.label == 'Remote A' &&
            s.source == CatalogSource.remoteEndpoint &&
            s.remote!.tier == ServerPrivacyTier.private),
        isTrue,
      );
    });
  });
}

/// 假发现门面（scan 返回预设，不触发平台通道）。
class _FakeDiscovery implements LocalPluginSource {
  _FakeDiscovery(this.result);
  final List<LocalPluginInfo> result;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<List<LocalPluginInfo>> scan() async => result;

  @override
  McpClient createClient(LocalPluginInfo info) =>
      throw UnimplementedError('测试不调用');
}

/// 假端点 store（load 返回预设，不读盘）。
class _FakeStore extends ServerEndpointStore {
  _FakeStore(this.eps)
      : super(file: File('x'), secure: InMemorySecureKeyValue());

  final List<ServerEndpoint> eps;

  @override
  Future<List<ServerEndpoint>> load() async => eps;
}
