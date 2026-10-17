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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import '../../core/errors/mcp_error.dart';
import 'mcp_transport.dart';

/// 本地插件 Binder 传输：Dart 侧门面，原生实现见 android 侧 BinderTransportBridge。
///
/// 构造即触发 [bind]（异步连接 + 注册进程级事件路由表），随后 [send]/[sendStream]
/// 在 READY 前由原生状态机兜底入挂起队列（见 BinderTransportBridge），无需 Dart 侧等待。
///
/// 事件回传（T-trans-3，§1.2.2 / §5，全量 MethodChannel 推挽）：
///  - `notifications/progress` → 经 `_eventBroadcast` 喂给在途 [sendStream]，由
///    [McpClient.callWithProgress] 的 `onProgress` 收侧兑现；
///  - `_async` 异步终帧（同 id `result`/`error`）→ 唤醒 [send]/[sendStream] 等待的 completer；
///  - 反向请求（server→client，带 method+id，如 `sampling/createMessage`）→ 经
///    [onServerRequest] 处理后由 [answerReverse] 回程，闭环见 §1.2.2；
///  - `onTransportError` 死亡信封（binderDied）→ [_failInFlight] 秒级收敛在途。
class BinderTransport implements McpTransport {
  BinderTransport({
    required this.transportId,
    required this.packageName,
    required this.serviceClassName,
    MethodChannel? channel,
    Duration? asyncTerminalTimeout,
  })  : _channel = channel ?? const MethodChannel('goodhub/binder_mcp'),
        asyncTerminalTimeout = asyncTerminalTimeout ?? _kAsyncTerminalTimeout {
    // 顺序要紧：reset 必须先于 bind 入队（同频道 FIFO）——反序会让首轮
    // 装配的 reset 清掉本实例刚 bind 的传输（native 'unknown transport'）。
    // 注册实例并确保事件路由表就绪（进程级只设一次，见 [_ensureMethodCallHandler]）。
    _instances[transportId] = this;
    _ensureMethodCallHandler();
    _guardRegistrySize(); // debug 守卫：未走 close() 的实例会被静态表强引用驻留
    // 触发连接（异步；首个 send 前完成 bind，CONNECTING 期间请求入队）。
    _channel.invokeMethod<void>('bind', <String, Object>{
      'transportId': transportId,
      'packageName': packageName,
      'serviceClassName': serviceClassName,
    }).ignore();
  }

  /// 区分多插件的标识（与宿主侧 transports Map 的 key 对齐）。
  final String transportId;

  /// 目标插件包名（物理主键，§9.3）。
  final String packageName;

  /// 目标插件 Service 全限定类名（如 com.zzh.goodhub.sample.dummy.DummyPluginService）。
  final String serviceClassName;

  final MethodChannel _channel;

  // ---- 原生→Dart 事件路由（全量 MethodChannel 推挽，T-trans-3）----

  /// 事件回传专用 MethodChannel（与请求通道同名、方向相反）：原生经
  /// `invokeMethod('onNativeEvent' / 'onTransportError')` 推帧，本路由表按
  /// transportId 分发到实例，并回 `{'delivered': bool}` ACK（丢件不静默）。
  ///
  /// 为何不用 EventChannel：其消息处理器按**频道名**全局单例——任一实例的
  /// cancel 都会 `setMessageHandler(name, null)` 置空全局 handler，静默杀死
  /// 同频道其他实例的事件投递（2026-10-17「发送信息后卡死」根因）。
  /// MethodChannel 的 handler 只设一次、永不按实例注销，该状态机缺陷被
  /// 结构性消除，且原生每帧都能拿到投递回执。
  static const MethodChannel _eventChannel = MethodChannel('goodhub/binder_mcp');

  /// 路由表就绪标记（进程级只设一次；Hot Restart 后 isolate 重建自然重置）。
  static bool _handlerInitialized = false;

  /// 存活实例注册表（transportId → 实例）：同 id 后建实例覆盖前实例（前实例
  /// 已关闭或其事件本就无人消费）；[close] 只摘自己，避免误摘后建实例。
  ///
  /// 防泄漏契约（静态强引用）：实例只在本表被强引用，泄漏的唯一路径是
  /// 「未走 [close] 就离开作用域」——故 [close] 首行即摘除自己（先于任何
  /// await/抛异常，成败无关）；本守卫负责把违约暴露出来，不上
  /// WeakReference/Finalizer（弱引用取值与「对象已回收但事件正到达」竞态
  /// 的复杂度远高于收益）。
  static final Map<String, BinderTransport> _instances =
      <String, BinderTransport>{};

