import 'package:flutter/foundation.dart' show kIsWeb;

/// Where the Dairee server lives. In the browser it is the address the app
/// was opened from; on the phones it is dairee.skifi.co, or whatever a build
/// names with --dart-define=DAIREE_API=https://example.com
const String _built = String.fromEnvironment('DAIREE_API', defaultValue: 'https://dairee.skifi.co');

String get kApiBase {
  if (kIsWeb) {
    final o = Uri.base;
    if (o.scheme == 'http' || o.scheme == 'https') return o.origin;
  }
  return _built;
}

/// The public site, for links in messages (never the local test address).
const String kSite = _built;
String get kPrivacyUrl => '$kSite/privacy';
String get kTermsUrl => '$kSite/terms';
String get kSupportUrl => '$kSite/support';
const String kSupportEmail = 'contact@skifi.co';

/// The web app's sign-in page, sent to new staff.
String get kLoginUrl => '$kSite/app/';

/// A farm's customers sign in here.
String customerUrl(String slug) => '$kSite/c/$slug';
