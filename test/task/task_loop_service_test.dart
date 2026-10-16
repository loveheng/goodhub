import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/inference_error.dart';
import 'package:goodhub/mcp/goodshare_task_api.dart';
import 'package:goodhub/task/task_inference.dart';
import 'package:goodhub/task/task_loop_service.dart';

class FakeApi implements GoodshareTaskApi {
  FakeApi({required this.claimResult});

  ClaimedTask claimResult;
  int closeCount = 0;
  int touchCount = 0;
  Object? touchError;
  final applied = <ApplyPayload>[];
  Object? applyResult = {'id': 'i1'};

  @override
  void close() {} // P1-D：幂等释放通道（计数未用于断言，占位满足契约）

  @override
  Future<ClaimedTask> claim() async => claimResult;

  @override
  Future<void> touch(String taskId) async {
    touchCount++;
    final e = touchError;
    // 仅周期心跳（第 2 次起）炸一次：首次 touch 是前置校验，炸了推理都不会开始
    if (e != null && touchCount >= 2) {
      touchError = null;
      throw e;
    }
  }

  @override
  Future<Object?> apply(ApplyPayload payload) async {
    applied.add(payload);
    return applyResult;
  }
}

class FakeInference implements TaskInference {
  final Completer<String> _gate = Completer<String>();
  Object? throwNext;
  final tasks = <ClaimedTask>[];

  void complete(String note) => _gate.complete(note);

  @override
  Future<String> infer(ClaimedTask task) async {
    tasks.add(task);
    final t = throwNext;
    if (t != null) {
      throwNext = null;
      throw t;
    }
    return _gate.future;
  }
}

void main() {
  ClaimedTask claimed() => const ClaimedTask(
        taskId: 't1',
        itemId: 'i1',
        taskAction: 'summarize',
        text: '内容',
        version: 3,
      );

  test('happy path：claim→touch→infer→apply(note+乐观锁)，事件序列完整', () async {
    final api = FakeApi(claimResult: claimed());
    final inf = FakeInference()..complete('笔记');
    final events = <TaskLoopEvent>[];
    final service = TaskLoopService(api: api, inference: inf)
      ..onEvent = events.add;
    final processed = await service.runOnce();
    expect(processed, isTrue);
    expect(api.applied.single.note, '笔记');
    expect(api.applied.single.expectedVersion, 3);
    expect(events.map((e) => e.runtimeType).toList(), [
      ClaimStarted,
      TaskClaimed,
      HeartbeatSent,
      Applied,
    ]);
  });

  test('idle：无 touch 无 infer，返回 false', () async {
    final api = FakeApi(claimResult: ClaimedTask.idle);
    final inf = FakeInference();
    final service = TaskLoopService(api: api, inference: inf);
    expect(await service.runOnce(), isFalse);
    expect(api.touchCount, 0);
    expect(inf.tasks, isEmpty);
  });

  test('推理期间周期心跳（契约 §3.3）', () async {
    final api = FakeApi(claimResult: claimed());
    final inf = FakeInference();
    final service = TaskLoopService(
      api: api,
      inference: inf,
      heartbeatInterval: const Duration(milliseconds: 10),
    );
    final done = service.runOnce();
    await Future<void>.delayed(const Duration(milliseconds: 45));
    inf.complete('笔记');
    await done;
    // 初始 1 次 + 推理窗口内 ≥2 次周期心跳
    expect(api.touchCount, greaterThanOrEqualTo(3));
  });

  test('心跳中途失败不中断推理（DEGRADE 留痕路径），apply 照常', () async {
    final api = FakeApi(claimResult: claimed())..touchError = Exception('网络抖动');
    final inf = FakeInference();
    final service = TaskLoopService(
      api: api,
      inference: inf,
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    final done = service.runOnce();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    inf.complete('笔记');
    expect(await done, isTrue);
    expect(api.applied.single.note, '笔记');
  });

  test('推理失败：LoopFailed 通告 + 异常上抛 + 不 apply', () async {
    final api = FakeApi(claimResult: claimed());
    final inf = FakeInference()..throwNext = const InferenceException('引擎全灭');
    final events = <TaskLoopEvent>[];
    final service = TaskLoopService(api: api, inference: inf)
      ..onEvent = events.add;
    await expectLater(service.runOnce(), throwsA(isA<InferenceException>()));
    expect(events.whereType<LoopFailed>(), isNotEmpty);
    expect(api.applied, isEmpty);
  });

  test('not_found 分支：apply 收尾不受推理影响', () async {
    final api = FakeApi(
      claimResult: const ClaimedTask(
        taskId: 't1',
        itemId: 'i1',
        taskAction: 'summarize',
        notFoundNote: '条目已删',
      ),
    );
    final inf = FakeInference();
    final events = <TaskLoopEvent>[];
    final service = TaskLoopService(api: api, inference: inf)
      ..onEvent = events.add;
    expect(await service.runOnce(), isTrue);
    expect(api.applied.single.note, contains('not_found 收尾'));
    expect(inf.tasks, isEmpty);
    expect(events.whereType<NotFoundClosed>(), isNotEmpty);
  });
}
