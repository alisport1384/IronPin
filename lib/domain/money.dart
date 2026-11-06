/// Currency is never inferred from the magnitude of a price.
double? toman(double? amount, String currency) {
  if (amount == null || !amount.isFinite || amount < 0) return null;
  return switch (currency.trim()) {
    'تومان' => amount,
    'ریال' => amount / 10,
    _ => null,
  };
}

String faDigits(Object value) => value
    .toString()
    .replaceAllMapped(RegExp('[0-9]'), (m) => '۰۱۲۳۴۵۶۷۸۹'[int.parse(m[0]!)]);

String moneyWords(double value) {
  if (!value.isFinite || value < 0 || value > 9000000000000000) {
    return 'مبلغ خارج از محدوده';
  }
  const ones = [
    '',
    'یک',
    'دو',
    'سه',
    'چهار',
    'پنج',
    'شش',
    'هفت',
    'هشت',
    'نه',
    'ده',
    'یازده',
    'دوازده',
    'سیزده',
    'چهارده',
    'پانزده',
    'شانزده',
    'هفده',
    'هجده',
    'نوزده'
  ];
  const tens = [
    '',
    '',
    'بیست',
    'سی',
    'چهل',
    'پنجاه',
    'شصت',
    'هفتاد',
    'هشتاد',
    'نود'
  ];
  const hundreds = [
    '',
    'صد',
    'دویست',
    'سیصد',
    'چهارصد',
    'پانصد',
    'ششصد',
    'هفتصد',
    'هشتصد',
    'نهصد'
  ];
  const scales = ['', 'هزار', 'میلیون', 'میلیارد', 'تریلیون', 'کوادریلیون'];
  String chunk(int n) {
    final parts = <String>[];
    if (n >= 100) parts.add(hundreds[n ~/ 100]);
    n %= 100;
    if (n >= 20) {
      parts.add(tens[n ~/ 10]);
      n %= 10;
    }
    if (n > 0) parts.add(ones[n]);
    return parts.join(' و ');
  }

  // The textual amount corresponds to the displayed, rounded whole toman.
  var n = value.round();
  if (n == 0) return 'صفر تومان';
  final parts = <String>[];
  for (var i = 0; n > 0; i++, n ~/= 1000) {
    if (n % 1000 != 0) {
      parts.insert(0, '${chunk(n % 1000)}${i == 0 ? '' : ' ${scales[i]}'}');
    }
  }
  return '${parts.join(' و ')} تومان';
}
