import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_tier.dart';
import 'llm_model.dart';

/// 端侧 LLM 引擎接口（M2 自 goodshare 随迁，原设计见 goodshare 仓
/// docs/design/on-device-llm.md，随迁后 SSOT 移至本仓 docs/design/）。
///
/// 双端分治：Android = LiteRT-LM Kotlin（Stable）+ SoC 感知模型包；
/// iOS = FoundationModels 系统模型（零下载）。两端实现各自独立，
/// 本层只约定 Dart 侧契约。
///
/// 三条口径：
/// - `isAvailable` **动态探测、不做一次性持久化**（模型包状态动态，防 OCR 误判锁死的坑）；
/// - 生成失败不抛给调用方——返回 null 交给上层走「占位完成 + 可观测反馈」；
/// - 引擎不可用时上层不应入队（入队前预检）。
/// 端侧约束解码规格（architecture §2：端侧仅提取/分类 + 约束解码）。
///
/// 经原生桥映射到 LiteRT-LM `ResponseFormat.json/regex`；2026-10-11 真机实证
/// 通过（regex/JSON Schema 均严格合规，约束开销可忽略——见 architecture §2）。
/// 原生失败（不支持/未下载模型）仍照常降级 null。
class LlmResponseFormat {
  const LlmResponseFormat.jsonSchema(this.schemaOrPattern) : kind = 'json';

  const LlmResponseFormat.regex(this.schemaOrPattern) : kind = 'regex';

  /// 与原生 parseResponseFormat 的分支字面量对齐：'json' | 'regex'。
  final String kind;

  /// json = JSON Schema 文本；regex = 正则模式。
  final String schemaOrPattern;

  Map<String, String> toChannelArgs() => {'type': kind, 'value': schemaOrPattern};
}

abstract class OnDeviceLlmEngine {
  /// 实现名（日志 / 设置页展示）。
  String get name;

  /// 引擎可用性：Android = 模型包已下载且引擎可初始化；iOS = Apple Intelligence 门控。
  Future<bool> get isAvailable;

  /// 不可用时给人类看的原因（设置页小字）；可用时为 null。
  ///
  /// 同步兜底文案——真实原因走 [unavailableReasonAsync]（异步探测）。
  String? get unavailableReason;

  /// 异步取真实原因（R1：任务 note 必须携带真值，否则 AI/用户被「未下载模型」
  /// 兜底文案误导——实测模型在机仍报不可用，真因在 init/生成阶段却不可见）。
  /// 默认回退到同步值；原生桥实现（ChannelLlmEngine）向原生取真值。
  Future<String?> unavailableReasonAsync() async => unavailableReason;

  /// 文本生成。失败 / 不可用 / 空产出返回 null（不抛，翻译式降级）。
  ///
  /// [system] 为任务指令（摘要/关键词等由调用方组装）；[maxTokens] 限制输出长度；
  /// [responseFormat] 传约束解码规格（缺省 = 无约束；约束失败与普通失败同口径降级）。
  Future<String?> generate(
    String prompt, {
    String? system,
    int maxTokens = 512,
    LlmResponseFormat? responseFormat,
  });

  /// 取消当前在途生成（§10 Abort 级联①步：终止本地 LLM Generator）。
  ///
  /// 引擎为单飞行（原生单线程 executor 一次只跑一个生成），故「取消在途」无歧义；
  /// 无在途生成时为无害 no-op（返回 false）。取消后 [generate] 的返回值不落地——
  /// 取消方已放弃结果（Cancelled ≠ Failed，取消不是产出也不是失败）。
  Future<bool> cancelActive();

  /// 预热引擎（§2 前台驻留策略的挂载点）：后台初始化引擎至就绪才完成，
  /// await 期间即「离线引擎唤醒中」反馈窗口；已热时立即完成。模型缺失返回 false。
  Future<bool> warmup();

  /// 释放引擎（§2 Doze/后台期策略）：排队在途生成之后执行，释放权重内存。
  Future<void> release();

  /// 引擎是否已热（已初始化驻留）。
  Future<bool> isWarmed();
}

/// MethodChannel 桥实现：Android 原生 handler 提供同名协议
/// （`goodhub/llm`：`isAvailable` / `unavailableReason` / `generate` / `cancel` /
/// `warmup` / `release` / `isWarmed` / `socModel`）。
///
/// 原生侧不可用（如 LiteRT-LM 依赖缺失、非 Android 平台）时 MethodChannel 抛
/// MissingPluginException —— 统一落 [UnavailableLlmEngine] 语义（isAvailable=false），
/// 绝不让异常穿透到任务循环。
class ChannelLlmEngine implements OnDeviceLlmEngine {
  ChannelLlmEngine({this.channel = const MethodChannel('goodhub/llm')});

  final MethodChannel channel;

