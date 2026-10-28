/// Numbers, money, dates and names the way a farm writes them.
library;

const List<String> kMonths = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];
const List<String> kMonthsShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const List<String> kDaysShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// 65000 as "65,000" and 150000 as "1,50,000" (Indian grouping).
String groupDigits(num value) {
  final negative = value < 0;
  var s = value.abs().truncate().toString();
  if (s.length > 3) {
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    s = '${parts.join(',')},$last3';
  }
  return negative ? '-$s' : s;
}

/// 150000 as "150,000" (groups of three).
String groupThousands(num value) {
  final negative = value < 0;
  final s = value.abs().truncate().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return negative ? '-$b' : b.toString();
}

class Currency {
  const Currency(this.code, this.symbol, {this.indian = false, this.spaced = false});
  final String code;
  final String symbol;
  final bool indian;
  final bool spaced;

  /// Whole amounts without decimals; anything with paise or cents keeps two.
  String format(num value) {
    final v = (value * 100).round() / 100;
    final whole = indian ? groupDigits(v) : groupThousands(v);
    final cents = ((v.abs() - v.abs().truncate()) * 100).round();
    final digits = cents == 0 ? whole : '$whole.${cents.toString().padLeft(2, '0')}';
    final sign = v < 0 && !digits.startsWith('-') ? '-' : '';
    return spaced ? '$sign$symbol $digits' : '$sign$symbol$digits';
  }
}

const List<Currency> kCurrencies = [
  Currency('INR', '₹', indian: true),
  Currency('AED', 'AED', spaced: true),
  Currency('SAR', 'SAR', spaced: true),
  Currency('QAR', 'QAR', spaced: true),
  Currency('KWD', 'KWD', spaced: true),
  Currency('OMR', 'OMR', spaced: true),
  Currency('BHD', 'BHD', spaced: true),
  Currency('USD', r'$'),
  Currency('GBP', '£'),
  Currency('EUR', '€'),
  Currency('LKR', 'Rs', spaced: true),
  Currency('PKR', 'Rs', spaced: true),
  Currency('BDT', 'Tk', spaced: true),
  Currency('NPR', 'Rs', spaced: true),
  Currency('KES', 'KSh', spaced: true),
];

Currency currencyOf(String? code) {
  final c = (code ?? '').trim().toUpperCase();
  for (final x in kCurrencies) {
    if (x.code == c) return x;
  }
  return kCurrencies.first;
}

/// ₹1,750 or AED 1,750.
String money(num? value, [String? currency]) => currencyOf(currency).format(value ?? 0);

