import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'app_logger.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import '../domain/market.dart';

class SourceEndpoint {
  final String id, name, url, category, parser, sellerCity;
  final bool defaultEnabled;
  const SourceEndpoint(
      this.id, this.name, this.url, this.category, this.parser, this.sellerCity,
      {this.defaultEnabled = true});
}

const endpoints = [
  SourceEndpoint(
      'melal-rebar',
      'آهن ملل • میلگرد',
      'https://ahanmelal.com/rebar/ribbed-rebar-price',
      'میلگرد',
      'melal',
      'اصفهان'),
  SourceEndpoint('melal-sheet', 'آهن ملل • ورق',
      'https://ahanmelal.com/steel-sheet', 'ورق', 'melal', 'اصفهان'),
  SourceEndpoint('melal-beam', 'آهن ملل • تیرآهن',
      'https://ahanmelal.com/beam/ipe-beam-price', 'تیرآهن', 'melal', 'اصفهان'),
  SourceEndpoint(
      'melal-angle',
      'آهن ملل • نبشی',
      'https://ahanmelal.com/steel-t-bars-studs-angles/steel-angle-price',
      'نبشی',
      'melal',
      'اصفهان'),
  SourceEndpoint(
      'melal-channel',
      'آهن ملل • ناودانی',
      'https://ahanmelal.com/steel-t-bars-studs-angles/steel-stud-price',
      'ناودانی',
      'melal',
      'اصفهان'),
  SourceEndpoint(
      'melal-profile',
      'آهن ملل • پروفیل',
      'https://ahanmelal.com/steel-profile-square-tube',
      'پروفیل',
      'melal',
      'اصفهان'),
  SourceEndpoint('melal-pipe', 'آهن ملل • لوله',
      'https://ahanmelal.com/metal-pipe', 'لوله', 'melal', 'اصفهان'),
  SourceEndpoint('asre-esfahan', 'عصرآهن • میلگرد ذوب آهن',
      'https://asreahan.com/rebar/esfahan-steel', 'میلگرد', 'asre', 'تبریز'),
  SourceEndpoint('asre-khorasan', 'عصرآهن • میلگرد نیشابور',
      'https://asreahan.com/rebar/khorasan-steel', 'میلگرد', 'asre', 'تبریز'),
  SourceEndpoint('telegram-mashhad', 'مشهد فولاد توس • فهرست تصویری',
      'https://t.me/s/mashhadfoolad1', 'عمومی', 'telegram', 'مشهد'),
  SourceEndpoint('telegram-ahanresan', 'آهن‌رسان مشهد • اعلام کانال',
      'https://t.me/s/ahanresan', 'عمومی', 'telegram', 'مشهد'),
  SourceEndpoint('telegram-bonyan', 'بنیان فولاد قوام حسینی • مشهد',
      'https://t.me/s/ahanalatehoseini', 'عمومی', 'telegram', 'مشهد',
      defaultEnabled: false),
  SourceEndpoint('telegram-ahanemashhad', 'آهن ویژه مشهد • توس ۷',
      'https://t.me/s/ahanemashhad', 'عمومی', 'telegram', 'مشهد'),
  SourceEndpoint('telegram-melal', 'تلگرام آهن ملل', 'https://t.me/s/ahanmelal',
      'عمومی', 'telegram', 'اصفهان',
      defaultEnabled: false),
  SourceEndpoint('telegram-mkz', 'تلگرام مرکزآهن • کانال اصلی',
      'https://t.me/s/markazeahan', 'عمومی', 'telegram', 'اصفهان',
      defaultEnabled: false),
  SourceEndpoint('telegram-mkz1', 'تلگرام مرکزآهن • میلگرد',
      'https://t.me/s/markazeahan1', 'میلگرد', 'telegram', 'اصفهان',
      defaultEnabled: false),
  SourceEndpoint('telegram-mkz2', 'تلگرام مرکزآهن • لوله/پروفیل',
      'https://t.me/s/markazeahan2', 'پروفیل', 'telegram', 'اصفهان',
      defaultEnabled: false),
  SourceEndpoint('telegram-mkz3', 'تلگرام مرکزآهن • مقاطع',
      'https://t.me/s/markazeahan3', 'نبشی', 'telegram', 'اصفهان',
      defaultEnabled: false),
  SourceEndpoint('telegram-mkz4', 'تلگرام مرکزآهن • ورق',
      'https://t.me/s/markazeahan4', 'ورق', 'telegram', 'اصفهان',
      defaultEnabled: false),
  SourceEndpoint('telegram-asre', 'تلگرام عصرآهن', 'https://t.me/s/asreahancom',
      'عمومی', 'telegram', 'تبریز',
      defaultEnabled: false),
  SourceEndpoint('telegram-ahanprice', 'تلگرام آهن پرایس • ahanprice',
      'https://t.me/s/ahanprice', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-milgerdprice', 'تلگرام آهن پرایس • MilgerdPrice',
      'https://t.me/s/MilgerdPrice', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-tirahanprice', 'تلگرام آهن پرایس • Tirahanprice',
      'https://t.me/s/Tirahanprice', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-varaghprice', 'تلگرام آهن پرایس • VaraghPrice',
      'https://t.me/s/VaraghPrice', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-l-uprice', 'تلگرام آهن پرایس • L_Uprice',
      'https://t.me/s/L_Uprice', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-profileprice', 'تلگرام آهن پرایس • ProfilePrice',
      'https://t.me/s/ProfilePrice', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-looleprice', 'تلگرام آهن پرایس • LoolePrice',
      'https://t.me/s/LoolePrice', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-modiranahan-z', 'تلگرام مدیران آهن • modiranahan_z',
      'https://t.me/s/modiranahan_z', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-ahan-online', 'تلگرام آهن آنلاین • ahan_online',
      'https://t.me/s/ahan_online', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-ao-thin-plate', 'تلگرام آهن آنلاین • AO_Thin_plate',
      'https://t.me/s/AO_Thin_plate', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-ao-pipe-box', 'تلگرام آهن آنلاین • Ao_pipe_box',
      'https://t.me/s/Ao_pipe_box', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-fooladsell', 'تلگرام فولادسل • Fooladsell',
      'https://t.me/s/Fooladsell', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-kavirsteel', 'تلگرام فولاد کویر • kavirsteel',
      'https://t.me/s/kavirsteel', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-asroon', 'تلگرام آهنگر — لینک مقاله • asroon',
      'https://t.me/s/asroon', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
  SourceEndpoint(
      'telegram-shekoftegroup',
      'تلگرام گروه صنعتی شکفته • shekoftegroup',
      'https://t.me/s/shekoftegroup',
      'عمومی',
      'telegram',
      'نامشخص',
      defaultEnabled: false),
  SourceEndpoint('telegram-novinpars', 'نوین پارس مشهد • تلگرام',
      'https://t.me/s/novinparsgroup', 'عمومی', 'telegram', 'مشهد',
      defaultEnabled: false),
  SourceEndpoint('telegram-hayperahan', 'هایپر آهن مشهد • تلگرام',
      'https://t.me/s/hayperahan', 'عمومی', 'telegram', 'مشهد',
      defaultEnabled: false),
  SourceEndpoint('telegram-radmanahan', 'رادمان آهن مشهد • تلگرام',
      'https://t.me/s/radmanahan', 'عمومی', 'telegram', 'مشهد',
      defaultEnabled: false),
  SourceEndpoint('telegram-fiahan', 'آهن‌آلات حیدری • تلگرام',
      'https://t.me/s/FIAHAN', 'عمومی', 'telegram', 'تهران',
      defaultEnabled: false),
  SourceEndpoint('telegram-ahan100', 'آهن صد • تلگرام',
      'https://t.me/s/atifoolad', 'عمومی', 'telegram', 'نامشخص',
      defaultEnabled: false),
];
// Office location is NOT the manufacturing or loading location.
const sellers = [
  {
    'name': 'نوین پارس',
    'city': 'مشهد',
    'phone': '05191002002',
    'url': 'https://novinpars.com/',
    'address': 'مشهد؛ نشانی دقیق پیش از مراجعه از مجموعه تأیید شود',
    'status':
        'سایت رسمی و کانال بله عمومی؛ نرخ‌های فاقد واحد/ارز کامل عددی نمی‌شوند'
  },
  {
    'name': 'رادمان آهن',
    'city': 'مشهد',
    'phone': '05137651478',
    'url': 'https://radmanahan.ir/contact-us/',
    'address': 'مشهد، بین توس۳ و۵',
    'status': 'نشانی/شماره و شناسه ایتا و روبیکا از صفحه تماس رسمی مشاهده شد'
  },
  {
    'name': 'هایپر آهن',
    'city': 'مشهد',
    'phone': '05136909700',
    'url': 'https://eitaa.com/hayperahan',
    'address': 'مشهد، طرحچی۲۵',
    'status':
        'خوداظهاری کانال عمومی؛ نمونه پست مشاهده‌شده۱۴۰۴ قدیمی است؛ نرخ روز فرض نشود'
  },
  {
    'name': 'آهن خوش‌کام',
    'city': 'مشهد',
    'phone': '05136945542',
    'url': 'https://khoshkamiron.ir/product/میلگرد/',
    'address': 'مشهد، نبش کشاورز۵/۱۴',
    'status':
        'اطلاعات نمایه‌شده صفحه مجموعه؛ دریافت مستقیم محیط ناموفق و تازگی مستقل تأیید نشد'
  },
  {
    'name': 'آهن رسان',
    'city': 'مشهد',
    'phone': '05131916',
    'url': 'https://ahanresan.com/contact/',
    'address': 'بلوار جانباز، مجتمع نیکا، طبقه ۱-',
    'status':
        'نشانی از سایت؛ اتصال اعلام کانال فعال است، قیمت فاقد واحد صریح رتبه‌بندی نمی‌شود'
  },
  {
    'name': 'مشهد فولاد توس',
    'city': 'مشهد',
    'phone': '05131670',
    'url': 'https://mashhadfoolad.com/telegram-steel-price/',
    'address': 'مشهد؛ نشانی دقیق دفتر را پیش از مراجعه از فروشنده تأیید کنید',
    'status':
        'کانال رسمی معرفی‌شده در سایت؛ لیست‌های مشاهده‌شده تصویری‌اند و به نرخ عددی تبدیل نمی‌شوند'
  },
  {
    'name': 'تیک آهن',
    'city': 'مشهد',
    'phone': '05136916425',
    'url': 'https://tikahan.com/تماس-با-ما/',
    'address':
        'خین عرب، طرحچی ۷، چهارراه اول سمت چپ، طرحچی ۷/۲، انبار دوم سمت راست، درب آبی',
    'status':
        'نشانی از صفحه تماس؛ لینک تلگرام صفحه با متن آن متفاوت است، رسمی بودن کانال احراز نشد'
  },
  {
    'name': 'بنیان فولاد قوام حسینی',
    'city': 'مشهد',
    'phone': '0513636',
    'url': 'https://ahan.co/market-analysis/',
    'address': 'بلوار طرحچی؛ شماره دقیق انبار پیش از مراجعه تأیید شود',
    'status':
        'دفتر مشهد و کانال ahanalatehoseini در سایت معرفی شده؛ دریافت قیمت عددی تضمین نمی‌شود'
  },
  {
    'name': 'آهن‌آلات مهران — آهن ویژه مشهد',
    'city': 'مشهد',
    'phone': '05137655450',
    'url': 'https://t.me/s/ahanemashhad',
    'address': 'بلوار توس، نبش توس ۷',
    'status': 'نشانی خوداظهاری در کانال عمومی؛ لیست تصویری و خارج مقایسه عددی'
  },
  {
    'name': 'گروه شکفته (تولیدکننده)',
    'city': 'نامشخص',
    'phone': '',
    'url': 'https://www.shekofte.com/لیست-قیمت',
    'address': 'محصولات مشهد و یزد؛ نشانی دفتر فروش نیازمند تایید',
    'status':
        'مرجع رسمی محصول؛ شهر این مدخل مربوط به تولید مشهد است، نه دفتر احرازنشده'
  },
  {
    'name': 'آهن ملل',
    'city': 'اصفهان',
    'phone': '03135020',
    'url': 'https://ahanmelal.com/',
    'address':
        'خیابان مطهری، حد فاصل پل آذر و پل فلزی، جنب مسجد انقلاب، ساختمان گلدیران، طبقه ۲ واحد ۳',
    'status': 'اتصال جدول قیمت؛ شهر دفتر از پانوشت سایت'
  },
  {
    'name': 'عصرآهن',
    'city': 'تبریز',
    'phone': '04133250280',
    'url': 'https://asreahan.com/contact-us',
    'address': 'خیابان امام، فلکه دانشگاه، برج بلور، طبقه ۶ واحد B',
    'status': 'اتصال جدول میلگرد؛ شهر دفتر از صفحه تماس'
  },
];
String knownCity(String text) {
  final s = latin(text);
  // Longest matching city first. No inference from telephone area code or a brand.
  for (final c in [
    'بوئین زهرا',
    'شهرکرد',
    'نیشابور',
    'اصفهان',
    'مشهد',
    'تهران',
    'تبریز',
    'همدان',
    'کاشان',
    'اهواز',
    'سیرجان',
    'کرمان',
    'شهرضا',
    'ابرکوه',
    'قزوین',
    'تاکستان',
    'بناب',
    'میانه',
    'رشت',
    'ساری',
    'یزد',
    'ابهر',
    'دزفول',
    'شاهرود',
    'سمنان',
    'اردبیل',
    'قم',
    'اراک'
  ]) {
    if (s.contains(c)) return c;
  }
  return 'نامشخص';
}

class SourceParser {
  static List<Quote> parse(SourceEndpoint e, String body, DateTime fetchedAt) {
    if (body.contains('Account Suspended') ||
        body.contains('captcha-delivery.com')) {
      throw const FormatException('صفحه مسدود/تعلیق‌شده؛ قیمت دریافت نشد.');
    }
    return switch (e.parser) {
      'melal' => melal(e, body, fetchedAt),
      'asre' => asre(e, body, fetchedAt),
      'telegram' => telegram(e, body, fetchedAt),
      _ => throw const FormatException('مبدل تعریف نشده')
    };
  }

  static List<Quote> melal(SourceEndpoint e, String body, DateTime fetched) {
    final doc = html.parse(body);
    final result = <Quote>[];
    for (final box in doc.querySelectorAll('.filterTable')) {
      final headers = box
          .querySelectorAll('.gridHeader .th')
          .map((c) => latin(c.text))
          .toList();
      final mobile = box.querySelector('.table-m') != null;
      // Melal desktop header explicitly declares toman; its observed mobile
      // accordion uses the same priceText/data-price2 contract but omits currency.
      final toman = headers.any((s) => s.contains('قیمت (تومان)')) ||
          (mobile &&
              headers.contains('قیمت') &&
              box.querySelector('.priceText[data-price2]') != null);
      if (headers.isEmpty || !toman) {
        continue;
      }
      final brand =
          box.attributes['data-table-title'] ?? box.attributes['title'] ?? '';
      final url =
          box.querySelector('a.h2titleproduct')?.attributes['href'] ?? e.url;
      for (final row in box.querySelectorAll(mobile ? '.tr-row' : '.trbody')) {
        final cells =
            row.children.where((x) => x.classes.contains('td')).toList();
        if (cells.length != headers.length) continue;
        final fields = <String, String>{
          for (var i = 0; i < headers.length; i++)
            headers[i]: latin(cells[i].text)
        };
        final collapse =
            row.querySelector('.accordion-toggle')?.attributes['href'];
        if (mobile &&
            collapse != null &&
            RegExp(r'^#collapse_[a-zA-Z0-9_-]+$').hasMatch(collapse)) {
          final panel = box.querySelector(collapse);
          final labels = panel?.querySelectorAll('.th > span') ?? [];
          final vals = panel?.querySelectorAll('.td > span') ?? [];
          if (labels.length == vals.length) {
            for (var i = 0; i < labels.length; i++) {
              final key = latin(labels[i].text).replaceAll(':', '').trim();
              fields[key] = latin(vals[i].text);
            }
          }
        }
        String field(bool Function(String) pred) =>
            fields.entries
                .where((x) => pred(x.key))
                .map((x) => x.value)
                .firstOrNull ??
            '';
        if (mobile && !(doc.body?.text.contains('تومان') ?? false)) {
          fields['مبنای ارز'] = 'تومان؛ تایید از جدول دسکتاپ همین منبع';
        }
        final priceCell = row.querySelector('.priceText');
        final displayed = number(priceCell?.text ?? '');
        final original = number(priceCell?.attributes['data-price2'] ?? '');
        final mismatch = displayed != null &&
            original != null &&
            (displayed - original).abs() > 1;
        final amount = mismatch ? null : displayed;
        final title = field((k) => k.startsWith('نوع ') || k == 'محصول');
        final unit = parseUnit(field((k) => k == 'واحد'));
        final date = field((k) => k.contains('به روز رسانی'));
        final loading = field((k) => k == 'بارگیری');
        final weight =
            number(field((k) => k == 'وزن' || k.contains('وزن شاخه')));
        final length = number(field((k) => k.contains('طول')));
        final onclick =
            row.querySelector('[onclick]')?.attributes['onclick'] ?? '';
        final key = collapse?.replaceFirst('#collapse_', '') ??
            RegExp(r"showChart\('([^']+)'\)").firstMatch(onclick)?[1];
        final identity = key ??
            base64Url.encode(utf8.encode(
                '$brand|${Map.fromEntries(fields.entries.where((x) => !x.key.contains("قیمت") && !x.key.contains("به روز") && x.key != "نوسان"))}'));
        result.add(Quote(
            id: '${e.id}:$identity',
            endpoint: e.id,
            seller: 'آهن ملل',
            sellerCity: e.sellerCity,
            title: title.isEmpty
                ? '$brand ${field((k) => k.contains('سایز'))}'
                : title,
            category: e.category,
            material: materialOf('$title $brand'),
            brand: brand.replaceFirst('قیمت ', ''),
            loading: loading.isEmpty ? 'نامشخص' : loading,
            loadingCity: knownCity(loading),
            unit: unit,
            tax: 'بدون ارزش افزوده',
            amount: amount != null && amount > 0 && unit != 'unknown'
                ? amount
                : null,
            pieceKg: weight,
            lengthM: length,
            sourceUrl: url,
            sourceDateRaw: date,
            fetchedAt: fetched,
            details: fields,
            status: mismatch
                ? 'اختلاف عدد نمایشی و داده؛ نیازمند تایید'
                : amount == null
                    ? 'تماس/ناموجود/عدد نامعتبر'
                    : 'اعلام فروشنده؛ موجودی نیازمند تایید'));
      }
    }
    return result;
  }

  static List<Quote> asre(SourceEndpoint e, String body, DateTime fetched) {
    final doc = html.parse(body);
    final node = doc.querySelector('#__NEXT_DATA__');
    if (node == null) return [];
    final j = jsonDecode(node.text) as Map<String, dynamic>;
    final queries =
        j['props']?['pageProps']?['dehydratedState']?['queries'] as List? ?? [];
    final result = <Quote>[];
    for (final query in queries) {
      final pages = query['state']?['data']?['pages'];
      if (pages is! List) continue;
      for (final page in pages) {
        for (final p in page['data']?['products'] as List? ?? []) {
          if (p['sellers'] is! List || p['specification'] is! Map) continue;
          final spec = Map<String, dynamic>.from(p['specification']);
          for (final s in p['sellers']) {
            // Actual detail rows, not category minima; never use seller.weight as branch mass.
            final seller = latin('${s['name'] ?? ''}');
            final amount = (s['price'] as num?)?.toDouble();
            final date = '${s['updatedAt'] ?? ''}';
            final title =
                '${spec['category'] ?? e.category} ${spec['size'] ?? ''} ${p['producerName'] ?? ''} ${spec['standard'] ?? ''}';
            result.add(Quote(
                id: '${e.id}:${p['productId']}:${s['loadingAreaCode']}:$seller',
                endpoint: e.id,
                seller: seller,
                sellerCity: seller.contains('عصر') ? 'تبریز' : 'نامشخص',
                title: latin(title),
                category: e.category,
                material: materialOf(title),
                brand: '${p['producerName'] ?? ''}',
                loading: '${s['loadingArea'] ?? 'نامشخص'}',
                loadingCity: knownCity('${s['loadingArea'] ?? ''}'),
                unit: e.category == 'میلگرد' ? 'kg' : 'unknown',
                tax: 'نامشخص',
                sourceDateRaw: date,
                sourceUrl: e.url,
                fetchedAt: fetched,
                pieceKg: (spec['weight'] as num?)?.toDouble(),
                lengthM: number(latin('${spec['state']}')
                    .replaceAll(RegExp(r'[^0-9.]'), '')),
                amount: s['stocked'] == true && amount != null && amount > 0
                    ? amount
                    : null,
                status: s['stocked'] == true
                    ? 'اعلام فروشنده؛ مالیات نیازمند تایید'
                    : 'ناموجود در منبع',
                details: spec.map((k, v) => MapEntry(k, '$v'))
                  ..addAll({
                    'تلفن': '${s['phone'] ?? ''}',
                    'موجودی': '${s['stocked']}',
                    'واحد': 'کیلوگرم (جدول میلگرد)'
                  })));
          }
        }
      }
    }
    return result;
  }

  static List<Quote> telegram(SourceEndpoint e, String body, DateTime fetched) {
    final doc = html.parse(body);
    final result = <Quote>[];
    for (final message in doc.querySelectorAll('.tgme_widget_message')) {
      final node = message.querySelector('.tgme_widget_message_text');
      if (node == null) continue;
      // Preserve message as evidence. Ambiguous units/tax are not promoted to a ranked price.
      final text = latin(node.text);
      if (!RegExp('قیمت|میلگرد|نبشی|ناودانی|ورق|تیرآهن|پروفیل|لوله')
          .hasMatch(text)) continue;
      final post = message.attributes['data-post'] ?? '';
      if (post.isEmpty) continue;
      final date = message.querySelector('time')?.attributes['datetime'] ?? '';
      final hasImage =
          message.querySelector('.tgme_widget_message_photo_wrap') != null;
      final short = text.length > 110 ? text.substring(0, 110) : text;
      result.add(Quote(
          id: '${e.id}:$post',
          endpoint: e.id,
          seller: e.name,
          sellerCity: e.sellerCity,
          title: short,
          category: e.category,
          unit: 'unknown',
          tax: 'نامشخص',
          sourceUrl: 'https://t.me/$post',
          sourceDateRaw:
              '', // Publication is not evidence of the price announcement date.
          fetchedAt: fetched,
          amount: null,
          status: hasImage
              ? 'فهرست تصویری؛ خارج از مقایسه عددی'
              : 'اعلام متنی؛ واحد/تاریخ نرخ نیازمند تایید',
          details: {
            'متن پیام': text,
            'زمان انتشار پیام': date,
            'قالب': hasImage ? 'تصویر' : 'متن'
          }));
    }
    return result;
  }
}

class SourceClient {
  final http.Client client;
  List<String> cityNames = [];
  SourceClient({http.Client? client}) : client = client ?? http.Client();
  Future<List<Quote>> fetch(SourceEndpoint e) async {
    unawaited(AppLogger.instance
        .record('network', 'fetch_started', {'endpoint': e.id}));
    final r = await client.get(Uri.parse(e.url), headers: {
      'User-Agent': 'IronPin/0.2 (public price page reader)',
      'Accept': 'text/html'
    }).timeout(const Duration(seconds: 22));
    if (r.statusCode != 200) {
      throw FormatException('HTTP ${r.statusCode}؛ داده قبلی حفظ شد.');
    }
    if (r.bodyBytes.length > 8 * 1024 * 1024) {
      throw const FormatException('صفحه بیش از اندازه بزرگ است.');
    }
    final watch = Stopwatch()..start();
    final rows = await compute(_parseInBackground, {
      'endpoint': e,
      'bytes': r.bodyBytes,
      'fetchedAt': DateTime.now().toUtc(),
      'cities': cityNames
    });
    await AppLogger.instance.record('parser', 'parsed', {
      'endpoint': e.id,
      'rows': rows.length,
      'bytes': r.bodyBytes.length,
      'elapsedMs': watch.elapsedMilliseconds
    });
    if (rows.isEmpty) {
      throw const FormatException(
          'هیچ ردیف معتبری پیدا نشد؛ احتمال تغییر ساختار سایت.');
    }
    return rows;
  }

  void close() => client.close();
}

List<Quote> _parseInBackground(Map<String, Object> input) {
  final rows = SourceParser.parse(
      input['endpoint'] as SourceEndpoint,
      utf8.decode(input['bytes'] as Uint8List, allowMalformed: true),
      input['fetchedAt'] as DateTime);
  final cities = (input['cities'] as List<String>).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  if (cities.isEmpty) return rows;
  return rows.map((q) {
    if (q.loadingCity != 'نامشخص') return q;
    final text =
        ' ${latin(q.loading).replaceAll(RegExp(r"[^\w\u0600-\u06FF ]"), ' ')} ';
    final match =
        cities.where((c) => text.contains(' ${latin(c)} ')).firstOrNull;
    return match == null
        ? q
        : Quote.fromJson(q.toJson()..['loadingCity'] = match);
  }).toList();
}
