/// 混合引擎默认装配（M2-T2，S2 正式接线）：首个 BYOK profile + 密钥 → 云端
/// 引擎；端侧 = `:engine` Genie 正式路径（AIDL → 持久会话，进程级共享实例）。
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

import '../core/notice_category.dart';
import '../llm/cloud/byok_store.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/device_tier.dart';
import '../llm/llm.dart';
import '../llm/on_device_engine.dart';
import '../llm/on_device_engine_adapter.dart';
import '../llm/on_device_engine_aidl.dart';
import '../llm/on_device_gate_override.dart';
import 'discovery_executor.dart';
import 'local_resource_tool_executor.dart';
import 'memory_tool_executor.dart';
import 'plan_proposal_tool.dart';
import 'skill_registry.dart';
import 'degradation_controller.dart';
import 'fenced_cloud_engine.dart';
import 'hybrid_cloud_engine.dart';

/// 组装默认混合引擎。判据阈值取 [controller]（连接 5s 硬超时由引擎构造吸收）。
///
/// [maskOverride]（联调注入位，仅 debug 页与测试传入）：透传
/// [FencedCloudEngine.maskOverride]——遮蔽失败路径注入，真机验证拦截卡三态
/// （取消/明文一次/fail-closed）；生产调用方一律不传（约定见引擎字段注释）。
///
/// [onNote]（ux-hardening P2-1）：BYOK 读取失败的**用户可见**通道——历史病是
/// 该失败仅 debugPrint，用户自带 key 失效后效果变差（静默退端侧）而完全不知
/// 道为什么；现经装配 note 通道以轨道通告呈现。

/// 端侧工具面判据（S2 纯聊天收口；[HybridCloudEngine.deviceToolPolicy] 注入源）：
/// tools 全为宿主本地元工具 → 放行（端侧单发不产工具调用，元工具静默缺席 =
/// 离线降级的可接受语义）；出现任何 MCP 服务端工具仍走云端编排（§2 硬约束本意
/// 不变）。工具名一律引用各 owner 的单源常量（防字符串双源漂移——query_memory
/// 曾漏单致纯聊天永不可端侧，回归钉 = hybrid_assembly_test 白名单覆盖测试）。
bool deviceToolFaceAllow(List<CloudToolSchema> tools) => tools.every((t) {
      final n = t.name;
      return n == DiscoveryExecutor.getConnectedApps ||
          n == DiscoveryExecutor.activateServerTools ||
          n == DiscoveryExecutor.useServer ||
          n == MemoryToolExecutor.updateToolName ||
          n == MemoryToolExecutor.queryToolName ||
          n == LocalResourceToolExecutor.toolName ||
          n == SkillRegistry.activateSkillToolName ||
          n == PlanProposalTool.toolName;
    });

Future<HybridCloudEngine> assembleDefaultHybridEngine({
  DegradationController? controller,
  PiiFenceDelegate? piiFenceDelegate,
  Future<String> Function(String)? maskOverride,
  void Function(String message, {bool danger, TrackNoticeCategory category})? onNote,
  ByokStore? byokStoreOverride,
}) async {
  final ctrl = controller ?? DegradationController();
  CloudLlmEngine? cloud;
  try {
    final store = byokStoreOverride ?? ByokStore();
    final profiles = await store.load();
    if (profiles.isNotEmpty) {
      // 生效位优先（用户显式选择，设置页置顶写入）；未选回退列表首位。
      final preferred = await store.preferredProfileId();
      final active =
          profiles.where((p) => p.id == preferred).firstOrNull ??
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
    // P2-1：失败不再只留痕——经 note 通道告知用户「本次为什么只有端侧」。
    onNote?.call('⚠ 云端模型配置读取失败，本次任务仅走端侧路径：$e', danger: true, category: TrackNoticeCategory.fact);
  }
  // §16 用户覆盖层（设置页）：读取偏好优先端侧。路由门禁层已降级 advisory
  //（2026-10-31 裁决，见 HybridCloudEngine），「紧急强行启用」与 ignore*
  // 放宽开关随拦截语义一并退役。
  final gateOverride = await OnDeviceGateOverride.read();

  return HybridCloudEngine(
    controller: ctrl,
    cloud: cloud,
    // S2 正式接线：端侧槽 = :engine Genie 正式路径（替换旧 LiteRT-LM 桥
    // ChannelLlmEngine——其模型管理链已归档，见 on-device epic 盘点）。
    // 进程级共享实例：MethodChannel handler 单槽，多实例互踩回调。
    onDevice: AidlOnDeviceLlmEngineAdapter(sharedOnDeviceEngine),
    // S2 纯聊天收口：AgentLoop 工具面恒含宿主本地元工具（发现/记忆/资源/
    // skill 激活/plan 提案——全部宿主本地拦截执行），字面 `tools.isEmpty`
    // 使纯聊天永远不可端侧。判据 = tools 全为宿主本地元工具即放行（端侧
    // 单发不产工具调用，元工具静默缺席 = 离线降级的可接受语义）；出现任何
    // MCP 服务端工具仍走云端编排（§2 硬约束本意不变）。
    deviceToolPolicy: deviceToolFaceAllow,
    // 用户启用覆盖：偏好优先端侧。
    preferOnDevice: gateOverride.preferOnDevice,
    // 场景 A/B/C 切云语义拆分：前台态探针（场景 B 后台冷装载 → 不切云、打
    // PendingForegroundLoad 暂存等前台；场景 C 前台冷装载 → 加载态 + 超时保护
    // → 终态显式失败 / 可自愈类按需降级云端）。探针异常按后台保守处理。
    isForegroundProbe: () => sharedOnDeviceEngine.isForeground(),
    // §16 设备分级门禁（advisory，2026-10-31 裁决）：RAM/电量/省电/温控判定
    // 结果只留痕提示，不拦截路由（探针走 goodhub/llm 设备信息通道）。
    // S2 正式接线：Genie 常驻会话就绪（权重已驻留 ~1.9GB）时豁免可用 RAM
    // 门槛——冷加载门槛对驻留态失义（自锁：常驻自己压低 availMem）。
    deviceTierGate: () async {
      final probe = await ChannelLlmEngine().deviceProbe();
      if (probe == null) {
        return (pass: true, reason: '探针不可用放行（非 Android/未实现）');
      }
      // M4：票据面权威状态（checkStatus 轮询面已退役）；未知（null）按
      // 非驻留处理（保守口径：冷加载门槛生效）。
      final status = await sharedOnDeviceEngine.authoritativeStatus();
      return DeviceTierGate.check(
        probe,
        sessionResident:
            status == EngineStatus.ready || status == EngineStatus.busy,
      );
    },
  );
}
