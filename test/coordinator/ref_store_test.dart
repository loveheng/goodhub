/// M2.5-T3 RefStore 内核单测：句柄解析 / 双介质存取 / TTL GC 联动删文件（C-3）/
/// 启动幂等清池 / Session 即焚。规格 = architecture.md §9。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/ref_store.dart';

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('refstore_test_');
  });

  tearDown(() async {
    await tmpDir.delete(recursive: true);
  });

  RefStore store({DateTime Function()? clock, Duration? ttl, Duration? gcInterval}) =>
      RefStore(
        cacheDir: tmpDir,
        clock: clock,
        ttl: ttl ?? const Duration(minutes: 30),
        gcInterval: gcInterval,
      );

  group('句柄格式与解析', () {
    test('put 返回 \$ref:<serverId>:<id>，parse 往返一致', () async {
      final s = store();
      final h = await s.put(serverId: 'goodshare', payload: 'hello');
      expect(h, startsWith(r'$ref:goodshare:'));
      final parsed = parseRefHandle(h);
      expect(parsed, isNotNull);
      expect(parsed!.serverId, 'goodshare');
    });

    test('非法句柄：非 \$ref 前缀 / 多段冒号 / 空段 → null（C-2 查无语义入口）', () {
      expect(parseRefHandle('goodshare:x'), isNull);
      expect(parseRefHandle(r'$ref:a:b:c'), isNull);
      expect(parseRefHandle(r'$ref::id'), isNull);
      expect(parseRefHandle(r'$ref:server:'), isNull);
    });
  });

  group('双介质', () {
    test('≤1MB 内存驻留：read 回原文，无落盘文件', () async {
      final s = store();
      final h = await s.put(serverId: 'goodshare', payload: '小载荷');
      expect(await s.read(h), '小载荷');
      expect(tmpDir.listSync().whereType<File>(), isEmpty);
      final entry = s.list().single;
      expect(entry.inlinePayload, '小载荷');
      expect(entry.filePath, isNull);
    });

    test('>1MB 落盘：文件存在、read 回读原文、sizeBytes 记录', () async {
      final s = store();
      final big = '字' * (1 << 20); // >1MB
      final h = await s.put(serverId: 'goodshare', payload: big);
      final entry = s.list().single;
      expect(entry.inlinePayload, isNull);
      expect(entry.filePath, isNotNull);
      expect(File(entry.filePath!).existsSync(), isTrue);
      expect(entry.sizeBytes, greaterThan(1 << 20));
      expect(await s.read(h), big);
    });

    test('preview：多行截取（≤maxLines 全保留）+ 空载荷占位', () async {
      final s = store();
      await s.put(serverId: 'goodshare', payload: '标题行\n第二行\n第三行');
      expect(s.list().single.preview, '标题行\n第二行\n第三行');
      await s.put(serverId: 'goodshare', payload: '   \n  ');
      expect(s.list().last.preview, '（空载荷）');
    });

    test('preview：超 maxChars 截断 + 省略号（授权卡摘要预算封顶）', () async {
      final s = store();
      await s.put(serverId: 'goodshare', payload: '长' * 400);
      final preview = s.list().single.preview;
      expect(preview.length, 301, reason: 'maxChars=300 + 省略号');
      expect(preview.endsWith('…'), isTrue);
    });
  });

  group('TTL 与 GC（C-3 联动删文件）', () {
    test('TTL 过期 → read 返回 null（查无语义，不抛）', () async {
      var now = DateTime(2026, 10, 11, 12);
      final s = store(clock: () => now, ttl: const Duration(minutes: 30));
      final h = await s.put(serverId: 'goodshare', payload: 'x');
      now = now.add(const Duration(minutes: 31));
      expect(await s.read(h), isNull);
    });

    test('gc：过期条目内存删 + tmp 文件同删；未过期条目不动', () async {
      var now = DateTime(2026, 10, 11, 12);
      final s = store(clock: () => now, ttl: const Duration(minutes: 30));
      final big = 'x' * (1 << 20 + 1);
      final oldHandle = await s.put(serverId: 'goodshare', payload: big);
      final oldEntry = s.list().single;
      now = now.add(const Duration(minutes: 10));
      await s.put(serverId: 'goodshare', payload: 'fresh');
      now = now.add(const Duration(minutes: 25)); // 旧条目 35min 过期，新条目 25min 未过期
      await s.gc();
      expect(s.length, 1);
      expect(await s.read(oldHandle), isNull);
      expect(File(oldEntry.filePath!).existsSync(), isFalse, reason: 'C-3：GC 必须联动删 tmp 文件');
      expect(File(oldEntry.filePath!).parent.listSync().whereType<File>(), isEmpty);
    });
  });

  group('Session 即焚与启动清扫', () {
    test('expireAll：内存清空 + 落盘文件全删（幂等）', () async {
      final s = store();
      await s.put(serverId: 'goodshare', payload: 'a' * (1 << 20 + 5));
      await s.put(serverId: 'goodshare', payload: 'b');
      await s.expireAll();
      expect(s.length, 0);
      expect(tmpDir.listSync().whereType<File>(), isEmpty);
      await s.expireAll(); // 幂等
      expect(s.length, 0);
    });

    test('sweepStartupOrphans：只删 ref_*.tmp，无关文件不碰', () async {
      final orphan = File('${tmpDir.path}/ref_deadbeef.tmp');
      await orphan.writeAsString('孤儿载荷');
      final unrelated = File('${tmpDir.path}/other_cache.bin');
      await unrelated.writeAsString('无关数据');
      final subdirFile = File('${tmpDir.path}/sub/ref_nested.tmp');
      await subdirFile.create(recursive: true);

      final s = store();
      await s.sweepStartupOrphans();

      expect(orphan.existsSync(), isFalse, reason: '进程死后的无主 tmp 必须清');
      expect(unrelated.existsSync(), isTrue, reason: '无关文件严禁误删');
      expect(subdirFile.existsSync(), isTrue, reason: '只扫本层，不递归');
    });

    test('read 句柄 serverId 不匹配 → null（句柄绑定来源 Server）', () async {
      final s = store();
      final h = await s.put(serverId: 'goodshare', payload: 'x');
      final forged = h.replaceFirst(r'$ref:goodshare:', r'$ref:evil:');
      expect(await s.read(forged), isNull, reason: '跨源伪造句柄按查无处理');
    });
  });
}
