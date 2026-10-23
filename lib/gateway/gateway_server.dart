/// 嵌入式 MCP 网关服务器（G1，thirdconnect.md §7）。
///
/// - **Streamable HTTP（协议 2025-06-18）**：POST /mcp 按 Accept 回单 JSON 或
///   SSE 帧流（tools/call 流式期间 progress 通知帧夹带，终帧 result）；
///   GET /mcp 维持 SSE 长连接接收服务器主动通知（tools/list_changed 下行）；
/// - **会话**：initialize 时下发 `Mcp-Session-Id`，后续请求须回带（缺失/未知
///   → 400）；
/// - **入站安全最小件（G3 起步）**：[requiredToken] 非空时强制
///   `Authorization: Bearer <token>` 校验（局域网配对口径，§7 物理通道 2）；
/// - **PC 60s 超时对策（TC12）**：GET SSE 流每 15s 心跳注释帧重置 PC 计时；
///   tools/call 的 SSE 流按 [keepAliveInterval] 主动推 `notifications/progress`
///   帧——下游无 progress 的长调用（本地插件冷启动 / Binder 慢调用）同样喂狗，
///   根除 PC「连续 60s 收不到任何 HTTP 数据包即超时」的掉线。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'mcp_gateway_handler.dart';
import 'projection_pipeline.dart';

/// 网关默认监听端口（单源：`gateway_controller` 起服入参缺省亦引此常量——
/// 双声明会漂移，由 drift-guard CONST 登记机械守护）。
const int kGatewayDefaultPort = 8766;

class McpGatewayServer {
  McpGatewayServer(this.template,
      {this.idleTimeout = const Duration(minutes: 10),
      this.keepAliveInterval = const Duration(seconds: 15)});

  /// 入站模板 handler：每 `Mcp-Session-Id` 经 [GatewayHandler.forSession] 派生
  /// 独立投影上下文（阶段二 D-D 每连接隔离）；所有连接共享其 faces / privateServerIds。
  final GatewayHandler template;

  /// 投影上下文空闲回收阈值：无 SSE 订阅且超过此时长无 POST 活动的连接视为泄漏
  /// （纯 POST 客户端不维持 SSE 下行通道），由 [_gcIdle] 定期回收其 handler/session
  /// 条目。维持 SSE 的长连接（即便静默）永不被回收。
  final Duration idleTimeout;

  /// **Keep-Alive 注入间隔**（TC12 · PC 60s 超时对策）：tools/call 的 SSE 流在
  /// 长调用 / 冷启动期间按此间隔主动推一条轻量 `notifications/progress` 帧，
  /// 喂 PC 端计时器（PC 规则：连续 60s 收不到任何 HTTP 数据包即超时）。
  /// 可注入（单测用短间隔），生产默认 15s。
  final Duration keepAliveInterval;

  /// 每连接（Mcp-Session-Id）独立投影 handler（阶段二 D-D 隔离支点）。
  /// 入站会话表：`Mcp-Session-Id` → 会话上下文（策略 + 连接级私有绑定 + handler）。
  ///
  /// **handler 可空 = 闲置内存态已被 GC 回收，但 sid 仍然有效**——后续请求按需
  /// 重建 handler（**不再 400**）。此前两个缺陷同源：把「连接存活」与「会话
  /// 有效」绑死——①「SSE 订阅一断即销毁会话」→ PC 复用旧 sid 吃 400（无线下
  /// NAT 空闲超时 / Wi-Fi 抖动必现）；②「纯 POST 客户端 10min 无请求 → sid
  /// 失效 → 400」（MCP 客户端不一定订阅 GET SSE）。现改为：**会话与 sid 长期
  /// 有效，只有内存态按闲置回收**。
  final Map<String, _GatewaySession> _sessions = {};

  HttpServer? _server;
  var _port = kGatewayDefaultPort;
  final Map<String, HttpResponse> _sseSubs = {};
  final Map<String, DateTime> _lastActivity = {};
  StreamSubscription<void>? _listChangedSub;
  Timer? _heartbeat;
  Timer? _idleGc;

  /// 非空时强制 Bearer Token 校验（G3 最小鉴权；空 = 开放，仅建议 ADB/调试）。
  String? requiredToken;

  bool get running => _server != null;
  int get port => _port;

