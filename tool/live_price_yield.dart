import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/sources.dart';

/// Measures what the real fetch+parse pipeline yields per source: total rows,
/// rows carrying a usable amount, and rows that only carry extracted text.
/// Network opt-in; not part of the offline suite.
void main() {
  test('live price yield per source', () async {
    final client = SourceClient(maxChannelPages: 2);
    final out = <Map<String, Object?>>[];
    final reachable = endpoints.where((e) =>
        e.url.contains('t.me') ||
        e.url.contains('ahanmelal.com') ||
        e.url.contains('asreahan.com'));
    var i = 0;
    Future<void> worker() async {
      while (i < reachable.length) {
        final e = reachable.elementAt(i++);
        try {
          final rows = await client.fetch(e);
          out.add({
            'id': e.id,
            'ok': true,
            'rows': rows.length,
            'priced': rows.where((q) => q.amount != null).length,
            'textOnly':
                rows.where((q) => q.amount == null && q.hasTextAmount).length,
          });
        } catch (err) {
          out.add({'id': e.id, 'ok': false, 'rows': 0, 'priced': 0, 'textOnly': 0,
            'error': err.toString().split('\n').first});
        }
      }
    }
    await Future.wait([worker(), worker(), worker(), worker()]);
    out.sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));
    final f = File(Platform.environment['OUT'] ?? '/tmp/live_yield.json');
    f.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    var rows = 0, priced = 0, text = 0, okc = 0;
    for (final r in out) {
      rows += r['rows'] as int;
      priced += r['priced'] as int;
      text += r['textOnly'] as int;
      if (r['ok'] == true) okc++;
    }
    // ignore: avoid_print
    print('YIELD sources=$okc/${out.length} rows=$rows priced=$priced textOnly=$text');
    client.close();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
