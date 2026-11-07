import 'market.dart';
import 'product_text.dart';

/// Evidence-based fields shared by ingestion and the product-first range form.
/// Brand, seller, geography and tax never restrict product matching.
const productFields = <String, Map<String, String>>{
  'ورق': {
    'kind': 'نوع ورق',
    'thickness': 'ضخامت',
    'width': 'عرض',
    'length': 'طول',
    'grade': 'گرید',
    'material': 'جنس',
    'form': 'حالت عرضه',
    'dimensions': 'ابعاد',
    'dimUnit': 'واحد ابعاد'
  },
  'میلگرد': {
    'size': 'قطر اسمی',
    'grade': 'گرید / آنالیز',
    'kind': 'نوع میلگرد',
    'length': 'طول',
    'material': 'جنس',
    'dimUnit': 'واحد ابعاد'
  },
  'تیرآهن': {
    'grade': 'استاندارد مقطع',
    'size': 'سایز / ارتفاع اسمی',
    'length': 'طول',
    'material': 'جنس',
    'dimUnit': 'واحد ابعاد'
  },
  'نبشی': {
    'dimensions': 'دو بال',
    'thickness': 'ضخامت',
    'length': 'طول',
    'form': 'فابریک / پرسی',
    'material': 'جنس',
    'grade': 'گرید',
    'dimUnit': 'واحد ابعاد'
  },
  'ناودانی': {
    'size': 'ارتفاع اسمی',
    'thickness': 'ضخامت',
    'length': 'طول',
    'grade': 'استاندارد مقطع',
    'material': 'جنس',
    'dimUnit': 'واحد ابعاد'
  },
  'سپری': {
    'size': 'سایز',
    'thickness': 'ضخامت',
    'length': 'طول',
    'grade': 'گرید',
    'material': 'جنس',
    'dimUnit': 'واحد ابعاد'
  },
  'پروفیل': {
    'dimensions': 'ابعاد مقطع',
    'thickness': 'ضخامت',
    'kind': 'نوع مقطع',
    'length': 'طول',
    'material': 'جنس',
    'grade': 'گرید',
    'dimUnit': 'واحد ابعاد'
  },
  'لوله': {
    'size': 'قطر اسمی طبق منبع',
    'thickness': 'ضخامت',
    'kind': 'نوع لوله',
    'length': 'طول',
    'schedule': 'رده',
    'material': 'جنس',
    'grade': 'گرید',
    'dimUnit': 'واحد قطر / ابعاد'
  },
  'تسمه': {
    'width': 'عرض',
    'thickness': 'ضخامت',
    'length': 'طول',
    'material': 'جنس',
    'grade': 'گرید',
    'dimUnit': 'واحد ابعاد'
  },
  'چهارپهلو': {
    'size': 'ضلع',
    'length': 'طول',
    'material': 'جنس',
    'grade': 'گرید',
    'dimUnit': 'واحد ابعاد'
  },
  'مفتول': {
    'size': 'قطر سیم',
    'kind': 'نوع مفتول',
    'material': 'جنس',
    'grade': 'گرید',
    'dimUnit': 'واحد ابعاد'
  },
  'مش جوشی': {
    'size': 'قطر سیم',
    'mesh': 'چشمه',
    'dimensions': 'ابعاد برگ',
    'material': 'جنس',
    'dimUnit': 'واحد ابعاد'
  },
  'توری': {
    'mesh': 'چشمه',
    'size': 'قطر سیم',
    'dimensions': 'ابعاد',
    'kind': 'نوع توری',
    'material': 'جنس',
    'dimUnit': 'واحد ابعاد'
  },
  'رابیتس': {
    'columns': 'تعداد ستون',
    'mass': 'وزن اعلامی برگ',
    'dimensions': 'ابعاد',
    'material': 'جنس',
    'dimUnit': 'واحد ابعاد'
  },
  'شمش': {
    'grade': 'آنالیز',
    'dimensions': 'مقطع',
    'length': 'طول',
    'material': 'جنس',
    'dimUnit': 'واحد ابعاد'
  },
  'قراضه': {
    'kind': 'نوع / درجه قراضه',
    'material': 'جنس',
    'form': 'خرید / فروش'
  },
};
String specNorm(String s) => ProductText.normalize(s)
    .toLowerCase()
    .replaceAll(RegExp(r'\s*[×*x]\s*'), 'x')
    .trim();