  /// 注册表尺寸守卫（debug only）：本地插件连接正常为个位数（goodshare /
  /// shiguang / 网关挂载 / 多轮 Run 并存）。超阈值 = 有实例未走 [close] 被
  /// 强引用驻留（生命周期泄漏），留痕告警而非抛错（不阻断运行）。
  static void _guardRegistrySize() {
    assert(() {
      const threshold = 10;
      if (_instances.length > threshold) {
        debugPrint(
          '[WARN] BinderTransport registry leak detected: '
          'count=${_instances.length}（阈值 $threshold）——'
          '检查是否有实例未走 close()',
        );
      }
      return true;
    }());
  }

  /// 确保事件路由表就绪（幂等；首实例构造时建立）：设 MethodCallHandler +
  /// 与原生做一次状态对齐（清掉上一轮 isolate 遗留的僵尸 Client/Callback）。
  /// 前置条件：全进程仅一个 isolate 创建 BinderTransport（现网事实；多
  /// isolate 场景需先改此约定，否则会清掉他 isolate 的连接）。
  static void _ensureMethodCallHandler() {
    if (_handlerInitialized) return;
    _handlerInitialized = true;
    _eventChannel.setMethodCallHandler(_onMethodCall);
    // Hot Restart 对齐：原生清空上一轮 isolate 的僵尸连接（冷启动为 no-op）。
    _eventChannel.invokeMethod<void>('resetAllTransports').ignore();
  }

