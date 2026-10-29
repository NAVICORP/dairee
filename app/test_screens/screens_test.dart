// Renders the main screens to pictures, so the design can be checked without
// a phone. The answers come from the real database rules: CI loads the demo
// farm (tools/demo.sql) into Postgres and records what the server says
// (tools/record_screens.py) into test_screens/fixtures.json first.
//
//   flutter test test_screens --update-goldens
//
// The pictures land in test_screens/shots/.
import 'dart:convert';
import 'dart:io';

import 'package:dairee/core/api.dart';
import 'package:dairee/core/farm.dart';
import 'package:dairee/ui/office/customers.dart';
import 'package:dairee/ui/office/herd.dart';
import 'package:dairee/ui/office/payments.dart';
import 'package:dairee/ui/office/shell.dart';
import 'package:dairee/ui/office/staff.dart';
import 'package:dairee/ui/office/staff_gate.dart';
import 'package:dairee/ui/office/wallboard.dart';
import 'package:dairee/ui/portal/portal_shell.dart';
import 'package:dairee/ui/start/welcome.dart';
import 'package:dairee/ui/theme.dart';
import 'package:dairee/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final l = FontLoader(name);
    for (final f in files) {
      l.addFont(rootBundle.load(f));
    }
    await l.load();
  }

  await family('Manrope', [for (final w in [500, 600, 700, 800]) 'assets/fonts/Manrope-$w.ttf']);
  await family('Bricolage', [for (final w in [600, 700]) 'assets/fonts/BricolageGrotesque-$w.ttf']);
  // Material icons, from the Flutter SDK running the test.
  final roots = <String>[
    if (Platform.environment['FLUTTER_ROOT'] != null) Platform.environment['FLUTTER_ROOT']!,
    File(Platform.resolvedExecutable).parent.path,
  ];
  for (final r in roots) {
    var dir = Directory(r);
    for (var i = 0; i < 8; i++) {
      final f = File('${dir.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      final g = File('${dir.path}/artifacts/material_fonts/MaterialIcons-Regular.otf');
      for (final x in [f, g]) {
        if (x.existsSync()) {
          final l = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.view(x.readAsBytesSync().buffer)));
          await l.load();
          return;
        }
      }
      dir = dir.parent;
    }
  }
}

/// A stand-in for dairee.skifi.co that answers from the recorded demo farm.
/// Table reads honour the filters and order the app sends, the way the
/// database API does; functions answer what the real function answered.
class FakeServer {
  FakeServer(this.fx);
  final Map<String, dynamic> fx;

  /// Whose answers to give for who-am-I and the round: asha (owner), dev
  /// (delivery), rahul (cow care).
  String who = 'asha';
  final List<String> unknown = [];

  http.Client get client => MockClient(_handle);

