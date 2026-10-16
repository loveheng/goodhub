/// 传输层异常形状判定（core 层识别 → 上层只消费枚举）。
///
/// **为什么要有这一层**：异常文案翻译（`ui/error_copy.dart`）需要识别
/// `SocketException` / `HttpException` 这类 **dart:io 具名类型**，但 UI 层禁
/// `dart:io`（arch-guard R1 / coding-standards Rule 1：平台污染不得进窗口层）。
/// 判定下沉本层——core 是基础设施层（叶层，零出向但允许 SDK 的 `dart:io`），
/// 上层 switch 只认 [TransportErrorKind] 枚举，不认平台类型。
library;

import 'dart:async';
import 'dart:io';

/// 传输层异常分类；[TransportErrorKind.none] = 非传输层异常，交调用方兜底。
enum TransportErrorKind {
  /// 非传输层异常（兜底形状）。
  none,

  /// 等待响应超时（含连接/读写各阶段）。
  timeout,

  /// 网络不通（DNS / 连接被拒 / 无网卡 / 握手失败）。
  socket,

  /// HTTP 协议层失败（非 2xx 之外的协议错误）。
  http,
}

/// 判定 [error] 是否属传输层及其种类。纯函数、无副作用、绝不抛（未知即 none）。
TransportErrorKind classifyTransportError(Object error) => switch (error) {
      TimeoutException() => TransportErrorKind.timeout,
      SocketException() => TransportErrorKind.socket,
      HttpException() => TransportErrorKind.http,
      _ => TransportErrorKind.none,
    };
