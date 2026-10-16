/// 同机 Binder 传输实现（thirdconnect T-trans-2/3）。
///
/// 纯传输：把已编码的 JSON-RPC 请求体经宿主侧 [BinderTransportBridge]（AIDL 客户端 +
/// 连接状态机）送到本地插件 Service，并消费插件经 [IMcpCallback.onEvent] 回推的事件
/// （progress / `_async` 异步终帧 / 反向请求），按约定 §1.2.2 / §5 路由。
///
/// 与 [HttpTransport] 对等：成功映射 200；传输层失败（冷启动超时/插件崩溃）映射为
/// [McpNetworkException]；插件自身返回的 JSON-RPC error 帧原样回传，由协议层裁决
/// （严禁传输层伪装 JSON-RPC error，§1.2.3）。
library;

import 'dart:async';
import 'dart:convert' as json;

import 'package:flutter/services.dart';

import '../../core/errors/mcp_error.dart';
import 'mcp_transport.dart';

/// 本地插件 Binder 传输：Dart 侧门面，原生实现见 android 侧 BinderTransportBridge。
///
/// 构造即触发 [bind]（异步连接 + 订阅事件流），随后 [send]/[sendStream] 在 READY 前由
/// 原生状态机兜底入挂起队列（见 BinderTransportBridge），无需 Dart 侧等待。
///
/// 事件回传（T-trans-3，§1.2.2 / §5）：
///  - `notifications/progress` → 经 `_eventBroadcast` 喂给在途 [sendStream]，由
///    [McpClient.callWithProgress] 的 `onProgress` 收侧兑现；
///  - `_async` 异步终帧（同 id `result`/`error`）→ 唤醒 [send]/[sendStream] 等待的 completer；
///  - 反向请求（server→client，带 method+id，如 `sampling/createMessage`）→ 经
///    [onServerRequest] 处理后由 [answerReverse] 回程，闭环见 §1.2.2。
class BinderTransport implements McpTransport {
  BinderTransport({
    required this.transportId,
    required this.packageName,
    required this.serviceClassName,
    MethodChannel? channel,
    EventChannel? events,
  })  : _channel = channel ?? const MethodChannel('goodhub/binder_mcp'),
        _events = events ?? const EventChannel('goodhub/binder_mcp_events') {
    // 触发连接（异步；首个 send 前完成 bind，CONNECTING 期间请求入队）。
    _channel.invokeMethod<void>('bind', <String, Object>{
      'transportId': transportId,
      'packageName': packageName,
      'serviceClassName': serviceClassName,
    }).ignore();
    // 订阅该 transport 的原生事件流（progress / 异步终帧 / 反向请求）。
    _eventSub = _events
        .receiveBroadcastStream(transportId)
        .listen(_onNativeEvent, onError: (Object _) {
      // 事件流错误（如插件断连）不致命，仅留痕。
    });
  }

  /// 区分多插件的标识（与宿主侧 transports Map 的 key 对齐）。
  final String transportId;

  /// 目标插件包名（物理主键，§9.3）。
  final String packageName;

  /// 目标插件 Service 全限定类名（如 com.zzh.goodhub.sample.dummy.DummyPluginService）。
  final String serviceClassName;

  final MethodChannel _channel;
  final EventChannel _events;
  StreamSubscription<dynamic>? _eventSub;

  /// server→client 反向请求处理器（与 [McpClient.onServerRequest] 对齐）：处理后经
  /// [answerReverse] 回程。由 [McpClient.binder] 工厂转发到 client 的处理器。
  Future<Map<String, Object?>?> Function(String method, Object? params)? onServerRequest;

  /// server→client 主动通知分发（无 id，如 `notifications/resources/updated`）：
  /// [McpClient.binder] 工厂转发到 [McpClient.handleServerNotification]（含
  /// [McpClient.onResourceUpdated]）。GET SSE 通道不适用 Binder（通知走 EventChannel），
  /// 故此处是 Binder 路径订阅失效感知（`notifications/resources/updated`）的唯一下行入口。
  void Function(String method, Object? params)? onServerNotification;

  /// 异步终帧等待表：key = JSON-RPC 请求 id；value = 同 id 经 onEvent 送达的真实结果 raw。
  final Map<Object, Completer<String>> _pendingTerminal = <Object, Completer<String>>{};

  /// 事件广播：所有 onEvent 消息（progress / 异步终帧）在此 fan-out，按请求维度过滤消费。
  /// 反向请求不进广播（直接走 [answerReverse] 回程）。
  final StreamController<Map<String, Object?>> _eventBroadcast =
      StreamController<Map<String, Object?>>.broadcast(sync: false);

