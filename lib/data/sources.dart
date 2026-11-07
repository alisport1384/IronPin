import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'app_logger.dart';
import 'public_messages.dart';
import 'public_tables.dart';
import '../domain/text_engine.dart';
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
      'https://t.me/s/ahanalatehoseini', 'عمومی', 'telegram', 'مشهد'),
  SourceEndpoint('telegram-ahanemashhad', 'آهن ویژه مشهد • توس ۷',
      'https://t.me/s/ahanemashhad', 'عمومی', 'telegram', 'مشهد'),
  SourceEndpoint('telegram-melal', 'تلگرام آهن ملل', 'https://t.me/s/ahanmelal',
      'عمومی', 'telegram', 'اصفهان'),
  SourceEndpoint('telegram-mkz', 'تلگرام مرکزآهن • کانال اصلی',
      'https://t.me/s/markazeahan', 'عمومی', 'telegram', 'اصفهان'),
  SourceEndpoint('telegram-mkz1', 'تلگرام مرکزآهن • میلگرد',
      'https://t.me/s/markazeahan1', 'میلگرد', 'telegram', 'اصفهان'),
  SourceEndpoint('telegram-mkz2', 'تلگرام مرکزآهن • لوله/پروفیل',
      'https://t.me/s/markazeahan2', 'پروفیل', 'telegram', 'اصفهان'),
  SourceEndpoint('telegram-mkz3', 'تلگرام مرکزآهن • مقاطع',
      'https://t.me/s/markazeahan3', 'نبشی', 'telegram', 'اصفهان'),
  SourceEndpoint('telegram-mkz4', 'تلگرام مرکزآهن • ورق',
      'https://t.me/s/markazeahan4', 'ورق', 'telegram', 'اصفهان'),
  SourceEndpoint('telegram-asre', 'تلگرام عصرآهن', 'https://t.me/s/asreahancom',
      'عمومی', 'telegram', 'تبریز'),
  SourceEndpoint('telegram-ahanprice', 'تلگرام آهن پرایس • ahanprice',
      'https://t.me/s/ahanprice', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-milgerdprice', 'تلگرام آهن پرایس • MilgerdPrice',
      'https://t.me/s/MilgerdPrice', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-tirahanprice', 'تلگرام آهن پرایس • Tirahanprice',
      'https://t.me/s/Tirahanprice', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-varaghprice', 'تلگرام آهن پرایس • VaraghPrice',
      'https://t.me/s/VaraghPrice', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-l-uprice', 'تلگرام آهن پرایس • L_Uprice',
      'https://t.me/s/L_Uprice', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-profileprice', 'تلگرام آهن پرایس • ProfilePrice',
      'https://t.me/s/ProfilePrice', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-looleprice', 'تلگرام آهن پرایس • LoolePrice',
      'https://t.me/s/LoolePrice', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-modiranahan-z', 'تلگرام مدیران آهن • modiranahan_z',
      'https://t.me/s/modiranahan_z', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-ahan-online', 'تلگرام آهن آنلاین • ahan_online',
      'https://t.me/s/ahan_online', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-ao-thin-plate', 'تلگرام آهن آنلاین • AO_Thin_plate',
      'https://t.me/s/AO_Thin_plate', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-ao-pipe-box', 'تلگرام آهن آنلاین • Ao_pipe_box',
      'https://t.me/s/Ao_pipe_box', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-fooladsell', 'تلگرام فولادسل • Fooladsell',
      'https://t.me/s/Fooladsell', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-kavirsteel', 'تلگرام فولاد کویر • kavirsteel',
      'https://t.me/s/kavirsteel', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('telegram-asroon', 'تلگرام آهنگر — لینک مقاله • asroon',
      'https://t.me/s/asroon', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint(
      'telegram-shekoftegroup',
      'تلگرام گروه صنعتی شکفته • shekoftegroup',
      'https://t.me/s/shekoftegroup',
      'عمومی',
      'telegram',
      'نامشخص'),
  SourceEndpoint('telegram-novinpars', 'نوین پارس مشهد • تلگرام',
      'https://t.me/s/novinparsgroup', 'عمومی', 'telegram', 'مشهد'),
  SourceEndpoint('telegram-hayperahan', 'هایپر آهن مشهد • تلگرام',
      'https://t.me/s/hayperahan', 'عمومی', 'telegram', 'مشهد'),
  SourceEndpoint('telegram-radmanahan', 'رادمان آهن مشهد • تلگرام',
      'https://t.me/s/radmanahan', 'عمومی', 'telegram', 'مشهد'),
  SourceEndpoint('telegram-fiahan', 'آهن‌آلات حیدری • تلگرام',
      'https://t.me/s/FIAHAN', 'عمومی', 'telegram', 'تهران'),
  SourceEndpoint('telegram-ahan100', 'آهن صد • تلگرام',
      'https://t.me/s/atifoolad', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint('public-bale-ahanonlineofficial', "آهن آنلاین • بله",
      "https://ble.ir/s/ahanonlineofficial", 'عمومی', 'bale', "نامشخص"),
  SourceEndpoint('public-bale-modiranahan', "مدیران آهن • بله",
      "https://ble.ir/s/modiranahan", 'عمومی', 'bale', "نامشخص"),
  SourceEndpoint('public-eitaa-modiranahan', "مدیران آهن • ایتا",
      "https://eitaa.com/modiranahan", 'عمومی', 'eitaa', "نامشخص",
      defaultEnabled: true),
  SourceEndpoint('public-eitaa-shekoftehsigmashhad', "گروه شکفته • ایتا",
      "https://eitaa.com/shekoftehsigmashhad", 'عمومی', 'eitaa', "نامشخص"),
  SourceEndpoint('public-bale-pivanco', "پیوان • بله",
      "https://ble.ir/s/pivanco", 'عمومی', 'bale', "نامشخص"),
  SourceEndpoint('public-eitaa-galvanizeahaninfo', "آهن اینفو • ایتا",
      "https://eitaa.com/Galvanizeahaninfo", 'عمومی', 'eitaa', "نامشخص"),
  SourceEndpoint('public-rubika-ahaninja1', "آهن اینجا • روبیکا",
      "https://rubika.ir/ahaninja1", 'عمومی', 'rubika', "نامشخص"),
  SourceEndpoint('public-eitaa-ahan100', "آهن صد • ایتا",
      "https://eitaa.com/Ahan100", 'عمومی', 'eitaa', "نامشخص"),
  SourceEndpoint('public-rubika-ahan100', "آهن صد • روبیکا",
      "https://rubika.ir/ahan100", 'عمومی', 'rubika', "نامشخص"),
  SourceEndpoint('public-bale-ahan100', "آهن صد • بله",
      "https://ble.ir/s/ahan100", 'عمومی', 'bale', "نامشخص"),
  SourceEndpoint('public-rubika-novinparsgroup', "نوین پارس • روبیکا",
      "https://rubika.ir/novinparsgroup/", 'عمومی', 'rubika', "مشهد"),
  SourceEndpoint('public-bale-novinparsgroup', "نوین پارس • بله",
      "https://ble.ir/s/novinparsgroup", 'عمومی', 'bale', "مشهد",
      defaultEnabled: true),
  SourceEndpoint('public-eitaa-radmanahan', "رادمان آهن • ایتا",
      "https://eitaa.com/radmanahan", 'عمومی', 'eitaa', "مشهد"),
  SourceEndpoint('public-rubika-radmanahan', "رادمان آهن • روبیکا",
      "https://rubika.ir/radmanahan", 'عمومی', 'rubika', "مشهد"),
  SourceEndpoint('public-eitaa-hayperahan', "هایپر آهن • ایتا",
      "https://eitaa.com/hayperahan", 'عمومی', 'eitaa', "مشهد"),
  SourceEndpoint('public-rubika-hayperahan', "هایپر آهن • روبیکا",
      "https://rubika.ir/hayperahan", 'عمومی', 'rubika', "مشهد"),
  SourceEndpoint('public-rubika-tikahan', "تیک آهن • روبیکا",
      "https://rubika.ir/tikahan", 'عمومی', 'rubika', "مشهد"),
  SourceEndpoint('public-eitaa-fiahan1', "آهن‌آلات حیدری • ایتا",
      "https://eitaa.com/fiahan1", 'عمومی', 'eitaa', "تهران"),
  SourceEndpoint('public-rubika-fiahan_com', "آهن‌آلات حیدری • روبیکا",
      "https://rubika.ir/fiahan_com", 'عمومی', 'rubika', "تهران"),
  SourceEndpoint('public-bale-fiahan', "آهن‌آلات حیدری • بله",
      "https://ble.ir/s/fiahan", 'عمومی', 'bale', "تهران"),
  SourceEndpoint('public-eitaa-samaneahan_com', "سامانه آهن • ایتا",
      "https://eitaa.com/samaneahan_com", 'عمومی', 'eitaa', "نامشخص"),
  SourceEndpoint('public-bale-ahaneroz', "آهن روز • بله",
      "https://ble.ir/s/ahaneroz", 'عمومی', 'bale', "نامشخص"),
  SourceEndpoint(
      'public-rubika-khabazzade_iron',
      "ورق و آهن‌آلات خباززاده • روبیکا",
      "https://rubika.ir/khabazzade_iron",
      'عمومی',
      'rubika',
      "نامشخص"),
  SourceEndpoint(
      'public-rubika-tahamtaniron',
      "فولاد گستر تهمتن خاورمیانه • روبیکا",
      "https://rubika.ir/TahamtanIron",
      'عمومی',
      'rubika',
      "نامشخص"),
  SourceEndpoint(
      'fardad-sheet',
      'فرداد فولاد مشهد • ورق',
      'https://fardadfoolad.ir/products/164/ورق-سیاه',
      'ورق',
      'public-table',
      'مشهد'),
  SourceEndpoint(
      'mashhad-sheet',
      'مشهد فولاد توس • جدول ورق',
      'https://mashhadfoolad.com/قیمت-ورق-آهن-سیاه/',
      'ورق',
      'public-table',
      'مشهد'),
  SourceEndpoint('telegram-ghanbari', 'بازرگانی قنبری • فرداد فولاد مشهد',
      'https://t.me/s/bazargani_ghanbari', 'عمومی', 'telegram', 'مشهد'),
  SourceEndpoint(
      'telegram-khabazzade',
      'خباززاده مشهد • تلگرام رسمی معرفی‌شده در سایت',
      'https://t.me/s/khabazzade_iron',
      'عمومی',
      'telegram',
      'مشهد'),
  SourceEndpoint('telegram-iromart', 'آیرومارت • تلگرام',
      'https://t.me/s/iromart', 'عمومی', 'telegram', 'نامشخص'),
  SourceEndpoint(
      'khabazzade-sheet',
      'خباززاده مشهد • جدول ورق',
      'https://www.khabazzadeh.com/ahan-price/sheet/',
      'ورق',
      'public-table',
      'مشهد'),
  SourceEndpoint(
      'samen-angle',
      'ثامن تجارت • نبشی',
      'https://samentejarat.com/nabshinavdani/nabshi/',
      'نبشی',
      'public-table',
      'نامشخص'),
  SourceEndpoint(
      'shahr-mashhad',
      'شهرآهن • محصولات فولاد پروفیل مشهد',
      'https://www.shahrahan.com/manufacturers/134-شرکت-فولاد-پروفیل-مشهد',
      'عمومی',
      'public-table',
      'نامشخص'),
];
// Office location is NOT the manufacturing or loading location.
const sellers = [
  {
    'name': 'آهن‌آلات خباززاده',
    'city': 'مشهد',
    'phone': '05136905551',
    'url': 'https://www.khabazzadeh.com/contact/',
    'address': 'مشهد، بلوار شهید چراغچی، چراغچی۵۳، نبش طرحچی۶، پلاک۱۱۰',
    'status':
        'دفتر و کانال تلگرام از صفحه تماس رسمی؛ مبلغ جدول بدون واحد صریح به کیلو یا برگ فرض نمی‌شود'
  },
  {
    'name': 'فرداد فولاد خراسان',
    'city': 'مشهد',
    'phone': '05136908383',
    'url': 'https://fardadfoolad.ir/contact',
    'address': 'مشهد، شهید چراغچی ۵۳، بین طرحچی ۱۳ و ۱۵',
    'status':
        'دفتر از صفحه تماس رسمی؛ جدول ورق تاریخ صریح دارد، ارز بدون تصریح حدس زده نمی‌شود'
  },
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
    final rows = switch (e.parser) {
      'public-table' => PublicTables.read(
          body: body,
          url: e.url,
          endpoint: e.id,
          seller: e.name,
          city: e.sellerCity,
          category: e.category,
          fetchedAt: fetchedAt),
      'melal' => melal(e, body, fetchedAt),
      'asre' => asre(e, body, fetchedAt),
      'telegram' => telegram(e, body, fetchedAt),
      'eitaa' || 'bale' || 'rubika' => PublicMessages.read(
          body: body,
          url: e.url,
          endpoint: e.id,
          seller: e.name,
          city: e.sellerCity,
          fetchedAt: fetchedAt,
          platform: e.parser),
      _ => throw const FormatException('مبدل تعریف نشده')
    };
    return rows.map(TextPriceEngine.enrich).toList();
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

  static List<Quote> telegram(
          SourceEndpoint e, String body, DateTime fetched) =>
      PublicMessages.read(
          body: body,
          url: e.url,
          endpoint: e.id,
          seller: e.name,
          city: e.sellerCity,
          fetchedAt: fetched,
          platform: 'telegram');
}

class SourceClient {
  final http.Client client;
  List<String> cityNames = [];
  final Map<String, List<SourceEndpoint>> discoveries = {};
  final Map<String, bool> complete = {};
  final int maxChannelPages;
  SourceClient({http.Client? client, this.maxChannelPages = 6})
      : client = client ?? http.Client();
  Future<List<Quote>> fetch(SourceEndpoint e) async {
    unawaited(AppLogger.instance
        .record('network', 'fetch_started', {'endpoint': e.id}));
    final channel = ['telegram', 'eitaa', 'bale', 'rubika'].contains(e.parser);
    final all = <String, Quote>{};
    final tableRows = <Quote>[];
    final found = <String, SourceEndpoint>{};
    final visited = <String>{};
    var url = e.url;
    var pages = 0;
    var finished = false;
    final fetched = DateTime.now().toUtc();
    while (visited.add(url) && pages < (channel ? maxChannelPages : 1)) {
      try {
        // Follow only published same-channel pagination; never construct a private API.
        final r = await client.get(Uri.parse(url), headers: {
          'User-Agent': 'IronPin/0.5 (public price reader)',
          'Accept': 'text/html'
        }).timeout(const Duration(seconds: 22));
        if (r.statusCode != 200) {
          throw FormatException('HTTP ${r.statusCode}؛ داده قبلی حفظ شد.');
        }
        if (r.bodyBytes.length > 8 * 1024 * 1024) {
          throw const FormatException('صفحه بیش از اندازه بزرگ است.');
        }
        final body = utf8.decode(r.bodyBytes, allowMalformed: true);
        final rows = await compute(_parseInBackground, {
          'endpoint': e,
          'bytes': r.bodyBytes,
          'fetchedAt': fetched,
          'cities': cityNames
        });
        final links =
            await compute(_discoverInBackground, {'body': body, 'url': url});
        for (final x in links) {
          found[x.id] = x;
        }
        if (!channel) tableRows.addAll(rows);
        for (final q in rows) {
          all.putIfAbsent(q.id, () => q);
        }
        pages++;
        if (!channel) {
          finished = true;
          break;
        }
        final next =
            await compute(_olderInBackground, {'url': url, 'body': body});
        final dates = rows
            .map((q) => q.publishedAt ?? q.marketAt)
            .whereType<DateTime>()
            .toList();
        if (next == null ||
            (dates.isNotEmpty &&
                dates.every((d) =>
                    d.isBefore(fetched.subtract(const Duration(days: 7)))))) {
          finished = true;
          break;
        }
        url = next;
        if (pages < maxChannelPages) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
      } catch (error) {
        if (all.isEmpty) rethrow;
        finished = false;
        await AppLogger.instance.record('network', 'older_page_failed', {
          'endpoint': e.id,
          'pagesReceived': pages,
          'errorType': error.runtimeType.toString()
        });
        break;
      }
    }
    discoveries[e.id] = found.values.toList();
    complete[e.id] = finished;
    await AppLogger.instance.record('parser', 'parsed', {
      'endpoint': e.id,
      'rows': all.length,
      'pages': pages,
      'coverage':
          finished ? 'preview_exhausted_or_week_reached' : 'page_limit_partial',
      'discovered': found.length
    });
    if (all.isEmpty) {
      throw const FormatException(
          'متن پیام/ردیف قیمت در پاسخ عمومی پیدا نشد؛ داده قبلی حفظ شد.');
    }
    return channel ? all.values.toList() : tableRows;
  }

  void close() => client.close();
}

/// URLs are only candidates discovered in public anchors. They remain disabled
/// until selected by the user; no account/phone/share/invite/private URL crawling.
SourceEndpoint? publicChannel(String raw,
    {String? name, String city = 'نامشخص'}) {
  final u = Uri.tryParse(raw);
  if (u == null ||
      !['http', 'https'].contains(u.scheme) ||
      u.userInfo.isNotEmpty ||
      u.hasPort) return null;
  final platforms = {
    'eitaa.com': 'eitaa',
    'ble.ir': 'bale',
    'rubika.ir': 'rubika',
    't.me': 'telegram',
    'telegram.me': 'telegram'
  };
  final parser = platforms[u.host.toLowerCase()];
  if (parser == null) return null;
  final parts = u.pathSegments.where((x) => x.isNotEmpty).toList();
  if (parts.isNotEmpty && parts.first == 's') parts.removeAt(0);
  if (parts.length != 1 ||
      !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{2,63}$').hasMatch(parts.first)) {
    return null;
  }
  final h = parts.first, low = h.toLowerCase();
  if (['share', 'join', 'joinchat', 's', 'search', 'proxy'].contains(low) ||
      low.endsWith('bot') ||
      low.contains('admin') ||
      low.contains('marketing')) return null;
  final host = parser == 'telegram' ? 't.me' : u.host.toLowerCase();
  return SourceEndpoint(
      'public-$parser-$low',
      name ?? 'کشف‌شده: $h',
      'https://$host/${parser == 'telegram' || parser == 'bale' ? 's/' : ''}$h',
      'عمومی',
      parser,
      city,
      defaultEnabled: false);
}

List<SourceEndpoint> _discoverInBackground(Map<String, String> input) {
  final base = Uri.parse(input['url']!);
  final doc = html.parse(input['body']!);
  final result = <String, SourceEndpoint>{};
  for (final a in doc.querySelectorAll('a[href]')) {
    final e = publicChannel(base.resolve(a.attributes['href']!).toString());
    if (e != null) result[e.id] = e;
  }
  return result.values.take(30).toList();
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

String? _olderInBackground(Map<String, String> input) =>
    PublicMessages.older(input['url']!, input['body']!);
