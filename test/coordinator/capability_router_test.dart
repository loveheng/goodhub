// 能力路由判定链回归钉（task-capability W2 · S14）。
//
// 红线：① 落空逐级可区分（六段 blockedAt + reason 各异）；② 声明侧 vs
// 端侧状态侧分类不得混淆（declarationSide 机械承载）；③ 推导口径零行为
// 变化（等价旧 toolFaceOk 判据）；④ localOnly 不可满足 = 显式失败不切云。
import 'package:goodhub/coordinator/capability_router.dart';
import 'package:goodhub/core/capability_requirement.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('① 声明段', () {
    test('needsTools=true → 声明侧落空（分流云端，编排问题）', () {
      final v = evaluateDeviceRoute(
        requirement:
            const CapabilityRequirement(needsTools: true, localOnly: true),
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
      );
      expect(v.deviceAllowed, isFalse);
      expect(v.blockedAt, DeviceRouteStage.declaration);
      expect(v.declarationSide, isTrue,
          reason: '声明自身可满足性侧——文案与降级路径不得混作资源问题');
      expect(v.reason, contains('工具'));
    });

    test('needsStructuredOutput=true → 声明侧落空（端侧约束解码承载未落地）',
        () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(
            needsTools: false, needsStructuredOutput: true),
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
      );
      expect(v.blockedAt, DeviceRouteStage.declaration);
      expect(v.declarationSide, isTrue);
      expect(v.reason, contains('结构化'));
    });

    test('localOnly + 端侧承载缺位 → 显式失败（无可产出路径，不切云）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(
            needsTools: true, localOnly: true),
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
      );
      expect(v.blockedAt, DeviceRouteStage.declaration);
      expect(v.declarationSide, isTrue);
      expect(v.reason, contains('不可满足'));
    });

    test('needsTools:false 显式声明 → 声明段过（端侧可服务）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(needsTools: false),
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
      );
      expect(v.deviceAllowed, isTrue);
    });
  });

  group('② 窗口准入段（S14c：tokenBudget + 资产窗口双维度）', () {
    test('输入估算+输出预留超资产窗口 → 声明侧落空（与预检同式，+64 脚手架）',
        () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(needsTools: false),
        deviceMounted: true,
        deviceCold: false,
        windowTokens: 1280,
        profileExcluded: false,
        offline: false,
        // 1024 + 200 + 64 = 1288 > 1280 → 拒（同式边界）。
        inputEstimateTokens: 1024,
        outputReserve: 200,
      );
      expect(v.blockedAt, DeviceRouteStage.windowAdmission);
      expect(v.declarationSide, isTrue);
      expect(v.reason, contains('1280'));
    });

    test('输入估算+输出预留压线不超窗口 → 过（1024+200+64=1288>1280 反例对照)',
        () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(needsTools: false),
        deviceMounted: true,
        deviceCold: false,
        windowTokens: 1280,
        profileExcluded: false,
        offline: false,
        inputEstimateTokens: 1000, // 1000+200+64=1264 ≤ 1280 → 过
        outputReserve: 200,
      );
      expect(v.deviceAllowed, isTrue);
    });

    test('声明 tokenBudget 被超（输入+输出 > budget）→ 声明侧落空', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(
            needsTools: false, tokenBudget: 1024),
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        inputEstimateTokens: 900,
        outputReserve: 200, // 1100 > 1024 → 拒
      );
      expect(v.blockedAt, DeviceRouteStage.windowAdmission);
      expect(v.declarationSide, isTrue);
      expect(v.reason, contains('tokenBudget'));
    });

    test('budget 在限 → 过（窗口未知时 budget 独立裁决不豁免）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(
            needsTools: false, tokenBudget: 4096),
        deviceMounted: true,
        deviceCold: false,
        windowTokens: null, // 窗口未知
        profileExcluded: false,
        offline: false,
        inputEstimateTokens: 1024,
        outputReserve: 512,
      );
      expect(v.deviceAllowed, isTrue);
    });

    test('双未知（窗口 null + 估算 null）不拦——S14 前口径延续', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(needsTools: false),
        deviceMounted: true,
        deviceCold: false,
        windowTokens: null,
        profileExcluded: false,
        offline: false,
        inputEstimateTokens: null,
      );
      expect(v.deviceAllowed, isTrue);
    });

    test('窗口未知但估算已知 + 无 budget → 不拦（缺一不判）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(needsTools: false),
        deviceMounted: true,
        deviceCold: false,
        windowTokens: null,
        profileExcluded: false,
        offline: false,
        inputEstimateTokens: 999999,
      );
      expect(v.deviceAllowed, isTrue);
    });
  });

  group('③ 时效段', () {
    test('交互级 + 冷态（在线）→ 状态侧落空 COLD_LOAD_BYPASSED_TO_CLOUD', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(
            needsTools: false, latencyClass: LatencyClass.interactive),
        deviceMounted: true,
        deviceCold: true,
        profileExcluded: false,
        offline: false,
      );
      expect(v.blockedAt, DeviceRouteStage.latency);
      expect(v.declarationSide, isFalse,
          reason: '冷热态是端侧运行时状态，非声明问题');
      expect(v.reason, contains('COLD_LOAD_BYPASSED_TO_CLOUD'));
    });

    test('交互级 + 冷态（离线）→ OFFLINE_COLD_LOAD_WAIT（装载等待方向）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(
            needsTools: false, latencyClass: LatencyClass.interactive),
        deviceMounted: true,
        deviceCold: true,
        profileExcluded: false,
        offline: true,
      );
      expect(v.reason, contains('OFFLINE_COLD_LOAD_WAIT'));
    });

    test('批处理级 + 冷态 → 不拦（可等待装载与排队）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(needsTools: false),
        deviceMounted: true,
        deviceCold: true,
        profileExcluded: false,
        offline: false,
      );
      expect(v.deviceAllowed, isTrue);
    });
  });

  group('④⑤ 端侧状态段', () {
    test('引擎未挂载 → readiness 落空（状态侧）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(needsTools: false),
        deviceMounted: false,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
      );
      expect(v.blockedAt, DeviceRouteStage.readiness);
      expect(v.declarationSide, isFalse);
    });

    test('准入画像双坏 → admissionProfile 落空（状态侧）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(needsTools: false),
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: true,
        offline: false,
      );
      expect(v.blockedAt, DeviceRouteStage.admissionProfile);
      expect(v.declarationSide, isFalse);
    });
  });

  group('S14b 驻留匹配度 × 主体属性（K19）', () {
    final req = const CapabilityRequirement(needsTools: false);

    test('驻留不匹配 + 宿主后台任务 → readiness 落空（禁换驻留，分流云端）',
        () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        subject: CallerSubject.hostBackground,
        residentMatched: false,
      );
      expect(v.blockedAt, DeviceRouteStage.readiness);
      expect(v.declarationSide, isFalse, reason: '驻留是端侧运行时状态');
      expect(v.reason, contains('后台任务'));
      expect(v.reason, contains('K19'));
    });

    test('驻留不匹配 + 外部 App → 同后台处置（以调用方为准）', () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        subject: CallerSubject.externalApp,
        residentMatched: false,
      );
      expect(v.blockedAt, DeviceRouteStage.readiness);
      expect(v.reason, contains('外部 App'));
    });

    test('驻留不匹配 + 宿主前台交互 → 放行（前台可触发换驻留走场景 C）', () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        subject: CallerSubject.hostForeground,
        residentMatched: false,
      );
      expect(v.deviceAllowed, isTrue);
    });

    test('驻留匹配 → 任意主体放行', () {
      for (final s in CallerSubject.values) {
        final v = evaluateDeviceRoute(
          requirement: req,
          deviceMounted: true,
          deviceCold: false,
          profileExcluded: false,
          offline: false,
          subject: s,
          residentMatched: true,
        );
        expect(v.deviceAllowed, isTrue, reason: 'subject=$s');
      }
    });

    test('驻留未知（票据不可达）→ 不拦，交装载链路对账', () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        subject: CallerSubject.hostBackground,
        residentMatched: null,
      );
      expect(v.deviceAllowed, isTrue);
    });

    test('主体缺省 = 宿主前台交互（存量调用零变化）', () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        residentMatched: false,
      );
      expect(v.deviceAllowed, isTrue);
    });

    test('后台任务 + 交互级冷态：时效段先拦（段序在驻留匹配之前）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(
            needsTools: false, latencyClass: LatencyClass.interactive),
        deviceMounted: true,
        deviceCold: true,
        profileExcluded: false,
        offline: false,
        subject: CallerSubject.hostBackground,
        residentMatched: false,
      );
      expect(v.blockedAt, DeviceRouteStage.latency);
    });
  });

  group('S14d 内存地板与配额（动态准入段，K9 两类落空分口径）', () {
    final req = const CapabilityRequirement(needsTools: false);

    test('availMem 跌破绝对地板 → memoryFloor 落空（资源故障侧，分流云端）',
        () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        availMemBytes: 800 * 1024 * 1024, // 800MB < 1GB 地板
      );
      expect(v.blockedAt, DeviceRouteStage.memoryFloor);
      expect(v.declarationSide, isFalse, reason: '内存是端侧运行时状态');
      expect(v.governanceViolation, isFalse,
          reason: '资源故障 ≠ 治理违规——分流云端保产出');
      expect(v.reason, contains('800'));
      expect(v.reason, contains('1024'));
    });

    test('availMem 高于地板 → 过', () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        availMemBytes: 2 * 1024 * 1024 * 1024,
      );
      expect(v.deviceAllowed, isTrue);
    });

    test('availMem 取证不可达（null）→ 不判，交运行时护栏链兜底', () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        availMemBytes: null,
      );
      expect(v.deviceAllowed, isTrue);
    });

    test('配额超限 → quota 落空（治理违规类，快速失败不切云）', () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        quotaExceeded: true,
        subject: CallerSubject.externalApp,
      );
      expect(v.blockedAt, DeviceRouteStage.quota);
      expect(v.governanceViolation, isTrue,
          reason: '治理违规 ≠ 资源故障——超限切云 = 算力成本转嫁宿主云端账单');
      expect(v.reason, contains('externalApp'));
    });

    test('配额在限（缺省 false）→ 过（存量调用零变化）', () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
      );
      expect(v.deviceAllowed, isTrue);
      expect(v.governanceViolation, isFalse);
    });

    test('段序：画像双坏先于内存地板先于配额（多段命中取最先）', () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: true,
        offline: false,
        availMemBytes: 0,
        quotaExceeded: true,
      );
      expect(v.blockedAt, DeviceRouteStage.admissionProfile);
    });

    test('localOnly + 配额超限：治理违规快速失败优先（都不切云，路径殊途同归）',
        () {
      final v = evaluateDeviceRoute(
        requirement: req,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        quotaExceeded: true,
      );
      expect(v.governanceViolation, isTrue);
      // 处置由调用方 send() 承接：governanceViolation → QuotaExceededException
      // 快速失败；localOnly 落空 → InferenceException 显式失败。两者都不切云。
    });
  });

  group('S14e 排除位 localOnly（K10：落空快速失败不切云）', () {
    /// 排除位声明（端侧可服务——needsTools=false，否则声明段先拦）。
    const localOnlyReq = CapabilityRequirement(needsTools: false, localOnly: true);

    test('窗口超窗 + 排除位 → 排除位违规（不切云）', () {
      final v = evaluateDeviceRoute(
        requirement: localOnlyReq,
        deviceMounted: true,
        deviceCold: false,
        windowTokens: 1280,
        profileExcluded: false,
        offline: false,
        inputEstimateTokens: 1024,
        outputReserve: 200,
      );
      expect(v.blockedAt, DeviceRouteStage.windowAdmission);
      expect(v.localOnlyViolation, isTrue);
    });

    test('交互级冷态（在线）+ 排除位 → 排除位违规（处置本是切云）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(
            needsTools: false,
            localOnly: true,
            latencyClass: LatencyClass.interactive),
        deviceMounted: true,
        deviceCold: true,
        profileExcluded: false,
        offline: false,
      );
      expect(v.blockedAt, DeviceRouteStage.latency);
      expect(v.localOnlyViolation, isTrue);
    });

    test('交互级冷态（离线）+ 排除位 → 非违规（处置 = 装载等待，云端不可达）',
        () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(
            needsTools: false,
            localOnly: true,
            latencyClass: LatencyClass.interactive),
        deviceMounted: true,
        deviceCold: true,
        profileExcluded: false,
        offline: true,
      );
      expect(v.blockedAt, DeviceRouteStage.latency);
      expect(v.localOnlyViolation, isFalse,
          reason: '离线冷态处置 = 装载等待，排除位不改变处置（分流必失败）');
    });

    test('引擎未挂载 + 排除位 → 排除位违规', () {
      final v = evaluateDeviceRoute(
        requirement: localOnlyReq,
        deviceMounted: false,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
      );
      expect(v.blockedAt, DeviceRouteStage.readiness);
      expect(v.localOnlyViolation, isTrue);
    });

    test('驻留不匹配（后台主体）+ 排除位 → 排除位违规', () {
      final v = evaluateDeviceRoute(
        requirement: localOnlyReq,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        subject: CallerSubject.hostBackground,
        residentMatched: false,
      );
      expect(v.blockedAt, DeviceRouteStage.readiness);
      expect(v.localOnlyViolation, isTrue);
    });

    test('准入画像双坏 + 排除位 → 排除位违规', () {
      final v = evaluateDeviceRoute(
        requirement: localOnlyReq,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: true,
        offline: false,
      );
      expect(v.blockedAt, DeviceRouteStage.admissionProfile);
      expect(v.localOnlyViolation, isTrue);
    });

    test('内存地板跌破 + 排除位 → 排除位违规（资源故障类在排除位下也不切云）', () {
      final v = evaluateDeviceRoute(
        requirement: localOnlyReq,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        availMemBytes: 800 * 1024 * 1024,
      );
      expect(v.blockedAt, DeviceRouteStage.memoryFloor);
      expect(v.localOnlyViolation, isTrue);
    });

    test('配额超限 + 排除位 → 治理违规口径优先（两端口径分属，不叠加）', () {
      final v = evaluateDeviceRoute(
        requirement: localOnlyReq,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
        quotaExceeded: true,
      );
      expect(v.governanceViolation, isTrue);
      expect(v.localOnlyViolation, isFalse);
    });

    test('无排除位时同类落空仍可切云（存量零行为变化）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(needsTools: false),
        deviceMounted: false,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
      );
      expect(v.blockedAt, DeviceRouteStage.readiness);
      expect(v.localOnlyViolation, isFalse);
    });

    test('排除位 + 端侧可服务 → 放行（排除位不拦可用路径）', () {
      final v = evaluateDeviceRoute(
        requirement: localOnlyReq,
        deviceMounted: true,
        deviceCold: false,
        profileExcluded: false,
        offline: false,
      );
      expect(v.deviceAllowed, isTrue);
      expect(v.localOnlyViolation, isFalse);
    });
  });

  group('⑥ 顺序与推导', () {
    test('段序固定：声明先于时效先于就绪（多段命中取最先）', () {
      final v = evaluateDeviceRoute(
        requirement: const CapabilityRequirement(needsTools: true),
        deviceMounted: false,
        deviceCold: true,
        profileExcluded: true,
        offline: false,
      );
      expect(v.blockedAt, DeviceRouteStage.declaration);
    });

    test('deriveChatRequirement 等价旧 toolFaceOk 判据（零行为变化）', () {
      // 无工具 → 放行（needsTools=false）。
      expect(deriveChatRequirement(const [], null).needsTools, isFalse);
      // 有工具 + 无策略注入（严格 isEmpty）→ needsTools=true（旧：不放行）。
      expect(deriveChatRequirement([const CloudToolSchema(name: 't', description: 't', parametersSchema: {})], null).needsTools, isTrue);
      // 有工具 + 策略放行 → needsTools=false（旧：全本地工具面放行）。
      expect(
        deriveChatRequirement([const CloudToolSchema(name: 't', description: 't', parametersSchema: {})], (_) => true).needsTools,
        isFalse,
      );
      // 有工具 + 策略拒绝 → needsTools=true（旧：不放行）。
      expect(
        deriveChatRequirement([const CloudToolSchema(name: 't', description: 't', parametersSchema: {})], (_) => false).needsTools,
        isTrue,
      );
    });
  });
}


