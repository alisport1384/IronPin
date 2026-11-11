import 'package:flutter/material.dart';
import 'dart:async';
import '../data/app_logger.dart';
import 'package:url_launcher/url_launcher.dart';
import '../domain/market.dart';

const ink = Color(0xff122c3d),
    teal = Color(0xff008c82),
    muted = Color(0xff657786);
String fmt(num? value, {int decimals = 0}) {
  if (value == null) return '—';
  final s = value.toStringAsFixed(decimals).split('.');
  final n = s[0]
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]}٬');
  final out = decimals > 0 ? '$n٫${s[1]}' : n;
  const en = '0123456789', fa = '۰۱۲۳۴۵۶۷۸۹';
  var r = out;
  for (var i = 0; i < 10; i++) {
    r = r.replaceAll(en[i], fa[i]);
  }
  return r;
}

/// «⟨…⟩ پیش» — how long ago something happened, in Persian.
String fmtAgo(DateTime at, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.inSeconds < 90) return 'همین حالا';
  if (diff.inMinutes < 60) return '${fmt(diff.inMinutes)} دقیقه پیش';
  if (diff.inHours < 24) return '${fmt(diff.inHours)} ساعت پیش';
  return '${fmt(diff.inDays)} روز پیش';
}

Future<void> openLink(BuildContext context, String raw) async {
  final uri = Uri.tryParse(raw);
  if (uri == null || !['https', 'http', 'tel'].contains(uri.scheme)) return;
  try {
    unawaited(AppLogger.instance.record('navigation', 'external_link',
        {'scheme': uri.scheme, 'host': uri.host}));
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('پیوند باز نشد.')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('برنامه مناسب برای بازکردن پیوند پیدا نشد.')));
    }
  }
}

Widget tag(String text, {Color color = teal}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
        color: color.withOpacity(.09), borderRadius: BorderRadius.circular(7)),
    child: Text(text,
        style: TextStyle(
            fontSize: 11, color: color, fontWeight: FontWeight.w700)));
Widget infoBox(String title, String text,
        {IconData icon = Icons.info_outline, Color color = teal}) =>
    Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: color.withOpacity(.07),
            border: Border.all(color: color.withOpacity(.15)),
            borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style:
                        TextStyle(fontWeight: FontWeight.bold, color: color)),
                const SizedBox(height: 5),
                Text(text, style: const TextStyle(fontSize: 12, height: 1.9))
              ]))
        ]));
Widget emptyState(String title, String detail,
        {IconData icon = Icons.inventory_2_outlined}) =>
    Center(
        child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 52, color: muted.withOpacity(.5)),
              const SizedBox(height: 18),
              Text(title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: muted, height: 1.9))
            ])));
/// The time windows offered by every tab, in days (`0` = the whole archive).
const windowLabels = <String, String>{
  '0': 'همه زمان‌ها',
  '1': '۲۴ ساعت',
  '3': '۳ روز',
  '7': '۱ هفته',
  '14': '۲ هفته',
  '30': '۱ ماه',
  '90': '۳ ماه',
  '180': '۶ ماه',
  '365': '۱ سال',
};

/// The label of a window in days.
String windowText(int days) => windowLabels['$days'] ?? '$days روز';

/// The time selector of the information tab and of every child tab.
///
/// [days] is the effective window; a child tab passes `inherit: true` and gets
/// an extra first option that means "same as the primary window", so its default
/// always equals the parent's default and it only differs when the user chooses
/// so for that tab.
Widget windowField(String label, int days, ValueChanged<int> onChanged,
    {bool inherit = false, int inherited = 0}) {
  final options = <String, String>{
    if (inherit) '-1': 'مانند بازه اصلی (${windowText(inherited)})',
    ...windowLabels,
  };
  return selectField(label, '$days', options, (v) => onChanged(int.parse(v)));
}

/// A compact one-line time selector for the tabs, so a window can be changed
/// without pushing the rest of the page out of view.
Widget windowChip(String label, int days, ValueChanged<int> onChanged,
    {bool inherit = false, int inherited = 0}) {
  final options = <String, String>{
    if (inherit) '-1': 'مانند بازه اصلی (${windowText(inherited)})',
    ...windowLabels,
  };
  return Align(
      alignment: Alignment.centerRight,
      child: PopupMenuButton<String>(
        initialValue: options.containsKey('$days') ? '$days' : null,
        onSelected: (v) => onChanged(int.parse(v)),
        itemBuilder: (_) => [
          for (final e in options.entries)
            PopupMenuItem(value: e.key, child: Text(e.value))
        ],
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.schedule, size: 15, color: teal),
              const SizedBox(width: 6),
              Flexible(
                  child: Text(
                      '$label: ${windowText(days < 0 ? inherited : days)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: ink))),
              const Icon(Icons.arrow_drop_down, size: 16, color: muted)
            ])),
      ));
}

Widget selectField(String label, String value, Map<String, String> options,
        ValueChanged<String> onChanged) =>
    DropdownButtonFormField<String>(
        value: options.containsKey(value) ? value : options.keys.first,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: options.entries
            .map((e) => DropdownMenuItem(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis)))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        });
String sourceDay(Quote q) =>
    q.sourceDateRaw.isEmpty ? 'تاریخ نرخ نامشخص' : q.sourceDateRaw;
