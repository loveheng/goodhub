/// 宿主侧任务消费循环单测（ai-app-split.md §3.12.2 宿主侧消费纪律）。
/// 覆盖：空拉终止 / 批量消化 / 达顶继续 / dirty 补跑 / 熔断 / 通道离线 /
/// 前台让路 / 生命周期解绑。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/inference_error.dart';
import 'package:goodhub/mcp/goodshare_task_api.dart';
import 'package:goodhub/task/task_consume_loop.dart';
import 'package:goodhub/task/task_inference.dart';
import 'package:goodhub/task/task_loop_service.dart';

/// 可控队列：按脚本依次返回 claimed / idle，并记录认领次数。
class _ScriptedApi implements GoodshareTaskApi {
  _ScriptedApi(this.script);

  final List<ClaimedTask> script;
  int claimCount = 0;
  final applied = <ApplyPayload>[];

  @override
  void close() {}

  @override
  Future<ClaimedTask> claim() async {
    final i = claimCount++;
    return i < script.length ? script[i] : ClaimedTask.idle;
  }

  @override
  Future<void> touch(String taskId) async {}

  @override
  Future<Object?> apply(ApplyPayload payload) async {
    applied.add(payload);
    return {'id': payload.itemId};
  }
}

/// 可控推理：默认直接产出；置 throwNext 则抛一次（毒丸场景）。
class _ScriptedInference implements TaskInference {
  Object? throwNext;

  /// 持续抛（毒丸/熔断场景：每条都失败）。
  Object? alwaysThrow;

  @override
  Future<String> infer(ClaimedTask task) async {
    final a = alwaysThrow;
    if (a != null) throw a;
    final t = throwNext;
    if (t != null) {
      throwNext = null;
      throw t;
    }
    return '产出';
  }
}

/// 闸门队列（F8 用）：claim 挂起等测试放行——精确控制「在途轮次」时机。
class _GatedApi extends _ScriptedApi {
  _GatedApi() : super(const []);

  final gates = <Completer<ClaimedTask>>[];

  @override
  Future<ClaimedTask> claim() {
    final g = Completer<ClaimedTask>();
    gates.add(g);
    return g.future;
  }

  void release(int i, ClaimedTask t) => gates[i].complete(t);
}

