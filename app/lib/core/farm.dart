import 'package:flutter/foundation.dart';

import 'api.dart';
import 'format.dart';

/// One farm the signed-in person works for, and what they may do there.
class FarmRole {
  FarmRole(this.j);
  final Map<String, dynamic> j;

  String get id => j['farm_id'] as String;
  String get name => (j['name'] as String?) ?? 'Farm';
  String get slug => (j['slug'] as String?) ?? '';
  String get currency => (j['currency'] as String?) ?? 'INR';
  String get timezone => (j['timezone'] as String?) ?? 'Asia/Kolkata';
  String get staffId => j['staff_id'] as String;
  String get staffName => (j['staff_name'] as String?) ?? '';
  bool get isAdmin => j['is_admin'] == true;
  bool get canDeliver => j['can_deliver'] == true;
  bool get canCare => j['can_care'] == true;
  bool get mustChangePassword => j['must_change_password'] == true;
  bool get profileEditing => j['profile_editing'] == true;
  List<String> get permissions => (j['permissions'] as List? ?? const []).map((e) => '$e').toList();

  /// The farm's own today, from the server (the phone's clock may be set anywhere).
  DateTime get today => parseDay(j['today']) ?? dayOnly(DateTime.now());

  /// Admin is a separate fact, not a full list: an admin opens every page.
  bool can(String page) => isAdmin || permissions.contains(page);

  /// Delivery staff with no office pages get the round and nothing else.
  bool get roundOnly => !isAdmin && permissions.isEmpty && canDeliver;
  bool get careOnly => !isAdmin && permissions.isEmpty && !canDeliver && canCare;
  bool get nothing => !isAdmin && permissions.isEmpty && !canDeliver && !canCare;

  /// Money is shown only with the Payments page.
  bool get seesMoney => can('payments');

  String money(num? v) => format(v);
  String format(num? v) => currencyOf(currency).format(v ?? 0);
}

/// The signed-in person and their farms, from whoami.
class Me extends ChangeNotifier {
  Me._();
  static final Me instance = Me._();

  Map<String, dynamic> j = const {};
  List<FarmRole> farms = const [];
  FarmRole? farm;
  List<(String, String)> areas = const [];

  String? get email => j['email'] as String?;
  String? get phone => j['phone'] as String?;

  /// Asks the server who this is, links any staff rows waiting for this
  /// number or email, and picks the farm (the last one used, or the first).
  Future<void> load() async {
    final r = await Api.instance.rpc('whoami');
    j = r is Map ? Map<String, dynamic>.from(r) : <String, dynamic>{};
    farms = (j['farms'] as List? ?? const []).whereType<Map>().map((e) => FarmRole(Map<String, dynamic>.from(e))).toList();
    areas = (j['areas'] as List? ?? const []).whereType<Map>().map((e) => ('${e['key']}', '${e['label']}')).toList();
    final want = Api.instance.farmId;
    farm = farms.where((f) => f.id == want).firstOrNull ?? farms.firstOrNull;
    await Api.instance.chooseFarm(farm?.id);
    notifyListeners();
  }

  Future<void> switchTo(FarmRole f) async {
    farm = f;
    await Api.instance.chooseFarm(f.id);
    notifyListeners();
  }

  void clear() {
    j = const {};
    farms = const [];
    farm = null;
    notifyListeners();
  }
}
