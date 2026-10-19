/// coordinator/chat_run_orchestrator.mountedServicesSection 单测（2026-10-19）。
///
/// 锁住的状态分叉契约：存在未锁槽私有服务时，摘要必须① 按纯聊天模式定性
///（未选中私有服务就当纯聊天，仅基础服务常驻，不主动调用工具——防幻觉
/// 直调熔断链）、② 私有行标「未锁定，需 use_server」（占槽无标记；纠偏旧
/// 「未激活」错标）、③ 尾句动词对齐（私有 = use_server）。已锁槽/纯公共时
/// 不注入纯聊天段。
library;

import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/chat_run_orchestrator.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/tool_router.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';

class _StubFace extends McpToolFace {
  _StubFace({required super.serverId})
      : super(client: McpClient.http(
            baseUrl: 'http://fake',
            httpClient: MockClient((_) async => http.Response(
                json.jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': {}}),
                200,
                headers: {'content-type': 'application/json'}))));

  @override
  List<CloudToolSchema> get cachedSchemas => const [];

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async =>
      const ToolExecutionResult(content: 'ok');
}

ToolRouter _router() {
  final router = ToolRouter(
    faces: {
      'pub': _StubFace(serverId: 'pub'),
      'lp1': _StubFace(serverId: 'lp1'),
      'lp2': _StubFace(serverId: 'lp2'),
    },
    privateServerIds: const {'lp1', 'lp2'},
  );
  // 对齐装配层口径：public 挂载即默认全激活（mcp_runtime assemble）。
  router.activatedServers.add('pub');
  return router;
}

const _summaries = <String, String>{
  'pub': '公共服务',
  'lp1': '插件一',
  'lp2': '插件二',
};

void main() {
  group('mountedServicesSection：无锁槽私有（纯聊天模式）', () {
    test('纯聊天模式定型：不主动调用工具 + 基础服务常驻 + 私有行标记 + use_server 尾句', () {
      final section =
          ChatRunOrchestrator.mountedServicesSection(_router(), _summaries);
      expect(section, contains('当前会话未锁定私有服务，按纯聊天模式处理'));
      expect(section, contains('不主动调用工具'));
      expect(section, contains('宿主基础能力（公共面工具、记忆、技能）常驻可用'));
      expect(section, contains('use_server(server_id) 锁定'));
      expect(section, contains('- lp1: 插件一 ［未锁定，需 use_server］'));
      expect(section, contains('- lp2: 插件二 ［未锁定，需 use_server］'));
      expect(section, contains('未锁定服务用 get_connected_apps 查看、use_server 锁定。'));
      expect(section, isNot(contains('activate_server_tools 激活。')),
          reason: '无未激活公共时尾句不走 activate 口径');
    });

    test('公共行无未激活标记（挂载即默认全激活）', () {
      final section =
          ChatRunOrchestrator.mountedServicesSection(_router(), _summaries);
      expect(section, contains('- pub: 公共服务\n'));
      expect(section, isNot(contains('pub: 公共服务 ［')),
          reason: 'public 挂载即全激活，不标未激活');
    });
  });

  group('mountedServicesSection：已锁槽 / 纯公共', () {
    test('槽位 lp1：lp1 无标记、lp2 仍标未锁定，不注入纯对话段', () {
      final router = _router();
      router.activePrivateServerId = 'lp1';
      final section =
          ChatRunOrchestrator.mountedServicesSection(router, _summaries);
      expect(section, contains('- lp1: 插件一\n'));
      expect(section, contains('- lp2: 插件二 ［未锁定，需 use_server］'));
      expect(section, isNot(contains('未锁定任何私有服务')),
          reason: '有槽位 = 私有域已定，不给纯对话出路段');
      expect(section, contains('未激活服务用 get_connected_apps 查看、activate_server_tools 激活。'));
    });

    test('纯公共（无私有）：原样摘要，无纯对话段无未锁定标记', () {
      final router = ToolRouter(faces: {'pub': _StubFace(serverId: 'pub')});
      router.activatedServers.add('pub'); // 挂载即默认全激活（装配层口径）
      final section = ChatRunOrchestrator.mountedServicesSection(
          router, const {'pub': '公共服务'});
      expect(section, contains('- pub: 公共服务\n'));
      expect(section, isNot(contains('未锁定')));
      expect(section, isNot(contains('未锁定任何私有服务')));
    });
  });
}
