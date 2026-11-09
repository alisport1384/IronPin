import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import '../domain/market.dart';
import '../domain/text_engine.dart';

/// Semantic HTML reader: verified post URLs and standard time metadata, not a
/// guessed private API or invented platform-specific CSS/JSON contract.
class PublicMessages {
  static String textOf(Node node) {
    final out = StringBuffer();
    void walk(Node n) {
      if (n is Text) {
        out.write(n.text);
        return;
      }
      if (n is! Element) {
        for (final c in n.nodes) {
          walk(c);
        }
        return;
      }
      if (['script', 'style', 'noscript', 'nav', 'footer']
          .contains(n.localName)) return;
      final block = [
        'p',
        'div',
        'li',
        'section',
        'article',
        'br',
        'tr',
        'h1',
        'h2',
        'h3',
        'h4',
        'img'
      ].contains(n.localName);
      if (block) out.write('\n');
      for (final c in n.nodes) {
        walk(c);
      }
      if (block && n.localName != 'img') out.write('\n');
    }

    walk(node);
    return out
        .toString()
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join('\n');
  }

  static List<Quote> read(
      {required String body,
      required String url,
      required String endpoint,
      required String seller,
      required String city,
      required DateTime fetchedAt,
      required String platform,
      String defaultCurrency = 'نامشخص'}) {
    final doc = html.parse(body), base = Uri.parse(url);
    final handle =
        base.pathSegments.where((s) => s.isNotEmpty && s != 's').firstOrNull ??
            '';
    final own = RegExp('^/(?:s/)?${RegExp.escape(handle)}/([0-9]+)\u0024',
        caseSensitive: false);
    String? postOf(Element a) {
      final u = base.resolve(a.attributes['href'] ?? '');
      if (u.host.toLowerCase() != base.host.toLowerCase()) return null;
      return own.firstMatch(u.path)?[1];
    }

    final result = <Quote>[], seen = <String>{};
    if (platform == 'telegram') {
      for (final message in doc.querySelectorAll('.tgme_widget_message')) {
        final post = message.attributes['data-post'] ?? '';
        if (post.isEmpty || !seen.add(post)) continue;
        final node = message.querySelector('.tgme_widget_message_text');
        final image =
            message.querySelector('.tgme_widget_message_photo_wrap') != null;
        if (node == null && !image) continue;
        result.addAll(TextPriceEngine.analyze(
            text: node == null ? 'لیست تصویری' : textOf(node),
            endpoint: endpoint,
            seller: seller,
            sellerCity: city,
            sourceUrl: 'https://t.me/$post',
            fetchedAt: fetchedAt,
            postId: post,
            publishedAt: sourceDate(
                message.querySelector('time')?.attributes['datetime'] ?? ''),
            image: image,
            defaultCurrency: defaultCurrency));
      }
      return result;
    }
    // Locate the largest non-overlapping ancestor containing exactly one post.
    // Multiple links to the same post (time/media) count as one, not many.
    for (final a in doc.querySelectorAll('a[href]')) {
      final post = postOf(a);
      if (post == null || !seen.add(post)) continue;
      Element box = a;
      while (box.parent != null && box.parent!.localName != 'html') {
        final parent = box.parent!;
        final ids = parent
            .querySelectorAll('a[href]')
            .map(postOf)
            .whereType<String>()
            .toSet();
        if (ids.length > 1) break;
        box = parent;
      }
      final dateNode = box.querySelector('time[datetime]');
      DateTime? published = sourceDate(dateNode?.attributes['datetime'] ?? '');
      if (published == null) {
        for (final n in box.querySelectorAll('[title]')) {
          final title = n.attributes['title'] ?? '';
          if (TextPriceEngine.datePattern.hasMatch(latin(title))) {
            published = TextPriceEngine.dateIn(title);
            break;
          }
        }
      }
      result.addAll(TextPriceEngine.analyze(
          text: textOf(box),
          endpoint: endpoint,
          seller: seller,
          sellerCity: city,
          sourceUrl: base.resolve(a.attributes['href']!).toString(),
          fetchedAt: fetchedAt,
          postId: '$handle/$post',
          publishedAt: published,
          defaultCurrency: defaultCurrency));
    }
    if (result.isNotEmpty) return result;
    if (platform == 'rubika') {
      throw const FormatException(
          'روبیکا فقط معرفی کانال برگرداند؛ پیام عمومی دریافت نشد و قیمت استخراج نشده است.');
    }
    // Some public previews expose dated text without post permalinks. Do not
    // manufacture publication time or post IDs: mark document-level evidence.
    final plain = textOf(doc.body ?? doc.documentElement!);
    if (!TextPriceEngine.datePattern.hasMatch(latin(plain))) return [];
    return TextPriceEngine.analyze(
            text: plain,
            endpoint: endpoint,
            seller: seller,
            sellerCity: city,
            sourceUrl: url,
            fetchedAt: fetchedAt,
            defaultCurrency: defaultCurrency,
            postId: 'document')
        .map((q) => Quote.fromJson(q.toJson()
          ..['details'] = {
            ...q.details,
            'حدود منبع':
                'متن سند عمومی؛ زمان انتشار مستقل/لینک هر پیام در دسترس نبود'
          }))
        .toList();
  }

  static String? older(String url, String body) {
    final base = Uri.parse(url);
    final doc = html.parse(body);
    for (final a in doc.querySelectorAll('a[href]')) {
      final u = base.resolve(a.attributes['href']!);
      if (u.scheme != 'https' ||
          u.host != base.host ||
          u.path != base.path ||
          u.userInfo.isNotEmpty ||
          u.hasPort) continue;
      if (RegExp(r'^\d+$').hasMatch(u.queryParameters['before'] ?? '') &&
          u.toString() != url) return u.toString();
    }
    return null;
  }
}
