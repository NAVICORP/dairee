import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/api.dart';
import 'core/outbox.dart';
import 'ui/office/staff_gate.dart';
import 'ui/portal/portal_shell.dart';
import 'ui/start/welcome.dart';
import 'ui/theme.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    // Phones stay upright; tablets turn freely (the wall board likes landscape).
    final view = PlatformDispatcher.instance.views.first;
    final shortest = view.physicalSize.shortestSide / view.devicePixelRatio;
    if (shortest < 600) await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: K.surface,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  await Future.wait([Api.instance.load(), Portal.instance.load()]);
  await Outbox.instance.load();
  runApp(const DaireeApp());
}

class DaireeApp extends StatelessWidget {
  const DaireeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dairee',
      debugShowCheckedModeBanner: false,
      theme: daireeTheme(),
      navigatorKey: navigatorKey,
      supportedLocales: const [Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Text never grows past a size that breaks the cards.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final scale = mq.textScaler.clamp(minScaleFactor: 0.85, maxScaleFactor: 1.3);
        return MediaQuery(data: mq.copyWith(textScaler: scale), child: child!);
      },
      home: const Gate(),
    );
  }
}

/// Who is using this device: a customer (the portal), staff (the farm), or
/// nobody yet (the welcome screen).
class Gate extends StatefulWidget {
  const Gate({super.key});

  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> with WidgetsBindingObserver {
  late final StreamSubscription<Session?> _staff;
  late final StreamSubscription<String?> _portal;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _staff = Api.instance.changes.listen((s) {
      if (s == null) navigatorKey.currentState?.popUntil((r) => r.isFirst);
      setState(() {});
    });
    _portal = Portal.instance.changes.listen((t) {
      if (t == null) navigatorKey.currentState?.popUntil((r) => r.isFirst);
      setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Outbox.instance.flush();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _staff.cancel();
    _portal.cancel();
    super.dispose();
  }

  /// A link from a farm (dairee.skifi.co/c/<farm>) opens customer sign-in.
  String? get _customerLink => kIsWeb ? Uri.base.queryParameters['customer'] : null;

  @override
  Widget build(BuildContext context) {
    final Widget page;
    if (Portal.instance.signedIn) {
      page = const PortalShell(key: ValueKey('portal'));
    } else if (Api.instance.signedIn) {
      page = const StaffGate(key: ValueKey('staff'));
    } else {
      page = Welcome(key: const ValueKey('welcome'), customerFarm: _customerLink);
    }
    return AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: page);
  }
}
