/// 嵌入式 MCP 网关服务器（G1，thirdconnect.md §7）。
///
/// - **Streamable HTTP（协议 2025-06-18）**：POST /mcp 按 Accept 回单 JSON 或
///   SSE 帧流（tools/call 流式期间 progress 通知帧夹带，终帧 result）；
///   GET /mcp 维持 SSE 长连接接收服务器主动通知（tools/list_changed 下行）；
/// - **会话**：initialize 时下发 `Mcp-Session-Id`，后续请求须回带（缺失/未知
///   → 400）；
/// - **入站安全最小件（G3 起步）**：[requiredToken] 非空时强制
///   `Authorization: Bearer <token>` 校验（局域网配对口径，§7 物理通道 2）；
/// - **PC 60s 超时对策（TC12，收窄版）**：GET SSE 流每 15s 心跳注释帧重置
///   PC 计时；tools/call 流式期间由 progress 帧天然喂狗（无 progress 的
///   长调用 Keep-Alive 注入留 G 系列后续收口）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'mcp_gateway_handler.dart';

class McpGatewayServer {
  McpGatewayServer(this.template,
      {this.idleTimeout = const Duration(minutes: 10)});

  /// 入站模板 handler：每 `Mcp-Session-Id` 经 [GatewayHandler.forSession] 派生
  /// 独立投影上下文（阶段二 D-D 每连接隔离）；所有连接共享其 faces / privateServerIds。
  final GatewayHandler template;

  /// 投影上下文空闲回收阈值：无 SSE 订阅且超过此时长无 POST 活动的连接视为泄漏
  /// （纯 POST 客户端不维持 SSE 下行通道），由 [_gcIdle] 定期回收其 handler/session
  /// 条目。维持 SSE 的长连接（即便静默）永不被回收。
  final Duration idleTimeout;

  /// 每连接（Mcp-Session-Id）独立投影 handler（阶段二 D-D 隔离支点）。
  final Map<String, GatewayHandler> _handlers = {};

  HttpServer? _server;
  var _port = 8766;
  final Set<String> _sessions = {};
  final Map<String, HttpResponse> _sseSubs = {};
  final Map<String, DateTime> _lastActivity = {};
  StreamSubscription<void>? _listChangedSub;
  Timer? _heartbeat;
  Timer? _idleGc;

  /// 非空时强制 Bearer Token 校验（G3 最小鉴权；空 = 开放，仅建议 ADB/调试）。
  String? requiredToken;

  bool get running => _server != null;
  int get port => _port;