class ProductFacts {
  final String family;
  final Map<String, String> values;
  const ProductFacts(this.family, this.values);
  factory ProductFacts.of(Quote q) {
    final family = ProductText.category(q.title).isNotEmpty
        ? ProductText.category(q.title)
        : ProductText.category(q.category);
    String field(String re) =>
        q.details.entries
            .where((e) => RegExp(re).hasMatch(latin(e.key)))
            .map((e) => latin(e.value))
            .firstOrNull ??
        '';
    final title = ProductText.normalize(q.title);
    final context = '$title ${field(r'^(?:نوع|پوشش|حالت|سطح مقطع)$')}';
    var kind = '';
    if (family == 'ورق') {
      kind = RegExp(r'گالوانیزه|روغنی|رنگی|آجدار|اسیدشویی|استیل|سیاه|سرد|گرم')
              .firstMatch(context)?[0] ??
          '';
      if (kind == 'گرم') kind = 'سیاه';
      if (kind == 'سرد') kind = 'روغنی';
    } else if (family == 'میلگرد') {
      kind = RegExp(r'آجدار|ساده|کلاف|بستر').firstMatch(context)?[0] ?? '';
    } else if (family == 'پروفیل') {
      kind = RegExp(r'مربع|مستطیل|مبلی|صنعتی|ستونی|درب|پنجره|[ZC](?![a-z])',
                  caseSensitive: false)
              .firstMatch(context)?[0] ??
          '';
    } else if (family == 'لوله') {
      kind =
          RegExp(r'مانیسمان|بدون درز|درزدار|داربستی|گازی|گالوانیزه|اسپیرال|جدار چاه|مبلی|صنعتی')
                  .firstMatch(context)?[0] ??
              '';
    } else {
      kind = field(r'^(?:نوع|درجه)$');
    }
    String capture(String label) =>
        RegExp('$label\\s*[:：]?\\s*(${ProductText.n})').firstMatch(title)?[1] ??
        '';
    final form =
        RegExp(r'فابریک|برشی|برش خورده|پرسی|رول|شیت|کلاف|شاخه|خرید|فروش')
                .firstMatch(context)?[0] ??
            '';
    final unit = field(r'واحد ابعاد|واحد قطر');
    final dimUnit = unit.isNotEmpty
        ? unit
        : RegExp(r'میلی\s*متر|میلیمتر|سانتی\s*متر|اینچ|\bmm\b|\bcm\b|\binch\b',
                    caseSensitive: false)
                .firstMatch(title)?[0] ??
            '';
    // Numeric values without declared units remain in source units. No silent
    // metres/mm equivalence, pipe nominal-to-OD, or three-number reordering.
    final values = <String, String>{
      'kind': kind,
      'size': q.sizeLabel,
      'thickness': q.thicknessLabel,
      'dimensions': q.dimensionsLabel,
      'grade': q.gradeLabel,
      // Legacy Quote defaults are not evidence for a selected material.
      'material': field(r'^(?:جنس|متریال)$').isNotEmpty
          ? field(r'^(?:جنس|متریال)$')
          : q.material != 'فولاد کربنی'
              ? q.material
              : RegExp(r'فولاد\s*کربنی|کربن\s*استیل').hasMatch(title)
                  ? 'فولاد کربنی'
                  : '',
      'width': field(r'^عرض(?:\s|\(|$)').isNotEmpty
          ? field(r'^عرض(?:\s|\(|$)')
          : capture('عرض'),
      'length': field(r'^طول(?:\s|\(|$)').isNotEmpty
          ? field(r'^طول(?:\s|\(|$)')
          : (capture('طول').isNotEmpty
              ? capture('طول')
              : q.lengthM?.toString() ?? ''),
      'form': form,
      'dimUnit': dimUnit,
      'schedule': field('رده').isNotEmpty ? field('رده') : capture('رده'),
      'mesh': field('چشمه').isNotEmpty ? field('چشمه') : capture('چشمه'),
      'columns': field('ستون').isNotEmpty
          ? field('ستون')
          : RegExp('(${ProductText.n})\\s*ستون').firstMatch(title)?[1] ?? '',
      'mass': q.pieceKg?.toString() ?? field('وزن'),
    };
    // Table dimensions can be the explicit section size (e.g. 40x40).
    if (values['dimensions']!.isEmpty &&
        ProductText.dimension.hasMatch(values['size']!)) {
      values['dimensions'] =
          ProductText.dimension.stringMatch(values['size']!)!;
    }
    return ProductFacts(family, values);
  }
  String get identity => [
        family,
        ...values.entries
            .where((e) => e.value.isNotEmpty)
            .map((e) => '${e.key}:${specNorm(e.value)}')
      ].join('|');
  bool matches(Map<String, String> constraints) {
    for (final e in constraints.entries) {
      if (e.value.trim().isEmpty) continue;
      final actual = values[e.key] ?? '';
      if (actual.isEmpty) return false;
      final wanted = specNorm(e.value), value = specNorm(actual);
      if (wanted == value) continue;
      if (e.key == 'dimensions') {
        if (wanted.split('x').length == 2 &&
            wanted.split('x').reversed.join('x') == value) continue;
        return false;
      }
      if (ProductText.measureMatches(wanted, value)) continue;
      return false;
    }
    return true;
  }
}
