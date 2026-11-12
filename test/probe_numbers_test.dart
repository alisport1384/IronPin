import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/text_engine.dart';
import 'package:ironpin/domain/market.dart';

Quote mk(String text) => TextPriceEngine.analyze(
      text: text,
      endpoint: 'e',
      seller: 'فروشنده',
      sourceUrl: 'https://t.me/s/x/1',
      fetchedAt: DateTime.now(),
      postId: '1',
    ).first;

void main() {
  test('probe number detection', () {
    void show(String label, String text) {
      final rows = TextPriceEngine.analyze(
          text: text,
          endpoint: 'e',
          seller: 'فروشنده',
          sourceUrl: 'https://t.me/s/x/1',
          fetchedAt: DateTime.now(),
          postId: '1');
      // ignore: avoid_print
      print('--- $label: ${rows.length} row(s)');
      for (final q in rows) {
        // ignore: avoid_print
        print('    amount=${q.amount} unit=${q.unit} cur=${q.currency} '
            'kg=${q.priceFor('kg')} ton=${q.priceFor('ton')} '
            'title=${q.title}');
        // ignore: avoid_print
        print('    panel: kg=${q.tomanFor('kg')} ton=${q.tomanFor('ton')} '
            'original=${q.tomanFor('original')}');
      }
    }

    show('single kg line', 'میلگرد ۱۶ ذوب آهن\nهر کیلو ۱۰۰ هزار تومان');
    show('two lines kg+ton',
        'میلگرد ۱۶ ذوب آهن\nکیلویی ۱۰۰ هزار تومان\nهر تن ۱۰ هزار تومان');
    show('one line both units',
        'میلگرد ۱۶: هر کیلو ۱۰۰ هزار تومان و هر تن ۱۰ هزار تومان');
    show('millions', 'میلگرد ۱۶ ذوب آهن\nهر تن ۱۰۰ میلیون تومان');
    show('separators', 'ورق سیاه ۳ میل\n۱۰.۰۰۰.۰۰۰ تومان هر تن');
    show('rial kg', 'میلگرد ۱۶\nکیلویی ۱,۰۰۰,۰۰۰ ریال');
    show('table-ish', 'میلگرد ۱۶ A3\nقیمت: ۱۰۰,۰۰۰ تومان / کیلو\nتن: ۱۰,۰۰۰');
    show('kilozir text', 'میلگرد ۱۶ اصفهان ۱۰۰ هزار تومان کیلو');
    expect(true, isTrue);
  });
}
