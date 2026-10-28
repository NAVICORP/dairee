import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// Something the server or the network said no to, in words a person can act on.
class ApiError implements Exception {
  ApiError(this.message, {this.status = 0, this.code});
  final String message;

  /// The HTTP status, or 0 when the server could not be reached at all.
  final int status;
  final String? code;

  /// No answer from the server: no signal, or the server is away.
  bool get offline => status == 0;

  /// The sign-in has ended and the person has to sign in again.
  bool get isSignedOut => status == 401;

  @override
  String toString() => message;
}

const _noConnection = 'No connection. Check your signal and try again.';
const _timeout = 'The server is taking too long. Try again in a moment.';

/// A signed-in staff session: the short-lived access token and the refresh
/// token that renews it.
class Session {
  Session({required this.accessToken, required this.refreshToken, required this.expiresAt, required this.user});

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final Map<String, dynamic> user;

  String? get email => _nonEmpty(user['email']);
  String? get phone => _nonEmpty(user['phone']);

  static String? _nonEmpty(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

  static Session? fromJson(dynamic j) {
    if (j is! Map) return null;
    final access = j['access_token'];
    final refresh = j['refresh_token'];
    if (access is! String || refresh is! String) return null;
    DateTime expires;
    final at = j['expires_at'];
    final inSec = j['expires_in'];
    if (at is num) {
      expires = DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000);
    } else if (inSec is num) {
      expires = DateTime.now().add(Duration(seconds: inSec.toInt()));
    } else {
      expires = _jwtExpiry(access) ?? DateTime.now().add(const Duration(minutes: 50));
    }
    final user = j['user'] is Map ? Map<String, dynamic>.from(j['user'] as Map) : <String, dynamic>{};
    return Session(accessToken: access, refreshToken: refresh, expiresAt: expires, user: user);
  }

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt.millisecondsSinceEpoch ~/ 1000,
        'user': user,
      };

  static DateTime? _jwtExpiry(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final exp = payload is Map ? payload['exp'] : null;
      return exp is num ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000) : null;
    } catch (_) {
      return null;
    }
  }
}

/// Talks to the Dairee server.
///
/// Staff sign in through /auth/v1 (the SkiFi login) and read and write
/// through /rest/v1, as themselves, so the database's row rules decide what
/// they see. Every request names the farm being worked in (x-farm-id).
///
/// Customers have no sign-in here: see [Portal].
class Api {
  Api._();
  static final Api instance = Api._();

  static const _storeKey = 'dairee.session';
  static const _farmKey = 'dairee.farm';
  http.Client _http = http.Client();

  /// For tests and screenshots: answers from a stand-in server.
  set client(http.Client c) => _http = c;
  final StreamController<Session?> _changes = StreamController<Session?>.broadcast();
  Session? _session;
  Future<void>? _refreshing;

  /// The farm being worked in: sent with every request.
  String? farmId;

  /// For screenshots and tests: every call fails at once, without the network.
  bool offline = false;

  Session? get session => _session;
  bool get signedIn => _session != null;
  Stream<Session?> get changes => _changes.stream;

