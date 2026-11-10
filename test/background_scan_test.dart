import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/background_scan.dart';
import 'package:ironpin/data/sources.dart';

void main() {
  test('background batches include enabled sources once in rotating order', () {
    final enabled = endpoints.take(37).toList();
    var cursor = 0;
    final seen = <String>[];
    while (seen.length < enabled.length) {
      final batch = selectScanBatch(enabled, cursor, size: 16);
      expect(batch.sources.length, lessThanOrEqualTo(16));
      seen.addAll(batch.sources
          .take(enabled.length - seen.length)
          .map((source) => source.id));
      cursor = batch.nextCursor;
    }
    expect(seen, enabled.map((source) => source.id).toList());
    expect(seen.toSet().length, enabled.length);
  });

  test('disabled sources are not introduced by batch selection', () {
    final enabled = [endpoints.first, endpoints.last];
    final batch = selectScanBatch(enabled, 1, size: 16);
    expect(batch.sources.map((source) => source.id), [
      endpoints.last.id,
      endpoints.first.id,
    ]);
    expect(batch.nextCursor, 1);
  });

  test('empty input and invalid batch size return no work', () {
    expect(selectScanBatch(const [], 0).sources, isEmpty);
    expect(selectScanBatch(endpoints.take(2).toList(), 0, size: 0).sources,
        isEmpty);
  });
}
