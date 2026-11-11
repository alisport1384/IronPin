import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ironpin/domain/maps_link.dart';
import 'package:ironpin/domain/maps_resolver.dart';

void main() {
  group('short map link resolution', () {
    test('a redirect to a long link gives coordinates and the city', () async {
      final resolver = MapsResolver(MockClient((request) async {
        expect(request.url.toString(), 'https://maps.app.goo.gl/abc123');
        return http.Response('', 302, headers: {
          'location':
              'https://www.google.com/maps/place/Mashhad/@36.2972,59.6067,15z'
        });
      }));
      final info = await resolver.resolve('https://maps.app.goo.gl/abc123');
      expect(info, isNotNull);
      expect(info!.lat, closeTo(36.2972, 1e-4));
      expect(info.city, 'مشهد');
      expect(info.evidence, contains('مختصات'));
    });

    test('a 200 page whose canonical address is the real maps URL is read',
        () async {
      final resolver = MapsResolver(MockClient((request) async =>
          http.Response(
              '<html><head><link rel="canonical" '
              'href="https://www.google.com/maps/place/Isfahan,+Jey/@32.6546,51.6680,13z">'
              '</head></html>',
              200)));
      final info = await resolver.resolve('https://maps.app.goo.gl/dead');
      expect(info, isNotNull);
      expect(info!.city, 'اصفهان');
    });

    test('a dead link is reported as unresolved, never guessed', () async {
      final resolver = MapsResolver(MockClient(
          (request) async => http.Response('Dynamic Link Not Found', 404)));
      final info = await resolver.resolve('https://maps.app.goo.gl/gone');
      expect(info, isNull);
      expect(
          MapsResolver.evidenceLine(null, 'https://maps.app.goo.gl/gone'),
          contains('باز نشد'));
    });

    test('offline leaves the link unresolved', () async {
      final resolver = MapsResolver(MockClient((request) async {
        throw const SocketExceptionStub();
      }));
      expect(await resolver.resolve('https://maps.app.goo.gl/offline'), isNull);
    });
  });

  test('only short links are queued for the network step', () {
    const text = 'آدرس مجموعه\nhttps://maps.app.goo.gl/KyKq\n'
        'https://www.google.com/maps/place/Mashhad/@36.2,59.6,12z';
    expect(shortMapsLinksIn(text), ['https://maps.app.goo.gl/KyKq']);
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
