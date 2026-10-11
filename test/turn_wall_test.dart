import 'package:flutter_test/flutter_test.dart';

import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/core/turn_wall.dart';

void main() {
  group('TurnWall 步数墙（max_turns 死循环保险丝）', () {
    test('默认 10 步：第 10 步耗尽，第 11 步消耗即抛', () {
      final wall = TurnWall();
      for (var i = 0; i < 10; i++) {
        wall.consume();
      }
      expect(wall.exhausted, isTrue);
      expect(wall.used, 10);
      expect(wall.consume,
          throwsA(isA<TurnWallExceeded>()));
      // 抛后计数不漂移（熔断出排查卡片后任务已终止，不再消耗）
      expect(wall.used, 10);
    });

    test('可配置 maxTurns（architecture §2：10 为默认，可配）', () {
      final wall = TurnWall(maxTurns: 3);
      wall.consume();
      wall.consume();
      wall.consume();
      expect(wall.exhausted, isTrue);
      expect(wall.consume, throwsA(isA<TurnWallExceeded>()));
    });

    test('TurnWallExceeded 是 McpException（走统一错误契约）', () {
      expect(const TurnWallExceeded('x'), isA<McpException>());
    });
  });
}
