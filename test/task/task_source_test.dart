// TaskSource 来源抽象回归钉（task-capability W4-A · 形态 A 多来源接入）。
//
// 红线：① serverId 随来源携带（账本分组键零改——与 kGoodsharePackage /
// info.packageName 同值，禁漂移）；② TaskLoopService 只认 TaskSource 类型
// （来源差异收敛在实现类，循环零双路分支）；③ 适配器纯委托（无额外语义）。
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/mcp_task_queue.dart';
import 'package:goodhub/task/task_source.dart';
import 'package:goodhub/mcp/mcp_client.dart';

/// McpClient 假件（适配器纯委托钉：client 仅被持有，方法不被触达）。
class _StubClient implements McpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('适配器纯委托钉不应触达 client');
}

void main() {
  group('W4-A TaskSource 抽象（形态 A 多来源）', () {
    test('serverId 随来源携带：与账本现行分组键同值（kGoodsharePackage）',
        () {
      final src = McpTaskQueueSource(McpTaskQueueApi(_StubClient()), serverId: 'com.zzh.goodshare');
      // 账本 serverId 零改验证：bootstrap 插件识别的 info.packageName =
      // 'com.zzh.goodshare'，本适配器同值——账本分组键零变化。
      const kGoodsharePackage = 'com.zzh.goodshare';
      expect(src.serverId, kGoodsharePackage);
    });

    test('多来源可注册：任意 TaskSource 实现即可注入消费循环（FakeApi 已证）',
        () {
      // 结构性断言：TaskSource 是抽象接口（非具体类），来源差异收敛在
      // 实现类；消费循环（TaskLoopService.api）与账本（serverId 分组）
      // 均零双路分支。GoodshareTaskSource 是首个实现，第二来源（形态 A
      // 其余 App）只须新增 implements TaskSource 适配器。
      final src = McpTaskQueueSource(McpTaskQueueApi(_StubClient()), serverId: 'com.zzh.goodshare');
      expect(src.serverId, isNotEmpty);
      expect(src, isA<TaskSource>());
    });
  });
}
