import 'market.dart' show latin;

/// Iranian phone evidence.
///
/// A phone number is a fact the seller wrote; the area code is the only part of
/// it that talks about place. Two rules keep this honest:
///
///  * a landline prefix locates a *fixed line*, never the seller's warehouse,
///    so it is stored as evidence («شاهد») and never overrides a city the text
///    states for itself;
///  * a mobile number (`09xx…`) carries no place at all — only an operator. The
///    app used to leave the city unknown for a post whose only contact was a
///    mobile, and the honest answer there is "unknown", not Isfahan.
class PhoneInfo {
  final String raw;

  /// `ثابت`, `موبایل` or `نامشخص`.
  final String kind;

  /// Two-digit landline area code without the leading zero (`031`).
  final String areaCode;

  /// City of the landline prefix, empty for a mobile.
  final String city;

  /// Province of the landline prefix, empty when unknown.
  final String province;

  /// Mobile operator name, empty for a landline or an unknown prefix.
  final String operator;

  /// Digits only, leading zero kept, `+98` folded to `0`.
  final String digits;

  /// A full number the country plan expects: 11 digits.
  ///
  /// A channel often writes only `03134155` (area code plus a short local
  /// number) because the rest is truncated by the platform; it is kept, marked
  /// incomplete, and used as weaker city evidence.
  final bool complete;

  const PhoneInfo({
    required this.raw,
    required this.kind,
    required this.digits,
    this.areaCode = '',
    this.city = '',
    this.province = '',
    this.operator = '',
    this.complete = false,
  });

  bool get hasCity => city.isNotEmpty;

  String get label => switch (kind) {
        'ثابت' => 'تلفن ثابت',
        'موبایل' => 'همراه',
        _ => 'شماره',
      };

  /// One line of evidence, written for the row's `details`.
  String get evidence {
    if (hasCity) {
      final suffix = complete ? '' : ' (شماره ناقص؛ فقط پیش‌شماره خوانده شد)';
      return '$label ${_pretty(digits)} → $city، استان $province$suffix';
    }
    if (operator.isNotEmpty) return '$label ${_pretty(digits)} → اپراتور $operator؛ شهر از شماره همراه تعیین نمی‌شود';
    return '$label ${_pretty(digits)} → پیش‌شماره ناشناخته؛ شهری استنتاج نشد';
  }

  static String _pretty(String d) => d.length == 11
      ? '${d.substring(0, 4)}-${d.substring(4)}'
      : d;
}

/// Landline area code → (city, province).
///
/// Only codes that the national plan documents are listed; a code that is not
/// here produces `نامشخص` instead of a guess.
const Map<String, List<String>> landlineAreas = {
  '021': ['تهران', 'تهران'],
  '026': ['کرج', 'البرز'],
  '025': ['قم', 'قم'],
  '031': ['اصفهان', 'اصفهان'],
  '032': ['قزوین', 'قزوین'],
  '034': ['کرمان', 'کرمان'],
  '035': ['یزد', 'یزد'],
  '038': ['شهرکرد', 'چهارمحال و بختیاری'],
  '041': ['تبریز', 'آذربایجان شرقی'],
  '044': ['ارومیه', 'آذربایجان غربی'],
  '045': ['اردبیل', 'اردبیل'],
  '051': ['مشهد', 'خراسان رضوی'],
  '054': ['زاهدان', 'سیستان و بلوچستان'],
  '056': ['بیرجند', 'خراسان جنوبی'],
  '058': ['بجنورد', 'خراسان شمالی'],
  '061': ['اهواز', 'خوزستان'],
  '066': ['خرم‌آباد', 'لرستان'],
  '071': ['شیراز', 'فارس'],
  '074': ['یاسوج', 'کهگیلویه و بویراحمد'],
  '076': ['بندرعباس', 'هرمزگان'],
  '077': ['بوشهر', 'بوشهر'],
  '081': ['همدان', 'همدان'],
  '083': ['کرمانشاه', 'کرمانشاه'],
  '084': ['ایلام', 'ایلام'],
  '086': ['اراک', 'مرکزی'],
  '087': ['سنندج', 'کردستان'],
  '011': ['ساری', 'مازندران'],
  '013': ['رشت', 'گیلان'],
  '017': ['گرگان', 'گلستان'],
  '023': ['سمنان', 'سمنان'],
  '024': ['زنجان', 'زنجان'],
};