  /// Picks up the session saved on this device, if there is one.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      farmId = prefs.getString(_farmKey);
      final raw = prefs.getString(_storeKey);
      if (raw == null) return;
      _session = Session.fromJson(jsonDecode(raw));
      if (_session != null && _session!.expiresAt.isBefore(DateTime.now().add(const Duration(seconds: 60)))) {
        try {
          await _refresh();
        } on ApiError catch (e) {
          if (e.status == 400 || e.status == 401 || e.status == 403 || e.status == 404) await _setSession(null);
        }
      }
    } catch (_) {
      _session = null;
    }
  }

  Future<void> chooseFarm(String? id) async {
    farmId = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id == null) {
        await prefs.remove(_farmKey);
      } else {
        await prefs.setString(_farmKey, id);
      }
    } catch (_) {
      // Kept for this visit either way.
    }
  }

  Future<void> _setSession(Session? s) async {
    _session = s;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (s == null) {
        await prefs.remove(_storeKey);
      } else {
        await prefs.setString(_storeKey, jsonEncode(s.toJson()));
      }
    } catch (_) {
      // The session still works for now; it just will not survive a restart.
    }
    _changes.add(s);
  }

  Map<String, String> _headers(bool withUser, [Map<String, String>? extra]) => {
        'apikey': 'public',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-Client-Info': 'dairee-app/1.0',
        'Authorization': 'Bearer ${withUser && _session != null ? _session!.accessToken : 'public'}',
        if (withUser && farmId != null) 'x-farm-id': farmId!,
        ...?extra,
      };

  Future<void> _fresh() async {
    final s = _session;
    if (s == null) return;
    if (s.expiresAt.isAfter(DateTime.now().add(const Duration(seconds: 60)))) return;
    try {
      await _refresh();
    } on ApiError catch (e) {
      if (e.status == 400 || e.status == 401 || e.status == 403 || e.status == 404) {
        await _setSession(null);
        throw ApiError('Your sign-in has ended. Please sign in again.', status: 401);
      }
      // No signal: carry on with the old token and let the server decide.
    }
  }

  Future<void> _refresh() {
    return _refreshing ??= () async {
      try {
        final r = await _raw('POST', '/auth/v1/token',
            query: {'grant_type': 'refresh_token'}, body: {'refresh_token': _session!.refreshToken}, withUser: false, retry: false);
        final next = Session.fromJson(r.json);
        if (next == null) throw ApiError('Please sign in again.', status: 401);
        await _setSession(next);
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<_Reply> _raw(String method, String path,
      {Object? body, Map<String, String>? query, bool withUser = true, bool retry = true, Map<String, String>? headers}) async {
    if (offline) throw ApiError(_noConnection);
    if (withUser) await _fresh();
    final uri = Uri.parse('$kApiBase$path').replace(queryParameters: query);
    http.Response r;
    try {
      final req = http.Request(method, uri)..headers.addAll(_headers(withUser, headers));
      if (body != null) req.body = jsonEncode(body);
      final streamed = await _http.send(req).timeout(const Duration(seconds: 30));
      r = await http.Response.fromStream(streamed).timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw ApiError(_timeout);
    } catch (_) {
      throw ApiError(_noConnection);
    }
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    dynamic j;
    if (text.isNotEmpty) {
      try {
        j = jsonDecode(text);
      } catch (_) {
        j = null;
      }
    }
    if (r.statusCode >= 200 && r.statusCode < 300) return _Reply(j, r.headers);
    // An access token that ran out early: renew once and try again.
    if (r.statusCode == 401 && withUser && retry && _session != null) {
      try {
        await _refresh();
      } on ApiError catch (e) {
        if (!e.offline) await _setSession(null);
        throw ApiError('Your sign-in has ended. Please sign in again.', status: 401);
      }
      return _raw(method, path, body: body, query: query, withUser: withUser, retry: false, headers: headers);
    }
    throw error(r.statusCode, j);
  }

  static ApiError error(int status, dynamic j) {
    String raw = '';
    String? code;
    if (j is Map) {
      raw = (j['message'] ?? j['msg'] ?? j['error_description'] ?? j['error'] ?? '').toString();
      code = (j['code'] ?? j['error_code'])?.toString();
    }
    if (raw.isEmpty) raw = status >= 500 ? 'The server had a problem. Try again in a minute.' : 'That did not work ($status).';
    return ApiError(nice(raw, code), status: status, code: code);
  }

  /// Server wording, turned into what to do next.
  static String nice(String m, [String? code]) {
    final s = m.toLowerCase();
    if (s.contains('row-level security') || s.contains('permission denied') || code == '42501' && s.contains('policy')) {
      return 'You do not have permission to do that. Ask an admin.';
    }
    if (s.contains('not on whatsapp')) return 'That number is not on WhatsApp. Use email instead.';
    if (s.contains('could not send')) return 'The code could not be sent. Try again in a minute.';
    if (s.contains('rate limit') || s.contains('too many')) return 'Too many tries. Wait a few minutes, then try again.';
    if ((s.contains('invalid') || s.contains('expired') || s.contains('not right')) &&
        (s.contains('token') || s.contains('otp') || s.contains('code')) &&
        !s.contains('jwt')) {
      return 'That code is not right, or it has expired.';
    }
    if (s.contains('invalid login credentials')) return 'That email and password do not match.';
    if (s.contains('jwt') || s.contains('not signed in')) return 'Your sign-in has ended. Please sign in again.';
    if (s.contains('duplicate key') && s.contains('tag_number')) return 'Another cow already has that tag number.';
    if (s.contains('duplicate key') && s.contains('staff_farm_phone')) return 'Someone on the staff already has that number.';
    if (s.contains('duplicate key') && s.contains('staff_farm_email')) return 'Someone on the staff already has that email.';
    if (s.contains('duplicate key')) return 'That is already saved.';
    if (s.contains('violates foreign key') && s.contains('customers')) {
      return 'This customer has bills or payments, so they cannot be deleted. Stop them instead.';
    }
    if (s.contains('violates foreign key')) return 'Other records still use this, so it cannot be deleted.';
    if (s.contains('bills_no_overlap')) return 'This customer already has a bill for some of those days.';
    return m;
  }

  // ---------------------------------------------------------------- sign in

  Future<void> sendWhatsAppCode(String phone) async {
    await _raw('POST', '/auth/v1/otp',
        body: {'phone': phone, 'create_user': true, 'channel': 'whatsapp', 'data': <String, dynamic>{}}, withUser: false);
  }

  Future<void> verifyWhatsAppCode(String phone, String code) async {
    final r = await _raw('POST', '/auth/v1/verify', body: {'phone': phone, 'token': code.trim(), 'type': 'sms'}, withUser: false);
    await _take(r.json);
  }

  Future<void> sendEmailCode(String email) async {
    await _raw('POST', '/auth/v1/otp',
        body: {'email': email.trim().toLowerCase(), 'create_user': true, 'data': <String, dynamic>{}}, withUser: false);
  }

  Future<void> verifyEmailCode(String email, String code) async {
    final r = await _raw('POST', '/auth/v1/verify',
        body: {'email': email.trim().toLowerCase(), 'token': code.trim(), 'type': 'email'}, withUser: false);
    await _take(r.json);
  }

  Future<void> signInWithPassword(String email, String password) async {
    final r = await _raw('POST', '/auth/v1/token',
        query: {'grant_type': 'password'}, body: {'email': email.trim().toLowerCase(), 'password': password}, withUser: false);
    await _take(r.json);
  }

  /// A password of the signed-in person's own choosing, for their email.
  Future<void> setPassword(String password) async {
    await _raw('PUT', '/auth/v1/user', body: {'password': password});
  }

  Future<void> _take(dynamic j) async {
    final s = Session.fromJson(j);
    if (s == null) throw ApiError('Sign-in did not finish. Please try again.');
    await _setSession(s);
  }

  Future<void> signOut() async {
    if (_session != null) {
      try {
        await _raw('POST', '/auth/v1/logout', retry: false);
      } catch (_) {
        // Signed out on this device either way.
      }
    }
    await chooseFarm(null);
    await _setSession(null);
  }

  /// Leaves every farm and deletes this person's Dairee account. The SkiFi
  /// login itself (shared with other SkiFi apps) stays.
  Future<void> deleteAccount() async {
    await rpc('delete_my_data');
    await signOut();
  }

  // ---------------------------------------------------------------- database

  Future<dynamic> rpc(String fn, [Map<String, dynamic>? args]) async =>
      (await _raw('POST', '/rest/v1/rpc/$fn', body: args ?? const {})).json;

  /// Calls a server function in supabase/functions.
  Future<dynamic> function(String name, [Map<String, dynamic>? body]) async =>
      (await _raw('POST', '/functions/v1/$name', body: body ?? const {})).json;

  static const int page = 1000;

  /// Every row a query matches. The database API answers at most a page of
  /// rows at a time and says nothing when it stops, so this asks page after
  /// page until one comes back short.
  Future<List<Map<String, dynamic>>> select(String table,
      {String columns = '*', Map<String, String>? where, String? order, int? limit}) async {
    final out = <Map<String, dynamic>>[];
    for (var from = 0;; from += page) {
      final size = limit == null ? page : (limit - out.length).clamp(0, page);
      if (size == 0) break;
      final q = <String, String>{'select': columns, ...?where};
      if (order != null) q['order'] = order;
      final r = await _raw('GET', '/rest/v1/$table', query: q, headers: {'Range-Unit': 'items', 'Range': '$from-${from + size - 1}'});
      final rows = (r.json as List? ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      out.addAll(rows);
      if (rows.length < size) break;
    }
    return out;
  }

  Future<Map<String, dynamic>> insert(String table, Map<String, dynamic> row, {String columns = '*'}) async {
    final r = await _raw('POST', '/rest/v1/$table',
        query: {'select': columns}, body: row, headers: {'Prefer': 'return=representation'});
    final list = r.json as List? ?? const [];
    if (list.isEmpty) throw ApiError('That was not saved. You may not have permission.');
    return Map<String, dynamic>.from(list.first as Map);
  }

  /// Changes rows and returns them. A change the database refuses does not
  /// raise an error: it simply changes nothing. So an update that comes back
  /// empty is reported, never shown as saved.
  Future<List<Map<String, dynamic>>> update(String table, Map<String, dynamic> patch,
      {required Map<String, String> where, String columns = '*'}) async {
    final r = await _raw('PATCH', '/rest/v1/$table',
        query: {'select': columns, ...where}, body: patch, headers: {'Prefer': 'return=representation'});
    final list = (r.json as List? ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    if (list.isEmpty) throw ApiError('Nothing was changed. You may not have permission, or it was removed.');
    return list;
  }

  Future<int> delete(String table, {required Map<String, String> where}) async {
    final r = await _raw('DELETE', '/rest/v1/$table',
        query: {'select': 'id', ...where}, headers: {'Prefer': 'return=representation'});
    final n = (r.json as List? ?? const []).length;
    if (n == 0) throw ApiError('Nothing was deleted. You may not have permission, or it was already gone.');
    return n;
  }
}

class _Reply {
  _Reply(this.json, this.headers);
  final dynamic json;
  final Map<String, String> headers;
}

/// The customer portal: a mobile number and a password the farm gave, checked
/// by the database, which hands back a session token kept on this device.
class Portal {
  Portal._();
  static final Portal instance = Portal._();

  static const _key = 'dairee.portal';
  http.Client _http = http.Client();

  /// For tests and screenshots: answers from a stand-in server.
  set client(http.Client c) => _http = c;
  final StreamController<String?> _changes = StreamController<String?>.broadcast();
  String? token;

  bool get signedIn => token != null;
  Stream<String?> get changes => _changes.stream;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      token = prefs.getString(_key);
    } catch (_) {
      token = null;
    }
  }

  Future<void> _set(String? t) async {
    token = t;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (t == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, t);
      }
    } catch (_) {
      // Kept for this visit either way.
    }
    _changes.add(t);
  }

  Future<dynamic> _call(String fn, Map<String, dynamic> args) async {
    if (Api.instance.offline) throw ApiError(_noConnection);
    http.Response r;
    try {
      r = await _http
          .post(Uri.parse('$kApiBase/rest/v1/rpc/$fn'),
              headers: const {'apikey': 'public', 'Content-Type': 'application/json', 'Accept': 'application/json'},
              body: jsonEncode(args))
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw ApiError(_timeout);
    } catch (_) {
      throw ApiError(_noConnection);
    }
    dynamic j;
    try {
      j = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      j = null;
    }
    if (r.statusCode >= 200 && r.statusCode < 300) return j;
    final e = Api.error(r.statusCode, j);
    if (r.statusCode == 401) await _set(null);
    throw e;
  }

  /// Signs in. Returns the farms to choose from when the same number and
  /// password work at more than one; otherwise null, and the portal is open.
  Future<List<Map<String, dynamic>>?> signIn(String phone, String password, {String? farm}) async {
    final j = await _call('portal_sign_in', {'phone': phone, 'password': password, 'farm': farm});
    // A wrong password comes back as an answer, so the server's count of tries sticks.
    if (j is Map && j['error'] != null) throw ApiError('${j['error']}', status: 400);
    if (j is Map && j['choose'] is List) {
      return (j['choose'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    final t = j is Map ? j['token'] as String? : null;
    if (t == null) throw ApiError('Sign-in did not finish. Please try again.');
    await _set(t);
    return null;
  }

  Future<dynamic> call(String fn, [Map<String, dynamic>? args]) {
    final t = token;
    if (t == null) throw ApiError('Please sign in again.', status: 401);
    return _call(fn, {'token': t, ...?args});
  }

  Future<void> signOut() async {
    final t = token;
    if (t != null) {
      try {
        await _call('portal_sign_out', {'token': t});
      } catch (_) {
        // Signed out on this device either way.
      }
    }
    await _set(null);
  }
}