  Future<http.Response> _handle(http.Request r) async {
    final path = r.url.path;
    dynamic body;
    if (path.startsWith('/rest/v1/rpc/')) {
      final fn = path.substring('/rest/v1/rpc/'.length);
      final args = r.body.isEmpty ? const <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(r.body) as Map);
      // The most particular answer recorded: for this day and round, this day, or any.
      final keys = [
        if (args['day'] != null && args['slot'] != null) '$fn@${args['day']}@${args['slot']}',
        if (args['day'] != null) '$fn@${args['day']}',
        fn,
      ];
      final as = (fx['as'] as Map)[who] as Map?;
      final rpc = fx['rpc'] as Map;
      if (fn.startsWith('portal_')) {
        body = (fx['portal'] as Map)[fn];
      } else {
        final from = [if (as != null) as, rpc];
        final where = [for (final m in from) for (final k in keys) if (m.containsKey(k)) (m, k)];
        if (where.isEmpty) {
          unknown.add(fn);
        } else {
          body = where.first.$1[where.first.$2];
        }
      }
    } else if (path.startsWith('/rest/v1/')) {
      final table = path.substring('/rest/v1/'.length);
      if (r.method == 'GET') {
        body = _rows(table, r.url.queryParameters, r.headers['Range']);
      } else {
        body = r.body.isEmpty ? [<String, dynamic>{}] : [jsonDecode(r.body)];
      }
    } else {
      body = <String, dynamic>{};
    }
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  }

  List<Map<String, dynamic>> _rows(String table, Map<String, String> q, String? range) {
    var rows = [for (final r in ((fx['tables'] as Map)[table] as List? ?? const [])) Map<String, dynamic>.from(r as Map)];
    for (final e in q.entries) {
      if (e.key == 'select' || e.key == 'order' || e.key == 'limit') continue;
      rows = rows.where((r) => _match(r[e.key], e.value)).toList();
    }
    final order = q['order'];
    if (order != null) {
      final keys = [for (final o in order.split(',')) o.split('.')];
      rows.sort((a, b) {
        for (final k in keys) {
          final c = _cmp(a[k[0]], b[k[0]], nullsFirst: k.contains('nullsfirst'));
          if (c != 0) return k.contains('desc') ? -c : c;
        }
        return 0;
      });
    }
    if (range != null) {
      final p = range.split('-').map(int.parse).toList();
      rows = rows.skip(p[0]).take(p[1] - p[0] + 1).toList();
    }
    return rows;
  }

  static int _cmp(dynamic a, dynamic b, {bool nullsFirst = false}) {
    if (a == null && b == null) return 0;
    if (a == null) return nullsFirst ? -1 : 1;
    if (b == null) return nullsFirst ? 1 : -1;
    if (a is num && b is num) return a.compareTo(b);
    if (a is bool && b is bool) return a == b ? 0 : (a ? 1 : -1);
    return '$a'.compareTo('$b');
  }

  static bool _match(dynamic v, String f) {
    final dot = f.indexOf('.');
    if (dot < 0) return true;
    final op = f.substring(0, dot);
    final x = f.substring(dot + 1);
    switch (op) {
      case 'eq':
        return '$v' == x;
      case 'neq':
        return '$v' != x;
      case 'is':
        return x == 'null' ? v == null : '$v' == x;
      case 'in':
        return x.replaceAll('(', '').replaceAll(')', '').split(',').contains('$v');
      case 'gte':
      case 'gt':
      case 'lte':
      case 'lt':
        if (v == null) return false;
        final c = v is num ? v.compareTo(num.parse(x)) : '$v'.compareTo(x);
        return switch (op) { 'gte' => c >= 0, 'gt' => c > 0, 'lte' => c <= 0, _ => c < 0 };
      default:
        return true;
    }
  }
}

final File _fixtures = File('test_screens/fixtures.json');
final bool _have = _fixtures.existsSync();
late FakeServer server;

Widget app(Widget child) => MaterialApp(debugShowCheckedModeBanner: false, theme: daireeTheme(), home: child);

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      await precacheImage((e.widget as Image).image, e);
    }
  });
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> shot(WidgetTester tester, String name) async {
  await settle(tester);
  await expectLater(find.byType(MaterialApp).first, matchesGoldenFile('shots/$name.png'));
}

/// Scrolls the last match into view, then taps it.
Future<void> see(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) return;
  await tester.ensureVisible(f.last);
  await settle(tester);
  await tap(tester, f);
}

/// Taps the last match, if there is one (the footer comes after the page).
Future<void> tap(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) return;
  await tester.tap(f.last, warnIfMissed: false);
  await settle(tester);
}

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(2880, 1800);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

Future<FarmRole> signIn(WidgetTester tester, [String who = 'asha']) async {
  server.who = who;
  await tester.runAsync(() => Me.instance.load());
  return Me.instance.farm!;
}

Future<void> shell(WidgetTester tester, [String who = 'asha']) async {
  final f = await signIn(tester, who);
  await tester.pumpWidget(app(FarmShell(farm: f, reload: () async {})));
  await settle(tester);
}

/// The morning round, whatever the time of day the pictures are made: in
/// the evening the round opens on the evening, one step after the morning.
Future<void> morning(WidgetTester tester) async {
  if (find.text('Evening, today').evaluate().isNotEmpty) await tap(tester, find.byTooltip('Round before'));
}