  /// 原生→Dart 事件路由入口（ACK 契约：命中实例回 delivered=true，否则
  /// false 让原生计数留痕）。
  static Future<Map<String, Object?>> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onNativeEvent':
        return _route(call.arguments, isError: false);
      case 'onTransportError':
        return _route(call.arguments, isError: true);
      default:
        throw MissingPluginException(call.method);
    }
  }

  /// 按 transportId 分发：error 信封（binderDied → SERVER_DIED）走
  /// [_failInFlight] 秒级收敛在途；消息帧进 [_onNativeEvent] JSON-RPC 链。
  static Map<String, Object?> _route(dynamic arguments, {required bool isError}) {
    if (arguments is! Map) return const <String, Object?>{'delivered': false};
    final tid = arguments['transportId'];
    if (tid is! String) return const <String, Object?>{'delivered': false};
    final transport = _instances[tid];
    if (transport == null) return const <String, Object?>{'delivered': false};
    if (isError) {
      final err = arguments['error'];
      final code = err is Map ? err['code'] : null;
      final message = err is Map ? err['message'] : null;
      transport._failInFlight(
        'binder transport 连接中断（${code is String ? code : 'UNKNOWN'}）：'
        '${message is String ? message : 'unknown'}',
      );
    } else {
      transport._onNativeEvent(arguments);
    }
    return const <String, Object?>{'delivered': true};
  }

  /// server→client 反向请求处理器（与 [McpClient.onServerRequest] 对齐）：处理后经
  /// [answerReverse] 回程。由 [McpClient.binder] 工厂转发到 client 的处理器。
  Future<Map<String, Object?>?> Function(String method, Object? params)? onServerRequest;

  /// server→client 主动通知分发（无 id，如 `notifications/resources/updated`）：
  /// [McpClient.binder] 工厂转发到 [McpClient.handleServerNotification]（含
  /// [McpClient.onResourceUpdated]）。GET SSE 通道不适用 Binder（通知走 EventChannel），
  /// 故此处是 Binder 路径订阅失效感知（`notifications/resources/updated`）的唯一下行入口。
  void Function(String method, Object? params)? onServerNotification;

  /// _async 终帧 idle 超时（防悬挂兜底，义务①）：插件侧保证必回终帧，此为进程死亡/
  /// 通道断连等漏推场景的最后防线（宽松取 120s，覆盖慢工具与进度流）。
  static const Duration _kAsyncTerminalTimeout = Duration(seconds: 120);

  /// 实际生效的终帧 idle 超时（可注入覆写，单测用；默认 [_kAsyncTerminalTimeout]）。
  late final Duration asyncTerminalTimeout;

  /// 异步终帧等待表：key = JSON-RPC 请求 id；value = 同 id 经 onEvent 送达的真实结果 raw。
  final Map<Object, Completer<String>> _pendingTerminal = <Object, Completer<String>>{};

  /// 在途 sendStream 控制器（终帧/看门狗未收尾的）：close / binderDied 死亡
  /// 信封时统一报错收敛，拒绝干等看门狗（乱序迟到的帧由 [_emitFrame] 守卫丢弃）。
  final Set<StreamController<String>> _inFlightStreams =
      <StreamController<String>>{};

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

  // ---- 原生事件入口（MethodChannel 推挽：{transportId, message}）----

  /// 秒级收敛本 transport 全部在途等待（close / binderDied 死亡信封共用）：
  /// - [send] 的 `_async` completer → McpNetworkException；
  /// - [sendStream] 的在途流 → addError + close（下游 tools/call 立即得 isError，
  ///   abort/断连场景不再干等 120s 看门狗）。
  /// 丢帧无害化：收敛后迟到的终帧 `_pendingTerminal.remove` 返回 null，
  /// 不再悬挂任何人（注销竞态的正解 = 让丢帧无害，而非纠结移除时序）。
  void _failInFlight(String reason) {
    for (final c in _pendingTerminal.values) {
      if (!c.isCompleted) c.completeError(McpNetworkException(reason));
    }
    _pendingTerminal.clear();
    for (final controller in _inFlightStreams.toList()) {
      if (!controller.isClosed) {
        controller.addError(McpNetworkException(reason));
        controller.close();
      }
    }
    _inFlightStreams.clear();
  }

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
      // 防悬挂兜底（义务①）：插件漏推终帧（进程死亡/通道断连）时超时断言，不永久悬挂。
      final String realRaw;
      try {
        realRaw = await completer.future.timeout(
          asyncTerminalTimeout,
          onTimeout: () => throw McpNetworkException(
            "binder _async 终帧超时（${asyncTerminalTimeout.inSeconds}s 未收到同 id 终帧）",
          ),
        );
      } finally {
        _pendingTerminal.remove(id); // 成功/失败/超时三路径均清，防悬挂残留
      }
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
  // 本地插件通知经 MethodChannel 推挽回推（_onNativeEvent），无独立 GET 长连接；
  // 协议层订阅监听对此类 server 退化为不监听（subscribeResource 仍受 caps 门控）。
  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('Binder 传输不支持 GET SSE 订阅通道（通知走 MethodChannel 推挽）');

  // ---- 流式（callWithProgress 用）：progress / _async 终帧经事件流回传 ----
  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final id = _requestIdOf(requestBody);
    final progressToken = _progressTokenOf(requestBody);

    final controller = StreamController<String>();
    _inFlightStreams.add(controller); // 在途登记：close/死亡时统一收敛
    void retire() => _inFlightStreams.remove(controller);
    // 订阅事件广播（在 await send 之前注册，规避 _async 终帧竞态）。
    late final StreamSubscription<Map<String, Object?>> sub;
    // 防悬挂看门狗（义务①）：_async 终帧漏推时超时断流报错，避免上层永久等待。
    Timer? asyncWatchdog;
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
        asyncWatchdog?.cancel();
        retire();
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
        retire();
        _emitFrame(controller, raw);
        controller.close();
      }
      // _async：不推占位帧，进度/终帧经 _eventBroadcast 后续到达并收尾；
      // 看门狗兜底（义务①）：终帧漏推时超时断流（上层收到 error 而非永久悬挂）。
      asyncWatchdog = Timer(asyncTerminalTimeout, () {
        if (controller.isClosed) return;
        retire();
        sub.cancel();
        controller.addError(
          McpNetworkException(
            "binder _async 终帧超时（${asyncTerminalTimeout.inSeconds}s 未收到同 id 终帧）",
          ),
        );
        controller.close();
      });
      return StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: controller.stream,
      );
    } catch (e) {
      retire();
      sub.cancel();
      controller.addError(e);
      controller.close();
      rethrow;
    }
  }

  /// 以 SSE `data:` 帧 + 空行封装（供 [McpClient.callWithProgress] 的 SSE 分帧解析复用）。
  /// 控制器已收尾（终帧到达后乱序迟到的 progress 帧）→ 静默丢弃：
  /// 向已关闭控制器 add 会抛 StateError（未捕获异步错误）。
  static void _emitFrame(StreamController<String> c, String rawJson) {
    if (c.isClosed) return;
    c.add('data: $rawJson');
    c.add(''); // 空行触发 SSE 断帧 flush
  }

  @override
  void close() {
    if (_closed) return; // 幂等：二次调用静默返回（守卫见字段注释）
    _closed = true;
    // 防泄漏契约（静态强引用）：摘除注册必须是 close() 的第一动作，先于任何
    // await/抛异常——只要进了 close()，强引用必定解除，后续原生通信成败无关。
    // 事件路由表进程级常驻、不随实例退订——无退订即无 cancel 踩踏（结构性
    // 根除），亦无重连重建路径。
    if (_instances[transportId] == this) _instances.remove(transportId);
    // 秒级收敛在途（abort/断连场景不再干等 120s 看门狗）；此后迟到的终帧
    // 因实例已摘除而被路由为 delivered=false 静默丢弃——等待者已全部失败，
    // 丢帧无害。
    _failInFlight('binder transport closed: $transportId');
    _eventBroadcast.close();
    _channel
        .invokeMethod<void>('close', <String, Object>{'transportId': transportId})
        .ignore();
  }
}
