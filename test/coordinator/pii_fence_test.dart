/// N7 PII 围栏内核单测（M2-T5a）：D3 基础四类遮蔽 + D2 同值同号 +
/// D5 反向还原（整段 + 流式切分）。
///
/// 校验向量均为确定性构造：身份证 11010519491231002X（校验位 X 合规）、
/// 银行卡 4111111111111111（Luhn 合规）；反例均经手算确认双校验皆败。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/pii_fence.dart';

void main() {
  group('遮蔽 · D3 基础四类', () {
    test('手机号命中，占位符类型标注编号', () async {
      final s = PiiRedactionSession();
      final out = await s.mask('完成后联系我 13812345678');
      expect(out.text, '完成后联系我 [手机号1]');
      expect(out.maskedCount, 1);
      expect(out.newEntries['13812345678'], '[手机号1]');
    });

    test('邮箱整体命中（含本地数字不被拆成手机号）', () async {
      final s = PiiRedactionSession();
      final out = await s.mask('邮箱 user13800138000@example.com');
      expect(out.text, '邮箱 [邮箱1]');
      expect(out.maskedCount, 1);
    });

    test('身份证校验位合规命中；校验位不合规且 Luhn 亦败则不遮', () async {
      final s = PiiRedactionSession();
      final ok = await s.mask('证件号 11010519491231002X');
      expect(ok.text, '证件号 [身份证1]');

      final bad = await s.mask('证件号 110105194912310021');
      expect(bad.text, '证件号 110105194912310021',
          reason: '末位改 1：身份证校验败（应为 X）且 Luhn 53%10≠0');
    });

    test('银行卡 Luhn 合规命中；不合规不遮', () async {
      final s = PiiRedactionSession();
      final ok = await s.mask('卡号 4111111111111111');
      expect(ok.text, '卡号 [银行卡1]');

      final bad = await s.mask('卡号 4111111111111112');
      expect(bad.text, '卡号 4111111111111112');
    });

    test('长数字串不截取假阳性（19 位订单号 Luhn 败、无内嵌手机号）', () async {
      final s = PiiRedactionSession();
      final out = await s.mask('订单号 1234567890123456789');
      expect(out.text, '订单号 1234567890123456789');
      expect(out.maskedCount, 0);
    });

    test('多类混排各自命中；同值跨文本同号（D2）', () async {
      final s = PiiRedactionSession();
      final first = await s.mask('张三 13812345678 a@b.com');
      expect(first.text, '张三 [手机号1] [邮箱1]');

      final second = await s.mask('李四 13812345678');
      expect(second.text, '李四 [手机号1]',
          reason: '同值复用既有占位符，无新增条目');
      expect(second.newEntries, isEmpty);

      final third = await s.mask('王五 13987654321');
      expect(third.text, '王五 [手机号2]', reason: '同类按首次出现顺序续号');
    });

    test('身份证优先于银行卡（同一 18 位跨度先到先得）', () async {
      final s = PiiRedactionSession();
      final out = await s.mask('11010519491231002X');
      expect(out.text, '[身份证1]');
    });
  });

  group('覆盖面 · T7 调参（分组书写归一化，2026-10-11）', () {
    test('手机号 3-4-4 分组（空格/连字符/混合）命中，值归一化', () async {
      final s = PiiRedactionSession();
      final a = await s.mask('电话 138 0013 8000');
      expect(a.text, '电话 [手机号1]');
      expect(a.newEntries['13800138000'], '[手机号1]',
          reason: '值取纯数字（3-4-4 标准分组）');
      expect(await s.mask('备用 138-0013-8000'), s.mappings.isNotEmpty ? '' : '');
      final b = await s.mask('再提 138-0013 8000 一次');
      expect(b.text, '再提 [手机号1] 一次',
          reason: '混合分隔符命中，与连续书写同值同号（D2）');
    });

    test('银行卡分组书写命中（Luhn 按剥隔后纯数字），与连续同号', () async {
      final s = PiiRedactionSession();
      final a = await s.mask('卡号 4111 1111 1111 1111');
      expect(a.text, '卡号 [银行卡1]');
      expect(a.newEntries['4111111111111111'], '[银行卡1]');

      final b = await s.mask('再刷卡 4111111111111111');
      expect(b.text, '再刷卡 [银行卡1]', reason: '分组与连续同值同号');
    });

    test('分组假阳性护栏：短数字组/日期/时间戳/换行竖排不遮', () async {
      final s = PiiRedactionSession();
      expect((await s.mask('日期 2026-10-11')).maskedCount, 0,
          reason: '8 位 <13 拒');
      expect((await s.mask('编号 0830-1234-5678')).maskedCount, 0,
          reason: '12 位 <13 拒');
      expect((await s.mask('时间戳 20261011123045')).maskedCount, 0,
          reason: '连续 14 位 Luhn 败');
      expect(
          (await s.mask('清单 1234\n5678\n9012\n3456')).maskedCount, 0,
          reason: '换行不作分隔符——竖排短数字列不误并');
    });

    test('分组手机号优先于银行卡组（11 位过不了卡长度门，语义归手机号）', () async {
      final s = PiiRedactionSession();
      final out = await s.mask('138 0013 8000');
      expect(out.text, '[手机号1]');
    });

    test('全角空格分组命中', () async {
      final s = PiiRedactionSession();
      final out = await s.mask('卡号 4111\u30001111\u30001111\u30001111');
      expect(out.text, '卡号 [银行卡1]');
    });
  });

  group('还原 · D5', () {
    test('整段往返：mask → restore == 原文', () async {
      final s = PiiRedactionSession();
      const origin = '张三 13812345678 a@b.com 卡 4111111111111111';
      final out = await s.mask(origin);
      expect(out.text, isNot(origin));
      expect(s.restore(out.text), origin);
    });

    test('未知占位符字面量不猜测还原', () async {
      final s = PiiRedactionSession();
      await s.mask('13812345678');
      expect(s.restore('模型幻觉 [手机号9] 保留'), '模型幻觉 [手机号9] 保留');
    });

    test('流式切分：占位符跨 delta 完整后整体还原', () async {
      final s = PiiRedactionSession();
      await s.mask('13812345678');
      final r = s.streamRestorer();
      expect(r.push('他的手机号是[手'), '他的手机号是',
          reason: '扣留只从 [ 起，其前 head 即时外发');
      expect(r.push('机号1'), '');
      expect(r.push(']，请查收。'), '13812345678，请查收。');
      expect(r.flush(), '');
    });

    test('流式：非占位符括号组按字面量外发', () {
      final s = PiiRedactionSession();
      final r = s.streamRestorer();
      expect(r.push('取数组[0]的值'), '取数组[0]的值');
    });

    test('流式：同前缀占位符取最长匹配（[邮箱1] vs [邮箱10]）', () async {
      final s = PiiRedactionSession();
      final emails = List.generate(11, (i) => 'u$i@example.com').join(' ');
      await s.mask(emails);
      expect(s.mappings.length, 11);

      final r = s.streamRestorer();
      expect(r.push('提到[邮箱1'), '提到');
      expect(r.push('0]和'), 'u9@example.com和',
          reason: '[邮箱10] → u9@example.com，不误还原为 [邮箱1]+0');
      expect(r.push('[邮箱11]'), 'u10@example.com');
    });

    test('流式 flush：缓冲内未完括号组按字面量收尾', () async {
      final s = PiiRedactionSession();
      await s.mask('13812345678');
      final r = s.streamRestorer();
      expect(r.push('尾缀[手'), '尾缀');
      expect(r.flush(), '[手');
    });
  });

  group('纯函数 redactSync', () {
    test('无命中返回原文零新增', () {
      final out = redactSync('普通文本无敏感信息', const {});
      expect(out.text, '普通文本无敏感信息');
      expect(out.newEntries, isEmpty);
      expect(out.maskedCount, 0);
    });

    test('既有映射传入时续号正确', () {
      final out = redactSync('再一个 18611112222',
          {'13812345678': '[手机号1]'});
      expect(out.text, '再一个 [手机号2]');
      expect(out.newEntries['18611112222'], '[手机号2]');
    });

    test('空文本短路（不进 Isolate 语义等价）', () {
      final out = redactSync('', const {});
      expect(out.text, '');
      expect(out.maskedCount, 0);
    });
  });
}
