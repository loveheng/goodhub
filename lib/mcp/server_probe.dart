/// Server 节点探活（M4-T5 节点卡数据面，ui-design §3.3）。
///
/// 节点卡展示「端口 / 延迟毫秒 / 在线绿点 / 已暴露工具计数 / 鉴权态」的
/// 取数面：对单端点做一次 `initialize` 握手 + `tools/list` 计数，全程计时。
///
/// - **鉴权态（F1.17 同机零信任）**：HTTP 401/403 → [NodeProbeResult.authDenied]
///   （节点卡 Rose「待授权」），与「离线」（连不上）显式区分，禁混灰阶；
/// - **只读探活**：仅握手 + 清单，不触发任何工具执行——对 Tier 2 vanilla
///   server 同样安全（initialize/tools/list 是 MCP 基线方法）；
/// - 探测失败不抛穿：结果以 [NodeProbeResult.online]=false 承载（错误文本进
///   error 字段供节点卡呈现）——探活是展示面取数，失败本身即「离线」观测值。
library;

import '../core/errors/mcp_error.dart';
import 'mcp_client.dart';

/// 单节点探活结果（节点卡渲染输入）。
class NodeProbeResult {
  const NodeProbeResult({
    required this.online,
    this.latencyMs,
    this.toolCount,
    this.authDenied = false,
    this.error,
  });

  /// 握手 + tools/list 全程成功（在线绿点）。
  final bool online;

  /// 全程耗时毫秒（握手 + 工具清单）；失败时为探测中止前耗时，展示面仅在
  /// [online] 时使用。
  final int? latencyMs;

  /// tools/list 已暴露工具数；形状异常时为 null（错误文本进 [error]）。
  final int? toolCount;

  /// 401/403 → 待授权（节点卡 Rose，禁与离线灰阶混淆）。
  final bool authDenied;

  final String? error;
}

/// 探活器：对单端点计时握手 + 工具计数。
///
/// [clientFactory] 测试注入位（默认 HTTP 传输真实装配）；生产探活一次性
/// 建 client 用完即弃（close 释放底层连接，无状态逐请求不留会话）。
class ServerProber {
  ServerProber({
    McpClientFactory? clientFactory,
    this.timeout = const Duration(seconds: 5),
  }) : _clientFactory =
            clientFactory ?? ((endpoint, apiKey) => McpClient.http(baseUrl: endpoint, apiKey: apiKey));

  final McpClientFactory _clientFactory;

  /// 单方法超时（握手 / 工具清单各计一次）；局域网直连 5s 足够宽。
  final Duration timeout;

  Future<NodeProbeResult> probe(String endpoint, {String? apiKey}) async {
    final sw = Stopwatch()..start();
    McpClient? client;
    try {
      client = _clientFactory(endpoint, apiKey);
      await client.negotiate().timeout(timeout);
      final toolCount = await _toolCount(client).timeout(timeout);
      sw.stop();
      return NodeProbeResult(
        online: true,
        latencyMs: sw.elapsedMilliseconds,
        toolCount: toolCount,
      );
    } on McpNetworkException catch (e) {
      sw.stop();
      final sc = e.statusCode;
      return NodeProbeResult(
        online: false,
        latencyMs: sw.elapsedMilliseconds,
        authDenied: sc == 401 || sc == 403,
        error: sc != null ? 'HTTP $sc' : e.message,
      );
    } on McpProtocolException catch (e) {
      // 握手已通、tools/list 形状异常 → 在线但工具数不可知（观测留痕不假报）。
      sw.stop();
      return NodeProbeResult(
        online: true,
        latencyMs: sw.elapsedMilliseconds,
        error: e.message,
      );
    } on Object catch (e) {
      sw.stop();
      return NodeProbeResult(
        online: false,
        latencyMs: sw.elapsedMilliseconds,
        error: '$e',
      );
    } finally {
      try {
        client?.close();
      } on Object {
        // close 失败不影响探活结果（连接资源由进程退出兜底）。
      }
    }
  }

  Future<int> _toolCount(McpClient client) async {
    final result = await client.call('tools/list');
    if (result is! Map) {
      throw const McpProtocolException('tools/list result is not an object');
    }
    final tools = result['tools'];
    if (tools is! List) {
      throw const McpProtocolException('tools/list missing tools array');
    }
    return tools.length;
  }
}

/// MCP client 装配口径（endpoint + 可空 apiKey → client）。
typedef McpClientFactory = McpClient Function(String endpoint, String? apiKey);