Map<String, dynamic> row(String table, String key, String value) =>
    Map<String, dynamic>.from(((server.fx['tables'] as Map)[table] as List).cast<Map>().firstWhere((r) => '${r[key]}' == value));

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFonts();
    if (!_have) return;
    server = FakeServer(jsonDecode(_fixtures.readAsStringSync()) as Map<String, dynamic>);
    Api.instance.client = server.client;
    Portal.instance.client = server.client;
  });
  setUp(() {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    Portal.instance.token = null;
  });
  tearDownAll(() {
    if (_have && server.unknown.isNotEmpty) {
      // ignore: avoid_print
      print('Functions with no recorded answer: ${server.unknown.toSet().join(', ')}');
    }
  });

  final skip = !_have;

  testWidgets('welcome', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const Welcome()));
    await shot(tester, '01-welcome');
    await tap(tester, find.text('I work at a farm'));
    await shot(tester, '02-staff-sign-in');
    await tap(tester, find.text('Continue with WhatsApp'));
    await shot(tester, '03-staff-whatsapp');
  }, skip: skip);

  testWidgets('customer sign in', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(const Welcome()));
    await settle(tester);
    await tap(tester, find.text("I'm a customer"));
    await shot(tester, '04-customer-sign-in');
  }, skip: skip);

  testWidgets('start a farm', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(StartFarm(onMade: () async {})));
    await shot(tester, '05-start-farm');
  }, skip: skip);

  testWidgets('round, office', (tester) async {
    phone(tester);
    await shell(tester);
    await shot(tester, '09-today');
    await see(tester, find.text('HARBOUR HEIGHTS'));
    await shot(tester, '10-round');
    await see(tester, find.text('PALM GROVE'));
    await see(tester, find.text('Anitha Nair'));
    await shot(tester, '11-round-stops');
    await see(tester, find.text('Filter'));
    await shot(tester, '15-round-filter');
    await tap(tester, find.byTooltip('More'));
    await shot(tester, '14-round-menu');
  }, skip: skip);

  testWidgets('round, delivery', (tester) async {
    phone(tester);
    await shell(tester, 'dev');
    await morning(tester);
    await shot(tester, '12-round-delivery');
  }, skip: skip);

  testWidgets('packing', (tester) async {
    phone(tester);
    await shell(tester);
    await tap(tester, find.byTooltip('Packing'));
    await shot(tester, '13-packing');
  }, skip: skip);

  testWidgets('customers', (tester) async {
    phone(tester);
    await shell(tester);
    await tap(tester, find.text('Customers'));
    await shot(tester, '20-customers');
  }, skip: skip);

  testWidgets('a customer', (tester) async {
    phone(tester);
    final f = await signIn(tester);
    await tester.pumpWidget(app(CustomerPage(farm: f, customer: row('customers', 'name', 'Anitha Nair'))));
    await shot(tester, '21-customer');
    await tester.drag(find.byType(ListView).first, const Offset(0, -900));
    await shot(tester, '22-customer-more');
  }, skip: skip);

  testWidgets('customer editor', (tester) async {
    phone(tester);
    final f = await signIn(tester);
    await tester.pumpWidget(app(CustomerEditor(farm: f, customer: row('customers', 'name', 'Fathima Rasheed'))));
    await shot(tester, '23-customer-editor');
  }, skip: skip);

  testWidgets('pause sheet', (tester) async {
    phone(tester);
    final f = await signIn(tester);
    await tester.pumpWidget(app(CustomerPage(farm: f, customer: row('customers', 'name', 'Anitha Nair'))));
    await settle(tester);
    await tap(tester, find.text('Pause'));
    await shot(tester, '24-pause-sheet');
  }, skip: skip);

  testWidgets('vessels', (tester) async {
    phone(tester);
    final f = await signIn(tester);
    await tester.pumpWidget(app(CustomerPage(farm: f, customer: row('customers', 'name', 'Fathima Rasheed'))));
    await settle(tester);
    await tap(tester, find.text('Vessels'));
    await shot(tester, '25-vessels');
  }, skip: skip);

  testWidgets('pause and stop', (tester) async {
    phone(tester);
    await shell(tester);
    await tap(tester, find.text('Profile'));
    await tap(tester, find.text('Pause / Stop'));
    await shot(tester, '30-changes');
  }, skip: skip);

  testWidgets('payments', (tester) async {
    phone(tester);
    await shell(tester);
    await tap(tester, find.text('Profile'));
    await shot(tester, '40-profile');
    await tap(tester, find.text('To collect'));
    await shot(tester, '41-payments');
    await tap(tester, find.text('Bills'));
    await shot(tester, '42-bills');
  }, skip: skip);

  testWidgets('a bill', (tester) async {
    phone(tester);
    final f = await signIn(tester);
    final b = ((server.fx['tables'] as Map)['bill_balances'] as List).cast<Map>().firstWhere((b) => (b['balance_due'] as num) > 0);
    await tester.pumpWidget(app(BillPage(farm: f, billId: '${b['bill_id']}')));
    await shot(tester, '43-bill');
  }, skip: skip);

  testWidgets('a customer\'s money', (tester) async {
    phone(tester);
    final f = await signIn(tester);
    await tester.pumpWidget(app(CustomerMoney(farm: f, customer: row('customers', 'name', 'Jacob Varghese'))));
    await shot(tester, '44-customer-money');
  }, skip: skip);

  testWidgets('reports', (tester) async {
    phone(tester);
    await shell(tester);
    await tap(tester, find.text('Profile'));
    await tap(tester, find.text('Reports'));
    await shot(tester, '50-reports');
    await tap(tester, find.text('Money'));
    await shot(tester, '51-reports-money');
  }, skip: skip);

  testWidgets('herd', (tester) async {
    phone(tester);
    await shell(tester);
    await tap(tester, find.text('Profile'));
    await tap(tester, find.text('Cows'));
    await shot(tester, '60-herd');
  }, skip: skip);

  testWidgets('a cow', (tester) async {
    phone(tester);
    final f = await signIn(tester);
    await tester.pumpWidget(app(CowPage(farm: f, cowId: '${row('cows', 'tag_number', 'GM-01')['id']}')));
    await shot(tester, '61-cow');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
    await shot(tester, '62-cow-more');
  }, skip: skip);

  testWidgets('cow care', (tester) async {
    phone(tester);
    await shell(tester, 'rahul');
    await shot(tester, '63-cow-care');
  }, skip: skip);

  testWidgets('staff', (tester) async {
    phone(tester);
    await shell(tester);
    await tap(tester, find.text('Profile'));
    await tap(tester, find.text('Staff'));
    await shot(tester, '70-staff');
  }, skip: skip);

  testWidgets('staff editor', (tester) async {
    phone(tester);
    final f = await signIn(tester);
    await tester.pumpWidget(app(StaffEditor(farm: f, staff: row('staff', 'name', 'Omana Varghese'))));
    await shot(tester, '71-staff-editor');
  }, skip: skip);

  testWidgets('settings', (tester) async {
    phone(tester);
    await shell(tester);
    await tap(tester, find.text('Profile'));
    await tap(tester, find.text('Settings'));
    await shot(tester, '80-settings');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1400));
    await shot(tester, '81-settings-more');
  }, skip: skip);

  testWidgets('date picker', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(Builder(builder: (context) {
      return Scaffold(body: Center(child: KButton(label: 'Pick', onPressed: () => pickDate(context, initial: DateTime(2026, 10, 28)))));
    })));
    await settle(tester);
    await tap(tester, find.text('Pick'));
    await shot(tester, '82-date-picker');
  }, skip: skip);

  testWidgets('wall board', (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final f = await signIn(tester);
    await tester.pumpWidget(app(WallBoard(farm: f)));
    await shot(tester, '83-wall-board');
    await tester.pumpWidget(const SizedBox());
  }, skip: skip);

  testWidgets('portal', (tester) async {
    phone(tester);
    Portal.instance.token = 'demo';
    await tester.pumpWidget(app(const PortalShell()));
    await shot(tester, '90-portal-home');
    await tap(tester, find.text('Payment'));
    await shot(tester, '91-portal-payment');
    await tap(tester, find.text('Changes'));
    await shot(tester, '92-portal-changes');
    await tap(tester, find.text('Profile'));
    await shot(tester, '93-portal-profile');
  }, skip: skip);

  // The web app on a computer: the side bar instead of the footer.
  testWidgets('web, today', (tester) async {
    desktop(tester);
    await shell(tester);
    await shot(tester, 'w1-today');
    await see(tester, find.text('HARBOUR HEIGHTS'));
    await see(tester, find.text('LAKE VIEW'));
    await shot(tester, 'w5-round');
  }, skip: skip);

  testWidgets('web, customers', (tester) async {
    desktop(tester);
    await shell(tester);
    await tap(tester, find.text('Customers'));
    await shot(tester, 'w2-customers');
  }, skip: skip);

  testWidgets('web, payments', (tester) async {
    desktop(tester);
    await shell(tester);
    await tap(tester, find.text('To collect'));
    await shot(tester, 'w3-payments');
  }, skip: skip);

  testWidgets('web, welcome', (tester) async {
    desktop(tester);
    await tester.pumpWidget(app(const Welcome()));
    await shot(tester, 'w4-welcome');
  }, skip: skip);
}
