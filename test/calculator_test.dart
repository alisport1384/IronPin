import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/calculator.dart';

WeightResult calc(String shape, Map<String, double> v,
        {String unit = 'm',
        double q = 1,
        double density = 7850,
        double length = 6,
        double waste = 0}) =>
    SteelCalculator.calculate(
        shape: shape,
        values: v,
        density: density,
        inputUnit: unit,
        quantity: q,
        lengthPerPiece: length,
        wastePercent: waste);
void main() {
  group('Dimensional weight calculations', () {
    test('16mm x 12m round uses density, not mismatched units', () {
      expect(calc('round', {'d': 16}, q: 12).kg,
          closeTo(18.940033789962143, 0.00001));
    });
    test('1x2m sheet 2mm is 31.4kg', () {
      expect(calc('plate', {'b': 1000, 't': 2, 'coat': 0}, q: 2).kg, 31.4);
    });
    test('sheet surface-to-weight', () {
      expect(
          calc('plate', {'b': 1250, 't': 2, 'coat': 0}, unit: 'm2', q: 10).kg,
          closeTo(157, 1e-8));
    });
    test('coating total both sides in gsm is added once', () {
      expect(calc('plate', {'b': 1000, 't': 1, 'coat': 275}).kg,
          closeTo(8.125, 1e-8));
    });
    test('pipe uses OD and hollow interior', () {
      expect(calc('pipe', {'d': 48.3, 't': 2}, q: 6).kg,
          closeTo(math.pi * 2 * 46.3 * .00785 * 6, 1e-9));
    });
    test('RHS sharp corner approximation subtracts interior', () {
      expect(calc('rhs', {'h': 40, 'b': 40, 't': 2}, q: 6).kg,
          closeTo(14.3184, 1e-9));
    });
    test('angle removes overlapping square', () {
      expect(
          calc('angle', {'h': 50, 'b': 50, 't': 5}).kg, closeTo(3.72875, 1e-9));
    });
    test('channel with distinct web and flange', () {
      expect(calc('channel', {'h': 100, 'b': 50, 'tw': 6, 'tf': 8}).kg,
          closeTo(10.2364, 1e-9));
    });
    test('I beam ideal geometry without root radii', () {
      expect(calc('ibeam', {'h': 200, 'b': 100, 'tw': 5.6, 'tf': 8.5}).kg,
          closeTo((1700 + 183 * 5.6) * .00785, 1e-8));
    });
    test('tee geometry', () {
      expect(calc('tee', {'h': 50, 'b': 50, 'tw': 5, 'tf': 5}).kg,
          closeTo(475 * .00785, 1e-8));
    });
    test('rectangle bar', () {
      expect(calc('square', {'h': 40, 'b': 20}).kg, 6.28);
    });
    test('hex uses across flats, not across vertices', () {
      expect(calc('hex', {'s': 30}).kg,
          closeTo(math.sqrt(3) / 2 * 900 * .00785, 1e-8));
    });
    test('catalog IPE200 sample 12m', () {
      expect(calc('catalog', {'kgm': 22.4}, q: 12).kg, closeTo(268.8, 1e-8));
    });
    test('formed sheet uses unfolded width, not useful width', () {
      final r = calc(
          'formed', {'developed': 1250, 'useful': 1000, 't': .8, 'coat': 0},
          unit: 'm2', q: 10);
      expect(r.kg, 78.5);
      expect(r.area, 10);
    });
    test('mesh sums actual wire count two directions', () {
      final r = calc('mesh',
          {'width': 2, 'panelLength': 3, 'dx': 6, 'dy': 6, 'nx': 11, 'ny': 16},
          unit: 'piece', q: 2);
      expect(r.kg,
          closeTo(2 * (11 * 3 + 16 * 2) * math.pi * 36 / 4 * .00785, 1e-8));
      expect(r.area, 12);
    });
    test('rabitz requires declared piece mass', () {
      expect(
          calc('piece', {'kgpiece': .9, 'pieceArea': 1.44},
                  unit: 'piece', q: 10)
              .kg,
          9);
    });
    test('bulk from measured kilograms', () {
      expect(calc('bulk', {}, unit: 'kg', q: 1000).kg, 1000);
    });
    test('inverse round trip kg to metres', () {
      final r = calc('pipe', {'d': 48.3, 't': 2}, q: 6);
      expect(calc('pipe', {'d': 48.3, 't': 2}, unit: 'kg', q: r.kg).metres,
          closeTo(6, 1e-8));
    });
    test('piece input keeps equivalent count', () {
      expect(calc('catalog', {'kgm': 20}, unit: 'piece', q: 3, length: 12).kg,
          720);
    });
    test('density varies by actual material', () {
      expect(
          calc('plate', {'b': 1000, 't': 1, 'coat': 0}, density: 2700).kg, 2.7);
    });
    test('waste added once', () {
      expect(calc('bulk', {}, unit: 'kg', q: 100, waste: 5).kg, 105);
    });
  });
  group('Reject invalid geometry and inputs', () {
    test('zero and negative', () {
      for (final q in [0.0, -2.0, double.nan, double.infinity]) {
        expect(() => calc('round', {'d': 16}, q: q), throwsFormatException);
      }
    });
    test('pipe cannot be solid', () {
      expect(() => calc('pipe', {'d': 20, 't': 10}), throwsFormatException);
    });
    test('RHS collapsed interior', () {
      expect(() => calc('rhs', {'h': 20, 'b': 40, 't': 11}),
          throwsFormatException);
    });
    test('invalid angle', () {
      expect(() => calc('angle', {'h': 20, 'b': 20, 't': 20}),
          throwsFormatException);
    });
    test('invalid I web/flange', () {
      expect(() => calc('ibeam', {'h': 20, 'b': 20, 'tw': 2, 'tf': 11}),
          throwsFormatException);
    });
    test('useful width exceeds developed width', () {
      expect(
          () => calc('formed',
              {'developed': 1000, 'useful': 1250, 't': .8, 'coat': 0}),
          throwsFormatException);
    });
    test('wire count must be integer', () {
      expect(
          () => calc(
              'mesh',
              {
                'width': 2,
                'panelLength': 3,
                'dx': 6,
                'dy': 6,
                'nx': 11.5,
                'ny': 16
              },
              unit: 'piece'),
          throwsFormatException);
    });
    test('area cannot be inferred for bar', () {
      expect(() => calc('round', {'d': 16}, unit: 'm2'), throwsFormatException);
    });
    test('metres cannot be inferred for scrap', () {
      expect(() => calc('bulk', {}, unit: 'm'), throwsFormatException);
    });
  });
  group('Cost calculation', () {
    const r = WeightResult(100, 5, 2, 10, 20);
    test('kg + tax + final shipping and services', () {
      expect(
          SteelCalculator.cost(r, 'kg', 100000,
              taxPercent: 10, shipping: 200000, services: 50000),
          closeTo(11250000, .001));
    });
    test('ton price conversion', () {
      expect(SteelCalculator.cost(r, 'ton', 100000000), 10000000);
    });
    test('metres, pieces and area', () {
      expect(SteelCalculator.cost(r, 'm', 100), 500);
      expect(SteelCalculator.cost(r, 'piece', 100), 200);
      expect(SteelCalculator.cost(r, 'm2', 100), 1000);
    });
    test('negative price rejected', () {
      expect(() => SteelCalculator.cost(r, 'kg', -1), throwsFormatException);
    });
  });
}