  Future<void> start({InternetAddress? address, int port = kGatewayDefaultPort}) async {
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
    // 先取副本并清表，再逐个关闭——**不可边遍历边 await**：`resp.close()` 会
    // 让出事件循环，SSE 断连回调（`_handleGet` 的 done 分支）会并发移除
    // `_sseSubs` 条目 → Concurrent modification 崩溃（2026-10-23 由新增
    // 「SSE 断开后会话仍可用」钉子当场抓出）。
    final subs = _sseSubs.values.toList();
    _sseSubs.clear();
    for (final resp in subs) {
      try {
        await resp.close();
      } on Object catch (_) {}
    }
    for (final ctx in _sessions.values) {
      ctx.handler?.disposeSession(); // P0-B：停服清空全部连接的会话豁免
    }
    _sessions.clear();
    _lastActivity.clear(); // 活跃时间表随会话表一并清（否则残留条目泄漏）
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

    // initialize：新会话 + 下发 Mcp-Session-Id + **绑定投影策略**（PR2）。
    // 策略仅在此处从 URL query 解析一次；后续 tools/list / tools/call 一律
    // 忽略 URL 参数（只读会话绑定值），会话内不可中途变更。
    if (method == 'initialize') {
      final ProjectionPolicy policy;
      try {
        policy = ProjectionPolicy.parse(
          req.uri.queryParameters,
          // 「可访问」= 已挂载：`single` 目标若为私有服务，本连接会被**连接级
          // 绑定**到它（见下方），故未激活也不构成不可达。
          isAccessible: (serverId) => template.faces.containsKey(serverId),
          // 「是否私有」= 已配置的私有域（`private` 档专用；私有叠加只对
          // 私有域开放——对公共服务谈「私有叠加」无意义）。
          isPrivate: (serverId) => template.privateServerIds.contains(serverId),
        );
      } on ProjectionPolicyException catch (e) {
        // Fail-Fast：策略非法 / 目标未挂载 → -32602，**严禁**静默退化为
        // full 或初始化为空工具面（后者会让 PC 误以为宿主无工具）。
        return _jsonRpcError(req, id, -32602,
            'invalid projection policy: ${e.message}',
            sessionId: null);
      }
      final sid =
          'gw-${DateTime.now().microsecondsSinceEpoch}-${_sessions.length}';
      // `single` 目标是私有服务 → 本连接投影**绑定**到它（连接级，不改宿主
      // 槽位）：否则四级管道的私有投影防火墙会拦掉它，PC 拿到空目录且
      // `single` 下无 `gateway__select_private` 可自救。权限集合与既有
      // `gateway__select_private` 完全相同（仅改本连接投影）。
      // 私有叠加绑定（连接级，不改宿主槽位）：
      // ① `policy=private` → 绑定该私有服务（联邦面 + 它）；
      // ② `policy=single` 目标是私有服务 → 同样绑定（否则私有投影防火墙会拦
      //    掉它，PC 拿到空目录且 `single` 下无 `gateway__select_private` 可自救）。
      final bindPrivateTarget = policy.isPrivate ||
          (policy.isSingle &&
              template.privateServerIds.contains(policy.targetServerId));
      final activePrivate = bindPrivateTarget ? policy.targetServerId : null;
      final handler = template.forSession(
        policy: policy,
        activePrivateServerId: activePrivate,
      );
      // 广播差分基线：会话建立时的投影集即为「无变化」基准（否则首次目录变更
      // 必然触发一次无意义广播）。
      handler.markProjectionBaseline();
      _sessions[sid] = _GatewaySession(
        policy: policy,
        activePrivateServerId: activePrivate,
        handler: handler,
      );
      _lastActivity[sid] = DateTime.now(); // 新建会话即算活跃
      if (_sessions.length > _maxSessions) _evictOldestSessions();
      return _jsonRpcResult(req, id, template.initialize(),
          sessionId: sid, sse: sse);
    }
    // 其余请求须持有会话。
    if (sessionId == null || !_sessions.containsKey(sessionId)) {
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
      return _jsonRpcResult(
          req, id, {'tools': _handlerFor(sessionId)!.toolsList()},
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
          traceId: traceId, hopCount: hopCount,
          progressToken: meta['progressToken']);
    }
    return _jsonRpcError(req, id, -32601, 'method not found: $method',
        sessionId: sessionId);
  }