  Future<void> start({InternetAddress? address, int port = 8766}) async {
    if (running) return;
    _port = port;
    _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    _port = _server!.port; // port=0（测试）时回填实际绑定端口
    debugPrint('[gateway] listening on '
        '${address?.address ?? '0.0.0.0'}:$_port/mcp');
    _listChangedSub =
        template.onToolsListChanged.listen((_) => _broadcastListChanged());
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) => _heartbeatPing());
    _idleGc = Timer.periodic(idleTimeout, (_) => _gcIdle());
    _server!.listen(_onRequest,
        onError: (Object e) => debugPrint('[DEGRADE] gateway: $e'));
  }

  Future<void> stop() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _idleGc?.cancel();
    _idleGc = null;
    await _listChangedSub?.cancel();
    _listChangedSub = null;
    for (final resp in _sseSubs.values) {
      try {
        await resp.close();
      } on Object catch (_) {}
    }
    _sseSubs.clear();
    for (final h in _handlers.values) {
      h.disposeSession(); // P0-B：停服清空全部连接的会话豁免
    }
    _handlers.clear();
    _sessions.clear();
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  Future<void> _onRequest(HttpRequest req) async {
    try {
      if (req.uri.path != '/mcp') return _plain(req, 404, 'not found');
      if (!_checkAuth(req)) return _plain(req, 401, 'unauthorized');
      if (req.method == 'POST') return await _handlePost(req);
      if (req.method == 'GET') return await _handleGet(req);
      return _plain(req, 405, 'method not allowed');
    } on Object catch (e) {
      debugPrint('[DEGRADE] gateway: request error: $e');
      try {
        _plain(req, 500, 'internal error');
      } on Object catch (_) {}
    }
  }

  bool _checkAuth(HttpRequest req) {
    final token = requiredToken;
    if (token == null || token.isEmpty) return true;
    return req.headers.value(HttpHeaders.authorizationHeader) == 'Bearer $token';
  }

  Future<void> _handlePost(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    Object? decoded;
    try {
      decoded = body.trim().isEmpty ? null : jsonDecode(body);
    } on FormatException {
      return _jsonRpcError(req, null, -32700, 'parse error');
    }
    if (decoded is! Map) return _jsonRpcError(req, null, -32600, 'invalid request');
    final method = decoded['method'];
    final id = decoded['id'];
    final params = decoded['params'];
    final sessionId = req.headers.value('mcp-session-id');
    final sse = (req.headers.value(HttpHeaders.acceptHeader) ?? '')
        .contains('text/event-stream');

    // initialize：新会话 + 下发 Mcp-Session-Id。
    if (method == 'initialize') {
      final sid =
          'gw-${DateTime.now().microsecondsSinceEpoch}-${_sessions.length}';
      _sessions.add(sid);
      _handlers[sid] = template.forSession();
      return _jsonRpcResult(req, id, template.initialize(),
          sessionId: sid, sse: sse);
    }
    // 其余请求须持有会话。
    if (sessionId == null || !_sessions.contains(sessionId)) {
      return _plain(req, 400, 'missing or unknown Mcp-Session-Id');
    }
    _lastActivity[sessionId] = DateTime.now(); // 刷新活跃时间（idle GC 判定源）
    // 通知帧（无 id）：202 空体（notifications/initialized 等）。
    if (id == null) return _plain(req, 202, '');
    if (method == 'ping') {
      return _jsonRpcResult(req, id, const <String, Object?>{},
          sessionId: sessionId, sse: sse);
    }
    if (method == 'tools/list') {
      return _jsonRpcResult(req, id, {'tools': _handlers[sessionId]!.toolsList()},
          sessionId: sessionId, sse: sse);
    }
    if (method == 'tools/call') {
      final name = params is Map ? params['name'] : null;
      if (name is! String || name.isEmpty) {
        return _jsonRpcError(req, id, -32602, 'missing tool name',
            sessionId: sessionId);
      }
      final args = (params is Map && params['arguments'] is Map)
          ? Map<String, Object?>.from(params['arguments'] as Map)
          : <String, Object?>{};
      // 环路防护入站上下文（A2 止血）：Header 优先于 `params._meta`（Header 是
      // 传输层事实源，`_meta` 供经其他 goodhub 网关转发而来的请求回带深度）。
      final meta = (params is Map && params['_meta'] is Map)
          ? Map<String, Object?>.from(params['_meta'] as Map)
          : const <String, Object?>{};
      final traceId = req.headers.value('x-mcp-trace-id') ??
          (meta['traceId'] is String ? meta['traceId']! as String : null);
      final hopCount =
          meta['hopCount'] is num ? (meta['hopCount']! as num).toInt() : 0;
      return _toolsCall(req, id, sessionId, name, args, sse,
          traceId: traceId, hopCount: hopCount);
    }
    return _jsonRpcError(req, id, -32601, 'method not found: $method',
        sessionId: sessionId);
  }

  /// tools/call：SSE 模式流式回（progress 通知帧 + 终帧 result）；JSON 模式
  /// 等待完成后单 JSON 返回。两路共用同一 [GatewayHandler.toolsCall]。
  Future<void> _toolsCall(HttpRequest req, Object id, String sessionId,
      String name, Map<String, Object?> args, bool sse,
      {String? traceId, int hopCount = 0}) async {
    final resp = req.response;
    if (sse) {
      resp.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      resp.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      // SSE 帧必须即达即发：bufferOutput 默认 true 会把 progress/心跳帧缓冲到
      // 连接关闭一次性吐出（goodshare M3-T1 同坑，AtomCode 真网实测抓到——
      // progress 全部挤压在收尾 1ms 内到达）。教训见 lessons.md mcp/传输段。
      resp.bufferOutput = false;
    }
    void onProgress(Map<String, Object?> p) {
      if (!sse) return;
      _sseFrame(resp, {
        'jsonrpc': '2.0',
        'method': 'notifications/progress',
        'params': p,
      });
    }

    final r = await _handlers[sessionId]!.toolsCall(
      name: name,
      arguments: args,
      onProgress: onProgress,
      traceId: traceId,
      hopCount: hopCount,
      sessionId: sessionId,
    );
    final code = r.errorCode;
    if (code != null) {
      // 环路阻断走协议级 error 帧（PC 客户端按错误处理，不会当工具失败重试
      // 而二次入环）。SSE 模式此时流头已写，仍以标准 error 帧收尾并关闭。
      if (sse) {
        _sseFrame(resp, {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': code, 'message': r.content},
        });
        await resp.close();
      } else {
        _jsonRpcError(req, id, code, r.content, sessionId: sessionId);
      }
      return;
    }
    final result = {
      'content': [
        {'type': 'text', 'text': r.content},
      ],
      'isError': r.isError,
    };
    if (sse) {
      _sseFrame(resp, {'jsonrpc': '2.0', 'id': id, 'result': result});
      await resp.close();
    } else {
      _jsonRpcResult(req, id, result, sessionId: sessionId, sse: false);
    }
  }

  /// GET /mcp：SSE 订阅通道（server→client 通知下行，§9.2）。
  Future<void> _handleGet(HttpRequest req) async {
    final sessionId = req.headers.value('mcp-session-id');
    if (sessionId == null || !_sessions.contains(sessionId)) {
      return _plain(req, 400, 'missing or unknown Mcp-Session-Id');
    }
    final resp = req.response;
    resp.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    resp.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    // 同 _toolsCall：订阅下行（list_changed/心跳）也须即达即发，防缓冲滞留。
    resp.bufferOutput = false;
    _sseSubs[sessionId] = resp;
    resp.write(': gateway stream open\n\n');
    await resp.done; // 客户端断连 / stop() 关闭时完成
    _sseSubs.remove(sessionId);
    _handlers.remove(sessionId); // 显式注销：释放该连接投影上下文（阶段二 D-D）
    _sessions.remove(sessionId);
    _lastActivity.remove(sessionId);
  }

  /// 投影上下文空闲回收（#7 剩余泄漏修复）：纯 POST 客户端不维持 SSE 订阅，
  /// 断连时无法经 [_handleGet] 的 done 清理，故按 [idleTimeout] 周期回收其条目。
  /// 维持 SSE 收下行通道的长连接（即便静默）不入回收范围。
  void _gcIdle() {
    final now = DateTime.now();
    for (final sid in _handlers.keys.toList()) {
      if (_sseSubs.containsKey(sid)) continue; // 维持 SSE 的长连接不踢
      final last = _lastActivity[sid];
      if (last == null || now.difference(last) > idleTimeout) {
        _handlers[sid]?.disposeSession(); // P0-B：连接回收即丢该连接的豁免集
        _handlers.remove(sid);
        _sessions.remove(sid);
        _lastActivity.remove(sid);
      }
    }
  }

  /// 工具目录变更 → 全体 SSE 订阅者下行（§9.2，PC 自动重拉 tools/list）。
  void _broadcastListChanged() {
    for (final resp in _sseSubs.values) {
      _sseFrame(resp, {
        'jsonrpc': '2.0',
        'method': 'notifications/tools/list_changed',
      });
    }
  }

  /// TC12 收窄版：GET SSE 流 15s 心跳（注释帧不计入 MCP 帧，仅喂狗）。
  /// 注意：dart:io `IOSink.flush()` 以 `_isBound` 互斥、与 close 相撞会同步抛
  /// StateError——此处（及全文件）不做显式 flush，写出即由 socket 自行调度。
  void _heartbeatPing() {
    for (final resp in _sseSubs.values) {
      try {
        resp.write(': keep-alive\n\n');
      } on Object catch (_) {}
    }
  }

  void _sseFrame(HttpResponse resp, Map<String, Object?> frame) {
    resp.write('event: message\ndata: ${jsonEncode(frame)}\n\n');
  }

  void _jsonRpcResult(
    HttpRequest req,
    Object? id,
    Object? result, {
    String? sessionId,
    bool sse = false,
  }) {
    final resp = req.response;
    if (sessionId != null) resp.headers.set('Mcp-Session-Id', sessionId);
    if (sse) {
      resp.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      _sseFrame(resp, {'jsonrpc': '2.0', 'id': id, 'result': result});
      resp.close();
    } else {
      _json(resp, {'jsonrpc': '2.0', 'id': id, 'result': result});
    }
  }

  void _jsonRpcError(
    HttpRequest req,
    Object? id,
    int code,
    String message, {
    String? sessionId,
  }) {
    final resp = req.response;
    if (sessionId != null) resp.headers.set('Mcp-Session-Id', sessionId);
    _json(resp, {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }

  void _json(HttpResponse resp, Map<String, Object?> body) {
    resp.headers.contentType = ContentType.json;
    resp.write(jsonEncode(body));
    resp.close();
  }

  void _plain(HttpRequest req, int status, String message) {
    final resp = req.response;
    resp.statusCode = status;
    resp.headers.contentType = ContentType.text;
    resp.write(message);
    resp.close();
  }
}
