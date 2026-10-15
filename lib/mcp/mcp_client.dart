/// MCP Client：JSON-RPC 2.0 协议层（无状态逐请求，接缝契约前提）。
///
/// 协议语义住本文件（coding-standards §1 边界纪律：core/network 只放纯传输底座）；
/// 原始 I/O 委托给 [McpTransport]（HTTP 实现见 transport/mcp_transport.dart；
/// 同机 Binder 实现规划于 thirdconnect T-trans-2/3）。本文件不含任何传输细节。
library;

import 'dart:async';
import 'dart:convert' as json;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../core/errors/mcp_error.dart';
import '../core/network/backoff.dart';
import 'json_rpc.dart';
import 'server_capabilities.dart';
import 'transport/binder_transport.dart';
import 'transport/mcp_transport.dart';

class McpClient {
  McpClient(this.transport);

  /// 便捷构造：HTTP 传输（兼容既有调用点，endpoint 须含 /mcp 路径）。
  factory McpClient.http({
    required String baseUrl,
    String? apiKey,
    http.Client? httpClient,
  }) =>
      McpClient(HttpTransport(
        baseUrl: baseUrl,
        apiKey: apiKey,
        httpClient: httpClient,
      ));

  /// 便捷构造：同机 Binder 传输（T-trans-2/3，零端口；对端 = 本地插件 Service）。
  /// [transportId] 区分多插件；[packageName]/[serviceClassName] 定位目标 Service。
  /// Binder 反向请求经 EventChannel 异步到达（非内联 SSE），由 [BinderTransport]
  /// 接管回程——此处把其 [BinderTransport.onServerRequest] 转发到本 client 的同一
  /// 处理器（闭包读最新值，handler 后置赋值安全）。
  factory McpClient.binder({
    required String transportId,
    required String packageName,
    required String serviceClassName,
  }) {
    final t = BinderTransport(
      transportId: transportId,
      packageName: packageName,
      serviceClassName: serviceClassName,
    );
    final client = McpClient(t);
    t.onServerRequest = (method, params) async {
      final handler = client.onServerRequest;
      if (handler == null) return null;
      return handler(method, params);
    };
    // Binder 路径 server 主动通知（无 id）分发到统一通知分发器（含 onResourceUpdated）。
    t.onServerNotification = (method, params) => client.handleServerNotification(method, params);
    return client;
  }

  /// 底层传输（HTTP / Binder / ...），协议层对其无感知。
  final McpTransport transport;

  /// 能力协商缓存（negotiate 幂等的载体）——一个 client 实例 = 一条 server 连接，
  /// 握手一次全程复用（SessionManager 共享连接池语义，architecture §15）。
  Future<ServerCapabilities>? _negotiating;

  /// 最近一次协商出的能力（订阅 gate / 重连重放判定用）；未协商时为 null。
  ServerCapabilities? _caps;

  /// server→client 反向请求处理器（M3，ai-app-split.md §3.11）：流式调用期间
  /// server 发来的 JSON-RPC request（如 sampling/createMessage）经此分派，
  /// 响应按 id POST 回端点（Streamable HTTP 回程序径）。null = 未启用反向
  /// 请求（server 请求收到 -32601 error 帧，不悬挂）；处理器抛 McpRpcException
  /// 转 error 帧（配额超限等结构化拒绝），其他异常转 -32603。
  Future<Map<String, Object?>?> Function(String method, Object? params)? onServerRequest;

  /// server→client 主动通知分发（T4-5，§3.10）：当前仅消费
  /// [notifications/resources/updated] → [onResourceUpdated]（D19 失效感知：
  /// 不自动重读，仅回告）；其余通知忽略。POST SSE 流（[callWithProgress]）与
  /// （收官将建的）GET SSE 订阅通道共用本分发器。
  void Function(String uri)? onResourceUpdated;

  /// 能力协商（M2.5-T2）：initialize 握手 + notifications/initialized 通知，
  /// 结果按 client 实例缓存（幂等——重复调用不重发请求）；握手失败后允许重试
  /// （缓存置空，下次调用重新握手——协商失败是「连不上/协议坏」，与 Polyfill
  /// 的「server 缺能力」降级语义不同层，后者由 [ServerCapabilities] 字段表达）。
  /// 清除握手缓存，强制下次 [negotiate] 重新握手（T4-3 重连语义：server 重启后
  /// 旧 session 失效，必须重 initialize 而非复用缓存——[negotiate] 的缓存是为
  /// 「连得上但重复调用」省握手，与「连不上要重连」语义不同层）。
  void resetNegotiation() => _negotiating = null;