  @override
  String get name => '端侧大模型';

  @override
  Future<bool> get isAvailable async {
    try {
      return await channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('[LlmEngine] isAvailable failed: ${e.code}');
      return false;
    }
  }

  @override
  String? get unavailableReason {
    // 同步 getter 拿不到异步结果；原生侧把原因并入 isAvailable 的返回负载，
    // 此处仅给桥层兜底文案（设置页会用 [unavailableReasonAsync] 取真值）。
    return '端侧大模型引擎不可用（未下载模型或系统不支持）';
  }

  /// 异步取真值原因（设置页 / 任务 note 用）；原生侧未实现时返回兜底文案。
  @override
  Future<String?> unavailableReasonAsync() async {
    try {
      return await channel.invokeMethod<String>('unavailableReason') ?? unavailableReason;
    } on MissingPluginException {
      return '当前平台无端侧大模型引擎';
    } on PlatformException catch (e) {
      return e.message ?? unavailableReason;
    }
  }

  @override
  Future<String?> generate(
    String prompt, {
    String? system,
    int maxTokens = 512,
    LlmResponseFormat? responseFormat,
  }) async {
    try {
      final r = await channel.invokeMethod<String>('generate', {
        'prompt': prompt,
        'system': ?system,
        'max_tokens': maxTokens,
        if (responseFormat != null) 'response_format': responseFormat.toChannelArgs(),
      });
      final t = r?.trim();
      return (t == null || t.isEmpty) ? null : t;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      // message 带上：spike 期间「SDK 不支持约束」与「空产出」靠它区分
      debugPrint('[LlmEngine] generate failed: ${e.code} ${e.message ?? ''}');
      return null;
    }
  }

  /// 设备环境探针（§16 门禁数据源：RAM/电量/充电/省电/温控）。
  /// 非 Android / 原生未实现返回 null → [DeviceTierGate] 按未知放行。
  Future<DeviceProbe?> deviceProbe() async {
    try {
      final m = await channel.invokeMethod<Map<Object?, Object?>>('deviceProbe');
      return m == null ? null : DeviceProbe.fromMap(m);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('[LlmEngine] deviceProbe failed: ${e.code} ${e.message ?? ''}');
      return null;
    }
  }

  /// 设备 SoC 型号（`ro.soc.model`，原生回传）；非 Android / 读取失败为 null。
  /// 用于 NPU 专包的「本机可见性」判定（goodshare on-device-llm.md §3.1 SoC 感知）。
  Future<String?> socModel() async {
    try {
      return await channel.invokeMethod<String>('socModel');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> cancelActive() async {
    try {
      return await channel.invokeMethod<bool>('cancel') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      // 取消失败不可观测阻断 Abort 级联（级联还要走②③④步），留痕即可
      debugPrint('[LlmEngine] cancel failed: ${e.code} ${e.message ?? ''}');
      return false;
    }
  }

  @override
  Future<bool> warmup() async {
    try {
      return await channel.invokeMethod<bool>('warmup') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('[LlmEngine] warmup failed: ${e.code} ${e.message ?? ''}');
      return false;
    }
  }

  @override
  Future<void> release() async {
    try {
      await channel.invokeMethod<void>('release');
    } on MissingPluginException {
      // 非 Android 平台无原生桥，无引擎可释放
    } on PlatformException catch (e) {
      debugPrint('[LlmEngine] release failed: ${e.code} ${e.message ?? ''}');
    }
  }

  @override
  Future<bool> isWarmed() async {
    try {
      return await channel.invokeMethod<bool>('isWarmed') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// 兜底实现：恒不可用（测试 / 无原生桥平台）。
class UnavailableLlmEngine implements OnDeviceLlmEngine {
  const UnavailableLlmEngine(this.reason);

  final String reason;

  @override
  String get name => '端侧大模型（不可用）';

  @override
  Future<bool> get isAvailable async => false;

  @override
  String? get unavailableReason => reason;

  @override
  Future<String?> unavailableReasonAsync() async => reason;

  @override
  Future<String?> generate(
    String prompt, {
    String? system,
    int maxTokens = 512,
    LlmResponseFormat? responseFormat,
  }) async => null;

  @override
  Future<bool> cancelActive() async => false;

  @override
  Future<bool> warmup() async => false;

  @override
  Future<void> release() async {}

  @override
  Future<bool> isWarmed() async => false;
}

/// NPU 专包对本机是否可见（SoC 感知；goodshare on-device-llm.md §3.1）。
/// [soc] 为原生回传的 `ro.soc.model`；null（非 Android / 未知）→ 仅通用包可见。
bool llmModelVisibleOnDevice(LlmModel m, String? soc) =>
    m.socModel == null || (soc != null && soc.toUpperCase() == m.socModel!.toUpperCase());
