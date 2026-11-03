import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_bench_archive.dart';
import 'package:goodhub/llm/on_device_bench_suite.dart';

/// 端侧适用性对照表采集套件单测（task-capability W2 · S11）。
///
/// **钉住的三件事**：
/// ① **质量判据是机械的**——同档判据对固定产出的结论恒定（可复现，不靠人看）；
/// ② **taxonomy 无缺类**——任务类型枚举每类至少一例（缺类 = 对照表缺行）；
/// ③ **采集行契约不漂移**——键集固定、坏行拒收（归档与消费面按此解析）。
void main() {
  group('质量判据（机械）', () {
    test('事实组全命中 = 合格', () {
      final g = gradeFactGroups('好的，王工在深圳负责维护。', const [
        ['王工'],
        ['深圳'],
      ]);
      expect(g.quality, OnDeviceBenchQuality.pass);
      expect(g.score, 1.0);
    });

    test('事实组部分命中 = 降级；零命中 = 不可用', () {
      final degraded = gradeFactGroups('王工今天休假。', const [
        ['王工'],
        ['深圳'],
      ]);
      expect(degraded.quality, OnDeviceBenchQuality.degraded);
      expect(degraded.score, 0.5);

      final failed = gradeFactGroups('与任务无关的闲聊。', const [
        ['王工'],
        ['深圳'],
      ]);
      expect(failed.quality, OnDeviceBenchQuality.fail);
      expect(failed.score, 0.0);
    });

    test('别名组内任一命中即算命中', () {
      final g = gradeFactGroups('手机充电时很烫。', const [
        ['发热', '烫', '温度'],
      ]);
      expect(g.quality, OnDeviceBenchQuality.pass);
    });

    test('事实全命中但超长 = 降级（啰嗦是可用性减项）', () {
      final g = gradeFactGroups('王工在深圳负责设备维护工作。' * 10, const [
        ['王工'],
        ['深圳'],
      ], maxChars: 60);
      expect(g.quality, OnDeviceBenchQuality.degraded);
      expect(g.note, contains('冗长'));
    });

    test('标签判据：精确输出 = 合格，夹带解释 = 降级，未命中 = 不可用', () {
      expect(
        gradeLabel('发热', const ['发热', '烫']).quality,
        OnDeviceBenchQuality.pass,
      );
      expect(
        gradeLabel('发热。', const ['发热', '烫']).quality,
        OnDeviceBenchQuality.pass,
      );
      expect(
        gradeLabel('发热，因为充电功率过高导致', const ['发热', '烫']).quality,
        OnDeviceBenchQuality.degraded,
      );
      expect(
        gradeLabel('屏幕', const ['发热', '烫']).quality,
        OnDeviceBenchQuality.fail,
      );
    });

    test('结构化判据：字段全对 = 合格，缺字段 = 降级，不可解析 = 不可用', () {
      const expected = {
        'name': ['林工'],
        'city': ['深圳'],
        'date': ['3月12日', '3 月 12 日', '3月12'],
      };
      expect(
        gradeJsonFields(
          '{"name":"林工","city":"深圳","date":"3月12日"}',
          expected,
        ).quality,
        OnDeviceBenchQuality.pass,
      );
      expect(
        gradeJsonFields('{"name":"林工"}', expected).quality,
        OnDeviceBenchQuality.degraded,
      );
      expect(
        gradeJsonFields('这不是 JSON', expected).quality,
        OnDeviceBenchQuality.fail,
      );
    });

    test('JSON 抽取容忍代码块包裹与前后解释', () {
      final obj = extractJsonObject('好的：\n```json\n{"a":1}\n```\n以上。');
      expect(obj, isNotNull);
      expect(obj!['a'], 1);
      expect(extractJsonObject('no json here'), isNull);
    });

    test('复读判据：复读历史轮 = 不可用（不是降级）', () {
      final g = gradeNoEcho(
        '好的，王工。您负责深圳地区的设备维护工作。',
        const [
          ['王工'],
          ['深圳'],
        ],
        const ['好的，王工。您负责深圳地区的设备维护工作。'],
      );
      expect(g.quality, OnDeviceBenchQuality.fail);
      expect(g.note, contains('复读'));
    });

    test('判据缺失（事实组为空）= 不可用（禁空判据假通过）', () {
      expect(
        gradeFactGroups('任意产出', const []).quality,
        OnDeviceBenchQuality.fail,
      );
    });
  });

  group('用例集不变量', () {
    test('taxonomy 每类至少一例（缺类 = 对照表缺行）', () {
      for (final type in OnDeviceBenchTaskType.values) {
        expect(
          OnDeviceBenchSuite.cases.where((c) => c.taskType == type).isNotEmpty,
          isTrue,
          reason: '任务类型 ${type.id} 无用例',
        );
      }
    });

    test('用例 id 唯一', () {
      final ids = OnDeviceBenchSuite.cases.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('末轮必须是 user（端侧 Runner 契约：末轮非 user 即拒）', () {
      for (final c in OnDeviceBenchSuite.cases) {
        expect(c.turns.last.role, 'user', reason: '用例 ${c.id} 末轮非 user');
      }
    });

    test('短/长两档都有用例（上下文压力维度不可缺）', () {
      for (final tier in OnDeviceBenchInputTier.values) {
        expect(
          OnDeviceBenchSuite.cases.where((c) => c.tier == tier).isNotEmpty,
          isTrue,
          reason: '体量档 ${tier.id} 无用例',
        );
      }
    });

    test('结构化产出任务存在（约束解码承载的取证面）', () {
      expect(
        OnDeviceBenchSuite.cases
            .where((c) => c.taskType.shape == OnDeviceBenchOutputShape.json)
            .isNotEmpty,
        isTrue,
      );
    });
  });

  group('采集行契约', () {
    OnDeviceBenchRow sample() => const OnDeviceBenchRow(
      model: 'gemma3-1b',
      ctx: 1280,
      segment: 'pass=auto',
      taskType: 'summarize',
      caseId: 'summarize-long',
      tier: 'long',
      promptChars: 1045,
      ttftMs: 1234,
      tpotMs: 12.5,
      tokPerSec: 80.0,
      chars: 96,
      quality: 'pass',
      score: 1.0,
      note: 'facts 3/3',
    );

    test('行 → JSON → 行 往返一致', () {
      final row = sample();
      final back = OnDeviceBenchRow.fromJson(row.toJson());
      expect(back, isNotNull);
      expect(back!.caseId, row.caseId);
      expect(back.ttftMs, row.ttftMs);
      expect(back.tokPerSec, row.tokPerSec);
      expect(back.quality, row.quality);
    });

    test('坏行拒收：缺键 / 类型错', () {
      final json = sample().toJson();
      expect(validateBenchRow(json), isNull);

      final missing = Map<String, dynamic>.from(json)..remove('ttftMs');
      expect(validateBenchRow(missing), contains('缺键'));

      final wrongType = Map<String, dynamic>.from(json)..['tokPerSec'] = '快';
      expect(validateBenchRow(wrongType), contains('类型错'));

      expect(OnDeviceBenchRow.fromJson(wrongType), isNull);
    });

    test('必需键集与行字段一一对应（键集漂移即红）', () {
      final json = sample().toJson();
      for (final key in kOnDeviceBenchRowKeys) {
        expect(json.containsKey(key), isTrue, reason: '缺键 $key');
      }
    });
  });

  group('适用档位判定（机械）', () {
    OnDeviceBenchRow row(String quality) => OnDeviceBenchRow(
      model: 'm',
      ctx: 0,
      segment: 'pass=auto',
      taskType: 'qa',
      caseId: 'c',
      tier: 'short',
      promptChars: 100,
      ttftMs: 1,
      tpotMs: 1,
      tokPerSec: 1,
      chars: 1,
      quality: quality,
      score: 1,
    );

    test('全合格 = 可用；合格 + 降级 = 降级可用', () {
      expect(benchApplicability([row('pass'), row('pass')]), '可用');
      expect(benchApplicability([row('pass'), row('degraded')]), '降级可用');
    });

    test('含失败 = 部分不可用；全失败 = 不可用', () {
      expect(benchApplicability([row('pass'), row('fail')]), '部分不可用');
      expect(benchApplicability([row('fail'), row('fail')]), '不可用');
    });

    test('空集合 = 未采集（禁空表假通过）', () {
      expect(benchApplicability([]), '未采集');
    });
  });

  group('归档渲染', () {
    test('输出逐用例表 + 分段汇总 + 任务类型总览（格式对齐既有基准归档）', () {
      final md = renderBenchArchive([
        const OnDeviceBenchRow(
          model: 'gemma3-1b',
          ctx: 1280,
          segment: 'pass=auto',
          taskType: 'summarize',
          caseId: 'summarize-long',
          tier: 'long',
          promptChars: 1045,
          ttftMs: 1234,
          tpotMs: 12.5,
          tokPerSec: 80.0,
          chars: 96,
          quality: 'pass',
          score: 1.0,
          note: 'facts 3/3',
        ),
        const OnDeviceBenchRow(
          model: 'gemma3-1b',
          ctx: 1280,
          segment: 'pass=auto',
          taskType: 'summarize',
          caseId: 'summarize-short',
          tier: 'short',
          promptChars: 180,
          ttftMs: 200,
          tpotMs: 10.0,
          tokPerSec: 100.0,
          chars: 50,
          quality: 'degraded',
          score: 0.5,
          note: 'facts 1/2',
        ),
      ], model: 'gemma3-1b');
      expect(md, contains('# 端侧适用性对照表'));
      expect(md, contains('## 逐用例'));
      expect(md, contains('## 分段汇总'));
      expect(md, contains('## 任务类型总览'));
      expect(md, contains('| summarize |'));
      expect(md, contains('TTFT 区间(ms)'));
      expect(md, contains('降级可用'));
      // 浮点格式收敛到一位小数（禁长精度噪声进归档表）
      expect(md, contains('80.0'));
      expect(md, isNot(contains('80.000000')));
    });
  });
}
