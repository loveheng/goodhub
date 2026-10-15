/// 混合引擎默认装配（M2-T2）：首个 BYOK profile + 密钥 → 云端引擎；端侧桥兜底。
///
/// BYOK 配置 UI 属 M3 设置页（原服务大厅）——T2 阶段 profile 经 ByokStore 预置（无 UI 路径），
/// 无 profile / 安全存储不可用时云端缺位，任务循环仍可走端侧或可观测报错。
///
/// N7 围栏（M2-T5b）：云端引擎恒包 [FencedCloudEngine] 装饰（D1 单咽喉——
/// 端侧路径不设防）。**一次装配 = 一次 Run 的围栏映射会话（D2）**：调用方
/// 按 Run 装配（debug 联调页每 Run、任务页每 runOnce；降级判据记忆经
/// [controller] 跨 Run 注入保留）。[piiFenceDelegate] 缺省 null = 无人值守
/// fail-closed（D4；有人值守面在 T5c 接确认卡）。
library;

import 'package:flutter/foundation.dart';

import '../llm/cloud/byok_store.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/device_tier.dart';
import '../llm/llm.dart';
import 'degradation_controller.dart';
import 'fenced_cloud_engine.dart';
import 'hybrid_cloud_engine.dart';

/// 组装默认混合引擎。判据阈值取 [controller]（连接 5s 硬超时由引擎构造吸收）。
///
/// [maskOverride]（联调注入位，仅 debug 页与测试传入）：透传
/// [FencedCloudEngine.maskOverride]——遮蔽失败路径注入，真机验证拦截卡三态
/// （取消/明文一次/fail-closed）；生产调用方一律不传（约定见引擎字段注释）。
Future<HybridCloudEngine> assembleDefaultHybridEngine({
  DegradationController? controller,
  PiiFenceDelegate? piiFenceDelegate,
  Future<String> Function(String)? maskOverride,
}) async {
  final ctrl = controller ?? DegradationController();
  CloudLlmEngine? cloud;
  try {
    final store = ByokStore();
    final profiles = await store.load();
    if (profiles.isNotEmpty) {
      // 生效位优先（用户显式选择，设置页置顶写入）；未选回退列表首位。
      final preferred = await store.preferredProfileId();
      final active = profiles.where((p) => p.id == preferred).firstOrNull ??
          profiles.first;
      final key = await store.apiKey(active.id);
      if (key != null && key.isNotEmpty) {
        cloud = FencedCloudEngine(
          inner: engineFor(
            active,
            apiKey: key,
            connectTimeout: ctrl.connectTimeout,
          ),
          delegate: piiFenceDelegate,
          maskOverride: maskOverride,
        );
      }
    }
  } catch (e) {
    // DEGRADE: BYOK 配置读取失败不阻断任务循环——云端缺位走端侧/可观测报错。
    debugPrint('[DEGRADE] byok-assembly: $e');
  }
  return HybridCloudEngine(
    controller: ctrl,
    cloud: cloud,
    onDevice: ChannelLlmEngine(),
    // §16 设备分级门禁（初值实时探针）：RAM/电量/省电/温控不达标时端侧关闸
    deviceTierGate: () async {
      final probe = await ChannelLlmEngine().deviceProbe();
      if (probe == null) {
        return (pass: true, reason: '探针不可用放行（非 Android/未实现）');
      }
      return DeviceTierGate.check(probe);
    },
  );
}
