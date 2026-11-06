import 'dart:math' as math;

class CalcField {
  final String key, label;
  final double initial;
  const CalcField(this.key, this.label, this.initial);
}

class Shape {
  final String id, label, note;
  final List<CalcField> fields;
  const Shape(this.id, this.label, this.fields, this.note);
}

const shapes = [
  Shape(
      'round',
      'میلگرد / مفتول / گرد توپر',
      [CalcField('d', 'قطر (میلی‌متر)', 16)],
      'وزن هندسی اسمی؛ وزن باسکول/کارخانه مبنای خرید است.'),
  Shape(
      'plate',
      'ورق تخت / تسمه',
      [
        CalcField('b', 'عرض (میلی‌متر)', 1000),
        CalcField('t', 'ضخامت فلز پایه (میلی‌متر)', 2),
        CalcField(
            'coat', 'جرم کل پوشش دو رو (گرم بر مترمربع؛ صفر اگر نامعلوم)', 0)
      ],
      'پوشش فقط با جرم کل اعلام‌شده اضافه می‌شود؛ ضخامت پایه نباید پوشش را دوباره حساب کند.'),
  Shape(
      'pipe',
      'لوله / مقطع دایره توخالی',
      [
        CalcField('d', 'قطر خارجی واقعی (میلی‌متر؛ نه نمره اینچی)', 48.3),
        CalcField('t', 'ضخامت جداره (میلی‌متر)', 2)
      ],
      'برای رده ۲۰/۴۰/۸۰ ابتدا قطر خارجی و ضخامت واقعی از جدول سازنده وارد شود.'),
  Shape(
      'rhs',
      'قوطی مربع / مستطیل',
      [
        CalcField('h', 'ارتفاع خارجی (میلی‌متر)', 40),
        CalcField('b', 'عرض خارجی (میلی‌متر)', 40),
        CalcField('t', 'ضخامت (میلی‌متر)', 2)
      ],
      'تقریب گوشه تیز؛ شعاع گوشه و تلرانس ساخت در آن نیست. برای خرید وزن واحد معتبر را وارد کنید.'),
  Shape(
      'angle',
      'نبشی بال مساوی / نامساوی',
      [
        CalcField('h', 'بال اول (میلی‌متر)', 50),
        CalcField('b', 'بال دوم (میلی‌متر)', 50),
        CalcField('t', 'ضخامت (میلی‌متر)', 5)
      ],
      'تقریب هندسی با حذف هم‌پوشانی؛ شعاع ریشه و گردی بال‌ها لحاظ نشده است.'),
  Shape(
      'channel',
      'ناودانی — برآورد هندسی',
      [
        CalcField('h', 'ارتفاع کل (میلی‌متر)', 100),
        CalcField('b', 'عرض بال (میلی‌متر)', 50),
        CalcField('tw', 'ضخامت جان (میلی‌متر)', 6),
        CalcField('tf', 'ضخامت بال (میلی‌متر)', 8)
      ],
      'تقریب بال موازی؛ برای UPN بال شیب‌دار و خرید واقعی از وزن هر متر جدول سازنده استفاده کنید.'),
  Shape(
      'ibeam',
      'تیرآهن I / H — برآورد هندسی',
      [
        CalcField('h', 'ارتفاع کل (میلی‌متر)', 200),
        CalcField('b', 'عرض بال (میلی‌متر)', 100),
        CalcField('tw', 'ضخامت جان (میلی‌متر)', 5.6),
        CalcField('tf', 'ضخامت بال (میلی‌متر)', 8.5)
      ],
      'تقریب بدون شعاع ریشه؛ جایگزین جدول IPE/HEA/HEB یا محاسبه مقاومت سازه نیست.'),
  Shape(
      'tee',
      'سپری — برآورد هندسی',
      [
        CalcField('h', 'ارتفاع کل (میلی‌متر)', 50),
        CalcField('b', 'عرض بال (میلی‌متر)', 50),
        CalcField('tw', 'ضخامت جان (میلی‌متر)', 5),
        CalcField('tf', 'ضخامت بال (میلی‌متر)', 5)
      ],
      'تقریب بال و جان مستطیلی؛ وزن کاتالوگ اولویت دارد.'),
  Shape(
      'square',
      'چهارپهلو / بیلت مستطیلی',
      [
        CalcField('h', 'ارتفاع (میلی‌متر)', 40),
        CalcField('b', 'عرض (میلی‌متر)', 40)
      ],
      'وزن هندسی اسمی با چگالی انتخابی.'),
  Shape(
      'hex',
      'شش‌پر توپر',
      [CalcField('s', 'فاصله دو وجه موازی (میلی‌متر)', 30)],
      'اندازه ورودی فاصله دو وجه است؛ نه فاصله دو رأس.'),
  Shape(
      'catalog',
      'وزن معتبر هر متر — تیرآهن، هاش، Z/C و ...',
      [CalcField('kgm', 'وزن هر متر از کاتالوگ/باسکول (کیلوگرم)', 22.4)],
      'برای هر استاندارد و سایز، وزن همان ردیف را وارد کنید؛ ۲۲٫۴ صرفاً مثال IPE200 است.'),
  Shape(
      'formed',
      'ورق فرم‌دار / عرشه / کرکره',
      [
        CalcField('developed', 'عرض بازشده ورق پیش از فرم (میلی‌متر)', 1250),
        CalcField('useful', 'عرض مفید پوشش (میلی‌متر)', 1000),
        CalcField('t', 'ضخامت پایه (میلی‌متر)', 0.8),
        CalcField('coat', 'جرم کل پوشش (گرم بر مترمربع)', 0)
      ],
      'مساحت، سطح مفید پوشش است؛ وزن از عرض بازشده حساب می‌شود. اورلب طولی/پرت جدا وارد شود.'),
  Shape(
      'mesh',
      'مش جوشی مستطیلی',
      [
        CalcField('width', 'عرض پنل (متر)', 2),
        CalcField('panelLength', 'طول پنل (متر)', 3),
        CalcField('dx', 'قطر سیم‌های طولی (میلی‌متر)', 6),
        CalcField('dy', 'قطر سیم‌های عرضی (میلی‌متر)', 6),
        CalcField('nx', 'تعداد سیم طولی در عرض پنل', 11),
        CalcField('ny', 'تعداد سیم عرضی در طول پنل', 16)
      ],
      'تعداد سیم‌ها باید با لبه و چشمه واقعی پنل تطبیق داده شود؛ محاسبه با تعداد صریح سیم است.'),
  Shape(
      'piece',
      'رابیتس / توری / قطعه با وزن اعلامی',
      [
        CalcField('kgpiece', 'وزن هر برگ/رول/قطعه (کیلوگرم)', 0.9),
        CalcField(
            'pieceArea', 'مساحت مفید هر قطعه (مترمربع؛ اگر معلوم است)', 1.44)
      ],
      'از وزن واقعی سازنده استفاده شود؛ تعداد ستون رابیتس به تنهایی وزن را تعیین نمی‌کند.'),
  Shape('bulk', 'قراضه / کلاف / مواد اولیه وزن‌شده', [],
      'تبدیل متراژ بدون وزن واحد معتبر مجاز نیست؛ فقط وزن واقعی ثبت‌شده محاسبه می‌شود.'),
];

