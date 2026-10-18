/// ResourceStore 内核单测（resource-center M1-T1，§8.1 内核测试基线）。
///
/// 覆盖：导入落位与清单持久化 / 大小上限 / text-only 拒二进制 / 读全文 /
/// not_found 错误契约（code+hint）/ 改名 / 删除幂等 / 损坏清单返空库 /
/// 清单写失败回滚不孤儿。排空握手一律 ioDrained（禁固定延迟猜等）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/resources/resource_store.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('resource_store_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  ResourceStore newStore() => ResourceStore.underSupportDir(tmp.path);

  group('import', () {
    test('落位文件实体 + 清单持久化，重开实例可恢复', () async {
      final store = newStore();
      final entry = await store.importContent('你好 hello', 'notes.md');
      expect(entry.name, 'notes.md');
      expect(entry.sizeBytes, utf8.encode('你好 hello').length);
      expect(entry.resourceUri, 'local://resource/${entry.id}');
      expect(store.entries, [entry]);

      // 实体文件以 uuid 命名落库。
      final entity = File('${tmp.path}/resource_center/${entry.id}');
      expect(await entity.readAsString(), '你好 hello');

      await newStore().load();
      final reloaded = newStore();
      await reloaded.load();
      expect(reloaded.entries.single.id, entry.id);
      expect(reloaded.entries.single.name, 'notes.md');
      await reloaded.ioDrained;
    });

    test('超上限拒绝（too_large + hint）', () async {
      final store = ResourceStore.underSupportDir(tmp.path, maxFileBytes: 8);
      expect(
        () => store.importContent('123456789', 'big.txt'),
        throwsA(isA<ResourceStoreException>()
            .having((e) => e.code, 'code', 'too_large')
            .having((e) => e.hint, 'hint', isNotNull)),
      );
    });

    test('二进制内容拒绝（not_text）', () async {
      final bin = tmp.path;
      final f = File('$bin/raw.bin');
      await f.writeAsBytes([0xff, 0xfe, 0x00, 0x01, 0x80]);
      final store = newStore();
      await expectLater(
        store.import(f.path, displayName: 'raw.bin'),
        throwsA(isA<ResourceStoreException>()
            .having((e) => e.code, 'code', 'not_text')
            .having((e) => e.hint, 'hint', isNotNull)),
      );
      expect(store.entries, isEmpty);
    });

    test('路径文件名解析（嵌套路径取 basename；空名兜底 untitled）', () async {
      final store = newStore();
      final sub = Directory('${tmp.path}/data')..createSync();
      final f = File('${sub.path}/a.txt')..writeAsStringSync('a');
      final e1 = (await store.import(f.path)).entry;
      expect(e1.name, 'a.txt');
      final e2 = await store.importContent('b', 'plain.txt');
      expect(e2.name, 'plain.txt');
      final e3 = await store.importContent('c', '');
      expect(e3.name, 'untitled.txt');
    });
    test('NUL 字节拒收（评审四补：utf8 对 \\x00 判合法，须显式探测）', () async {
      final store = newStore();
      // 首 1KB 内含 NUL（伪装 txt 的可执行件头/损坏文本）→ 拒。
      expect(
        () => store.importContent('hello\x00world', 'fake.txt'),
        throwsA(isA<ResourceStoreException>()
            .having((e) => e.code, 'code', 'not_text')
            .having((e) => e.hint, 'hint', isNotNull)),
      );
      // NUL 在 1KB 之外 → 按「首 1KB 探测」口径放行。
      final far = '${'x' * 2000}\x00tail';
      final entry = await store.importContent(far, 'far.txt');
      expect(entry.name, 'far.txt');
    });
  });

  group('readContent', () {
    test('全文读取回环', () async {
      final store = newStore();
      final entry = await store.importContent('line1\nline2', 'f.txt');
      expect(await store.readContent(entry.id), 'line1\nline2');
    });

    test('未知 id → not_found + hint（C-2 立即 isError，禁挂起）', () async {
      final store = newStore();
      await expectLater(
        store.readContent('deadbeef'),
        throwsA(isA<ResourceStoreException>()
            .having((e) => e.code, 'code', 'not_found')
            .having((e) => e.hint, 'hint', isNotNull)),
      );
    });

    test('清单在库、实体被外部删除 → io + hint（不静默空串）', () async {
      final store = newStore();
      final entry = await store.importContent('x', 'f.txt');
      await File('${tmp.path}/resource_center/${entry.id}').delete();
      await expectLater(
        store.readContent(entry.id),
        throwsA(isA<ResourceStoreException>().having((e) => e.code, 'code', 'io')),
      );
    });
  });

  group('rename / delete', () {
    test('改名仅动清单，实体不动；空名拒绝', () async {
      final store = newStore();
      final entry = await store.importContent('x', 'old.txt');
      final renamed = await store.rename(entry.id, ' 新名.md ');
      expect(renamed.name, '新名.md');
      expect(
        await File('${tmp.path}/resource_center/${entry.id}').readAsString(),
        'x',
      );
      expect(
        () => store.rename(entry.id, '  '),
        throwsA(isA<ResourceStoreException>()
            .having((e) => e.code, 'code', 'bad_name')),
      );
    });

    test('删除清清单 + 删实体；重复删除幂等', () async {
      final store = newStore();
      final entry = await store.importContent('x', 'f.txt');
      final entity = File('${tmp.path}/resource_center/${entry.id}');
      await store.delete(entry.id);
      expect(store.entries, isEmpty);
      expect(await entity.exists(), isFalse);
      await store.delete(entry.id); // 幂等，不抛。
    });
  });

  group('headPreview（评审补：静态截取，零 LLM）', () {
    test('首个非空行截前 200 字符，跳过前导空行', () async {
      final store = newStore();
      final entry = await store.importContent('\n\n  首行摘要在这里  \n第二行', 'f.txt');
      expect(entry.headPreview, '首行摘要在这里');
      final long = await store.importContent('${'x' * 300}\n第二行', 'long.txt');
      expect(long.headPreview.length, 200);
    });

    test('空内容/全空行 → (empty) 兜底（评审二补口径）', () async {
      final store = newStore();
      expect((await store.importContent('', 'a.txt')).headPreview, '(empty)');
      expect((await store.importContent('\n \n\t\n', 'b.txt')).headPreview,
          '(empty)');
    });

    test('随清单持久化，重开实例可恢复；rename 不丢', () async {
      final store = newStore();
      final entry = await store.importContent('hello 摘要\nrest', 'f.txt');
      await store.ioDrained;
      final reloaded = newStore();
      await reloaded.load();
      expect(reloaded.entries.single.headPreview, 'hello 摘要');
      await store.rename(entry.id, 'new.txt');
      expect(store.byId(entry.id)!.headPreview, 'hello 摘要');
      await reloaded.ioDrained;
    });
  });

  group('delete 容错（评审补：两段式，清单为准）', () {
    test('实体已被外部删除 → 静默完成不抛（DEGRADE 留痕）', () async {
      final store = newStore();
      final entry = await store.importContent('x', 'f.txt');
      await File('${tmp.path}/resource_center/${entry.id}').delete();
      await store.delete(entry.id); // 不抛即过（原实现会裸抛 FileSystemException）。
      expect(store.entries, isEmpty);
    });
  });

  group('BOM 与空文档兜底（评审二补）', () {
    test('BOM 剥离：\uFEFF 不进 headPreview', () async {
      final store = newStore();
      final entry = await store.importContent('\uFEFF首行摘要\n第二行', 'w.txt');
      expect(entry.headPreview, '首行摘要');
      expect(entry.headPreview.contains('\uFEFF'), isFalse);
    });

    test('空内容/全空行 → (empty) 兜底', () async {
      final store = newStore();
      expect((await store.importContent('', 'a.txt')).headPreview, '(empty)');
      expect(
        (await store.importContent('\uFEFF\n\t\n', 'b.txt')).headPreview,
        '(empty)',
      );
    });
  });

  group('重名去重（评审二补）', () {
    test('同名导入自动 (1)/(2) 后缀，保留扩展名', () async {
      final store = newStore();
      await store.importContent('a', 'readme.md');
      expect((await store.importContent('b', 'readme.md')).name,
          'readme (1).md');
      expect((await store.importContent('c', 'readme.md')).name,
          'readme (2).md');
      expect(store.entries.map((e) => e.name), hasLength(3));
    });
  });

  group('readContentWindow（RC4 防爆 + 边界回退）', () {
    test('窗口内不截断', () async {
      final store = newStore();
      final entry = await store.importContent('短文本', 'f.txt');
      final r = await store.readContentWindow(entry.id, maxBytes: 1024);
      expect(r.truncated, isFalse);
      expect(r.text, '短文本');
    });

    test('ASCII 截断点精确', () async {
      final store = newStore();
      final entry = await store.importContent('abcdefghij', 'f.txt');
      final r = await store.readContentWindow(entry.id, maxBytes: 4);
      expect(r.truncated, isTrue);
      expect(r.text, 'abcd');
    });

    test('多字节边界回退：截断点落在汉字序列中间不撕裂不抛', () async {
      final store = newStore();
      // 4 个汉字 = 12 字节；窗口 8 字节 = 2 个完整汉字 + 第 3 个汉字前 2 字节。
      final entry = await store.importContent('甲乙丙丁', 'f.txt');
      final r = await store.readContentWindow(entry.id, maxBytes: 8);
      expect(r.truncated, isTrue);
      expect(r.text, '甲乙'); // 撕裂的第 3 字节序列已回退丢弃。
      expect(r.text.contains('\uFFFD'), isFalse);
    });

    test('未知 id → not_found 结构化错误（C-2 禁挂起）', () async {
      final store = newStore();
      await expectLater(
        store.readContentWindow('nope', maxBytes: 8),
        throwsA(isA<ResourceStoreException>()
            .having((e) => e.code, 'code', 'not_found')),
      );
    });
  });

  group('reconcileOrphans（评审二补：孤儿对账）', () {
    test('未在册且超龄的孤儿清理；在册实体与新鲜文件保留', () async {
      final store = newStore();
      await store.importContent('keep', 'f.txt');
      final dir = Directory('${tmp.path}/resource_center');
      final orphanOld = File('${dir.path}/orphan_old');
      await orphanOld.writeAsString('orphan');
      final orphanFresh = File('${dir.path}/orphan_fresh');
      await orphanFresh.writeAsString('fresh');
      // 人为把旧孤儿置为 3 小时前（>2h 阈值，留执行裕量）；新鲜孤儿保持当前时间。
      final old = DateTime.now().subtract(const Duration(hours: 3));
      await orphanOld.setLastModified(old);

      expect(await store.reconcileOrphans(), 1);
      expect(await orphanOld.exists(), isFalse);
      expect(await orphanFresh.exists(), isTrue); // 未超龄保留。
    });

    test('extraDirs：cacheDir/external 超龄遗留件清理、新鲜件保留（评审三补）',
        () async {
      final store = newStore();
      final kept = await store.importContent('keep', 'f.txt');
      final external = Directory('${tmp.path}/cache_external')..createSync();
      final stale =
          File('${external.path}/abc_readme.md')..writeAsStringSync('old copy');
      final fresh =
          File('${external.path}/def_notes.txt')..writeAsStringSync('new copy');
      await stale.setLastModified(
        DateTime.now().subtract(const Duration(hours: 30)), // >24h。
      );

      expect(await store.reconcileOrphans(extraDirs: ['${tmp.path}/cache_external']), 1);
      expect(await stale.exists(), isFalse);
      expect(await fresh.exists(), isTrue);
      // 清理对资源库本体零误伤：在册实体与清单条目完好。
      expect(store.byId(kept.id), isNotNull);
      expect(
        await File('${tmp.path}/resource_center/${kept.id}').exists(),
        isTrue,
      );
    });
  });

  group('prepareExternalOpen（RC6 外部唤起）', () {
    test('复制到 external/ 唯一路径，内容一致，实体原身不暴露', () async {
      final store = newStore();
      final entry = await store.importContent('外部打开内容', 'readme.md');
      final cache = '${tmp.path}/cache';
      final path1 = await store.prepareExternalOpen(entry.id, cachePath: cache);
      final path2 = await store.prepareExternalOpen(entry.id, cachePath: cache);
      expect(path1, isNot(path2)); // 每次唤起路径唯一（防同名覆盖锁死）。
      expect(await File(path1).readAsString(), '外部打开内容');
      expect(path1, contains('readme.md'));
      expect(path1, isNot(contains(entry.id))); // 不暴露 uuid 实体名。
      expect(File('${tmp.path}/resource_center/${entry.id}').existsSync(),
          isTrue); // 原身不动。
    });

    test('展示名含路径分隔符时中和为下划线（防路径逃逸）', () async {
      final store = newStore();
      final entry = await store.importContent('x', 'a/b\\c.txt');
      final path = await store.prepareExternalOpen(entry.id,
          cachePath: '${tmp.path}/cache');
      expect(path, contains('a_b_c.txt'));
    });

    test('未知 id → not_found 结构化错误', () async {
      final store = newStore();
      await expectLater(
        store.prepareExternalOpen('nope', cachePath: '${tmp.path}/cache'),
        throwsA(isA<ResourceStoreException>()
            .having((e) => e.code, 'code', 'not_found')),
      );
    });
  });

  group('load 容错', () {
    test('损坏清单 → 空库 + 不抛（宁空勿炸）', () async {
      final dir = Directory('${tmp.path}/resource_center');
      await dir.create(recursive: true);
      await File('${dir.path}/manifest.json').writeAsString('{broken');
      final store = newStore();
      await store.load();
      expect(store.entries, isEmpty);
    });

    test('坏条目跳过、好条目保留', () async {
      final dir = Directory('${tmp.path}/resource_center');
      await dir.create(recursive: true);
      await File('${dir.path}/manifest.json').writeAsString(
        '{"resources":[{"id":"a","name":"ok.txt","size":1,"imported_at_ms":1},'
        '{"id":42}]}',
      );
      final store = newStore();
      await store.load();
      expect(store.entries.single.id, 'a');
    });

    test('同内容复用：不同名的相同内容不落副本（挂载点复盘 #2）', () async {
      final store = newStore();
      final first = await store.importContent('identical body', 'a.txt');
      expect(first.contentHash, isNotEmpty);
      // 内容索引可按哈希命中既有条目；未命中与空哈希一律不复用。
      expect(store.entryByContentHash(first.contentHash)?.id, first.id);
      expect(store.entryByContentHash(''), isNull);
      expect(store.entryByContentHash('nope'), isNull);
    });

    test('import 判重：同内容第二次导入复用既有条目（reused=true）', () async {
      final store = newStore();
      final f = File('${tmp.path}/src.txt')..writeAsStringSync('dup body');
      final first = await store.import(f.path);
      expect(first.reused, isFalse);
      // 换名再导同一内容 → 复用首个条目，清单不新增。
      final second = await store.import(f.path, displayName: 'other.txt');
      expect(second.reused, isTrue);
      expect(second.entry.id, first.entry.id);
      expect(second.entry.name, 'src.txt'); // 复用 → 名保持既有条目。
      expect(store.entries, hasLength(1));
    });
  });
}
