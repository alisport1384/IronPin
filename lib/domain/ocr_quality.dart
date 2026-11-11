// Pure Dart on purpose: this file is used by the app and by the offline
// pipeline tool (tool/photo_pipeline.dart), which runs without a Flutter engine.

/// A confidence number for engines that do not report one.
///
/// It is a statement about the *text*, not about the picture: how much of it
/// looks like Persian steel vocabulary, whether a price and a contact exist, and
/// how much noise is in it. Deliberately capped below 1 so a row can never claim
/// a perfect read.
class OcrQuality {
  static const _products = [
    'آهن', 'میلگرد', 'ورق', 'تیرآهن', 'تیر آهن', 'نبشی', 'ناودانی', 'لوله',
    'پروفیل', 'قوطی', 'سپری', 'تسمه', 'بست', 'بولت', 'مفتول', 'توری', 'کلاف',
    'گالوانیزه', 'روغنی', 'آجدار', 'فولاد', 'شمش', 'ضخامت', 'سایز', 'گرید'
  ];

  static double score(String text) {
    final t = text.trim();
    if (t.isEmpty) return 0;
    var score = 0.0;
    final useful = t
        .replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '')
        .runes
        .length;
    final persian = RegExp(r'[\u0600-\u06FF0-9]').allMatches(t).length;
    final total = t.replaceAll(RegExp(r'\s'), '').length;
    if (total > 0 && persian / total > 0.7) score += 0.3;
    if (useful > 40) score += 0.1;
    final hits = _products.where((p) => t.contains(p)).length;
    score += (hits >= 2 ? 0.3 : hits == 1 ? 0.15 : 0.0);
    if (RegExp(r'(?:تومان|ریال|تومن|ریال)').hasMatch(t)) score += 0.15;
    if (RegExp(r'\d[\d.,]{3,}').hasMatch(t)) score += 0.1;
    if (RegExp(r'0\d{2}[\s-]?\d{5,8}').hasMatch(t)) score += 0.05;
    if (RegExp(r'https?://|goo\.gl|maps\.app').hasMatch(t)) score += 0.05;
    return score > 0.95 ? 0.95 : score;
  }
}
