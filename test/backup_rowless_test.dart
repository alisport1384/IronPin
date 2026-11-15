import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/backup.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 0.9.7 — بازیابی بکاپ باید بگوید فایل اصلاً چه دارد: یک خروجیِ بدون ردیف
/// (مثل فایل گوشیِ تازه) فقط تنظیمات برمی‌گرداند و این را صریحاً می‌گوید، و
/// بکاپ کامل واقعاً ردیف‌های قیمت را برمی‌گرداند — نه اینکه «۰» بی‌سروصدا
/// نشان دهد.
Quote quote(int n) => Quote(
    id: 'r$n',
    endpoint: 'catalog',
    seller: 'فروشنده',
    title: 'ورق سیاه 3',
    category: 'ورق',
    thickness: '3',
    grade: 'ST37',
    amount: 100.0 + n,
    unit: 'kg',
    currency: 'تومان',
    sourceDateRaw: DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 1))
        .toIso8601String(),
    fetchedAt: DateTime.now().toUtc(),
    sourceUrl: 'https://example.com/$n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('یک فایل بدون ردیف خودش را معرفی می‌کند؛ بکاپ کامل ردیف را برمی‌گرداند',
      () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-rowless');
    addTearDown(() => dir.delete(recursive: true));

    // An export of a phone that never fetched: settings only, zero rows.
    final empty = await MarketStore.open(
        dbPath: '${dir.path}/empty.db', factory: databaseFactoryFfi);
    await empty.setSetting('retentionMonth', '1405-08');
    final emptyFile = File('${dir.path}/empty.jsonl');
    await MarketBackup(empty).write(emptyFile);
    expect(await empty.historyCount(), 0);

    final target = await MarketStore.open(
        dbPath: '${dir.path}/target.db', factory: databaseFactoryFfi);
    final rowless = await MarketBackup(target).merge(emptyFile);
    expect(rowless.fileLatest, 0);
    expect(rowless.fileHistory, 0);
    expect(rowless.fileHasNoRows, isTrue,
        reason: 'the file declares itself rowless so the UI can say so');
    expect(rowless.latest, 0);
    expect(rowless.history, 0);
    expect(await target.setting('retentionMonth'), '1405-08',
        reason: 'settings still come back');

    // A full export declares its rows and restores them into a fresh phone.
    final full = await MarketStore.open(
        dbPath: '${dir.path}/full.db', factory: databaseFactoryFfi);
    await full.saveSnapshot('catalog', [quote(1), quote(2)]);
    final fullFile = File('${dir.path}/full.jsonl');
    await MarketBackup(full).write(fullFile);
    final restored = await MarketBackup(target).merge(fullFile);
    expect(restored.fileHasNoRows, isFalse);
    expect(restored.fileLatest, greaterThanOrEqualTo(2));
    expect(restored.latest, greaterThanOrEqualTo(2),
        reason: 'the rows of a full backup must actually arrive');
    expect(restored.history, greaterThanOrEqualTo(2));

    await empty.close();
    await full.close();
    await target.close();
  });
}