void main() {
  const idle = ClaimedTask.idle;
  ClaimedTask claimed(String id) => ClaimedTask(
        taskId: id,
        itemId: 'i-$id',
        taskAction: 'llm_summarize',
        text: '正文',
        version: 1,
      );

  /// 去抖窗口内推进（测试用零延迟构造，避免真等 300ms）。
  TaskConsumeLoop loop(
    TaskLoopService service, {
    bool Function()? isChannelAlive,
    bool Function()? isHostBusy,
    int maxPerRound = 5,
    Duration debounce = Duration.zero,
    void Function(TaskConsumeEvent)? onEvent,
  }) =>
      TaskConsumeLoop(
        service: service,
        isChannelAlive: isChannelAlive,
        isHostBusy: isHostBusy,
        maxPerRound: maxPerRound,
        debounce: debounce,
        busyRetryDelay: const Duration(milliseconds: 1),
        onEvent: onEvent,
      );

  test('空拉终止：队列 idle → 只 claim 一次，不做无谓轮询', () async {
    final api = _ScriptedApi([idle]);
    final service = TaskLoopService(
      api: api,
      inference: _ScriptedInference(),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    final l = loop(service);
    l.trigger();
    await pumpEventQueue();
    expect(api.claimCount, 1);
    l.dispose();
  });

  test('批量消化：连续任务全数处理至 idle（幂等自洽）', () async {
    final api = _ScriptedApi([claimed('t1'), claimed('t2'), claimed('t3')]);
    final service = TaskLoopService(
      api: api,
      inference: _ScriptedInference(),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    final l = loop(service);
    l.trigger();
    await pumpEventQueue();
    expect(api.claimCount, 4, reason: '3 条任务 + 1 次 idle 终止');
    expect(api.applied.length, 3);
    l.dispose();
  });

  test('达顶继续：单轮跑满上限 ≠ 队列空，须继续下一轮', () async {
    final api = _ScriptedApi([
      for (var i = 0; i < 7; i++) claimed('t$i'),
    ]);
    final service = TaskLoopService(
      api: api,
      inference: _ScriptedInference(),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    final l = loop(service, maxPerRound: 3);
    l.trigger();
    await pumpEventQueue();
    expect(api.claimCount, 8, reason: '7 条任务 + 1 次 idle；达顶后继续而非停在第 3 条');
    l.dispose();
  });

  test('单飞 dirty：运行期间再次 trigger 不并发，本轮结束后补跑', () async {
    final gate = Completer<String>();
    final api = _ScriptedApi([claimed('t1'), claimed('t2')]);
    final inf = _ScriptedInference();
    final service = TaskLoopService(
      api: api,
      inference: _LateInference(gate),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    final l = loop(service);
    l.trigger();
    // 等首条进入推理（单飞已建立）
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(l.isRunning, isTrue);
    l.trigger(); // 运行期间到达 → 只置 dirty
    gate.complete('产出');
    await pumpEventQueue();
    expect(api.claimCount, 4,
        reason: '2 条任务 + 本轮 idle 终止 + dirty 补跑轮的 idle 确认；无并发重入');
    l.dispose();
    expect(inf, isNotNull);
  });

  test('熔断：连续失败达阈即停本轮，不无限重试', () async {
    final api = _ScriptedApi([
      for (var i = 0; i < 5; i++) claimed('fail-$i'),
    ]);
    final inf = _ScriptedInference();
    final events = <TaskConsumeEvent>[];
    final service = TaskLoopService(
      api: api,
      inference: inf,
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    // 每条都抛（毒丸）：连续 3 次即熔断
    inf.alwaysThrow = StateError('boom');
    final l = loop(service, onEvent: events.add);
    l.trigger();
    await pumpEventQueue();
    expect(events.whereType<TaskConsumeTripped>(), isNotEmpty, reason: '达阈熔断');
    expect(api.claimCount, lessThan(5), reason: '熔断后不再继续认领');
    l.dispose();
  });

  test('毒丸防护：推理失败须回写 failed 终态（不留 processing 反复认领）', () async {
    final api = _ScriptedApi([claimed('poison')]);
    final inf = _ScriptedInference()..throwNext = InferenceException('推理炸了');
    final service = TaskLoopService(
      api: api,
      inference: inf,
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    final events = <TaskConsumeEvent>[];
    final l = loop(service, onEvent: events.add);
    l.trigger();
    await pumpEventQueue();
    expect(api.applied, isNotEmpty, reason: '失败必须 apply 收尾');
    expect(api.applied.single.note, contains('推理失败'));
    expect(api.applied.single.summaryMd, isNull, reason: 'note-only = failed 终态');
    l.dispose();
  });

  test('通道离线：触发被跳过，不发 IPC', () async {
    final api = _ScriptedApi([claimed('t1')]);
    final service = TaskLoopService(
      api: api,
      inference: _ScriptedInference(),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    final events = <TaskConsumeEvent>[];
    final l = loop(service, isChannelAlive: () => false, onEvent: events.add);
    l.trigger();
    await pumpEventQueue();
    expect(api.claimCount, 0);
    expect(events.whereType<TaskConsumeSkipped>(), isNotEmpty);
    l.dispose();
  });

  test('算力让路：前台忙碌时暂缓，idle 后自动重试', () async {
    final api = _ScriptedApi([claimed('t1')]);
    final service = TaskLoopService(
      api: api,
      inference: _ScriptedInference(),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    var busy = true;
    final events = <TaskConsumeEvent>[];
    final l = loop(service, isHostBusy: () => busy, onEvent: events.add);
    l.trigger();
    await pumpEventQueue();
    expect(api.claimCount, 0, reason: '前台忙 → 暂缓');
    expect(events.whereType<TaskConsumeDeferred>(), isNotEmpty);
    busy = false;
    await pumpEventQueue(times: 100); // 等待 busyRetryDelay(1ms) 重试
    expect(api.claimCount, greaterThan(0), reason: '前台 idle → 自动补跑');
    l.dispose();
  });

  test('生命周期解绑：dispose 后 trigger 无副作用，定时器清干净', () async {
    final api = _ScriptedApi([claimed('t1')]);
    final service = TaskLoopService(
      api: api,
      inference: _ScriptedInference(),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    final l = loop(service, debounce: const Duration(milliseconds: 1));
    l.dispose();
    l.trigger();
    await pumpEventQueue(times: 50);
    expect(api.claimCount, 0, reason: '解绑后不再消费');
    expect(l.isRunning, isFalse);
  });

  // F8（review-fix-2026-10）：dispose 只在 _pump 入口检查一次的原实现，do/while
  // 轮内无检查——dispose 后对已断通道继续 claim 直到失败熔断。闸门式 claim：
  // 第一条在途时 dispose，放行后不得出现第二次 claim。撤修复即红（gates 长 2）。
  test('F8：dispose 即停在途轮次——不再对已断通道 claim', () async {
    final api = _GatedApi();
    final service = TaskLoopService(
      api: api,
      inference: _ScriptedInference(),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    final l = loop(service);
    l.trigger();
    await pumpEventQueue();
    expect(api.gates.length, 1, reason: '前置：首轮 claim 在途（挂起等放行）');

    l.dispose(); // 在途时销毁
    api.release(0, claimed('t1'));
    await pumpEventQueue();
    await pumpEventQueue();
    expect(api.gates.length, 1,
        reason: 'F8：dispose 后不得再发起 claim（原实现会续 claim 到熔断）');
  });

  test('F8：轮内通道断开即停（单步间复查 isChannelAlive）', () async {
    final api = _GatedApi();
    final service = TaskLoopService(
      api: api,
      inference: _ScriptedInference(),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    var alive = true;
    final l = loop(service, isChannelAlive: () => alive);
    l.trigger();
    await pumpEventQueue();
    expect(api.gates.length, 1);

    alive = false; // 轮内断开
    api.release(0, claimed('t1'));
    await pumpEventQueue();
    await pumpEventQueue();
    expect(api.gates.length, 1,
        reason: 'F8：通道断开后不得继续 claim（原实现仅在 pump 启动时查一次）');
    l.dispose();
  });


}

/// 受控推理：等外部 complete 才返回（用于构造「运行中」窗口）。
class _LateInference implements TaskInference {
  _LateInference(this.gate);
  final Completer<String> gate;

  @override
  Future<String> infer(ClaimedTask task) async => gate.future;
}

/// 推进事件队列（Dart 单线程：微任务 + 定时器）。
Future<void> pumpEventQueue({int times = 20}) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
