import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'config.dart';

/// Sign in with Google (every platform) and with Apple (iPhone), both through
/// SkAuth. Google goes through SkAuth's own Google sign-in with a PKCE code:
/// the phones open it in the system's sign-in sheet and come back through
/// dairee.skifi.co/auth/app, which hands the code to the app's own address;
/// the web app leaves for Google and picks the code up when it comes back.
/// Apple is the native sheet, whose token SkAuth checks itself.

/// The app's own address scheme, which the sign-in sheet listens for.
const _scheme = 'co.skifi.dairee';
const _verifierKey = 'dairee.pkce_verifier';

/// The person closed the sign-in sheet: not an error worth showing.
class SignInCancelled implements Exception {}

/// Apple's sheet is offered on the iPhone only (Google is everywhere).
bool get appleOffered => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

String _random(int length) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final r = Random.secure();
  return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
}

String _challenge(String verifier) => base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');

Future<void> signInWithGoogle() async {
  final verifier = _random(64);
  final back = kIsWeb ? '$kApiBase/app/' : '$kSite/auth/app';
  final url = Uri.parse('$kApiBase/auth/v1/authorize').replace(queryParameters: {
    'provider': 'google',
    'redirect_to': back,
    'code_challenge': _challenge(verifier),
    'code_challenge_method': 's256',
  });

  if (kIsWeb) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_verifierKey, verifier);
    // The page leaves for Google; finishWebSignIn picks it up on the way back.
    await launchUrl(url, webOnlyWindowName: '_self');
    return;
  }

  final String result;
  try {
    result = await FlutterWebAuth2.authenticate(url: url.toString(), callbackUrlScheme: _scheme);
  } on PlatformException catch (e) {
    if (e.code == 'CANCELED' || e.code == 'CANCELLED') throw SignInCancelled();
    throw ApiError('Google sign-in did not open. Please try again.');
  }
  await _finish(Uri.parse(result).queryParameters, verifier);
}

/// On the web app: back from Google with a code in the address.
Future<void> finishWebSignIn() async {
  if (!kIsWeb) return;
  final q = Uri.base.queryParameters;
  if (q['code'] == null && q['error'] == null) return;
  final prefs = await SharedPreferences.getInstance();
  final verifier = prefs.getString(_verifierKey);
  await prefs.remove(_verifierKey);
  if (verifier == null) return; // an old address, already used
  await _finish(q, verifier);
}

Future<void> _finish(Map<String, String> q, String verifier) async {
  if (q['error'] != null) {
    if (q['error'] == 'access_denied') throw SignInCancelled();
    throw ApiError(q['error_description'] ?? 'Google sign-in did not finish. Please try again.');
  }
  final code = q['code'];
  if (code == null || code.isEmpty) throw ApiError('Google sign-in did not finish. Please try again.');
  await Api.instance.exchangeCode(code, verifier);
}

Future<void> signInWithApple() async {
  final raw = _random(32);
  final AuthorizationCredentialAppleID cred;
  try {
    cred = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
      nonce: sha256.convert(utf8.encode(raw)).toString(),
    );
  } on SignInWithAppleAuthorizationException catch (e) {
    if (e.code == AuthorizationErrorCode.canceled) throw SignInCancelled();
    throw ApiError('Apple sign-in did not finish. Please try again.');
  }
  final token = cred.identityToken;
  if (token == null) throw ApiError('Apple sign-in did not finish. Please try again.');
  await Api.instance.signInWithIdToken('apple', token, nonce: raw);
}
