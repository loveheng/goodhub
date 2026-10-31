import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_session_gate.dart';
import 'package:goodhub/llm/on_device_session_ticket.dart';

/// 生成前会话闸门回归钉（M2 第一刀）。
///
/// 撤实现即红的六条：
///  1. 票据**未就绪必须装载后再生成**（事故一：主进程 `loadState` 说谎 ready
///     → 跳过装载 → `genie session not ready`）；
///  2. **未连接（bind 超时）交装载链路重连，绝不原地判死**（事故二：3s 未连接
///     此前直接 `StateError`，既不重试也不切云，还被读成「设备不支持」）；
///  3. 票据就绪**零额外装载**（闸门不能把每次生成都变成一次装载）；
///  4. 取票据失败**放行**（新增观测面不得抢先改变既有失败语义）；
///  5. 装载后**以权威票据复核**（不信本地态）；
///  6. 装载失败按既有口径分流：可自愈 → 切云，终态 → 显式报错不切云。
void main() {
  SessionTicket ticketWith(EngineStatus status) => SessionTicket(
        instanceId: 'inst-a',
        seq: 3,
        status: status,
        modelId: 'qwen3-5-2b-q4-0',
        runtime: 'qairt',
        issuedAtMs: 1,
      );

  test('票据未就绪 → 先装载再放行（事故一解药）', () async {
    var loadCalls = 0;
    var loaded = false;
    final logs = <String>[];
    final err = await ensureSessionReadyForGenerate(
      // 装载前 assetMissing、装载后 ready（模拟权威侧状态随装载推进）。
      fetch: () async =>
          loaded ? ticketWith(EngineStatus.ready) : ticketWith(EngineStatus.assetMissing),
      load: () async {
        loadCalls++;
        loaded = true;
        return EngineStatus.ready;
      },
      connected: true,
      log: logs.add,
    );
    expect(err, isNull);
    expect(loadCalls, 1);
    expect(logs.any((l) => l.contains('session-gate')), isTrue);
  });

  test('未连接 → 交装载链路重连，不判死（事故二解药）', () async {
    var loadCalls = 0;
    final logs = <String>[];
    final err = await ensureSessionReadyForGenerate(
      fetch: () async => null,
      load: () async {
        loadCalls++;
        return EngineStatus.ready;
      },
      connected: false,
      log: logs.add,
    );
    expect(err, isNull);
    expect(loadCalls, 1);
    expect(logs.any((l) => l.contains('未连接')), isTrue);
  });

  test('票据就绪（ready/busy）→ 零装载直接放行', () async {
    for (final s in [EngineStatus.ready, EngineStatus.busy]) {
      var loadCalls = 0;
      final err = await ensureSessionReadyForGenerate(
        fetch: () async => ticketWith(s),
        load: () async {
          loadCalls++;
          return EngineStatus.ready;
        },
        connected: true,
      );
      expect(err, isNull);
      expect(loadCalls, 0);
    }
  });

  test('取票据失败 → 未知态交装载链路（I2，M2 判定口径）', () async {
    var loadCalls = 0;
    final logs = <String>[];
    final err = await ensureSessionReadyForGenerate(
      fetch: () async => throw StateError('channel down'),
      load: () async {
        loadCalls++;
        return EngineStatus.ready;
      },
      connected: true,
      log: logs.add,
    );
    expect(err, isNull);
    expect(loadCalls, 1);
    expect(logs.any((l) => l.contains('ticket fetch failed')), isTrue);
  });

  test('装载后以权威票据复核：仍未就绪 → 切云信号', () async {
    final err = await ensureSessionReadyForGenerate(
      fetch: () async => ticketWith(EngineStatus.assetMissing),
      load: () async => EngineStatus.assetMissing,
      connected: true,
    );
    expect(err, isA<EngineDiedException>());
    expect(err.toString(), contains('装载后仍未就绪'));
  });

  test('装载失败分流：可自愈 → 切云信号；终态 → 显式报错', () async {
    final retryable = await ensureSessionReadyForGenerate(
      fetch: () async => ticketWith(EngineStatus.assetMissing),
      load: () async => throw const OnDeviceLoadException(
        '引擎进程中断（系统回收或崩溃），请重试',
        retryable: true,
      ),
      connected: true,
    );
    expect(retryable, isA<EngineDiedException>());

    final terminal = await ensureSessionReadyForGenerate(
      fetch: () async => ticketWith(EngineStatus.assetMissing),
      load: () async => throw const OnDeviceLoadException('端侧模型资产缺失或下载失败'),
      connected: true,
    );
    expect(terminal, isA<OnDeviceLoadException>());
  });
}
