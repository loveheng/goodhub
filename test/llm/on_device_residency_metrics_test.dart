import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_residency_metrics.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// S-R0-b 回归锚（on-device-residency）：Piggyback 观测面——JSONL 账本整本
/// 原子写（KeyedWriteQueue）+ 滚动截半 + 事件旁路面失败不反噬主路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late OnDeviceResidencyMetrics metrics;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('residency-metrics-test');
    SharedPreferences.setMockInitialValues({});
    metrics = OnDeviceResidencyMetrics.forTest(() async => tmp);
    final f = File('${tmp.path}/residency_metrics.jsonl');
    if (f.existsSync()) f.deleteSync();
  });
  tearDown(() async => tmp.deleteSync(recursive: true));

  List<String> lines() =>
      const LineSplitter().convert(File('${tmp.path}/residency_metrics.jsonl').readAsStringSync());

  test('事件追加 → 每行合法 JSON，ts/event 字段齐备', () async {
    await metrics.event('load_ready', {'status': 0});
    await metrics.event('evicted', {'reason': 'ttl-elapsed(30000ms)'});
    final l = lines();
    expect(l.length, 2);
    final first = jsonDecode(l[0]) as Map<String, Object?>;
    expect(first['event'], 'load_ready');
    expect(first['ts'], isA<String>());
    expect((jsonDecode(l[1]) as Map)['reason'], 'ttl-elapsed(30000ms)');
  });

  test('滚动截半：超 _maxLines 后保留后半', () async {
    for (var i = 0; i < 530; i++) {
      await metrics.event('send', {'mode': 'device', 'i': i});
    }
    final l = lines();
    expect(l.length, lessThanOrEqualTo(512),
        reason: '滚动截半防账本膨胀（No Active Polling 纪律的落盘面）');
    expect((jsonDecode(l.last) as Map)['i'], 529, reason: '最新事件保留');
  });
}