/// Mobile prefixes, kept deliberately short: an unknown prefix stays unknown.
const Map<String, String> mobileOperators = {
  '0910': 'همراه اول', '0911': 'همراه اول', '0912': 'همراه اول',
  '0913': 'همراه اول', '0914': 'همراه اول', '0915': 'همراه اول',
  '0916': 'همراه اول', '0917': 'همراه اول', '0918': 'همراه اول',
  '0919': 'همراه اول', '0990': 'همراه اول', '0991': 'همراه اول',
  '0992': 'همراه اول', '0993': 'همراه اول', '0994': 'همراه اول',
  '0930': 'ایرانسل', '0933': 'ایرانسل', '0935': 'ایرانسل',
  '0936': 'ایرانسل', '0937': 'ایرانسل', '0938': 'ایرانسل',
  '0939': 'ایرانسل', '0901': 'ایرانسل', '0902': 'ایرانسل',
  '0903': 'ایرانسل', '0905': 'ایرانسل', '0941': 'رایتل',
  '0920': 'تالیا', '0921': 'تالیا', '0932': 'تالیا',
};

/// Cities the app can name from a written place, without the network.
const List<String> knownCities = [
  'تهران', 'کرج', 'قم', 'اصفهان', 'مشهد', 'تبریز', 'شیراز', 'اهواز', 'رشت',
  'ساری', 'کرمان', 'یزد', 'همدان', 'کرمانشاه', 'ارومیه', 'اردبیل', 'زنجان',
  'قزوین', 'سمنان', 'گرگان', 'زاهدان', 'بیرجند', 'بجنورد', 'خرم‌آباد',
  'یاسوج', 'بندرعباس', 'بوشهر', 'ایلام', 'اراک', 'سنندج', 'شهرکرد', 'کاشان',
  'نجف‌آباد', 'خمینی‌شهر', 'شاهین‌شهر', 'فولادشهر', 'زرین‌شهر', 'دلیجان',
  'ساوه', 'ملایر', 'بروجرد', 'دورود', 'قائم‌شهر', 'بابل', 'آمل', 'گرمسار',
  'اسلامشهر', 'شهریار', 'ورامین', 'پاکدشت', 'پرند', 'رباط‌کریم', 'بهشتی‌شهر',
  'آبادان', 'دزفول', 'ماهشهر', 'بندر ماهشهر', 'مسجد سلیمان', 'شوشتر', 'بهبهان',
  'شاهرود', 'سبزوار', 'نیشابور', 'تربت حیدریه', 'تربت جام', 'قوچان', 'کاشمر',
  'مراغه', 'مرند', 'میانه', 'خوی', 'سلماس', 'مهاباد', 'بوکان', 'سقز', 'پیرانشهر',
  'خلخال', 'پارس‌آباد', 'آستارا', 'بندر انزلی', 'لاهیجان', 'آستانه اشرفیه',
  'صومعه‌سرا', 'فومن', 'تالش', 'رودسر', 'چابهار', 'ایرانشهر', 'سراوان', 'زابل',
  'خاش', 'بم', 'رفسنجان', 'سیرجان', 'جیرفت', 'کهنوج', 'بافت', 'بردسیر', 'شهربابک',
  'میبد', 'اردکان', 'بافق', 'مهریز', 'تفت', 'ابرکوه', 'سپیدان', 'فسا', 'جهرم',
  'لار', 'مرودشت', 'کازرون', 'نی‌ریز', 'استهبان', 'داراب', 'اقلید', 'آباده',
  'گلپایگان', 'نایین', 'اردستان', 'سمیرم', 'فریدن', 'چادگان', 'خوانسار', 'دهاقان',
  'برخوار', 'شهرضا', 'دولت‌آباد', 'کوهپایه', 'ورزنه', 'مبارکه', 'مجلسی'
];

/// Latin spellings of Iranian cities, as Google Maps writes them.
///
/// A place link is usually `maps/place/Mashhad/` or `.../Isfahan,+Jey+Industrial/`;
/// without these aliases a Persian-only city list would answer «نامشخص» for the
/// most common kind of map link.
const Map<String, String> cityLatinNames = {
  'tehran': 'تهران', 'karaj': 'کرج', 'qom': 'قم', 'isfahan': 'اصفهان',
  'esfahan': 'اصفهان', 'mashhad': 'مشهد', 'tabriz': 'تبریز', 'shiraz': 'شیراز',
  'ahvaz': 'اهواز', 'rasht': 'رشت', 'sari': 'ساری', 'kerman': 'کرمان',
  'yazd': 'یزد', 'hamedan': 'همدان', 'kermanshah': 'کرمانشاه', 'urmia': 'ارومیه',
  'ardabil': 'اردبیل', 'zanjan': 'زنجان', 'qazvin': 'قزوین', 'semnan': 'سمنان',
  'gorgan': 'گرگان', 'zahedan': 'زاهدان', 'birjand': 'بیرجند',
  'bojnourd': 'بجنورد', 'khorramabad': 'خرم‌آباد', 'yasuj': 'یاسوج',
  'bandar abbas': 'بندرعباس', 'bushehr': 'بوشهر', 'ilam': 'ایلام',
  'arak': 'اراک', 'sanandaj': 'سنندج', 'shahrekord': 'شهرکرد',
  'kashan': 'کاشان', 'najafabad': 'نجف‌آباد', 'sirjan': 'سیرجان',
  'sabzevar': 'سبزوار', 'neyshabur': 'نیشابور', 'shahroud': 'شاهرود',
  'saveh': 'ساوه', 'malayer': 'ملایر', 'borujerd': 'بروجرد', 'amol': 'آمل',
  'babol': 'بابل', 'golpayegan': 'گلپایگان', 'mobarakeh': 'مبارکه',
  'fooladshahr': 'فولادشهر', 'abadan': 'آبادان', 'dezful': 'دزفول',
  'mahshahr': 'ماهشهر', 'bandar mahshahr': 'ماهشهر', 'ramsar': 'رامسر',
  'chabahar': 'چابهار', 'lamerd': 'لامرد', 'jask': 'جاسک'
};

