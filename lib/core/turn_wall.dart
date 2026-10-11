/// 步数墙：单任务 Agent Loop 硬限 max_turns（死循环保险丝，architecture §2，M1 提前落）。
/// 分工（coding-standards §2 规则 3）：步数墙管「逻辑无错但空转」，
/// 两步熔断管「同一工具连续报错」——互补不互替。
library;

import 'errors/mcp_error.dart';

class TurnWall {
  TurnWall({this.maxTurns = 10});

  /// 单任务硬限（可配），architecture §2：max_turns=10。
  final int maxTurns;

  int used = 0;

  bool get exhausted => used >= maxTurns;

  /// 每步（一次 LLM turn / 工具轮）开始时消耗；超限即抛，调用方熔断出排查卡片。
  void consume() {
    if (exhausted) {
      throw TurnWallExceeded(
          '步数墙已达上限（used=$used, max=$maxTurns）：熔断出排查卡片');
    }
    used++;
  }
}
