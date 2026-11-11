import 'market.dart';
import 'product_text.dart';

/// A global display scope, never a restriction on fetching or retained data.
/// All explicit row-level location roles are included; no factory geocoding,
/// phone-prefix inference, or unrelated raw-post/footer text is used.
bool cityMatches(Quote q, String selected) {
  final city = ProductText.normalize(selected).trim();
  if (city.isEmpty) return true;
  if (city == 'نامشخص') {
    return [q.sellerCity, q.loadingCity, q.loading]
        .every((s) => s.isEmpty || s == 'نامشخص');
  }
  final boundary =
      RegExp('(?<![آ-یA-Za-z])${RegExp.escape(city)}(?![آ-یA-Za-z])');
  bool has(String text) => boundary.hasMatch(ProductText.normalize(text));
  return has(q.sellerCity) ||
      has(q.loadingCity) ||
      has(q.loading) ||
      has(q.title) ||
      has(q.brand) ||
      q.details.entries.any((e) =>
          RegExp('شهر|محل|بارگیری|تولید|کارخانه|انبار|دفتر|مبدا|مبدأ')
              .hasMatch(e.key) &&
          // A comparison or conflict line names every city that was weighed,
          // also the ones that lost; it does not place the row in them.
          !RegExp('مقایسه|تعارض').hasMatch(e.key) &&
          has(e.value));
}