class WeightResult {
  final double kg, metres, pieces, area, kgPerMetre;
  const WeightResult(
      this.kg, this.metres, this.pieces, this.area, this.kgPerMetre);
}

class SteelCalculator {
  static WeightResult calculate(
      {required String shape,
      required Map<String, double> values,
      required double density,
      required String inputUnit,
      required double quantity,
      double lengthPerPiece = 6,
      double wastePercent = 0}) {
    if (!density.isFinite ||
        density <= 0 ||
        !quantity.isFinite ||
        quantity <= 0 ||
        !lengthPerPiece.isFinite ||
        lengthPerPiece <= 0 ||
        !wastePercent.isFinite ||
        wastePercent < 0 ||
        wastePercent > 100) {
      throw const FormatException(
          'چگالی، مقدار و طول باید مثبت و پرت بین صفر تا صد باشد.');
    }
    if (!['kg', 'm', 'piece', 'm2'].contains(inputUnit)) {
      throw const FormatException('واحد مقدار نامعتبر است.');
    }
    if (inputUnit == 'piece' && quantity != quantity.roundToDouble()) {
      throw const FormatException('تعداد قطعه ورودی باید صحیح باشد.');
    }
    final spec = shapes.firstWhere((s) => s.id == shape);
    for (final f in spec.fields) {
      final v = values[f.key];
      if (v == null || !v.isFinite || (f.key == 'coat' ? v < 0 : v <= 0)) {
        throw FormatException('${f.label}: مقدار معتبر لازم است.');
      }
    }
    double v(String key) => values[key]!;
    double areaMm = 0, kgm = 0, kgPiece = 0, unitArea = 0;
    switch (shape) {
      case 'round':
        areaMm = math.pi * v('d') * v('d') / 4;
        break;
      case 'plate':
        areaMm = v('b') * v('t');
        unitArea = v('b') / 1000;
        break;
      case 'pipe':
        if (2 * v('t') >= v('d')) {
          throw const FormatException(
              'دو برابر ضخامت باید کمتر از قطر خارجی باشد.');
        }
        areaMm = math.pi * v('t') * (v('d') - v('t'));
        break;
      case 'rhs':
        if (2 * v('t') >= math.min(v('b'), v('h'))) {
          throw const FormatException('ضخامت برای ابعاد قوطی نامعتبر است.');
        }
        areaMm =
            v('b') * v('h') - (v('b') - 2 * v('t')) * (v('h') - 2 * v('t'));
        break;
      case 'angle':
        if (v('t') >= math.min(v('h'), v('b'))) {
          throw const FormatException('ضخامت باید کمتر از طول بال باشد.');
        }
        areaMm = v('t') * (v('h') + v('b') - v('t'));
        break;
      case 'channel':
      case 'ibeam':
        if (2 * v('tf') >= v('h') || v('tw') >= v('b')) {
          throw const FormatException('ابعاد جان و بال نامعتبر است.');
        }
        areaMm = 2 * v('b') * v('tf') + (v('h') - 2 * v('tf')) * v('tw');
        break;
      case 'tee':
        if (v('tf') >= v('h') || v('tw') >= v('b')) {
          throw const FormatException('ابعاد سپری نامعتبر است.');
        }
        areaMm = v('b') * v('tf') + (v('h') - v('tf')) * v('tw');
        break;
      case 'square':
        areaMm = v('h') * v('b');
        break;
      case 'hex':
        areaMm = math.sqrt(3) / 2 * v('s') * v('s');
        break;
      case 'catalog':
        kgm = v('kgm');
        break;
      case 'formed':
        if (v('useful') > v('developed')) {
          throw const FormatException(
              'عرض مفید نباید از عرض بازشده بیشتر باشد.');
        }
        areaMm = v('developed') * v('t');
        unitArea = v('useful') / 1000;
        break;
      case 'mesh':
        if (v('nx') != v('nx').roundToDouble() ||
            v('ny') != v('ny').roundToDouble()) {
          throw const FormatException('تعداد سیم باید عدد صحیح باشد.');
        }
        kgPiece =
            (v('nx') * v('panelLength') * math.pi * v('dx') * v('dx') / 4 +
                    v('ny') * v('width') * math.pi * v('dy') * v('dy') / 4) *
                density /
                1e6;
        unitArea = v('width') * v('panelLength');
        break;
      case 'piece':
        kgPiece = v('kgpiece');
        unitArea = v('pieceArea');
        break;
      case 'bulk':
        if (inputUnit != 'kg') {
          throw const FormatException(
              'این کالا فقط با وزن واقعی قابل محاسبه است.');
        }
        break;
    }
    if (areaMm > 0) {
      kgm = areaMm * density / 1e6;
    }
    if ((shape == 'plate' || shape == 'formed') && v('coat') > 0) {
      kgm += (shape == 'plate' ? v('b') : v('developed')) /
          1000 *
          v('coat') /
          1000;
    }
    final discrete = shape == 'mesh' || shape == 'piece';
    double kg = 0, metres = 0, pieces = 0, area = 0;
    if (discrete) {
      if (inputUnit == 'm') {
        throw const FormatException(
            'برای این کالا تعداد، مساحت یا وزن انتخاب کنید.');
      }
      pieces = inputUnit == 'piece'
          ? quantity
          : inputUnit == 'm2'
              ? quantity / unitArea
              : quantity / kgPiece;
      kg = pieces * kgPiece;
      area = pieces * unitArea;
    } else if (shape == 'bulk') {
      kg = quantity;
    } else {
      if (kgm <= 0) {
        throw const FormatException('وزن واحد معتبر لازم است.');
      }
      if (inputUnit == 'm2' && unitArea <= 0) {
        throw const FormatException(
            'محاسبه مساحت برای این مقطع تعریف نشده است.');
      }
      metres = inputUnit == 'kg'
          ? quantity / kgm
          : inputUnit == 'piece'
              ? quantity * lengthPerPiece
              : inputUnit == 'm2'
                  ? quantity / unitArea
                  : quantity;
      kg = metres * kgm;
      pieces = metres / lengthPerPiece;
      area = metres * unitArea;
    }
    if (![kg, metres, pieces, area, kgm].every((v) => v.isFinite && v >= 0)) {
      throw const FormatException('مقادیر خارج از محدوده محاسبه است.');
    }
    final factor = 1 + wastePercent / 100;
    return WeightResult(
        kg * factor, metres * factor, pieces * factor, area * factor, kgm);
  }

  static double cost(WeightResult r, String priceUnit, double price,
      {double taxPercent = 0, double shipping = 0, double services = 0}) {
    if (!price.isFinite ||
        price < 0 ||
        !taxPercent.isFinite ||
        taxPercent < 0 ||
        taxPercent > 100 ||
        !shipping.isFinite ||
        shipping < 0 ||
        !services.isFinite ||
        services < 0) {
      throw const FormatException('قیمت و هزینه‌ها نامعتبر است.');
    }
    final amount = switch (priceUnit) {
      'kg' => r.kg,
      'ton' => r.kg / 1000,
      'm' => r.metres,
      'piece' => r.pieces,
      'm2' => r.area,
      _ => throw const FormatException('واحد قیمت نامعتبر است.')
    };
    if (amount <= 0) {
      throw const FormatException('تبدیل به واحد قیمت انتخابی ممکن نیست.');
    }
    final total = amount * price * (1 + taxPercent / 100) + shipping + services;
    if (!total.isFinite) {
      throw const FormatException('مبلغ خارج از محدوده محاسبه است.');
    }
    return total;
  }
}
