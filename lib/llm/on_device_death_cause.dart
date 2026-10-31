/// 端侧 `:engine` 死因排除法裁定（G2-3，墓碑机制 ADR 2026-10-31）。
///
/// SIGKILL（LMK/OEM）按 POSIX 不可捕获 → 死因对 App 不可见；排除法 =
/// 「有没有 Crash Stack」切开硬崩溃与 LMK，再用「死时 FLAG_LOADING +
/// 内存低」钉死 LMK（decisions.md 死因可见性 ADR）：
///
/// | 证据 | 裁定 |
/// |---|---|
/// | 崩溃栈文件在（SIGSEGV/SIGABRT/SIGBUS 落盘，G2-2） | `hardCrash`（驱动/SDK 崩溃，硬故障） |
/// | 无栈 + `FLAG_LOADING`（装载中死亡） | `lmkSigkill`（软故障——装载窗口即 2~3GB 分配窗口，mem-pressure 击杀的天然现场；栈缺失由「SIGKILL 不可捕获」立法保证） |
/// | 无栈 + `FLAG_READY`（装载完成后死亡） | `runtimeTerminated`（运行期外部终止，按环境再判） |
/// | flag 文件不存在 | `unknownColdStart`（未受理过装载即死 = 冷启动窗口，天然非快死） |
///
/// 纯逻辑件（目录列举/文件读取注入化）：裁定规则可纯 Dart 单测。
library;

import 'dart:io';

/// 死因三态 + 冷启动未知态。
enum EngineDeathCause {
  /// LMK / OEM 内存压力 SIGKILL（软故障——计入快死棘轮驱动退火）。
  lmkSigkill,

  /// 驱动 / SDK 崩溃（硬故障——计入熔断 countable 面语义归属）。
  hardCrash,

  /// 运行期外部终止（FLAG_READY 后死亡，按环境再判）。
  runtimeTerminated,

  /// 无墓碑（冷启动窗口死亡 / flag 已清 / 墓碑面不可用）——非快死。
  unknownColdStart,
}

/// 墓碑现场快照（目录证据的结构化载体）。
class TombstoneEvidence {
  const TombstoneEvidence({
    this.flagState,
    this.hasCrashStack,
  });

  /// `<pid>.flag` 内容（FLAG_LOADING / FLAG_READY）；缺失 = null。
  final String? flagState;

  /// `<pid>.stack` 是否存在（G2-2 崩溃栈落盘）。
  final bool? hasCrashStack;
}

/// 排除法裁定（纯函数）：[evidence] 缺失维度 = 未知，按保守侧收口。
///
/// 内存证据（availRam）只作日志对账不参与判定：死亡后主进程探测存在
/// 「击杀→释放→水位回升」竞态，把它放进裁定式会引入概率性——ADR 的
/// 「整机内存低」由 FLAG_LOADING 语义承载（装载窗口即分配窗口）。
EngineDeathCause classifyEngineDeath(TombstoneEvidence evidence) {
  if (evidence.hasCrashStack == true) return EngineDeathCause.hardCrash;
  switch (evidence.flagState) {
    case 'FLAG_LOADING':
      return EngineDeathCause.lmkSigkill;
    case 'FLAG_READY':
      return EngineDeathCause.runtimeTerminated;
    default:
      return EngineDeathCause.unknownColdStart;
  }
}

/// 读取墓碑目录证据（生产实现）：取最新 `<pid>.flag` 与任意 `*.stack`，
/// 读后即清（一次性证据，防 PID 复用污染下次裁定）。
///
/// 目录不可读 / 无文件 → 空证据（裁定落 `unknownColdStart`，非快死侧）。
Future<TombstoneEvidence> readTombstoneEvidence(String tombstoneDir) async {
  String? flagState;
  bool? hasCrashStack;
  try {
    final dir = Directory(tombstoneDir);
    if (!await dir.exists()) {
      return const TombstoneEvidence(flagState: null, hasCrashStack: false);
    }
    // flag：取修改时间最新的一个（旧进程残留由读后清理收敛）。
    File? newestFlag;
    await for (final f in dir.list()) {
      if (f is! File) continue;
      if (f.path.endsWith('.flag')) {
        final stat = await f.stat();
        if (newestFlag == null ||
            stat.modified.isAfter(await newestFlag.lastModified())) {
          newestFlag = f;
        }
      } else if (f.path.endsWith('.stack')) {
        hasCrashStack = true;
      }
    }
    if (newestFlag != null) {
      flagState = (await newestFlag.readAsString()).trim();
      await newestFlag.delete(); // 读后即清（一次性证据）
    }
  } on FileSystemException {
    // 墓碑面不可用：空证据侧（裁定保守落非快死），调用方留痕。
  }
  return TombstoneEvidence(flagState: flagState, hasCrashStack: hasCrashStack);
}