const String _digits = r'[0-9۰-۹٠-٩]';

/// Normalises one phone-like token to digits with a leading zero.
String normalizeIranPhone(String raw) {
  var d = latin(raw).replaceAll(RegExp('[^0-9]'), '');
  if (d.startsWith('0098')) d = '0${d.substring(4)}';
  if (d.startsWith('98') && d.length >= 11) d = '0${d.substring(2)}';
  if (d.startsWith('9') && d.length == 10) d = '0$d';
  return d;
}

/// Classifies one number. Never invents a city for a mobile.
PhoneInfo classifyPhone(String raw) {
  final digits = normalizeIranPhone(raw);
  if (digits.startsWith('09') && digits.length >= 8) {
    final operator = mobileOperators[digits.substring(0, 4)] ?? '';
    return PhoneInfo(
        raw: raw,
        kind: 'موبایل',
        digits: digits,
        operator: operator,
        complete: digits.length == 11);
  }
  if (digits.startsWith('0') && digits.length == 11) {
    final area = digits.substring(0, 3);
    final place = landlineAreas[area];
    return PhoneInfo(
        raw: raw,
        kind: 'ثابت',
        digits: digits,
        areaCode: area,
        city: place?[0] ?? '',
        province: place?[1] ?? '',
        complete: true);
  }
  // A truncated landline (`03134155`) still carries its area code.
  if (digits.startsWith('0') && digits.length >= 8 && digits.length < 11) {
    final area = digits.substring(0, 3);
    final place = landlineAreas[area];
    return PhoneInfo(
        raw: raw,
        kind: 'ثابت',
        digits: digits,
        areaCode: area,
        city: place?[0] ?? '',
        province: place?[1] ?? '',
        complete: false);
  }
  return PhoneInfo(raw: raw, kind: 'نامشخص', digits: digits);
}

final RegExp _phoneToken = RegExp(
    '(?:\\+?98|0)$_digits{2}[\\s\\-‌]*$_digits{3,8}(?:[\\s\\-]?$_digits{2,4})?');

/// Every phone-like token of a text, de-duplicated, longest first.
List<PhoneInfo> phonesIn(String text) {
  final seen = <String>{};
  final out = <PhoneInfo>[];
  for (final m in _phoneToken.allMatches(latin(text))) {
    final digits = normalizeIranPhone(m[0]!);
    if (digits.length < 8 || !seen.add(digits)) continue;
    // Long order codes and bank/ID numbers are not contact numbers.
    if (digits.length > 13) continue;
    out.add(classifyPhone(digits));
  }
  return out;
}

/// City named by a landline in this text, or `''`.
///
/// The full 11-digit number wins over a truncated one, because a short token can
/// be a coincidence; both are reported with their basis by [landlineEvidence].
String landlineCityIn(String text) {
  final phones = phonesIn(text).where((p) => p.hasCity).toList();
  if (phones.isEmpty) return '';
  phones.sort((a, b) {
    if (a.complete != b.complete) return a.complete ? -1 : 1;
    return b.digits.length.compareTo(a.digits.length);
  });
  return phones.first.city;
}

/// Evidence lines for every phone that carries place information.
Map<String, String> phoneEvidence(String text) {
  final phones = phonesIn(text);
  if (phones.isEmpty) return const {};
  final out = <String, String>{};
  final withPlace = phones.where((p) => p.hasCity).toList();
  for (var i = 0; i < phones.length && i < 4; i++) {
    out['شماره ${i + 1}'] = phones[i].evidence;
  }
  if (withPlace.isNotEmpty) {
    out['مبنای شهر از شماره'] =
        'پیش‌شماره ${withPlace.first.areaCode} → ${withPlace.first.city}';
  }
  return out;
}
