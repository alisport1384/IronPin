import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/public_tables.dart';
import 'package:ironpin/data/source_finder_io.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/searcher.dart';
import 'package:ironpin/domain/source_finder.dart';
import 'package:ironpin/ui/finder_panel.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

http.Response page(String body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(body), status,
        headers: {'content-type': 'text/html; charset=utf-8'});

String duck(Map<String, String> results) => '<html><body>${[
      for (final e in results.entries)
        '<div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=${Uri.encodeQueryComponent(e.key)}&amp;rut=1">${e.value}</a>'
            '<a class="result__snippet">${e.value}</a></div>'
    ].join()}</body></html>';

const steelPost = '''
<p>قیمت میلگرد 14 ذوب آهن 38500 تومان</p><p>قیمت تیرآهن 16 فروش ویژه</p>
<p>ورق سیاه 3 میل قیمت 41000 تومان تحویل بنگاه</p><p>نبشی و ناودانی موجودی انبار</p>''';

String channel(String title, String body) =>
    '<html><head><meta property="og:title" content="$title"><title>$title</title></head>'
    '<body><div>$body</div></body></html>';

Future<MarketStore> memory() => MarketStore.open(
    dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);

final duckOnly = [finderProviders.firstWhere((p) => p.id == 'ddg')];

SourceFinder finderOn(MarketStore store, MockClientHandler handler,
        {DateTime Function()? clock,
        List<String>? probes,
        List<FinderProvider>? providers}) =>
    SourceFinder(store,
        client: MockClient(handler),
        pageGap: Duration.zero,
        searchGap: Duration.zero,
        providers: providers ?? duckOnly,
        probes: probes ?? const ['https://probe.example/'],
        clock: clock);

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  group('which list a public address belongs to', () {
    test('channels are named canonically on their own list', () {
      final t = classifyLink('https://telegram.me/s/SteelShop/1234')!;
      expect([t.url, t.kind, t.key, t.part, t.readable],
          ['https://t.me/SteelShop', 'telegram', 'telegram:steelshop', 1, true]);
      expect(classifyLink('https://eitaa.com/@ahanyar')!.url,
          'https://eitaa.com/ahanyar');
      expect(classifyLink('http://www.ble.ir/s/steelbale')!.key,
          'bale:steelbale');
      expect(classifyLink('https://rubika.ir/ahanshop/')!.part,
          FinderPart.domestic);
      expect(previewUrl('bale', 'https://ble.ir/steelbale'),
          'https://ble.ir/s/steelbale');
      expect(previewUrl('telegram', 'https://t.me/SteelShop'),
          'https://t.me/s/SteelShop');
      expect(previewUrl('eitaa', 'https://eitaa.com/ahanyar'),
          'https://eitaa.com/ahanyar');
    });
    test('networks that need a login are listed but never readable', () {
      final i = classifyLink('https://instagram.com/Ahan.Page/reels/')!;
      expect([i.url, i.part, i.readable],
          ['https://www.instagram.com/ahan.page/', FinderPart.social, false]);
      expect(
          classifyLink('https://www.whatsapp.com/channel/0029Vay85UeElah1MIGrFV2u')!
              .kind,
          'whatsapp');
      expect(classifyLink('https://splus.ir/ahanshop')!.readable, false);
    });
    test('invites, contacts, bots, files and search engines are not places', () {
      for (final u in [
        'https://t.me/joinchat/AAAA',
        'https://t.me/+abcdef',
        'https://t.me/share/url?url=x',
        'https://t.me/pricebot',
        'https://eitaa.com/ahan100marketing',
        'https://ble.ir/ahan100admin',
        'https://rubika.ir/989139595788',
        'https://ble.ir/join/Y2IyNTRkN2',
        'https://web.eitaa.com/#@ahan',
        'https://wa.me/989121234567',
        'https://www.instagram.com/p/Cabc123/',
        'https://www.google.com/search?q=x',
        'https://duckduckgo.com/?q=x',
        'https://trustseal.enamad.ir/?id=1',
        'https://shop.example/catalog.pdf',
        'ftp://shop.example/',
        'https://user:pw@shop.example/',
        'https://192.168.1.1/',
        'https://🌐www.tehran-ahan.com/',
        'http://%F0%9F%8C%90pivan.co/',
        'mailto:a@b.c',
        ''
      ]) {
        expect(classifyLink(u), isNull, reason: u);
      }
    });
    test('a website keeps its page and loses tracking noise', () {
      final a = classifyLink(
          'https://WWW.AhanShop.example/price/rebar/?utm_source=x&cat=2#top')!;
      expect(a.url, 'https://ahanshop.example/price/rebar?cat=2');
      expect(a.host, 'ahanshop.example');
      expect(a.part, FinderPart.sites);
      expect(classifyLink('https://ahanshop.example')!.key,
          'site:ahanshop.example/');
    });
    test('what the app already reads is known', () {
      final known = finderKnownKeys();
      expect(known, contains('telegram:ahanmelal'));
      expect(known, contains('host:ahanmelal.com'));
      final s = FinderState();
      expect(
          s.offer(classifyLink('https://t.me/ahanmelal')!,
              from: 'x', depth: 0, hinted: true, now: 1, known: known),
          false);
      expect(
          s.offer(classifyLink('https://ahanmelal.com/any/page')!,
              from: 'x', depth: 0, hinted: true, now: 1, known: known),
          false);
    });
  });

  group('evidence of selling goods', () {
    test('a short text needs one product and one trade word', () {
      expect(sellsGoods('کانال قیمت میلگرد'), true);
      expect(sellsGoods('پخش آهن آلات مشهد'), true);
      expect(sellsGoods('کانال آشپزی و قیمت طلا'), false);
      expect(sellsGoods('میلگرد'), false);
      expect(tradeEvidence('فروش تیرآهن و هاش').product, 'تیرآهن');
    });
    test('a whole page needs the subject to recur', () {
      final news = 'امروز در خبرها آمد که ورق تازه‌ای در پرونده باز شد. ' * 30;
      expect(news.length, greaterThan(600));
      expect(sellsGoods('$news قیمت'), false);
      expect(sellsGoods('$news قیمت میلگرد، فروش تیرآهن، خرید نبشی'), true);
    });
  });

  group('the questions of a round', () {
    test('rounds are small, ordered and walk through the whole bank', () {
      expect(FinderPlan.queries(FinderPart.sites, 0), [
        'قیمت میلگرد امروز',
        'قیمت تیرآهن امروز',
        'قیمت ورق امروز',
        'قیمت آهن مشهد',
        'آهن فروشی مشهد'
      ]);
      expect(FinderPlan.queries(FinderPart.domestic, 0).take(3), [
        'کانال ایتا قیمت آهن',
        'کانال بله قیمت آهن',
        'کانال روبیکا قیمت آهن'
      ]);
      for (final part in FinderPart.all) {
        final bank = FinderPlan.bank(part);
        expect(bank.toSet().length, bank.length, reason: 'no repeats');
        final asked = <String>{
          for (var r = 0; r < FinderPlan.cycleRounds; r++)
            ...FinderPlan.queries(part, r)
        };
        expect(asked, bank.toSet(), reason: 'every question is reached');
        expect(FinderPlan.queries(part, 1).toSet()
            .intersection(FinderPlan.queries(part, 0).toSet()), isEmpty);
      }
      expect(FinderPlan.bank(FinderPart.sites), contains('آهن فروشی بجنورد'));
      expect(FinderPlan.usesSiteOperator('site:t.me قیمت آهن'), true);
      expect(FinderPlan.usesSiteOperator('کانال تلگرام قیمت آهن'), false);
      expect(FinderPlan.tokens('site:eitaa.com قیمت میلگرد'), ['قیمت', 'میلگرد']);
    });
  });

  group('the remembered state', () {
    FinderLink link(String u) => classifyLink(u)!;
    test('a list completes when its work ends, then hands its entries over',
        () {
      final s = FinderState()..beginRound(100);
      expect(s.queue.where((t) => t.type == 'S').length,
          3 * FinderPlan.perRound);
      expect(s.offer(link('https://t.me/steelshop'),
          from: 'q', depth: 0, hinted: true, now: 100), true);
      expect(s.offer(link('https://t.me/s/SteelShop/9'),
          from: 'q', depth: 0, hinted: true, now: 100), false);
      // No reader for Instagram: listed only when found with evidence.
      expect(s.offer(link('https://instagram.com/ahan.page'),
          from: 'q', depth: 0, hinted: false, now: 100), false);
      expect(s.offer(link('https://instagram.com/ahan.page'),
          from: 'q', depth: 0, hinted: true, now: 100), true);
      expect(s.offer(link('https://t.me/toodeep'),
          from: 'q', depth: 3, hinted: true, now: 100), false);
      s.updateCompletion(100);
      expect(s.complete, [false, false, false]);
      s.queue.clear();
      s.updateCompletion(110);
      // The websites and the domestic list have nothing pending; the social
      // list still has an unread candidate.
      expect(s.complete, [true, false, true]);
      final e = s.nextToVerify({})!;
      expect(e.key, 'telegram:steelshop');
      s.confirm(e, name: 'فروشگاه آهن', contact: 'تلفن 05137654321');
      expect(e.handoff, '');
      s.updateCompletion(120);
      expect(s.complete, [true, true, true]);
      expect(s.completedAt, [110, 120, 110]);
      expect(e.handoff, 'wait');
      // The Instagram page stays on the list and is never handed over.
      final insta = s.entry('instagram:ahan.page')!;
      expect([insta.state, insta.handoff], ['unreadable', '']);
      expect(s.waiting(120).map((x) => x.key), ['telegram:steelshop']);
      // Found after completion: handed over as soon as it is confirmed.
      s.offer(link('https://t.me/latecomer'),
          from: 'x', depth: 1, hinted: true, now: 130);
      s.updateCompletion(130);
      expect(s.complete[FinderPart.social], true);
      s.confirm(s.entry('telegram:latecomer')!);
      s.updateCompletion(131);
      expect(s.waiting(131).length, 2);
    });
    test('the first searcher accepts, or rejects after three spaced attempts',
        () {
      final s = FinderState();
      s.offer(link('https://t.me/steelshop'),
          from: 'q', depth: 0, hinted: true, now: 1);
      final e = s.entry('telegram:steelshop')!
        ..state = 'ok'
        ..handoff = 'wait';
      s.verdict(e, rows: 0, note: 'ردیف قیمت پیدا نشد', now: 1000);
      expect([e.handoff, e.handoffTries], ['wait', 1]);
      expect(s.waiting(1000 + 3600), isEmpty);
      expect(s.waiting(1000 + FinderState.handoffRetrySeconds).single, e);
      s.verdict(e, rows: 0, note: 'x', now: 200000);
      s.verdict(e, rows: 0, note: 'x', now: 400000);
      expect(e.handoff, 'rejected');
      expect(s.waiting(900000), isEmpty);
      final other = FinderEntry(
          url: 'https://eitaa.com/ahanyar',
          kind: 'eitaa',
          key: 'eitaa:ahanyar',
          part: 2,
          state: 'ok',
          handoff: 'wait');
      s.lists[2].add(other);
      s.verdict(other, rows: 7, note: 'هوش جستجوگر ۱: 7 ردیف معتبر', now: 5);
      expect(other.handoff, 'accepted');
      expect(s.acceptedCount, 1);
    });
    test('after a short rest the next questions are asked', () {
      const t = 1800000000;
      final s = FinderState()..beginRound(t);
      s.queue.clear();
      s.offer(link('https://ble.ir/steelbale'),
          from: 'q', depth: 0, hinted: true, now: t);
      final e = s.entry('bale:steelbale')!;
      s
        ..failed(e, 'x')
        ..failed(e, 'x')
        ..failed(e, 'در سه نوبت در دسترس نبود');
      expect(e.state, 'unreachable');
      s.updateCompletion(t + 100);
      expect(s.allComplete, true);
      expect(s.roundCompletedAt, t + 100);
      expect(s.maybeNextRound(t + 160), false);
      expect(s.maybeNextRound(t + 100 + FinderState.roundRestSeconds), true);
      expect(s.round, 1);
      expect(s.queue.map((q) => q.value),
          containsAll(FinderPlan.queries(FinderPart.sites, 1)));
      // The lists stay open for hand-over while the new round works.
      expect(s.complete, [true, true, true]);
      // A place that could not be reached is tried again once a day, not
      // with every round.
      expect(e.state, 'unreachable');
      s.queue.clear();
      s.updateCompletion(t + 90000);
      expect(s.maybeNextRound(t + 90000 + FinderState.roundRestSeconds), true);
      expect([e.state, e.tries], ['new', 0]);
      // Once every question of the banks was asked, rounds are a day apart.
      s.round = FinderPlan.cycleRounds;
      s.queue.clear();
      s.discard(e);
      s.updateCompletion(t + 200000);
      expect(s.maybeNextRound(t + 200000 + FinderState.roundRestSeconds), false);
      expect(
          s.maybeNextRound(t + 200000 + FinderState.settledRestSeconds), true);
    });
    test('work that cannot be done now does not hold a list open', () {
      final s = FinderState()..beginRound(100);
      s.offer(link('https://t.me/steelshop'),
          from: 'q', depth: 0, hinted: true, now: 100);
      s.offer(link('https://ahanshop.example/'),
          from: 'q', depth: 0, hinted: true, now: 100);
      // Questions are waiting and candidates are unread: nothing is complete.
      s.updateCompletion(110);
      expect(s.complete, [false, false, false]);
      // No search page takes questions now, and Telegram does not answer on
      // this network: only the website list still has something to read.
      s.updateCompletion(120,
          askable: (_) => false, resting: (e) => e.kind == 'telegram');
      expect(s.complete, [false, true, true]);
      s.confirm(s.entry('site:ahanshop.example/')!, table: true);
      s.updateCompletion(130,
          askable: (_) => false, resting: (e) => e.kind == 'telegram');
      expect(s.complete, [true, true, true]);
      expect(s.waiting(130).single.key, 'site:ahanshop.example/');
      expect(s.unanswered(FinderPart.sites), FinderPlan.perRound);
      // The questions are still there and are asked when a page takes them;
      // the Telegram candidate is still unread and is read when it answers.
      expect(s.entry('telegram:steelshop')!.state, 'new');
      expect(s.roundCompletedAt, 130);
      s.updateCompletion(140);
      expect(s.roundCompletedAt, 0);
      expect(s.complete, [true, true, true]);
      // A list that already holds two rounds of unanswered questions gets no
      // more of them.
      s.round = 1;
      s.beginRound(150);
      s.round = 2;
      s.beginRound(160);
      expect(s.unanswered(FinderPart.sites), 2 * FinderPlan.perRound);
    });
    test('state survives storage; damaged pieces cost progress, not safety',
        () {
      final s = FinderState()..beginRound(100);
      s.addSeedPages(['https://ahanmelal.com/']);
      s.offer(link('https://t.me/steelshop'),
          from: 'جستجو: قیمت میلگرد', depth: 0, hinted: true, now: 100);
      s.offer(link('https://ahanshop.example/price?cat=2'),
          from: 'q', depth: 1, hinted: true, inner: true, now: 101);
      s.confirm(s.entry('telegram:steelshop')!,
          name: 'فروشگاه آهن', contact: 'مشهد 05137654321');
      s.discard(s.entry('site:ahanshop.example/price?cat=2')!);
      s.cooldown['ddg'] = 999;
      s.providerNote['gerdoo'] = 'ok|170';
      s.hostFails['eitaa.com'] = 1;
      s.revivedAt = 55;
      final stored = s.toSettings();
      expect(stored.keys.toSet(), FinderState.settingKeys.toSet());
      expect(stored.values.every((v) => v.length < 200000), true);
      final back = FinderState.fromSettings(stored);
      expect(back.queue.length, s.queue.length);
      expect(back.entry('telegram:steelshop')!.name, 'فروشگاه آهن');
      expect(back.entry('telegram:steelshop')!.contact, 'مشهد 05137654321');
      expect(back.knows('site:ahanshop.example/price?cat=2'), true);
      expect(back.cooldown['ddg'], 999);
      expect(back.providerNote, {'gerdoo': 'ok|170'});
      expect(back.hostFails, {'eitaa.com': 1});
      expect(back.revivedAt, 55);
      final broken = FinderState.fromSettings({
        ...stored,
        'finder.queue': '{not json',
        'finder.list.1': jsonEncode([
          {'u': 'javascript:alert(1)', 'k': 'telegram', 'a': 1},
          {'u': 'https://t.me/joinchat/xyz', 'k': 'telegram', 'a': 1},
          {'u': 'https://t.me/steelshop', 'k': 'eitaa', 'a': 1},
          {'u': 'https://t.me/realone', 'k': 'telegram', 'a': 1, 'ho': 'bogus'},
          {'u': 'https://t.me/goodone', 'k': 'telegram', 'a': 1},
        ])
      });
      expect(broken.queue, isEmpty);
      expect(broken.lists[1].map((e) => e.key), ['telegram:goodone']);
    });
    test('one seller cannot crowd the list; the three lists take turns', () {
      final s = FinderState();
      for (var i = 0; i < 14; i++) {
        s.offer(link('https://bigshop.example/price/$i'),
            from: 'q', depth: 0, hinted: true, now: i);
      }
      expect(s.lists[0].length, FinderState.maxPerHost);
      expect(FinderState.maxPerHost, 10);
      s.offer(link('https://eitaa.com/ahanyar'),
          from: 'q', depth: 1, hinted: true, now: 50);
      s.offer(link('https://t.me/steelshop'),
          from: 'q', depth: 1, hinted: true, now: 51);
      // By age and depth alone the websites would come first every time.
      expect(s.nextToVerify({})!.part, FinderPart.sites);
      expect(s.nextToVerify({}, prefer: FinderPart.social)!.key,
          'telegram:steelshop');
      expect(s.nextToVerify({}, prefer: FinderPart.domestic)!.key,
          'eitaa:ahanyar');
      // A list with nothing to read gives its turn away.
      s.discard(s.entry('eitaa:ahanyar')!);
      expect(s.nextToVerify({}, prefer: FinderPart.domestic)!.part,
          FinderPart.sites);
    });
    test('one reading each is a complete pass; a page that did not answer '
        'is continued later and holds nothing open', () {
      final s = FinderState()..startedAt = 1;
      for (final u in [
        'https://slow.example/',
        'https://ahanshop.example/',
        'https://fresh.example/'
      ]) {
        s.offer(link(u), from: 'q', depth: 0, hinted: true, now: 1);
      }
      final slow = s.entry('site:slow.example/')!,
          shop = s.entry('site:ahanshop.example/')!;
      s.failed(slow, 'x');
      expect([slow.state, slow.tries], ['new', 1]);
      s.updateCompletion(10);
      expect(s.complete[FinderPart.sites], false, reason: 'two are untried');
      // Every candidate gets its first reading before any gets a second.
      expect(s.nextToVerify({})!.key, 'site:ahanshop.example/');
      s.confirm(shop, table: true);
      expect(s.nextToVerify({})!.key, 'site:fresh.example/');
      s.discard(s.entry('site:fresh.example/')!);
      expect(s.nextToVerify({})!.key, 'site:slow.example/');
      s.updateCompletion(20);
      expect(s.complete[FinderPart.sites], true);
      expect(shop.handoff, 'wait');
      // The slow one is still a candidate and is read when it answers; found
      // to sell goods then, it is handed over like the rest.
      s.confirm(slow);
      s.updateCompletion(30);
      // A page that showed no price table is a seller on the list, not a
      // source to read: it is not handed over.
      expect([slow.state, slow.handoff], ['ok', '']);
      slow.table = true;
      s.updateCompletion(31);
      expect(slow.handoff, 'wait');
      // The same for a seller page that did not answer.
      final t = FinderState()..startedAt = 1;
      t.addSeedPages(['https://ahanmelal.com/']);
      t.updateCompletion(5);
      expect(t.allComplete, false);
      t.queue.single.tries = 1;
      t.updateCompletion(6);
      expect(t.allComplete, true);
    });
    test('state written by 0.9.3 continues with small rounds', () {
      final old = FinderState()..startedAt = 1700000000;
      old.offer(link('https://t.me/steelshop'),
          from: 'فهرست پژوهش برنامه', depth: 0, hinted: true, now: 5);
      old.confirm(old.entries.single, name: 'فروشگاه آهن');
      for (var i = 0; i < 52; i++) {
        old.queue.add(FinderTask('S', 'پرسش قدیمی $i', i % 3));
      }
      old.addSeedPages(['https://ahanmelal.com/']);
      old.cooldown['ddg'] = 1900000000;
      old.strikes = 4;
      final stored = old.toSettings();
      stored['finder.meta'] = jsonEncode(
          (jsonDecode(stored['finder.meta']!) as Map)..['v'] = 1);
      final s = FinderState.fromSettings(stored);
      // What was found and decided stays…
      expect(s.entry('telegram:steelshop')!.name, 'فروشگاه آهن');
      expect(s.queue.map((t) => t.type), ['P']);
      // …the one long round of questions and the rest of the search pages go.
      expect(s.cooldown, isEmpty);
      expect([s.startedAt, s.round], [0, 0]);
      s.beginRound(1800000000);
      expect(s.unanswered(FinderPart.sites), FinderPlan.perRound);
      // A state of this version is read back as it is.
      final again = FinderState.fromSettings(s.toSettings());
      expect(again.startedAt, 1800000000);
      expect(again.unanswered(FinderPart.sites), FinderPlan.perRound);
    });
    test('a full list stays inside the archive limit for one setting', () {
      final s = FinderState();
      for (var i = 0; i < 400; i++) {
        s.offer(link('https://shop$i.example/${'p' * 150}'),
            from: 'جستجو: ${'ق' * 200}', depth: 0, hinted: true, now: i);
      }
      expect(s.lists[0].length, FinderState.maxPerPart);
      expect(s.dropped, 150);
      for (final e in s.lists[0]) {
        s.confirm(e, name: 'ن' * 90, contact: 'ت' * 400, note: 'ی' * 300);
      }
      expect(s.toSettings()['finder.list.0']!.length, lessThan(200000));
    });
  });

  group('reading public pages', () {
    test('title, lines and every address, written or linked', () {
      final p = readFinderPage({
        'url': 'https://ahanshop.example/about/',
        'body': '<html><head><title> آهن شاپ </title>'
            '<meta name="description" content="فروش میلگرد"><script>var a="https://t.me/hidden";</script></head>'
            '<body><p>آدرس: مشهد، بلوار توس</p><p>تلفن 05137654321</p>'
            '<a href="/price/rebar">قیمت میلگرد</a><a href="https://t.me/steelshop">تلگرام</a>'
            '<a href="tel:051">تماس</a><a href="#top">بالا</a>'
            '<footer>ایتا: eitaa.com/ahanyar</footer></body></html>'
      });
      expect(p.title, 'آهن شاپ');
      expect([p.site, p.table], ['', false]);
      final priced = readFinderPage({
        'url': 'https://ahanshop.example/price',
        'body': '<head><meta property="og:site_name" content="آهن شاپ"></head>'
            '<body><table><tr><th>محصول</th><th>قیمت</th></tr></table></body>'
      });
      expect([priced.site, priced.table], ['آهن شاپ', true]);
      expect(p.text, contains('فروش میلگرد'));
      expect(p.text.split('\n'), contains('تلفن 05137654321'));
      expect(p.text, isNot(contains('hidden')));
      expect(p.links.map((a) => a.url), [
        'https://ahanshop.example/price/rebar',
        'https://t.me/steelshop',
        'https://eitaa.com/ahanyar'
      ]);
      expect(Searcher.contactLines(p.text), contains('05137654321'));
    });
    test('a page is judged where it is read: sells, contact, size', () {
      final shop = judgeFinderPage({
        'url': 'https://ahanshop.example/',
        'body': channel('آهن شاپ', '$steelPost<p>تلفن 05137654321</p>')
      });
      expect([shop.sells, shop.title], [true, 'آهن شاپ']);
      expect(shop.contact, contains('05137654321'));
      final empty = judgeFinderPage({
        'url': 'https://t.me/s/nopreview',
        'body': channel('کانال', '')
      });
      expect(empty.sells, false);
      expect(empty.textLength, lessThan(200));
    });
    test('a real observed search answer page yields its result addresses', () {
      final body =
          File('test/fixtures/finder_ddg_observed.html').readAsStringSync();
      final r = readSearchResults({'provider': 'ddg', 'body': body});
      expect(r.length, 10);
      expect(r.first.url, 'https://eitaa.com/fiahan1/41');
      expect(r.map((a) => a.url), contains('https://t.me/moshaveranahan'));
      expect(r.every((a) => !a.url.contains('duckduckgo')), true);
      expect(classifyLink(r.first.url)!.key, 'eitaa:fiahan1');
      expect(saysNoResults(body), false);
    });
    test('wrapped result links are opened, never guessed', () {
      final target = base64Url
          .encode(utf8.encode('https://ahanshop.example/price'))
          .replaceAll('=', '');
      expect(
          unwrapResultLink(
              'https://www.bing.com/ck/a?!&&p=1&u=a1$target&ntb=1'),
          'https://ahanshop.example/price');
      expect(unwrapResultLink('https://www.bing.com/ck/a?u=zz'), isNull);
      expect(
          unwrapResultLink(
              '//duckduckgo.com/l/?uddg=https%3A%2F%2Ft.me%2Fsteelshop&rut=1'),
          'https://t.me/steelshop');
      expect(unwrapResultLink('//duckduckgo.com/l/?uddg='), isNull);
      expect(unwrapResultLink('https://ahanshop.example/a'),
          'https://ahanshop.example/a');
      // Links back to the search page itself are never results.
      final r = readSearchResults({
        'provider': 'bing',
        'body': '<rss><channel><item><title>فروش آهن</title>'
            '<link>https://ahanshop.example/price?a=1&amp;b=2</link>'
            '<description>قیمت میلگرد</description></item>'
            '<item><title>x</title><link>https://www.bing.com/x</link>'
            '<description>y</description></item></channel></rss>'
      });
      expect(r.single.url, 'https://ahanshop.example/price?a=1&b=2');
      expect(r.single.text, 'فروش آهن قیمت میلگرد');
    });
  });

  group('real observed answer pages', () {
    test('Gerdoo links its results directly', () {
      final body =
          File('test/fixtures/finder_gerdoo_observed.html').readAsStringSync();
      final r = readSearchResults({'provider': 'gerdoo', 'body': body});
      expect(r.length, greaterThanOrEqualTo(8));
      expect(r.map((a) => a.url),
          contains('https://eshia.ir/feqh/archive/text/javadi/tafsir/64/640606/'));
      expect(r.every((a) => !a.url.contains('gerdoo.me')), true);
      expect(r.every((a) => !a.url.contains('google.com')), true);
      // Each result carries its own title and summary, not the whole page.
      final first = r.firstWhere((a) => a.url.contains('aparat.com/v/'));
      expect(first.text, contains('سوره بقره'));
      expect(first.text.length, lessThanOrEqualTo(300));
      expect(answersQuestion('آیه ۲۸ سوره بقره', r), true);
      expect(answersQuestion('قیمت میلگرد امروز', r), false);
    });
    test('Bing answers in its RSS form with plain addresses', () {
      final body =
          File('test/fixtures/finder_bing_rss_observed.xml').readAsStringSync();
      final r = readSearchResults({'provider': 'bing', 'body': body});
      expect(r.length, 10);
      expect(r.every((a) => a.url.startsWith('http')), true);
      expect(r.every((a) => !a.url.contains('bing.com')), true);
      expect(answersQuestion('rebar price', r), true);
      expect(answersQuestion('قیمت میلگرد', r), false);
    });
    test('a directory page gives the channel it describes', () {
      final body = File('test/fixtures/finder_directory_observed.html')
          .readAsStringSync();
      final p = readFinderPage(
          {'url': 'https://mychannels.ir/eitaa/economic/webgram', 'body': body});
      expect(p.links.map((a) => a.url), contains('https://eitaa.com/webgram'));
      expect(webAddressOf('tg://resolve?domain=steelshop'),
          'https://t.me/steelshop');
      expect(webAddressOf('et://resolve?domain='), isNull);
      expect(webAddressOf('https://resolve/?domain=x'), isNull);
      expect(isDirectoryHost('mychannels.ir'), true);
      expect(isDirectoryHost('ahanonline.com'), false);
    });
  });

  group('a website nobody wrote an adapter for', () {
    List<Quote> read(String fixture, {bool owned = true}) => PublicTables.read(
        body: File('test/fixtures/$fixture.html').readAsStringSync(),
        url: 'https://seller.example/price',
        endpoint: 'finder-site-x',
        seller: 'seller.example',
        city: 'نامشخص',
        category: 'عمومی',
        fetchedAt: DateTime.utc(2026, 11, 11),
        headingOwned: owned);
    SearcherResult judge(List<Quote> rows) => Searcher.process(rows,
        now: DateTime.utc(2026, 11, 11, 12), windowDays: 30);

    test('a real price table whose rows name the product in a hidden cell',
        () {
      // The reader of the registered sources finds nothing here…
      expect(read('site_ahanonline_size_observed', owned: false), isEmpty);
      // …the heading-owned reading finds every row.
      final rows = read('site_ahanonline_size_observed');
      expect(rows.length, 21);
      final first = rows.first;
      expect(first.title, 'میلگرد 8 پردیس آجدار A2 کارخانه');
      expect(first.brand, 'پردیس');
      expect([first.amount, first.currency, first.unit],
          [126820.0, 'تومان', 'kg']);
      expect(first.loading, 'کارخانه');
      expect(first.details['مبنای نام کالا'], 'سلول نام کالا در همان ردیف');
      expect(first.details['مبنای تاریخ'], 'تاریخ صریح پیش از جدول');
      expect(first.sourceDateRaw, isNotEmpty);
      expect(judge(rows).quotes.length, 21);
    });
    test('rows inherit the product from the heading that owns the table', () {
      final rows = read('site_alanchand_observed');
      expect(rows, isNotEmpty);
      expect(rows.every((q) => q.title.startsWith('تیرآهن 14 ')), true);
      expect(rows.first.details['مبنای نام کالا'], 'سرعنوان پیش از جدول');
      // The unit is the one written in the price header, «تومان/کیلو».
      expect(rows.every((q) => q.unit == 'kg' && q.currency == 'تومان'), true);
      expect(rows.first.details['مبنای واحد'], 'واحد نوشته‌شده در سرستون قیمت');
      // «۲۰ آبان» has no year: the date stays unknown, it is not completed.
      expect(rows.every((q) => q.sourceDateRaw.isEmpty), true);
      expect(judge(rows).quotes, isNotEmpty);
    });
    test('each section names its own table in its <header>', () {
      // The real page: 31 per-brand sections under one h1. Each section's
      // header says which brand its table is; the first one is the median.
      final rows = read('site_ahanonline_category_observed');
      expect(rows, isNotEmpty);
      expect(rows.any((q) => q.title.contains('میانه')), false);
      final brands =
          rows.map((q) => q.title.replaceFirst(RegExp(r' [\d.]+$'), '')).toSet();
      expect(brands, {'میلگرد ظفر بناب', 'میلگرد نیشابور'});
      expect(rows.first.details['مبنای نام کالا'], 'سرعنوان پیش از جدول');
      expect(rows.first.details['مبنای تاریخ'], 'تاریخ نوشته‌شده درون جدول');
      expect(rows.every((q) => q.currency == 'تومان' && q.amount != null), true);
      // No unit is written for these tables, so none is assumed.
      expect(rows.every((q) => q.unit == 'unknown'), true);
      expect(judge(rows).quotes.length, rows.length);
    });
    test('what cannot be told apart, or is not a price list, is not read', () {
      // Several tables under one heading with nothing written to tell them
      // apart: which brand each one is cannot be read, so none is.
      const twin = '<table><tr><th>سایز</th><th>قیمت (تومان)</th></tr>'
          '<tr><td>12</td><td>105,000</td></tr></table>';
      List<Quote> page(String body) => PublicTables.read(
          body: body,
          url: 'u',
          endpoint: 'e',
          seller: 's',
          city: 'نامشخص',
          category: 'عمومی',
          fetchedAt: DateTime.utc(2026, 11, 11),
          headingOwned: true);
      expect(page('<h1>قیمت میلگرد آجدار</h1>$twin$twin'), isEmpty);
      expect(page('<h1>قیمت میلگرد آجدار</h1>$twin').single.title,
          'میلگرد آجدار 12');
      // A table under a title that announces a median or a chart is not a
      // list of offers, whatever product the page is about.
      expect(page('<h1>قیمت میلگرد</h1><h2>میانه قیمت میلگرد</h2>$twin'),
          isEmpty);
      // Averages, lowest and highest: statistics, not offers.
      expect(read('site_foolad24_stats_observed'), isEmpty);
      // The history of one price.
      final history = PublicTables.read(
          body: '<h2>روند تغییرات قیمت پروفیل</h2><table>'
              '<tr><th>تاریخ</th><th>قیمت (تومان)</th></tr>'
              '<tr><td>1405/08/20</td><td>175,000</td></tr></table>',
          url: 'u',
          endpoint: 'e',
          seller: 's',
          city: 'نامشخص',
          category: 'عمومی',
          fetchedAt: DateTime.utc(2026, 11, 11),
          headingOwned: true);
      expect(history, isEmpty);
      expect(PublicTables.ownerPhrase('روند تغییرات قیمت پروفیل'), '');
      expect(PublicTables.ownerPhrase('عملکرد'), '');
      expect(PublicTables.ownerPhrase('قیمت میلگرد ۸'), 'میلگرد 8');
      expect(PublicTables.ownerPhrase('لیست قیمت ورق سیاه امروز | آهن فلان'),
          'ورق سیاه');
      expect(PublicTables.ownerPhrase('قیمت تیرآهن ۱۴ به تفکیک کارخانه'),
          'تیرآهن 14');
    });
    test('a small seller: one heading, one table of sizes and prices', () {
      final rows = PublicTables.read(
          body: '<h2>قیمت میلگرد</h2><p>آخرین بروزرسانی: 1405/08/20</p>'
              '<table><thead><tr><th>سایز</th><th>قیمت هر کیلو (تومان)</th></tr></thead>'
              '<tbody><tr><td>12</td><td>105,000</td></tr>'
              '<tr><td>14</td><td>تماس بگیرید</td></tr>'
              '<tr><td colspan="2">آخرین بروز رسانی : 1405/8/21</td></tr></tbody></table>',
          url: 'u',
          endpoint: 'e',
          seller: 's',
          city: 'مشهد',
          category: 'عمومی',
          fetchedAt: DateTime.utc(2026, 11, 12),
          headingOwned: true);
      expect(rows.map((q) => q.title), ['میلگرد 12', 'میلگرد 14']);
      expect([rows[0].amount, rows[0].unit, rows[0].currency],
          [105000.0, 'kg', 'تومان']);
      expect(rows[1].amount, isNull);
      expect(rows[0].details['مبنای تاریخ'], 'تاریخ نوشته‌شده درون جدول');
      expect(rows[0].details['تاریخ متن منبع'], '1405/8/21');
      // Nothing is invented for the registered sources: without the mode the
      // same page yields nothing, exactly as before.
      expect(read('site_alanchand_observed', owned: false), isEmpty);
    });
  });

  group('the place is decided by the first searcher', () {
    test('address, then landline; a mobile names no city', () {
      expect(Searcher.placeOfText('آدرس: مشهد، بلوار توس ۷').city, 'مشهد');
      final phone = Searcher.placeOfText('تلفن 05137654321');
      expect(phone.city, isNotEmpty);
      expect(phone.basis, contains('تلفن ثابت'));
      expect(Searcher.placeOfText('09151234567').city, '');
      expect(Searcher.placeOfText('  ').city, '');
    });
  });

  group('the list builder at work', () {
    late MarketStore store;
    setUp(() async => store = await memory());
    tearDown(() async => store.close());

    http.Response world(http.Request request) {
      final u = request.url;
      if (u.host == 'html.duckduckgo.com') {
        final q = u.queryParameters['q']!;
        if (q == 'قیمت میلگرد امروز') {
          return page(duck({
            'https://ahanshop.example/': 'فروش آهن آلات و قیمت میلگرد',
            'https://news.example/sport': 'اخبار ورزشی امروز',
            'https://t.me/steelshop': 'کانال قیمت میلگرد',
            'https://t.me/cooking': 'آشپزی',
            'https://www.instagram.com/ahan.page/': 'پیج فروش آهن آلات',
          }));
        }
        return page('<html><body><div class="no-results">No results</div></body></html>');
      }
      switch (u.toString()) {
        case 'https://t.me/s/steelshop':
          return page(channel('فروشگاه آهن توس',
              '$steelPost<p>آدرس: مشهد، بلوار توس</p><p>تلفن 05137654321</p>'
              '<a href="https://ble.ir/steelbale">بله</a>'
              '<a href="https://t.me/steelshop/55">پست</a>'
              '<a href="https://steelsite.example/">سایت ما</a>'));
        case 'https://t.me/s/cooking':
          return page(channel('آشپزی', '<p>طرز تهیه کیک و شیرینی</p>' * 40));
        case 'https://ble.ir/s/steelbale':
          return page(channel('آهن توس در بله', steelPost));
        case 'https://steelsite.example/':
          return page(channel('وب‌سایت ما', '<p>درباره ما و تماس</p>' * 50));
        case 'https://ahanshop.example/':
          return page(channel('آهن شاپ',
              '$steelPost<a href="/price/rebar">قیمت میلگرد</a>'
              '<a href="/blog/x">مقاله</a><a href="https://rubika.ir/ahanshop">روبیکا</a>'
              '<a href="https://other-shop.example/">همکاران</a>'));
        case 'https://ahanshop.example/price/rebar':
          return page(channel('قیمت میلگرد',
              '$steelPost<table><tr><th>محصول</th><th>قیمت (تومان)</th></tr>'
              '<tr><td>میلگرد 14</td><td>38,500</td></tr></table>'
              '<a href="/price/beam">قیمت تیرآهن</a>'));
        case 'https://rubika.ir/ahanshop':
          return page(channel('آهن شاپ', '<p>کانال فروش میلگرد</p>'));
        case 'https://probe.example/':
          return page('ok');
      }
      return page('not found', 404);
    }

    Future<void> drain(SourceFinder f) async {
      for (var i = 0; i < 40; i++) {
        final r = await f.runSlice(maxSteps: 25);
        if (r.idle) return;
      }
      fail('the round did not end');
    }

    test('questions, readings and links fill the three lists to completion',
        () async {
      final f = finderOn(store, (r) async => world(r));
      await drain(f);
      final s = f.state;
      expect(s.complete, [true, true, true]);
      expect(s.queue, isEmpty);
      expect(s.lists[0].map((e) => e.key).toSet(), {
        'site:ahanshop.example/',
        'site:ahanshop.example/price/rebar',
      });
      // The inner page is not followed further and other sites are not taken
      // from a website; the unrelated pages left the lists.
      expect(s.knows('site:steelsite.example/'), true);
      expect(s.knows('telegram:cooking'), true);
      expect(s.entry('site:news.example/sport'), isNull);
      expect(s.lists[1].map((e) => '${e.key}/${e.state}').toSet(),
          {'telegram:steelshop/ok', 'instagram:ahan.page/unreadable'});
      expect(s.lists[2].map((e) => e.key).toSet(),
          {'bale:steelbale', 'rubika:ahanshop'});
      final shop = s.entry('telegram:steelshop')!;
      expect(shop.name, 'فروشگاه آهن توس');
      expect(shop.contact, contains('05137654321'));
      expect(s.entry('site:ahanshop.example/price/rebar')!.inner, true);
      // Complete lists are open: every confirmed entry the app can read
      // prices from is waiting. The seller's front page showed no price table:
      // it stays on the list as a seller and its price page is handed over.
      final batch = f.handoffBatch(limit: 20);
      expect(batch.map((h) => h.endpoint.id).toSet(), {
        'public-telegram-steelshop',
        'public-bale-steelbale',
        'public-rubika-ahanshop',
        'finder-site-${finderHash('https://ahanshop.example/price/rebar')}',
      });
      final front = s.entry('site:ahanshop.example/')!;
      expect([front.state, front.table, front.handoff], ['ok', false, '']);
      final telegram =
          batch.firstWhere((h) => h.entry.key == 'telegram:steelshop');
      expect(telegram.endpoint.url, 'https://t.me/s/steelshop');
      expect(telegram.endpoint.sellerCity, 'مشهد');
      expect(telegram.entry.cityBasis, 'آدرس نوشته‌شده در متن');
      expect(telegram.endpoint.defaultEnabled, false);
      final site = batch.firstWhere((h) => h.entry.inner);
      expect([site.endpoint.parser, site.endpoint.category],
          ['site-table', 'عمومی']);
      // The seller of a website is its host, not the sentence in its title.
      expect(site.entry.name, 'قیمت میلگرد');
      expect(site.endpoint.name, 'ahanshop.example');
    });

    test('two readings at a time at most, never two on one host', () async {
      final inflight = <String, int>{};
      var most = 0, sameHost = 0;
      final f = finderOn(store, (r) async {
        final host = r.url.host;
        inflight[host] = (inflight[host] ?? 0) + 1;
        if (inflight[host]! > 1) sameHost++;
        final all = inflight.values.fold<int>(0, (a, b) => a + b);
        if (all > most) most = all;
        await Future<void>.delayed(const Duration(milliseconds: 4));
        inflight[host] = inflight[host]! - 1;
        if (host == 'html.duckduckgo.com') {
          return page('<div class="no-results">No results</div>');
        }
        return page(channel('فروشگاه آهن', steelPost));
      });
      await f.seed(candidates: [
        for (var i = 0; i < 6; i++) 'https://t.me/steelshop$i',
        for (var i = 0; i < 6; i++) 'https://shop$i.example/',
        for (var i = 0; i < 4; i++) 'https://eitaa.com/ahanyar$i',
      ], pages: [
        'https://seller1.example/',
        'https://seller2.example/'
      ]);
      await drain(f);
      expect(most, 2);
      expect(sameHost, 0);
      expect(f.state.entries.where((e) => e.state == 'ok').length, 16);
      expect(f.state.complete, [true, true, true]);
    });

    test('progress is stored after every step and continued by a new run',
        () async {
      final first = finderOn(store, (r) async => world(r));
      await first.runSlice(maxSteps: 3);
      expect(first.state.allComplete, false);
      final stepsDone = first.state.searches + first.state.pages;
      expect(stepsDone, greaterThan(0));
      // A different run (the background task, or the app next time).
      final second = finderOn(store, (r) async => world(r));
      await second.load();
      expect(second.state.searches + second.state.pages, stepsDone);
      expect(second.state.queue.length, first.state.queue.length);
      await drain(second);
      expect(second.state.allComplete, true);
      // The first run notices the other one wrote and does not undo its work.
      await first.sync();
      expect(first.state.allComplete, true);
      expect(first.state.lists[2].length, 2);
    });

    test('offline: nothing is lost and nothing is counted as a failure',
        () async {
      var online = false;
      final f = finderOn(store, (r) async {
        if (!online) throw const SocketException('no network');
        return world(r);
      });
      await f.seed(candidates: ['https://t.me/steelshop']);
      final before = await f.runSlice(maxSteps: 20);
      expect(before.offline, true);
      // One question and one candidate: the slice ran out of work while
      // everything it tried failed, and nothing else answered either.
      expect(before.steps, 2);
      final s = f.state;
      expect(s.lastOnlineAt, 0);
      expect(s.entry('telegram:steelshop')!.tries, 0);
      expect(s.entry('telegram:steelshop')!.state, 'new');
      expect(s.cooldown, isEmpty);
      expect(s.providerNote, isEmpty);
      expect(s.queue.where((t) => t.type == 'S').length,
          FinderPart.all.fold<int>(
              0, (n, p) => n + FinderPlan.queries(p, 0).length));
      expect(s.lastError, contains('اینترنت'));
      online = true;
      await drain(f);
      expect(f.state.allComplete, true);
      expect(f.state.lastOnlineAt, greaterThan(0));
      expect(f.state.entry('telegram:steelshop')!.state, 'ok');
    });

    test('a dead host is not mistaken for being offline', () async {
      final f = finderOn(store, (r) async {
        if (r.url.host == 'eitaa.com') throw const SocketException('filtered');
        if (r.url.host == 'html.duckduckgo.com') {
          return page('<div class="no-results">No results</div>');
        }
        return world(r);
      });
      await f.seed(candidates: [
        for (var i = 0; i < 5; i++) 'https://eitaa.com/ahanyar$i',
        'https://t.me/steelshop'
      ]);
      var now = DateTime.utc(2026, 11, 11, 8);
      final timed = SourceFinder(store,
          client: f.client,
          pageGap: Duration.zero,
          searchGap: Duration.zero,
          providers: duckOnly,
          probes: const ['https://probe.example/'],
          clock: () => now);
      final timeline = <bool>[];
      for (var i = 0; i < 6; i++) {
        final r = await timed.runSlice(maxSteps: 60);
        expect(r.offline, false);
        timeline.add(timed.state.complete[FinderPart.domestic]);
        now = now.add(const Duration(minutes: 11));
      }
      final s = timed.state;
      // The dead host did not hold the list open: it was complete from the
      // first slice, while its candidates were still being retried.
      expect(timeline.first, true);
      expect(s.allComplete, true);
      expect(s.entry('telegram:steelshop')!.state, 'ok');
      expect(
          s.lists[2].where((e) => e.key.startsWith('eitaa:ahanyar')).map((e) => e.state).toSet(),
          {'unreachable'});
      // Unreachable places are kept and never handed over.
      expect(timed.handoffBatch(limit: 20).map((h) => h.entry.kind).toSet(),
          isNot(contains('eitaa')));
    });

    test('an unreachable search page does not stop the work: the next one is '
        'asked, and without any the lists still complete', () async {
      // The reported case: DuckDuckGo cannot be reached from this network.
      final asked = <String>[];
      String gerdoo(Map<String, String> results) => '<html><body>${[
            for (final e in results.entries)
              '<div class="search-result-wrapper"><a href="${e.key}"><div>${Uri.parse(e.key).host}</div></a>'
                  '<a href="${e.key}">${e.value}</a><div>${e.value}</div></div>'
          ].join()}<a href="https://gerdoo.me/settings/">تنظیمات</a></body></html>';
      final f = finderOn(store, (r) async {
        asked.add(r.url.host);
        if (r.url.host == 'html.duckduckgo.com') {
          throw const SocketException('filtered');
        }
        if (r.url.host == 'www.bing.com') throw const SocketException('down');
        if (r.url.host == 'gerdoo.me') {
          final q = r.url.queryParameters['query']!;
          expect(FinderPlan.usesSiteOperator(q), false,
              reason: 'Gerdoo ignores site:, such questions are not sent to it');
          return page(q == 'قیمت میلگرد امروز'
              ? gerdoo({
                  'https://ahanshop.example/': 'فروش آهن آلات و قیمت میلگرد',
                  'https://eitaa.com/ahanyar': 'کانال ایتا قیمت میلگرد'
                })
              : '<html><body><p>نتیجه‌ای یافت نشد</p></body></html>');
        }
        if (r.url.toString() == 'https://eitaa.com/ahanyar') {
          return page(channel('آهن‌یار', steelPost));
        }
        return world(r);
      }, providers: [
        finderProviders.firstWhere((p) => p.id == 'ddg'),
        finderProviders.firstWhere((p) => p.id == 'gerdoo'),
        finderProviders.firstWhere((p) => p.id == 'bing'),
      ]);
      await drain(f);
      final s = f.state;
      expect(asked.where((h) => h == 'html.duckduckgo.com').length, 1,
          reason: 'left alone after the first failure');
      expect(s.providerNote['ddg'], startsWith('net|'));
      expect(s.providerNote['gerdoo'], startsWith('ok|'));
      expect(s.complete, [true, true, true]);
      expect(s.entry('eitaa:ahanyar')!.handoff, 'wait');
      expect(s.entry('site:ahanshop.example/')!.from,
          'جستجو (گردو): قیمت میلگرد امروز');
      // Only the site: questions are still waiting — for a page that honours
      // the operator — and they do not hold the lists open.
      expect(s.queue.every((t) => FinderPlan.usesSiteOperator(t.value)), true);
      expect(s.queue, isNotEmpty);
      expect(f.report(), contains('ddg=net'));
      expect(f.report(), contains('gerdoo=ok'));

    });

    test('with no search page at all the lists are completed from the links '
        'sellers publish themselves, and hand-over still opens', () async {
      final g = finderOn(store, (r) async {
        if (['html.duckduckgo.com', 'gerdoo.me', 'www.bing.com']
            .contains(r.url.host)) {
          throw const SocketException('unreachable');
        }
        return world(r);
      }, providers: finderProviders);
      await g.seed(candidates: ['https://t.me/steelshop']);
      await drain(g);
      expect(g.state.complete, [true, true, true]);
      expect(g.state.searches, 0);
      expect(g.state.unanswered(FinderPart.sites), FinderPlan.perRound);
      expect(g.handoffBatch(limit: 10).map((h) => h.entry.key),
          containsAll(['telegram:steelshop', 'bale:steelbale']));
      expect(g.state.lastOnlineAt, greaterThan(0));
    });

    test('a refusing or misleading search page is left alone, not argued with',
        () async {
      final asked = <String>[];
      final f = finderOn(store, (r) async {
        asked.add(r.url.host);
        if (r.url.host == 'html.duckduckgo.com') return page('', 202);
        if (r.url.host == 'www.bing.com') {
          // Results that have nothing to do with the question.
          return page('<rss><channel><item><title>Outlook.com</title>'
              '<link>https://www.outlook.com</link>'
              '<description>Official Site</description></item></channel></rss>');
        }
        return world(r);
      }, providers: [
        finderProviders.firstWhere((p) => p.id == 'ddg'),
        finderProviders.firstWhere((p) => p.id == 'bing'),
      ]);
      await f.runSlice(maxSteps: 6);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(f.state.cooldown['ddg']! - now, closeTo(3 * 3600, 60));
      expect(f.state.cooldown['bing']! - now, closeTo(3600, 60));
      expect(asked.where((h) => h == 'html.duckduckgo.com').length, 1);
      expect(asked.where((h) => h == 'www.bing.com').length, 1);
      expect(f.state.providerNote['ddg'], startsWith('refused|'));
      expect(f.state.providerNote['bing'], startsWith('unreadable|'));
      // Nothing from the misleading answer reached the lists, the question
      // was not counted as answered, and the lists are not held open.
      expect(f.state.entries, isEmpty);
      expect(f.state.searches, 0);
      expect(f.state.unanswered(FinderPart.sites), FinderPlan.perRound);
      final r = await f.runSlice(maxSteps: 5);
      expect(r.idle, true);
      expect(f.state.allComplete, true);
    });

    test('a completed list is handed over without waiting for a refresh',
        () async {
      final fixture =
          File('test/fixtures/site_ahanonline_size_observed.html')
              .readAsStringSync();
      final s = FinderState()..startedAt = 1;
      s.offer(classifyLink('https://ahanonline.example/price/rebar-8')!,
          from: 'جستجو (گردو): قیمت میلگرد امروز',
          depth: 0,
          hinted: true,
          now: 1);
      s.confirm(s.entries.single,
          name: 'قیمت میلگرد 8', contact: 'تلفن 02154712000', table: true);
      s.updateCompletion(2);
      for (final e in s.toSettings().entries) {
        await store.setSetting(e.key, e.value);
      }
      final c = MarketController(store,
          client: SourceClient(
              client: MockClient((r) async => page(fixture))));
      try {
        c.enabled = {};
        await c.setDiscoveryDays(0);
        expect(await c.deliverFinderNow(), 1);
        final e = c.finder.state.entries.single;
        expect([e.handoff, e.applied], ['accepted', true]);
        final id = 'finder-site-${finderHash(e.url)}';
        expect(c.enabled, {id});
        final route = c.availableEndpoints.singleWhere((x) => x.id == id);
        expect([route.parser, route.name, route.sellerCity],
            ['site-table', 'ahanonline.example', 'تهران']);
        expect(c.quotes.length, 21);
        expect(c.quotes.every((q) => q.category == 'میلگرد'), true);
        // Nothing waits any more, so the next call has nothing to do.
        expect(await c.deliverFinderNow(), 0);
      } finally {
        c.dispose();
      }
    });

    test('a refresh hands waiting entries to the first searcher', () async {
      final fixture =
          File('test/fixtures/ghanbari_sheets_observed.html').readAsStringSync();
      final s = FinderState()..startedAt = 1;
      for (final u in [
        'https://t.me/ghanbari_found',
        'https://emptyshop.example/price'
      ]) {
        s.offer(classifyLink(u)!, from: 'q', depth: 0, hinted: true, now: 1);
      }
      for (final e in s.entries.toList()) {
        s.confirm(e,
            name: 'یافته', contact: 'آدرس: مشهد، بلوار توس', table: true);
      }
      s.updateCompletion(2);
      expect(s.waiting(2).length, 2);
      for (final e in s.toSettings().entries) {
        await store.setSetting(e.key, e.value);
      }
      final c = MarketController(store,
          client: SourceClient(client: MockClient((r) async {
        if (r.url.host == 't.me') return page(fixture);
        return page(channel('فروشگاه', '<p>قیمت‌ها را تلفنی بپرسید</p>'));
      })));
      try {
        c.enabled = {};
        await c.setDiscoveryDays(0);
        await c.refresh();
        final accepted = c.finder.state.entry('telegram:ghanbari_found')!;
        expect(accepted.handoff, 'accepted');
        expect(accepted.applied, true);
        expect(accepted.city, 'مشهد');
        expect(c.availableEndpoints.map((e) => e.id),
            contains('public-telegram-ghanbari_found'));
        expect(c.enabled, {'public-telegram-ghanbari_found'});
        expect(jsonDecode((await store.setting('enabled'))!),
            ['public-telegram-ghanbari_found']);
        expect(c.quotes, isNotEmpty);
        expect(c.quotes.every((q) => q.sellerCity == 'مشهد'), true);
        final refused = c.finder.state.entry('site:emptyshop.example/price')!;
        expect([refused.handoff, refused.handoffTries], ['wait', 1]);
        expect(refused.note, isNotEmpty);
        // A refused entry is not a route: no status row, not listed.
        final site = 'finder-site-${finderHash('https://emptyshop.example/price')}';
        expect(c.states.containsKey(site), false);
        expect(c.availableEndpoints.any((e) => e.id == site), false);
        // The accepted source is an ordinary route: the user can switch it off
        // and it stays off.
        await c.setEnabled('public-telegram-ghanbari_found', false);
        await c.applyFinderAccepted();
        expect(c.enabled, isEmpty);
      } finally {
        c.dispose();
      }
      // The next start still knows the accepted route.
      final next = MarketController(store);
      try {
        await next.finder.load(force: true);
        expect(next.finder.acceptedEndpoints().single.id,
            'public-telegram-ghanbari_found');
      } finally {
        next.dispose();
      }
    });

    testWidgets('the information tab shows the three lists', (t) async {
      await t.binding.setSurfaceSize(const Size(360, 780));
      addTearDown(() => t.binding.setSurfaceSize(null));
      late MarketController c;
      await t.runAsync(() async {
        c = MarketController(await memory());
        final s = c.finder.state..beginRound(1);
        s.offer(classifyLink('https://t.me/steelshop')!,
            from: 'جستجو: قیمت میلگرد', depth: 0, hinted: true, now: 1);
        s.confirm(s.entries.single, name: 'فروشگاه آهن توس');
      });
      await t.pumpWidget(MaterialApp(
          home: Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                  body: ListView(children: [FinderPanel(c: c)])))));
      expect(find.textContaining('هوش جستجوگر ۲'), findsWidgets);
      for (final title in FinderPart.titles) {
        expect(find.textContaining('$title •'), findsOneWidget);
      }
      expect(find.textContaining('صفحه‌های جستجو'), findsOneWidget);
      expect(find.textContaining('کپی گزارش وضعیت'), findsOneWidget);
      final tile = find.textContaining('${FinderPart.titles[1]} •');
      await t.ensureVisible(tile);
      await t.pumpAndSettle();
      await t.tap(tile);
      await t.pumpAndSettle();
      expect(find.text('فروشگاه آهن توس'), findsOneWidget);
      expect(find.textContaining('منتظر تکمیل فهرست'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        c.dispose();
        await c.store.close();
      });
    });
  });
}