num toNum(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;

/// 1.5 L, 0.5 L, 12 L.
String litres(Object? v) {
  final n = toNum(v);
  final r = (n * 1000).round() / 1000;
  var s = r == r.truncate() ? r.truncate().toString() : r.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return '$s L';
}

/// A vessel's size: 500 ml, 1 L, 5 L.
String capacity(int ml) => ml < 1000 ? '$ml ml' : litres(ml / 1000);

// ---------------------------------------------------------------- dates

/// A date as the database writes it: 2026-10-28.
String isoDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? parseDay(Object? v) {
  if (v is! String || v.length < 10) return null;
  return DateTime.tryParse(v.substring(0, 10));
}

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// Wed 28 Oct
String dayLabel(DateTime d) => '${kDaysShort[d.weekday - 1]} ${d.day} ${kMonthsShort[d.month - 1]}';

/// 28 Oct 2026
String dateLabel(DateTime d) => '${d.day} ${kMonthsShort[d.month - 1]} ${d.year}';

/// 28 Oct, or 28 Oct 2025 when not this year.
String shortDate(DateTime d, [DateTime? now]) {
  final n = now ?? DateTime.now();
  return d.year == n.year ? '${d.day} ${kMonthsShort[d.month - 1]}' : dateLabel(d);
}

/// October 2026
String monthLabel(DateTime d) => '${kMonths[d.month - 1]} ${d.year}';

/// today, tomorrow, yesterday, or Wed 28 Oct: for the middle of a sentence.
String dayInSentence(DateTime d, DateTime today) {
  final r = relativeDay(d, today);
  return r == 'Today' || r == 'Tomorrow' || r == 'Yesterday' ? r.toLowerCase() : r;
}

/// today, tomorrow, yesterday, or on Wed 28 Oct.
String onDay(DateTime d, DateTime today) {
  final r = dayInSentence(d, today);
  return r == 'today' || r == 'tomorrow' || r == 'yesterday' ? r : 'on $r';
}

/// Today, Tomorrow, Yesterday, or Wed 28 Oct.
String relativeDay(DateTime d, DateTime today) {
  final diff = dayOnly(d).difference(dayOnly(today)).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  return dayLabel(d);
}

/// 1 Oct to 15 Oct
String periodLabel(DateTime a, DateTime b) =>
    a.year == b.year ? '${a.day} ${kMonthsShort[a.month - 1]} to ${b.day} ${kMonthsShort[b.month - 1]} ${b.year}' : '${dateLabel(a)} to ${dateLabel(b)}';

/// 7:31 pm
String clock(DateTime d) {
  final h = d.hour, m = d.minute;
  final hh = (h % 12) == 0 ? 12 : h % 12;
  return '$hh:${m.toString().padLeft(2, '0')} ${h < 12 ? 'am' : 'pm'}';
}

/// "06:00:00" from the database as 6:00 am.
String timeOfDay(Object? v) {
  final s = '${v ?? ''}';
  final p = s.split(':');
  if (p.length < 2) return s;
  final h = int.tryParse(p[0]) ?? 0, m = int.tryParse(p[1]) ?? 0;
  return clock(DateTime(2000, 1, 1, h, m));
}

/// 20 Oct, 7:31 pm
String stamp(DateTime d) => '${shortDate(d)}, ${clock(d.toLocal())}';

String slotName(String slot) => switch (slot) { 'morning' => 'Morning', 'evening' => 'Evening', _ => 'Both rounds' };

// ---------------------------------------------------------------- people

/// Digits only, with the country code; 10 digits on their own are Indian.
String phoneDigits(String raw, {String defaultCountry = '91'}) {
  final t = raw.trim();
  var d = t.replaceAll(RegExp(r'[^0-9]'), '');
  if (t.startsWith('00')) d = d.substring(2);
  if (t.startsWith('+') || t.startsWith('00')) return d;
  if (d.length == 11 && d.startsWith('0')) d = d.substring(1);
  if (d.length == 10) return '$defaultCountry$d';
  return d;
}

/// +91 90721 50276
String prettyPhone(String? digits) {
  final d = (digits ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  if (d.isEmpty) return '';
  if (d.length == 12 && d.startsWith('91')) return '+91 ${d.substring(2, 7)} ${d.substring(7)}';
  return '+$d';
}

/// The number without the country code, as people say it: 9895177896.
String localPhone(String? digits) {
  final d = (digits ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

/// Up to two letters for an avatar.
String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  String first(String s) => String.fromCharCodes(s.runes.take(1));
  if (parts.length == 1) return first(parts.first).toUpperCase();
  return (first(parts.first) + first(parts.last)).toUpperCase();
}

/// Where a customer lives, short: Tower 1, 101.
String placeOf(Map<String, dynamic> c) {
  final b = (c['building'] as String? ?? '').trim();
  final r = (c['room'] as String? ?? '').trim();
  if (b.isEmpty && r.isEmpty) return (c['address'] as String? ?? '').trim();
  if (b.isEmpty) return r;
  if (r.isEmpty) return b;
  return '$b, $r';
}

/// Vessels as words: 2 x 500 ml bottle, 5 litre can.
String vesselsText(Object? list) {
  if (list is! List || list.isEmpty) return 'No vessels';
  return list.whereType<Map>().map((v) {
    final n = toNum(v['quantity'] ?? v['count']).toInt();
    final name = '${v['name'] ?? ''}';
    return n == 1 ? name : '$n x $name';
  }).join(', ');
}

/// A CSV cell: quoted when it needs to be.
String csvCell(Object? v) {
  final s = v == null ? '' : '$v';
  if (s.contains(RegExp(r'[",\n\r]'))) return '"${s.replaceAll('"', '""')}"';
  return s;
}
