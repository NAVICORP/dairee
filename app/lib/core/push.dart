import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Push notifications on Android and iPhone, through Firebase Cloud Messaging
/// (project "dairee"). The server decides what to send (push_outbox); the app
/// only tells it which phone belongs to whom, and opens the right page when a
/// notification is tapped. The web app has none.
class Push {
  Push._();
  static final Push instance = Push._();

  static const _prefKey = 'dairee.push_on';

  static const _android = FirebaseOptions(
    apiKey: 'AIzaSyAXRSguApUpaWemRAgXUy0YzMD6g9Eb8UQ',
    appId: '1:82265082986:android:d3acf1bd62426f6b9e4e13',
    messagingSenderId: '82265082986',
    projectId: 'dairee',
  );
  static const _ios = FirebaseOptions(
    apiKey: 'AIzaSyCo5oPQJqxkNcLbNiLm6M0QhbNlSRbfDmw',
    appId: '1:82265082986:ios:2d3145fab4532e4f9e4e13',
    messagingSenderId: '82265082986',
    projectId: 'dairee',
    iosBundleId: 'co.skifi.dairee',
  );

  bool get supported => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
  String get _platform => defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  bool _ready = false;
  bool on = true;
  String? _token;
  _Who _who = _Who.nobody;

  /// The page a tapped notification asks for (`pauses`, `today`, `bills`...).
  final ValueNotifier<String?> opened = ValueNotifier<String?>(null);

  /// Messages that arrive while the app is open (shown in the app on Android;
  /// the iPhone shows its own banner).
  final StreamController<RemoteMessage> _foreground = StreamController<RemoteMessage>.broadcast();
  Stream<RemoteMessage> get foreground => _foreground.stream;

  Future<void> init() async {
    if (!supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      on = prefs.getBool(_prefKey) ?? true;
      await Firebase.initializeApp(options: defaultTargetPlatform == TargetPlatform.iOS ? _ios : _android);
      final m = FirebaseMessaging.instance;
      await m.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
      FirebaseMessaging.onMessageOpenedApp.listen((msg) => opened.value = msg.data['link'] as String?);
      FirebaseMessaging.onMessage.listen((msg) {
        if (defaultTargetPlatform == TargetPlatform.android) _foreground.add(msg);
      });
      m.onTokenRefresh.listen((t) {
        _token = t;
        _send();
      });
      final first = await m.getInitialMessage();
      if (first != null) opened.value = first.data['link'] as String?;
      _ready = true;
    } catch (e) {
      debugPrint('push: not available: $e');
    }
  }

  /// After a farm sign-in: this phone hears the farm's messages.
  Future<void> attachStaff() => _attach(_Who.staff);

  /// After a portal sign-in: this phone hears the customer's messages.
  Future<void> attachCustomer() => _attach(_Who.customer);

  Future<void> _attach(_Who who) async {
    _who = who;
    if (!_ready || !on) return;
    try {
      final m = FirebaseMessaging.instance;
      final s = await m.requestPermission(alert: true, badge: true, sound: true);
      if (s.authorizationStatus == AuthorizationStatus.denied) return;
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        // The iPhone's own push address comes a moment after permission.
        for (var i = 0; i < 10 && await m.getAPNSToken() == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      _token = await m.getToken();
      await _send();
    } catch (e) {
      debugPrint('push: could not register: $e');
    }
  }

  Future<void> _send() async {
    final t = _token;
    if (t == null || !on) return;
    try {
      if (_who == _Who.staff && Api.instance.signedIn) {
        await Api.instance.rpc('register_device', {'token': t, 'platform': _platform});
      } else if (_who == _Who.customer && Portal.instance.signedIn) {
        await Portal.instance.call('portal_register_device', {'device': t, 'platform': _platform});
      }
    } catch (e) {
      debugPrint('push: register failed: $e');
    }
  }

  /// Before signing out: this phone stops hearing about this account.
  Future<void> detach() async {
    final t = _token;
    final who = _who;
    _who = _Who.nobody;
    if (!_ready || t == null) return;
    try {
      if (who == _Who.staff && Api.instance.signedIn) {
        await Api.instance.rpc('forget_device', {'token': t});
      } else if (who == _Who.customer) {
        await Portal.instance.call('portal_forget_device', {'device': t});
      }
    } catch (_) {
      // The server forgets it anyway once Firebase says the token is gone.
    }
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
    _token = null;
  }

  /// The switch in Profile.
  Future<void> setOn(bool value) async {
    final who = _who;
    if (!value) await detach();
    on = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (_) {}
    if (value && who != _Who.nobody) await _attach(who);
    _who = who;
  }
}

enum _Who { nobody, staff, customer }