  Future<ServerCapabilities> negotiate() {
    final existing = _negotiating;
    if (existing != null) return existing;
    final f = _doNegotiate().catchError((Object e, StackTrace st) {
      _negotiating = null; // 失败可重试
      throw e;
    });
    _negotiating = f;
    return f;
  }

  Future<ServerCapabilities> _doNegotiate() async {
    final result = await call('initialize', params: {
      'protocolVersion': kMcpProtocolVersion,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'goodhub', 'version': '0.1.0'},
    });
    final caps = ServerCapabilities.parse(result);
    _caps = caps;
    // 规范握手第二步（MCP 2025-06-18：client 必须回 initialized 通知）。
    // DEGRADE: 个别 server 对通知返回 4xx 时不阻断连接（capabilities 已到手，
    // 通知失败仅留痕）——降级为无通知连接，不得让握手整段失败。
    try {
      await notify('notifications/initialized');
    } catch (e) {
      debugPrint('[DEGRADE] mcp-negotiate: initialized notify failed (ignored): $e');
    }
    return caps;
  }

  Future<Object?> call(String method, {Object? params}) async {
    final req = JsonRpcRequest(method, params: params);
    final resp = await transport.send(req.encode());
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw McpNetworkException('HTTP ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    final body = resp.body.trim();
    if (body.isEmpty) return null; // 202 Accepted（notification）
    final decoded = _decodePayload(body, resp.contentType);
    final response = JsonRpcResponse.parse(decoded);
    final err = response.error;
    if (err != null) throw err;
    return response.result;
  }

  static int _progressTokenCounter = 0;

  /// 带进度通告的调用（M2.5-T7，ai-app-split.md §3.9）：自动注入
  /// `_meta.progressToken`，server 回 SSE 帧流时**流式分帧解析**——progress
  /// 通知帧走 [onProgress]，终帧返回 result；server 忽略 token 回单 JSON 时
  /// 原路解析（Tier 2 兼容，opt-in 语义的收侧）。
  /// [onRequestId]（M3-T2）：请求 id 分配即回调——Abort 级联下发
  /// `notifications/cancelled` 需要知道在途请求 id（§3.11 回程同路）。
  /// C-1 缓冲黑洞的收侧兑现：逐行消费字节流，progress 帧无需等响应结束即达。
  Future<Object?> callWithProgress(
    String method, {
    Object? params,
    required void Function(Object? progressParams) onProgress,
    void Function(int requestId)? onRequestId,
  }) async {
    final token = ++_progressTokenCounter;
    final p = params is Map<String, Object?>
        ? Map<String, Object?>.of(params)
        : <String, Object?>{};
    p['_meta'] = {
      ...((p['_meta'] as Map<String, Object?>?) ?? const {}),
      'progressToken': token,
    };
    final req = JsonRpcRequest(method, params: p);
    if (onRequestId != null && req.id != null) onRequestId(req.id!);
    final resp = await transport.sendStream(req.encode());
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      await resp.lines.drain<void>();
      throw McpNetworkException('HTTP ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    final contentType = resp.contentType;
    if (!contentType.contains('text/event-stream')) {
      // 单 JSON 回退：server 无 progress 感知（Polyfill 语义的收侧）
      final body = (await resp.lines.join()).trim();
      if (body.isEmpty) return null;
      final response = JsonRpcResponse.parse(_decodePayload(body, contentType));
      final err = response.error;
      if (err != null) throw err;
      return response.result;
    }

    // SSE 分帧解析：`:` comment（keep-alive 心跳）忽略；`data:` 行累积，
    // 空行断帧——progress 通知即达即回调；server→client 反向请求（M3 §3.11）
    // 分派处理器并回程；其余通知帧忽略；带 id 无 method 的帧为终帧。
    final frame = StringBuffer();
    await for (final line in resp.lines) {
      if (line.startsWith(':')) continue;
      if (line.startsWith('data:')) {
        frame
          ..write(line.substring(5).trim())
          ..write('\n');
        continue;
      }
      if (line.isNotEmpty || frame.isEmpty) continue;
      final payload = frame.toString().trim();
      frame.clear();
      final msg = json.jsonDecode(payload);
      if (msg is Map<String, Object?>) {
        final method = msg['method'];
        if (method == 'notifications/progress') {
          onProgress(msg['params']);
          continue;
        }
        if (method is String && method.isNotEmpty && msg['id'] != null) {
          await _answerServerRequest(method, msg['id']!, msg['params']);
          continue;
        }
        if (method != null) {
          // server 主动通知帧（订阅失效 notifications/resources/updated 等）：
          // 经统一分发器路由（GET SSE 订阅通道亦复用本分发器，T4-5 收官建 GET
          // 监听后，推送帧同路分发，无需改写此处）。
          handleServerNotification(method, msg['params']);
          continue;
        }
      }
      final response = JsonRpcResponse.parse(msg);
      final err = response.error;
      if (err != null) throw err;
      return response.result;
    }
    throw const McpProtocolException('SSE stream ended without result frame');
  }

  /// 反向请求回程：handler result → POST {id, result}；McpRpcException →
  /// POST {id, error}（code/message/data 原样）；其他异常 → -32603。回程
  /// 失败仅 [DEGRADE] 留痕——流仍在读终帧，严禁让帧读取中断（server 侧按
  /// 超时兜底）。无论成败 server 侧 completer 必被唤醒，不悬挂。
  Future<void> _answerServerRequest(String method, Object id, Object? params) async {
    Map<String, Object?> frame;
    final handler = onServerRequest;
    if (handler == null) {
      frame = {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': '宿主未启用反向请求处理: $method'},
      };
    } else {
      try {
        final result = await handler(method, params);
        frame = {'jsonrpc': '2.0', 'id': id, 'result': result};
      } on McpRpcException catch (e) {
        frame = {
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': e.code,
            'message': e.message,
            if (e.data != null) 'data': e.data,
          },
        };
      } catch (e) {
        frame = {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32603, 'message': '宿主反向请求处理失败: $e'},
        };
      }
    }
    try {
      await transport.send(json.jsonEncode(frame));
    } catch (e) {
      debugPrint('[DEGRADE] mcp-client: server-request answer send failed: $e');
    }
  }

  /// 兼容 JSON 与 SSE 两种响应体（Streamable HTTP 允许服务端回 SSE 帧）。
  Object? _decodePayload(String body, String contentType) {
    if (contentType.contains('text/event-stream')) {
      for (final line in body.split('\n')) {
        if (line.startsWith('data:')) {
          final data = line.substring(5).trim();
          if (data.isNotEmpty) return json.jsonDecode(data);
        }
      }
      throw const McpProtocolException('SSE response without data frame');
    }
    return json.jsonDecode(body);
  }

  Future<Object?> notify(String method, {Object? params}) async {
    final req = JsonRpcRequest(method, params: params, notify: true);
    // 鉴权头必须带上（M3-T2 修复）：notify 走同一端点，带 token 的 server
    // 对无鉴权通知回 401——negotiate 的 initialized 通知此前一直被 DEGRADE
    // 静默吞掉（每连接必现的潜在失败），notifications/cancelled 同路受益。
    final resp = await transport.send(req.encode());
    if (resp.statusCode >= 400) {
      throw McpNetworkException('HTTP ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    return null;
  }

  /// 心跳探活（T4-2，F1.4）：MCP `ping`（2025-06-18，server 回 `{}`，最轻量）。
  /// 失败（网络/4xx/旧 server 不支持 -32601）由连接健康层按口径处理，不在此抛。
  Future<void> ping() => call('ping');

  /// resources/list（ai-app-split.md §3.8）：只读数据面清单。Tier 2 Server
  /// 无此能力——调用方按 capabilities（hasPrompts/hasResources）先判再调。
  Future<List<Map<String, Object?>>> listResources() async {
    final result = await call('resources/list');
    if (result is! Map) {
      throw const McpProtocolException('resources/list result is not an object');
    }
    final resources = result['resources'];
    if (resources is! List) {
      throw const McpProtocolException('resources/list missing resources array');
    }
    return [
      for (final r in resources)
        if (r is Map<String, Object?>) r,
    ];
  }

  /// resources/read：返回首个 text 内容块的文本（同 claim text 基线的只读注入）。
  /// T4-5 收官（读后自动订阅）：读取成功后 best-effort 订阅该 uri（D8/D19 数据
  /// 快照实时读 + 失效感知闭环），并启动下行监听。订阅能力缺失/离线时静默忽略，
  /// 不阻断读取。
  Future<String> readResource(String uri) async {
    final result = await call('resources/read', params: {'uri': uri});
    if (result is! Map) {
      throw const McpProtocolException('resources/read result is not an object');
    }
    final contents = result['contents'];
    if (contents is! List || contents.isEmpty) {
      throw const McpProtocolException('resources/read missing contents');
    }
    final first = contents.first;
    if (first is Map && first['text'] is String) {
      await _autoSubscribeAfterRead(uri); // best-effort，不阻断读取
      return first['text'] as String;
    }
    throw const McpProtocolException('resources/read content missing text');
  }

  /// 读后自动订阅（best-effort）：capabilities 声明订阅能力时订阅该 uri（幂等）并
  /// 启动下行监听；失败（无能力/离线/网络错）静默忽略。
  Future<void> _autoSubscribeAfterRead(String uri) async {
    try {
      if (_caps?.hasSubscriptions ?? false) {
        await subscribeResource(uri); // 幂等：已订阅不重发
        unawaited(startNotificationListener()); // 启动 GET SSE 监听
      }
    } catch (_) {
      // 订阅失败不影响读取结果
    }
  }

  /// prompts/list（ai-app-split.md §3.7）：CoW 模板源清单（含版本元数据）。
  /// Tier 2 无此能力——调用方按 capabilities（hasPrompts）先判再调。
  Future<List<Map<String, Object?>>> listPrompts() async {
    final result = await call('prompts/list');
    if (result is! Map) {
      throw const McpProtocolException('prompts/list result is not an object');
    }
    final prompts = result['prompts'];
    if (prompts is! List) {
      throw const McpProtocolException('prompts/list missing prompts array');
    }
    return [
      for (final p in prompts)
        if (p is Map<String, Object?>) p,
    ];
  }

  /// prompts/get 原文通道（不传 arguments → server 回未渲染模板，CoW 同步用）。
  Future<String> getPromptRaw(String name) async {
    final result = await call('prompts/get', params: {'name': name});
    if (result is! Map) {
      throw const McpProtocolException('prompts/get result is not an object');
    }
    final messages = result['messages'];
    if (messages is! List || messages.isEmpty) {
      throw const McpProtocolException('prompts/get missing messages');
    }
    final first = messages.first;
    if (first is Map && first['content'] is Map) {
      final content = first['content'] as Map;
      if (content['text'] is String) return content['text'] as String;
    }
    throw const McpProtocolException('prompts/get message missing text');
  }

  // ---- T4-5 订阅消费（§3.10 resources/subscribe + notifications/resources/updated）----

  /// 已订阅的 resource URI 集合（server 重启后订阅失效，由 [McpConnection] 重连时重放）。
  final Set<String> _subscribedUris = {};

  /// 当前已订阅的 resource URI 只读视图。
  Set<String> get subscribedUris => Set.unmodifiable(_subscribedUris);

  /// server 是否声明 `resources.subscribe` 能力（订阅门控；T4-5）。
  bool get canSubscribe => _caps?.hasSubscriptions ?? false;

  /// 订阅资源（MCP §3.10 `resources/subscribe`）：server 声明 `resources.subscribe`
  /// 时方可订阅，否则抛协议违规（Tier 2 / 未声明订阅能力的 server 不提供失效感知）。
  /// 返回 server 下发的 subscriptionId（部分 server 返回空结果，此时为空串）。
  /// [force]=true 跳过幂等去重（重连重放场景：server 重启已清空订阅，本地仍记
  /// 已订阅，须重发）；默认幂等（同 uri 重复订阅不重发）。
  Future<String> subscribeResource(String uri, {bool force = false}) async {
    if (!(_caps?.hasSubscriptions ?? false)) {
      throw const McpProtocolException('server 未声明 resources.subscribe 能力');
    }
    if (!force && _subscribedUris.contains(uri)) return '';
    final result = await call('resources/subscribe', params: {'uri': uri});
    _subscribedUris.add(uri);
    return _asSubscriptionId(result);
  }

  /// 取消订阅（§3.10 `resources/unsubscribe`）。
  Future<void> unsubscribeResource(String uri) async {
    if (!(_caps?.hasSubscriptions ?? false)) {
      throw const McpProtocolException('server 未声明 resources.subscribe 能力');
    }
    await call('resources/unsubscribe', params: {'uri': uri});
    _subscribedUris.remove(uri);
  }

  String _asSubscriptionId(Object? result) {
    if (result is Map && result['subscriptionId'] != null) {
      return result['subscriptionId'].toString();
    }
    return '';
  }

  /// server→client 主动通知统一分发（见 [onResourceUpdated] 字段注释）。当前仅
  /// 消费 `notifications/resources/updated`；其余通知忽略（结构化不抛）。
  void handleServerNotification(Object? method, Object? params) {
    if (method == 'notifications/resources/updated') {
      final uri = params is Map ? params['uri'] : null;
      if (uri is String) onResourceUpdated?.call(uri);
    }
  }

  // ---- GET SSE 订阅通知下行监听（T4-5 收官，Streamable HTTP §3.10）----

  /// 订阅通知监听循环（GET /mcp SSE 长连接）。[startNotificationListener] 启动，
  /// [stopNotificationListener] 取消；断流/崩溃自动指数退避重连（不惊群）。
  StreamSubscription<void>? _notifySub;
  var _notifyListening = false;
  final ExponentialBackoff _notifyBackoff = const ExponentialBackoff();

  /// 启动订阅通知下行监听（幂等；仅 [ServerCapabilities.hasSubscriptions] 时有效）。
  /// 监听在独立 GET 长连接上解析 server 主动帧，经 [handleServerNotification] 分发。
  Future<void> startNotificationListener() async {
    if (_notifyListening || !(_caps?.hasSubscriptions ?? false)) return;
    _notifyListening = true;
    var attempt = 0;
    while (_notifyListening) {
      StreamedTransportResponse resp;
      try {
        resp = await transport.getStream();
        debugPrint('[mcp] GET SSE 订阅通知监听已开启');
      } on UnsupportedError {
        // 传输不支持（如 Binder）：安静退出，不监听（订阅能力不应出现于该类 server）。
        _notifyListening = false;
        return;
      } catch (e) {
        if (!_notifyListening) return;
        final wait = _notifyBackoff.delayFor(attempt);
        attempt++;
        if (wait > Duration.zero) await Future.delayed(wait);
        continue;
      }
      if (!_notifyListening) {
        resp.lines.drain<void>();
        return;
      }
      final sub = resp.lines.listen(
        (line) {
          if (_notifyListening) _ingestSseLine(line);
        },
        onError: (_) {},
      );
      _notifySub = sub;
      await sub.asFuture().catchError((_) {});
      _notifySub = null;
      debugPrint('[mcp] GET SSE 订阅通知监听结束（将退避重连）');
      if (!_notifyListening) return;
      // 流正常结束（server 关闭）：退避后重连（attempt 不清零，避免风暴）。
      final wait = _notifyBackoff.delayFor(attempt);
      attempt++;
      if (wait > Duration.zero) await Future.delayed(wait);
    }
  }

  /// 停止订阅通知监听（断连时由 [McpConnection] 调用，避免无谓重连）。
  void stopNotificationListener() {
    _notifyListening = false;
    _notifySub?.cancel();
    _notifySub = null;
  }

  /// SSE 帧累积缓冲（与 [callWithProgress] 同构，独立实例避免并发串帧）。
  final StringBuffer _notifyFrame = StringBuffer();

  /// 解析 GET SSE 单行：`:` 心跳忽略；`data:` 累积；空行断帧 → 分发。
  void _ingestSseLine(String line) {
    if (line.startsWith(':')) return;
    if (line.startsWith('data:')) {
      _notifyFrame
        ..write(line.substring(5).trim())
        ..write('\n');
      return;
    }
    if (line.isNotEmpty || _notifyFrame.isEmpty) return;
    final payload = _notifyFrame.toString().trim();
    _notifyFrame.clear();
    if (payload.isEmpty) return;
    try {
      final msg = json.jsonDecode(payload);
      if (msg is Map<String, Object?>) {
        handleServerNotification(msg['method'], msg['params']);
      }
    } catch (_) {
      // 畸形帧忽略
    }
  }

  void close() => transport.close();
}