  /// close 防重入守卫（window-slim P1-D）：二次 close 会让 broadcast
  /// controller 抛 StateError——幂等语义对齐 McpAssembly.close 范式。
  bool _closed = false;

  // ---- 请求体解析 ----
  static Object? _requestIdOf(String body) {
    try {
      final decoded = json.jsonDecode(body);
      if (decoded is Map<String, Object?>) return decoded['id'];
    } catch (_) {
      // 解析失败：返回 null，交由调用方退化处理。
    }
    return null;
  }

  static Object? _progressTokenOf(String body) {
    try {
      final decoded = json.jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        final params = decoded['params'];
        if (params is Map<String, Object?>) {
          final meta = params['_meta'];
          if (meta is Map<String, Object?>) return meta['progressToken'];
        }
      }
    } catch (_) {
      // 解析失败：返回 null（退化为「全部 progress 归属当前在途调用」）。
    }
    return null;
  }

  /// 是否 `_async` 占位终帧（§1.2.2）：插件在 call 内立即返回的 `{"result":{"_async":true}}`。
  static bool _isAsyncPlaceholder(Map<String, Object?> msg) {
    final result = msg['result'];
    return result is Map<String, Object?> && result['_async'] == true;
  }

  // ---- 原生事件入口（来自 EventChannel：{transportId, message}）----
  void _onNativeEvent(dynamic event) {
    if (event is! Map) return;
    final message = event['message'];
    if (message is! String) return;
    final Map<String, Object?> msg;
    try {
      final decoded = json.jsonDecode(message);
      if (decoded is! Map<String, Object?>) return;
      msg = decoded;
    } catch (_) {
      return;
    }

    final method = msg['method'];
    final id = msg['id'];
    if (method is String && method.isNotEmpty) {
      if (method == 'notifications/progress') {
        // 进度通知：仅喂广播，供在途 sendStream 的 callWithProgress 收侧兑现。
        _eventBroadcast.add(msg);
        return;
      }
      if (id != null) {
        // 反向请求（server→client，带 id）：处理并经 answerReverse 回程（§5 闭环）。
        _handleReverseRequest(method, id, msg['params']);
        return;
      }
      // 其他 server 主动通知帧（非 progress / 非反向请求、且无 id）：经
      // [onServerNotification] 分发（如 notifications/resources/updated → onResourceUpdated）。
      // Binder 无 GET SSE 通道，此即订阅失效感知的唯一下行入口（原实现误丢弃）。
      onServerNotification?.call(method, msg['params']);
    }

    // 终帧（result/error，无 method）：唤醒等待中的 send / sendStream。
    if (id != null) {
      final completer = _pendingTerminal.remove(id);
      completer?.complete(message); // 整条 raw 帧
      _eventBroadcast.add(msg); // 供 sendStream 收尾
    }
  }

  Future<void> _handleReverseRequest(
    String method,
    Object id,
    Object? params,
  ) async {
    final handler = onServerRequest;
    // 单点构造反向响应帧（final 单一赋值，规避 multi-assign 红线）：未启用处理器 →
    // -32601；否则处理器结果 → result，McpRpcException → error(code/message/data)，
    // 其他异常 → -32603（与 McpClient._answerServerRequest 对齐）。
    final frame = handler == null
        ? <String, Object?>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, Object?>{
              'code': -32601,
              'message': '宿主未启用反向请求处理: $method',
            },
          }
        : await _reverseFrame(handler, method, id, params);
    // 经 answerReverse（oneway）把响应回插件，插件按 id 关联原请求。
    _channel
        .invokeMethod<void>('answerReverse', <String, Object>{
          'transportId': transportId,
          'responseBody': json.jsonEncode(frame),
        })
        .ignore();
  }

  /// 构造反向请求响应帧：与 [McpClient._answerServerRequest] 同语义。
  static Future<Map<String, Object?>> _reverseFrame(
    Future<Map<String, Object?>?> Function(String, Object?) handler,
    String method,
    Object id,
    Object? params,
  ) async {
    try {
      final result = await handler(method, params);
      return <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      };
    } on McpRpcException catch (e) {
      return <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{
          'code': e.code,
          'message': e.message,
          if (e.data != null) 'data': e.data,
        },
      };
    } catch (e) {
      return <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{
          'code': -32603,
          'message': '宿主反向请求处理失败: $e',
        },
      };
    }
  }

  // ---- 单请求-响应（initialize / tools/list / 非进度 tools/call 走此）----
  @override
  Future<TransportResponse> send(String requestBody) async {
    final id = _requestIdOf(requestBody);
    // 先占位 completer（§1.2.2：_async 应答保持 completer 开启直到 onEvent 同 id 终帧）：
    // 必须在 await send 之前注册，规避「插件同步回 _async 后立刻异步推终帧」的竞态窗口。
    final completer = Completer<String>();
    if (id != null) _pendingTerminal[id] = completer;

    final String? firstBody;
    try {
      firstBody = await _channel.invokeMethod<String>('send', <String, Object>{
        'transportId': transportId,
        'requestBody': requestBody,
      });
    } on PlatformException catch (e) {
      _pendingTerminal.remove(id);
      throw McpNetworkException('binder transport failed: ${e.message}');
    }

    final raw = firstBody ?? '';
    Map<String, Object?>? firstMsg;
    try {
      final decoded = json.jsonDecode(raw);
      if (decoded is Map<String, Object?>) firstMsg = decoded;
    } catch (_) {
      // 非 JSON（异常时由上层 call 处理）。
    }

    if (firstMsg != null && _isAsyncPlaceholder(firstMsg) && id != null) {
      // _async：保持 completer 开启，直到 onEvent 同 id 终帧送达。
      final realRaw = await completer.future;
      _pendingTerminal.remove(id);
      return TransportResponse(
        statusCode: 200,
        contentType: 'application/json',
        body: realRaw,
      );
    }

    _pendingTerminal.remove(id); // 同步路径：completer 不被使用，清理。
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: raw,
    );
  }

  // ---- 订阅通知下行通道（GET SSE）：Binder 同机传输不适用 ----
  // 本地插件通知经 EventChannel 回推（_onNativeEvent），无独立 GET 长连接；
  // 协议层订阅监听对此类 server 退化为不监听（subscribeResource 仍受 caps 门控）。
  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('Binder 传输不支持 GET SSE 订阅通道（通知走 EventChannel）');

  // ---- 流式（callWithProgress 用）：progress / _async 终帧经事件流回传 ----
  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final id = _requestIdOf(requestBody);
    final progressToken = _progressTokenOf(requestBody);

    final controller = StreamController<String>();
    // 订阅事件广播（在 await send 之前注册，规避 _async 终帧竞态）。
    late final StreamSubscription<Map<String, Object?>> sub;
    sub = _eventBroadcast.stream.listen((msg) {
      final mMethod = msg['method'];
      if (mMethod == 'notifications/progress') {
        // progress：按 progressToken 归属当前在途调用（无 token 则全部归属）。
        final pToken = msg['params'] is Map<String, Object?>
            ? (msg['params'] as Map<String, Object?>)['progressToken']
            : null;
        if (progressToken == null || pToken == progressToken) {
          _emitFrame(controller, json.jsonEncode(msg));
        }
        return;
      }
      // 终帧（无 method 且 id 匹配）：收尾并关闭流（onCancel 负责取消订阅）。
      if (mMethod == null && (id == null || msg['id'] == id)) {
        _emitFrame(controller, json.jsonEncode(msg));
        controller.close();
      }
    });
    controller.onCancel = () => sub.cancel();

    try {
      final firstBody = await _channel.invokeMethod<String>('send', <String, Object>{
        'transportId': transportId,
        'requestBody': requestBody,
      }).onError<PlatformException>((e, _) {
        throw McpNetworkException('binder transport failed: ${e.message}');
      });

      final raw = firstBody ?? '';
      Map<String, Object?>? firstMsg;
      try {
        final decoded = json.jsonDecode(raw);
        if (decoded is Map<String, Object?>) firstMsg = decoded;
      } catch (_) {
        // 非 JSON：退化为单帧透传，交由上层 callWithProgress 报协议错误。
      }

      if (firstMsg == null || !_isAsyncPlaceholder(firstMsg)) {
        // 同步：初始响应即终帧，单 data 帧收尾。
        _emitFrame(controller, raw);
        controller.close();
      }
      // _async：不推占位帧，进度/终帧经 _eventBroadcast 后续到达并收尾。
      return StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: controller.stream,
      );
    } catch (e) {
      sub.cancel();
      controller.addError(e);
      controller.close();
      rethrow;
    }
  }

  /// 以 SSE `data:` 帧 + 空行封装（供 [McpClient.callWithProgress] 的 SSE 分帧解析复用）。
  static void _emitFrame(StreamController<String> c, String rawJson) {
    c.add('data: $rawJson');
    c.add(''); // 空行触发 SSE 断帧 flush
  }

  @override
  void close() {
    if (_closed) return; // 幂等：二次调用静默返回（守卫见字段注释）
    _closed = true;
    _eventSub?.cancel();
    _eventBroadcast.close();
    _channel
        .invokeMethod<void>('close', <String, Object>{'transportId': transportId})
        .ignore();
  }
}
