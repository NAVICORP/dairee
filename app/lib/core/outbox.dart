import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Ticks made on the round with no signal (a stairwell, a basement) wait
/// here, on the device, and go to the server as soon as it answers again.
/// Each one is sent exactly as it was made; the server checks it like any
/// other. A tick the server refuses is dropped and reported, never retried
/// for ever.
class Outbox extends ChangeNotifier {
  Outbox._();
  static final Outbox instance = Outbox._();

  static const _key = 'dairee.outbox';
  final List<Map<String, dynamic>> _items = [];
  bool _sending = false;
  Timer? _timer;

  /// The last refusal from the server, for the round screen to show once.
  String? lastRefusal;

  int get waiting => _items.length;

  /// What is still waiting for one round stop, newest last.
  List<Map<String, dynamic>> pendingFor(String customerId, String day, String slot) => [
        for (final i in _items)
          if ((i['args'] as Map)['customer_id'] == customerId && (i['args'] as Map)['day'] == day && (i['args'] as Map)['slot'] == slot) i,
      ];

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        _items
          ..clear()
          ..addAll((jsonDecode(raw) as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)));
      }
    } catch (_) {
      _items.clear();
    }
    _timer ??= Timer.periodic(const Duration(seconds: 20), (_) => flush());
    if (_items.isNotEmpty) unawaited(flush());
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_items));
    } catch (_) {
      // Kept in memory for this visit.
    }
    notifyListeners();
  }

  /// Sends now when there is a signal; otherwise keeps it for later.
  /// Returns true when the server has it, false when it is waiting.
  Future<bool> send(String fn, Map<String, dynamic> args) async {
    final item = {'fn': fn, 'args': args, 'farm': Api.instance.farmId, 'at': DateTime.now().toIso8601String()};
    if (_items.isEmpty) {
      try {
        await Api.instance.rpc(fn, args);
        return true;
      } on ApiError catch (e) {
        if (!e.offline) rethrow;
      }
    }
    _items.add(item);
    await _save();
    return false;
  }

  /// Sends whatever is waiting, oldest first, and stops at the first that
  /// still cannot reach the server.
  Future<void> flush() async {
    if (_sending || _items.isEmpty || !Api.instance.signedIn) return;
    _sending = true;
    final farm = Api.instance.farmId;
    try {
      while (_items.isNotEmpty) {
        final item = _items.first;
        // Made for another farm: send it as that farm.
        Api.instance.farmId = (item['farm'] as String?) ?? farm;
        try {
          await Api.instance.rpc(item['fn'] as String, Map<String, dynamic>.from(item['args'] as Map));
        } on ApiError catch (e) {
          if (e.offline) break;
          if (e.isSignedOut) break;
          lastRefusal = e.message;
        }
        _items.removeAt(0);
        await _save();
      }
    } finally {
      Api.instance.farmId = farm;
      _sending = false;
      notifyListeners();
    }
  }

  Future<void> clear() async {
    _items.clear();
    await _save();
  }
}