  /// tools/call：SSE 模式流式回（progress 通知帧 + 终帧 result）；JSON 模式
  /// 等待完成后单 JSON 返回。两路共用同一 [GatewayHandler.toolsCall]。
  Future<void> _toolsCall(HttpRequest req, Object id, String sessionId,
      String name, Map<String, Object?> args, bool sse,
      {String? traceId, int hopCount = 0, Object? progressToken}) async {
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

    // TC12 Keep-Alive：SSE 模式下按固定间隔主动推 progress 帧——下游插件
    // 无 progress 支持时长调用（本地插件冷启动 / Binder 慢调用）会静默超过
    // PC 的 60s 无数据超时，故由网关侧兜底喂狗。JSON 模式无法注入（响应体
    // 在调用结束才整体写出，中途插帧会破坏 JSON 单体语义）。
    final keepAlive = sse
        ? Timer.periodic(keepAliveInterval,
            (_) => _keepAlivePing(resp, id, name, progressToken))
        : null;
    try {
      final r = await _handlerFor(sessionId)!.toolsCall(
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
    } finally {
      // 定时器必随调用结束（成功 / 失败 / 环路阻断 / 客户端强断）取消——否则
      // 泄漏的周期任务会往已关闭的响应写帧。
      keepAlive?.cancel();
    }
  }

  /// GET /mcp：SSE 订阅通道（server→client 通知下行，§9.2）。
  Future<void> _handleGet(HttpRequest req) async {
    final sessionId = req.headers.value('mcp-session-id');
    if (sessionId == null || !_sessions.containsKey(sessionId)) {
      return _plain(req, 400, 'missing or unknown Mcp-Session-Id');
    }
    final resp = req.response;
    resp.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    resp.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    // 同 _toolsCall：订阅下行（list_changed/心跳）也须即达即发，防缓冲滞留。
    resp.bufferOutput = false;
    _sseSubs[sessionId] = resp;
    _lastActivity[sessionId] = DateTime.now(); // 订阅建立 = 连接活跃
    resp.write(': gateway stream open\n\n');
    await resp.done; // 客户端断连 / stop() 关闭时完成
    // **SSE 订阅断开 ≠ 会话结束**（2026-10-23 修）：无线场景下 NAT 空闲超时、
    // Wi-Fi 抖动、半开都会让订阅先断，而 PC 侧往往复用同一 sid 继续请求——
    // 此前直接销毁会话 → 客户端下一次请求吃 400「unknown session」。
    // 现在只解绑订阅；会话与 sid 保留，闲置内存态由 [_gcIdle] 按阈值回收。
    if (identical(_sseSubs[sessionId], resp)) _sseSubs.remove(sessionId);
    if (_sessions.containsKey(sessionId)) {
      _lastActivity[sessionId] = DateTime.now();
    }
  }

  /// 投影上下文空闲回收（#7 剩余泄漏修复）：纯 POST 客户端不维持 SSE 订阅，
  /// 断连时无法经 [_handleGet] 的 done 清理，故按 [idleTimeout] 周期回收其条目。
  /// 维持 SSE 收下行通道的长连接（即便静默）不入回收范围。
  void _gcIdle() {
    final now = DateTime.now();
    for (final entry in _sessions.entries.toList()) {
      final sid = entry.key;
      final ctx = entry.value;
      if (_sseSubs.containsKey(sid)) continue; // 订阅存活 = 连接活跃，不踢
      final last = _lastActivity[sid];
      final idle = last == null || now.difference(last) > idleTimeout;
      if (!idle) continue;
      // 只回收**内存态**（handler + 该连接的 L2 豁免集），**保留 sid 与策略**
      // ——后续请求按需重建 handler，客户端复用旧 sid 仍然可用（不再 400）。
      //
      // **sid 永不因空闲而失效**：PC 侧可能任意时刻回来用旧 sid（无线下连接
      // 断续是常态），一旦 400 就是「掉线」体感。会话条目本身极小（策略 + 可空
      // handler），容量由 [_maxSessions] + LRU 淘汰兜底，而非按时间删除。
      ctx.handler?.disposeSession(); // P0-B：连接回收即丢该连接的豁免集
      ctx.handler = null;
    }
  }

  /// 会话表容量上限（超出即 LRU 淘汰最久未活动的会话）——防异常客户端狂
  /// initialize 造大量 sid 撑爆内存。**不按时间删 sid**（见 [_gcIdle] 注释）。
  static const int _maxSessions = 256;

  /// LRU 淘汰：按最后活跃时间升序，先丢 handler 再删条目。
  void _evictOldestSessions() {
    final entries = _sessions.entries.toList()
      ..sort((a, b) {
        final la = _lastActivity[a.key] ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final lb = _lastActivity[b.key] ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return la.compareTo(lb);
      });
    var over = _sessions.length - _maxSessions;
    for (final e in entries) {
      if (over <= 0) break;
      e.value.handler?.disposeSession();
      _sessions.remove(e.key);
      _lastActivity.remove(e.key);
      over--;
    }
  }

  /// 取该连接的 handler；**闲置被 GC 后按需重建**（策略与连接级私有绑定从
  /// 会话条目恢复）。重建只丢内存态——该连接的 L2 会话豁免集随之重置，属可
  /// 接受代价（用户重新确认一次即可）。
  GatewayHandler? _handlerFor(String sid) {
    final ctx = _sessions[sid];
    if (ctx == null) return null;
    var handler = ctx.handler;
    if (handler == null) {
      handler = template.forSession(
        policy: ctx.policy,
        activePrivateServerId: ctx.activePrivateServerId,
      );
      handler.markProjectionBaseline(); // 重建即重置差分基线
      ctx.handler = handler;
    }
    return handler;
  }

  /// 工具目录变更 → SSE 订阅者下行（§9.2，PC 自动重拉 tools/list）。
  ///
  /// **投影差分抑制**（PR2）：信号本身不携带「哪个服务变了」，故按**每个连接
  /// 自己的投影集**判定——重算该连接投影并与上次快照比对，无变化即抑制。覆盖
  /// 两类噪音：`single` 会话对无关服务上下线无感 / `full` 会话对私有域变更无感。
  void _broadcastListChanged() {
    for (final entry in _sseSubs.entries) {
      final sid = entry.key;
      final handler = _sessions[sid]?.handler;
      if (handler == null) continue;
      if (!handler.projectionChangedSinceBaseline()) continue; // 无变化即抑制
      _sseFrame(entry.value, {
        'jsonrpc': '2.0',
        'method': 'notifications/tools/list_changed',
      });
    }
  }

  /// TC12 Keep-Alive 帧：tools/call 的 SSE 流在长调用期间主动推一条轻量
  /// `notifications/progress`（对齐设计稿 thirdconnect §10.4「每 15s 主动推一条
  /// 轻量 notifications/progress」——根除 PC 端「连续 60s 收不到任何 HTTP
  /// 数据包即超时」的掉线）。
  ///
  /// **为何 GET 通道用注释帧、本通道用真 MCP 帧**：GET 订阅通道只承载服务器主动
  /// 通知，`: keep-alive` 注释帧（不计入 MCP 帧）足以喂 TCP 计时器；而
  /// tools/call 的 SSE 流承载 progress 语义，PC 客户端按 MCP 帧解析——故推真
  /// `notifications/progress`，`progressToken` 优先回显客户端请求带来的
  /// `_meta.progressToken`，缺省用本次请求 id（客户端据此关联到该次调用）。
  void _keepAlivePing(
      HttpResponse resp, Object id, String toolName, Object? progressToken) {
    try {
      _sseFrame(resp, {
        'jsonrpc': '2.0',
        'method': 'notifications/progress',
        'params': <String, Object?>{
          'progressToken': progressToken ?? id,
          'message': 'goodhub 网关：工具 $toolName 仍在执行中（Keep-Alive）',
        },
      });
    } on Object catch (_) {} // 非数据面（coding-standards §4.2）：保活帧失败不丢用户数据，留痕不阻断
  }

  /// GET SSE 流 15s 心跳（注释帧不计入 MCP 帧，仅喂狗——订阅通道无请求语义，
  /// 用注释帧最安全，不会被客户端误认成 progress）。
  /// 注意：dart:io `IOSink.flush()` 以 `_isBound` 互斥、与 close 相撞会同步抛
  /// StateError——此处（及全文件）不做显式 flush，写出即由 socket 自行调度。
  void _heartbeatPing() {
    for (final entry in _sseSubs.entries.toList()) {
      final sid = entry.key;
      final resp = entry.value;
      try {
        resp.write(': keep-alive\n\n');
        // 心跳写成功 = 订阅仍可达（算连接活跃，不被 idle GC 回收）
        _lastActivity[sid] = DateTime.now();
      } on Object catch (_) {
        // 写失败 = 连接已死（对端消失 / 半开）——解绑订阅，让 idle GC 回收该
        // 会话的内存态（否则半开连接永不释放 → 僵尸会话泄漏）。
        // 非数据面（coding-standards §4.2）：保活帧失败不丢用户数据。
        _sseSubs.remove(sid);
      }
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

/// 一个入站会话（`Mcp-Session-Id` → 投影上下文）。
///
/// [handler] 可空 = 闲置内存态已被 GC 回收；[policy] 与 [activePrivateServerId]
/// 保留 —— 请求到达时按 [_McpGatewayServer._handlerFor] 重建 handler。
class _GatewaySession {
  _GatewaySession({
    required this.policy,
    this.activePrivateServerId,
    this.handler,
  });

  /// 本连接绑定的投影策略（不可变值对象，随会话长期保留）。
  final ProjectionPolicy policy;

  /// 连接级私有投影绑定（`single` 指向私有服务时）——重建 handler 时恢复。
  final String? activePrivateServerId;

  /// 该连接当前的 handler（内存态；闲置被 GC 后为 null，按需重建）。
  GatewayHandler? handler;
}
