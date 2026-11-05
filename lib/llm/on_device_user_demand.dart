import 'package:flutter/foundation.dart';

/// 端侧引擎槽的用户需求代次（timeout-signaling W1-2 让位状态机信号源）。
///
/// 用户路径（混合引擎装配的 adapter：enable / generateStream）每次进入即
/// `touch()` 递增；探针在 load 前止步、装载打断不记坏画像、让位时跳过
/// unload（已载模型转正给前台复用），全靠比对代次变化，无跨对象互斥锁。
/// 探针路径（`byProbe: true` 的 adapter 实例）不 touch——自驱动不算用户需求。
final ValueNotifier<int> onDeviceUserDemandGen = ValueNotifier<int>(0);

/// 用户路径进入标记（仅用户装配侧 adapter 调用；探针路径禁调）。
void touchOnDeviceUserDemand() => onDeviceUserDemandGen.value++;
