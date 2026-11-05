import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ironpin/data/sources.dart';

String fixture(String name) =>
    File('test/fixtures/$name.html').readAsStringSync();
void main() {
  final fetched = DateTime.utc(2026, 11, 5, 8);
  test('observed Melal table matches headers and row date', () {
    final rows =
        SourceParser.parse(endpoints[0], fixture('melal_rebar'), fetched);
    expect(rows.length, 3);
    expect(rows.first.amount, 119091);
    expect(rows.first.unit, 'kg');
    expect(rows.first.sourceDateRaw, '1405/8/12');
    expect(rows.first.sellerCity, 'اصفهان');
    expect(rows.first.loadingCity, 'نامشخص');
    expect(rows.first.pieceKg, 10.65);
    expect(rows.first.id, contains('629d8edeca4abef341951d0b'));
  });
  test('parses observed sheet/profile/pipe/angle header variants', () {
    for (final pair in [
      ('melal_sheet', 'melal-sheet'),
      ('melal_profile', 'melal-profile'),
      ('melal_pipe', 'melal-pipe'),
      ('melal_angle', 'melal-angle')
    ]) {
      final e = endpoints.firstWhere((x) => x.id == pair.$2);
      final rows = SourceParser.parse(e, fixture(pair.$1), fetched);
      expect(rows.length, 2, reason: pair.$1);
      expect(rows.first.amount, greaterThan(0));
    }
  });
  test('mobile accordion metadata uses per-row unit, source date and stable ID',
      () {
    final rows =
        SourceParser.parse(endpoints.first, fixture('melal_mobile'), fetched);
    expect(rows.length, 2);
    expect(rows.first.amount, 119091);
    expect(rows.first.unit, 'kg');
    expect(rows.first.pieceKg, 10.65);
    expect(rows.first.sourceDateRaw, '1405/8/12');
    expect(rows.first.id, 'melal-rebar:629d8edeca4abef341951d0b');
    expect(rows[1].loading, 'انبار');
    expect(rows[1].id, isNot(rows.first.id));
  });
  test(
      'observed channel desktop and mobile use identical confirmed currency and product IDs',
      () {
    final e = endpoints.firstWhere((x) => x.id == 'melal-channel');
    final desktop =
        SourceParser.parse(e, fixture('melal_channel_desktop'), fetched);
    final mobile =
        SourceParser.parse(e, fixture('melal_channel_mobile'), fetched);
    expect(desktop.length, 2);
    expect(mobile.length, 2);
    expect(mobile.first.amount, 122000);
    expect(mobile.first.amount, desktop.first.amount);
    expect(mobile.first.id, desktop.first.id);
    expect(mobile.first.unit, 'kg');
    expect(mobile.first.details['مبنای ارز'], contains('دسکتاپ'));
  });
  test('mismatched visible and data-price2 is quarantined', () {
    final b = fixture('melal_rebar')
        .replaceFirst('data-price2="119091"', 'data-price2="1190910"');
    final row = SourceParser.parse(endpoints[0], b, fetched).first;
    expect(row.amount, null);
    expect(row.status, contains('اختلاف'));
  });
  test('contact price is never numeric zero', () {
    final b = fixture('melal_rebar').replaceAll('119,091', 'تماس بگیرید');
    final q = SourceParser.parse(endpoints[0], b, fetched).first;
    expect(q.amount, null);
  });
  test('layout change produces no invented rows', () {
    expect(
        SourceParser.parse(
            endpoints[0], '<h1>price today 120000</h1>', fetched),
        isEmpty);
  });
  test('suspended 200 is rejected', () {
    expect(
        () => SourceParser.parse(
            endpoints[0], '<title>Account Suspended</title>', fetched),
        throwsFormatException);
  });
  test('Asre real detail schema ignores unavailable historical prices', () {
    final e = endpoints.firstWhere((e) => e.id == 'asre-esfahan');
    final rows = SourceParser.parse(e, fixture('asre_detail'), fetched);
    expect(rows.length, 3);
    expect(rows[0].amount, null);
    expect(rows[2].amount, 128000);
    expect(rows[2].pieceKg, 15);
    expect(rows[2].lengthM, 12);
    expect(rows[2].sellerCity, 'تبریز');
    expect(rows[2].loadingCity, 'اصفهان');
    expect(rows[2].sourceDateRaw, '2026-11-04T09:45:03.836Z');
  });
  test('category minima do not become product offers', () {
    final e = endpoints.firstWhere((e) => e.id == 'asre-esfahan');
    expect(
        SourceParser.parse(
            e,
            '<script id="__NEXT_DATA__">{"props":{"pageProps":{"initialState":{"products":[{"price":100}]}}}}</script>',
            fetched),
        isEmpty);
  });
  test('telegram message keeps evidence without assuming unit', () {
    final e = endpoints.firstWhere((e) => e.parser == 'telegram');
    final rows = SourceParser.parse(e, fixture('telegram'), fetched);
    expect(rows, isNotEmpty);
    expect(rows.first.amount, null);
    expect(rows.first.unit, 'unknown');
    expect(rows.first.details['متن پیام'], isNotEmpty);
  });
  test('HTTP errors fail without a successful empty snapshot', () async {
    final client = SourceClient(
        client: MockClient((r) async => http.Response('Forbidden', 403)));
    await expectLater(client.fetch(endpoints.first), throwsFormatException);
    client.close();
  });
  test('HTTP 200 changed layout is reported as parser error', () async {
    final client = SourceClient(
        client: MockClient((r) async => http.Response('new layout', 200)));
    await expectLater(client.fetch(endpoints.first), throwsFormatException);
    client.close();
  });
}
