// ignore_for_file: avoid_print
// Live check of short map links (run: dart run tool/live_maps.dart).
import 'package:http/http.dart' as http;
import 'package:ironpin/domain/maps_resolver.dart';

Future<void> main() async {
  final client = http.Client();
  final r = MapsResolver(client);
  for (final u in [
    'https://maps.app.goo.gl/FQD9k1QQRxAxjsyi7',
    'https://maps.app.goo.gl/MLxwTqBuKu16gqLJ9',
    'https://maps.app.goo.gl/S24HtPNnK2CwkxiD6',
    'https://nshn.ir/7bvowaGxdIEU',
    'https://maps.app.goo.gl/KyKq5e2b7vrHCjxb9',
  ]) {
    final sw = Stopwatch()..start();
    final res = await r.resolve(u);
    final info = res;
    print('$u\n  ${sw.elapsedMilliseconds}ms  city=${info?.city} basis=${info?.cityBasis} prov=${info?.province} coords=${info?.coordinates}\n  evidence=${MapsResolver.evidenceLine(res, u)}');
  }
  client.close();
}
