import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../start/welcome.dart' show PhoneField, fullPhone;
import '../theme.dart';
import '../widgets.dart';
import 'changes.dart';
import 'staff_gate.dart' show copyText;

const kCustomerTypes = ['home', 'shop', 'office', 'hostel', 'hotel', 'bulk'];
String typeLabel(String t) => t.isEmpty ? 'Home' : t[0].toUpperCase() + t.substring(1).replaceAll('_', ' ');

const _cols = 'id,name,phone,customer_type,building,room,address,route_order,milk_quantity,morning_quantity,evening_quantity,'
    'delivery_slot,delivery_staff_id,start_date,status,remarks,qr_token,created_at';

/// Every customer of the farm, page after page.
Future<List<Map<String, dynamic>>> loadCustomers({bool activeOnly = false}) => Api.instance.select('customers',
    columns: _cols, where: activeOnly ? {'status': 'eq.active'} : null, order: 'building.asc.nullsfirst,route_order.asc,name.asc');

/// Pick one customer, with a search box.
Future<Map<String, dynamic>?> pickCustomer(BuildContext context, {String title = 'Pick a customer'}) async {
  List<Map<String, dynamic>> list;
  try {
    list = await loadCustomers(activeOnly: true);
  } on ApiError catch (e) {
    if (context.mounted) toast(context, e.message, bad: true);
    return null;
  }
  if (!context.mounted) return null;
  final p = await showPicker<String>(context,
      title: title, search: true, options: [for (final c in list) PickOption(c['id'] as String, '${c['name']}', sub: placeOf(c))]);
  if (p == null) return null;
  return list.firstWhere((c) => c['id'] == p.value);
}

String quantityText(Map<String, dynamic> c) {
  final slot = c['delivery_slot'];
  if (slot == 'both') return '${litres(c['morning_quantity'])} morning, ${litres(c['evening_quantity'])} evening';
  return '${litres(c['milk_quantity'])} ${slot == 'evening' ? 'evening' : 'morning'}';
}

class CustomersPage extends StatefulWidget {
  const CustomersPage({super.key, required this.farm});
  final FarmRole farm;

  @override
  State<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<CustomersPage> {
  List<Map<String, dynamic>>? list;
  String? error;
  String status = 'active';
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await loadCustomers();
      if (mounted) {
        setState(() {
          list = r;
          error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> _open(Map<String, dynamic> c) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CustomerPage(farm: widget.farm, customer: c)));
    _load();
  }

  Future<void> _add() async {
    final made = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => CustomerEditor(farm: widget.farm)));
    await _load();
    if (made != null && mounted) _open(made);
  }

  @override
  Widget build(BuildContext context) {
    final all = list;
    final t = _q.text.trim().toLowerCase();
    final shown = (all ?? const <Map<String, dynamic>>[]).where((c) {
      if (status != 'all' && c['status'] != status) return false;
      if (t.isEmpty) return true;
      return '${c['name']} ${placeOf(c)} ${c['phone']} ${c['address'] ?? ''}'.toLowerCase().contains(t);
    }).toList();
    final canEdit = widget.farm.can('customers');
    return Scaffold(
      appBar: AppBar(title: const Text('Customers'), actions: [
        if (canEdit) RoundIcon(Icons.person_add_alt_1_rounded, tooltip: 'Add a customer', onTap: _add),
        const SizedBox(width: 8),
      ]),
      body: PageBody(onRefresh: _load, children: [
        SearchField(controller: _q, hint: 'Search name, room or number', onChanged: (_) => setState(() {})),
        const SizedBox(height: Sp.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: KSegmented<String>(
            items: [
              ('active', 'Active ${(all ?? const []).where((c) => c['status'] == 'active').length}'),
              ('stopped', 'Stopped ${(all ?? const []).where((c) => c['status'] == 'stopped').length}'),
              ('all', 'All'),
            ],
            value: status,
            onChanged: (v) => setState(() => status = v),
          ),
        ),
        const SizedBox(height: Sp.md),
        if (error != null && all == null)
          LoadFailed(message: error!, onRetry: _load)
        else if (all == null)
          const Padding(padding: EdgeInsets.all(40), child: Loading())
        else if (all.isEmpty)
          EmptyState(
            icon: Icons.people_outline_rounded,
            text: 'No customers yet. Add the first one, with how much milk they take and on which round.',
            action: canEdit ? KButton(label: 'Add a customer', icon: Icons.person_add_alt_1_rounded, onPressed: _add) : null,
          )
        else if (shown.isEmpty)
          const EmptyState(icon: Icons.search_off_rounded, text: 'Nobody matches.')
        else
          KGroup(children: [
            for (final c in shown)
              KRow(
                leading: Avatar('${c['name']}', size: 36, color: c['status'] == 'active' ? K.brand100 : K.surface2, fg: c['status'] == 'active' ? K.brand600 : K.muted),
                title: '${c['name']}',
                sub: [placeOf(c), quantityText(c)].where((x) => x.isNotEmpty).join(', '),
                trailing: c['status'] == 'stopped' ? const Pill.grey('Stopped') : const Icon(Icons.chevron_right_rounded, color: K.muted),
                onTap: () => _open(c),
              ),
          ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------- one customer

class CustomerPage extends StatefulWidget {
  const CustomerPage({super.key, required this.farm, required this.customer});
  final FarmRole farm;
  final Map<String, dynamic> customer;

  @override
  State<CustomerPage> createState() => _CustomerPageState();
}

class _CustomerPageState extends State<CustomerPage> {
  late Map<String, dynamic> c = widget.customer;
  List<Map<String, dynamic>> vessels = const [];
  List? history;
  Map<String, dynamic>? login;
  Map<String, dynamic>? money;
  String? staffName;

  String get id => c['id'] as String;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        Api.instance.select('customers', columns: _cols, where: {'id': 'eq.$id'}),
        Api.instance.select('customer_containers', columns: 'id,container_id,quantity,slot,containers(name,category,capacity_ml)', where: {'customer_id': 'eq.$id'}),
        Api.instance.rpc('customer_history', {'customer_id': id, 'days': 21}),
        Api.instance.rpc('customer_logins_status'),
        if (widget.farm.seesMoney) Api.instance.rpc('customer_balances'),
      ]);
      final rows = results[0] as List;
      if (rows.isEmpty) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final logins = results[3] is Map ? results[3] as Map : const {};
      Map<String, dynamic>? m;
      if (widget.farm.seesMoney && results.length > 4) {
        for (final b in (results[4] as List? ?? const []).whereType<Map>()) {
          if (b['customer_id'] == id) m = Map<String, dynamic>.from(b);
        }
      }
      String? sName;
      final sid = (rows.first as Map)['delivery_staff_id'];
      if (sid != null) {
        final s = await Api.instance.select('staff', columns: 'name', where: {'id': 'eq.$sid'});
        if (s.isNotEmpty) sName = '${s.first['name']}';
      }
      if (!mounted) return;
      setState(() {
        c = Map<String, dynamic>.from(rows.first as Map);
        vessels = (results[1] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        history = results[2] as List?;
        login = logins[id] is Map ? Map<String, dynamic>.from(logins[id] as Map) : null;
        money = m;
        staffName = sName;
      });
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  List<Map<String, dynamic>> _vesselsFor(String slot) => vessels.where((v) => v['slot'] == slot).toList();

  String _vesselsLine(String slot) {
    final v = _vesselsFor(slot);
    if (v.isEmpty) return 'No vessels set';
    return v.map((x) {
      final k = x['containers'] as Map? ?? const {};
      final n = toNum(x['quantity']).toInt();
      return n == 1 ? '${k['name']}' : '$n x ${k['name']}';
    }).join(', ');
  }

  bool get _takesMorning => c['delivery_slot'] != 'evening';
  bool get _takesEvening => c['delivery_slot'] != 'morning';

  Future<void> _password() async {
    try {
      final r = await Api.instance.rpc('issue_customer_password', {'customer_id': id});
      if (!mounted || r is! Map) return;
      final msg = 'Dairee, your milk account\n${customerUrl(widget.farm.slug)}\n\nMobile number: ${localPhone(r['phone'] as String?)}\n\n'
          'Temporary password: ${r['password']}\n\nYou will be asked to choose your own password when you sign in.';
      await _load();
      if (!mounted) return;
      await showKSheet<void>(context, title: 'Send it now', builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Send this to ${c['name']} now. The password is shown once; it is a handover, not something to keep.', style: T.small),
            const SizedBox(height: Sp.md),
            KCard(child: SelectableText(msg, style: T.body)),
            const SizedBox(height: Sp.lg),
            KButton(label: 'Copy login details', icon: Icons.copy_rounded, expand: true, onPressed: () => copyText(ctx, msg, 'Login details copied')),
            const SizedBox(height: Sp.sm),
            KButton(
              label: 'Send on WhatsApp',
              icon: Icons.chat_rounded,
              kind: KButtonKind.secondary,
              expand: true,
              onPressed: () => launchUrl(Uri.parse('https://api.whatsapp.com/send?phone=${c['phone']}&text=${Uri.encodeComponent(msg)}'),
                  mode: LaunchMode.externalApplication),
            ),
          ]));
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _revoke() async {
    if (!await confirm(context, title: 'Stop ${c['name']} signing in?', text: 'They are signed out everywhere. You can give a new password later.', yes: 'Stop sign-in')) return;
    try {
      await Api.instance.rpc('revoke_customer_login', {'customer_id': id});
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _price() async {
    final ctl = TextEditingController(text: money?['price'] == null ? '' : '${money!['price']}');
    final r = await showKSheet<String>(context, title: 'Own price for ${c['name']}', builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Leave empty to use the farm\'s price for the day.', style: T.small),
          const SizedBox(height: Sp.md),
          KField(label: 'Price a litre', controller: ctl, keyboard: const TextInputType.numberWithOptions(decimal: true), prefix: '${currencyOf(widget.farm.currency).symbol} '),
          const SizedBox(height: Sp.lg),
          KButton(label: 'Save', icon: Icons.check_rounded, expand: true, onPressed: () => Navigator.of(ctx).pop(ctl.text.trim())),
        ]));
    ctl.dispose();
    if (r == null) return;
    try {
      await Api.instance.rpc('set_customer_price', {'customer_id': id, 'price': r.isEmpty ? null : num.tryParse(r)});
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _delete() async {
    if (!await confirm(context,
        title: 'Delete ${c['name']}?',
        text: 'Their deliveries and pauses go too. A customer with bills or payments cannot be deleted: stop them instead.',
        yes: 'Delete',
        danger: true)) {
      return;
    }
    try {
      await Api.instance.delete('customers', where: {'id': 'eq.$id'});
      if (mounted) Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _setStatus(String s) async {
    try {
      await Api.instance.update('customers', {'status': s}, where: {'id': 'eq.$id'}, columns: 'id');
      await _load();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.farm;
    final canEdit = f.can('customers');
    final stopped = c['status'] == 'stopped';
    return Scaffold(
      appBar: AppBar(title: Text('${c['name']}'), actions: [
        if (canEdit)
          RoundIcon(Icons.edit_outlined, tooltip: 'Edit', onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CustomerEditor(farm: f, customer: c)));
            _load();
          }),
        const SizedBox(width: 8),
      ]),
      body: PageBody(onRefresh: _load, children: [
        KCard(
          child: Row(children: [
            Avatar('${c['name']}', size: 46),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${c['name']}', style: T.h2),
                if (placeOf(c).isNotEmpty) Text(placeOf(c), style: T.small),
                Text('${prettyPhone(c['phone'] as String?)}${(c['customer_type'] ?? 'home') == 'home' ? '' : ', ${typeLabel('${c['customer_type']}').toLowerCase()}'}', style: T.small),
              ]),
            ),
            RoundIcon(Icons.call_rounded, tooltip: 'Call', onTap: () => launchUrl(Uri.parse('tel:+${c['phone']}'))),
          ]),
        ),
        if (stopped) ...[const SizedBox(height: Sp.md), const Notice('Stopped: not on any round.', bad: false)],
        const SectionTitle('Milk'),
        KGroup(children: [
          if (_takesMorning)
            KRow(title: 'Morning, ${litres(c['delivery_slot'] == 'both' ? c['morning_quantity'] : c['milk_quantity'])}', sub: _vesselsLine('morning')),
          if (_takesEvening)
            KRow(title: 'Evening, ${litres(c['delivery_slot'] == 'both' ? c['evening_quantity'] : c['milk_quantity'])}', sub: _vesselsLine('evening')),
          KRow(title: 'Since ${dateLabel(parseDay(c['start_date']) ?? DateTime.now())}', sub: staffName == null ? 'No delivery person set' : 'Delivered by $staffName'),
          if ((c['remarks'] as String? ?? '').isNotEmpty) KRow(title: 'Notes', sub: '${c['remarks']}'),
        ]),
        const SizedBox(height: Sp.md),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
          if (canEdit)
            KButton(
                label: 'Vessels',
                icon: Icons.local_drink_outlined,
                kind: KButtonKind.secondary,
                small: true,
                onPressed: () async {
                  if (await editVessels(context, c, vessels)) _load();
                }),
          if (f.can('pauses')) ...[
            KButton(
                label: 'Pause',
                icon: Icons.pause_rounded,
                kind: KButtonKind.secondary,
                small: true,
                onPressed: () async {
                  if (await showPauseSheet(context, f, c)) _load();
                }),
            KButton(
                label: 'Change a day',
                icon: Icons.swap_horiz_rounded,
                kind: KButtonKind.secondary,
                small: true,
                onPressed: () async {
                  if (await showTemporarySheet(context, f, c)) _load();
                }),
          ],
        ]),
        if (widget.farm.seesMoney) ...[
          const SectionTitle('Money'),
          KGroup(children: [
            KRow(title: 'Owes ${f.money(toNum(money?['outstanding']))}', sub: '${money?['unpaid_bills'] ?? 0} unpaid bills'),
            KRow(title: 'Credit ${f.money(toNum(money?['credit']))}', sub: 'Advance money not used yet'),
            KRow(
              title: money?['price'] == null ? 'Farm price' : 'Own price ${f.money(toNum(money!['price']))} a litre',
              sub: 'Tap to change',
              onTap: _price,
              trailing: const Icon(Icons.chevron_right_rounded, color: K.muted),
            ),
          ]),
        ],
        const SectionTitle('Sign-in to the customer app'),
        KGroup(children: [
          KRow(
            title: login == null ? 'Cannot sign in yet' : (login!['temporary'] == true ? 'Has a temporary password' : 'Signs in with their own password'),
            sub: login == null
                ? 'Give a password and send it on WhatsApp'
                : (login!['last_seen'] == null ? 'Not signed in yet' : 'Last seen ${stamp(DateTime.parse('${login!['last_seen']}'))}'),
          ),
          if (canEdit)
            KRow(
              leading: const Icon(Icons.vpn_key_outlined, color: K.ink2, size: 20),
              title: login == null ? 'Give a password' : 'Give a new password',
              onTap: _password,
            ),
          if (canEdit && login != null)
            KRow(leading: const Icon(Icons.block_rounded, color: K.bad, size: 20), title: 'Stop sign-in', onTap: _revoke),
        ]),
        const SectionTitle('Last three weeks'),
        if (history == null)
          const Padding(padding: EdgeInsets.all(24), child: Loading())
        else if (history!.isEmpty)
          const KCard(child: Text('Nothing yet.', style: T.small))
        else
          KGroup(children: [
            for (final h in history!.whereType<Map>().take(42))
              KRow(
                title: '${dayLabel(parseDay(h['day'])!)}, ${'${h['slot']}' == 'morning' ? 'morning' : 'evening'}',
                sub: h['paused'] == true
                    ? 'Paused'
                    : '${litres(h['delivered'] == true ? h['qty'] : h['due'])}${h['temporary'] == true ? ', changed for the day' : ''}${(h['notes'] ?? '') != '' ? ', ${h['notes']}' : ''}',
                trailing: h['paused'] == true
                    ? const Pill.warn('Paused')
                    : h['delivered'] == true
                        ? const Pill('Delivered', icon: Icons.check_rounded)
                        : const Pill.grey('Not ticked'),
              ),
          ]),
        if (canEdit) ...[
          const SectionTitle('Manage'),
          KGroup(children: [
            KRow(
              leading: Icon(stopped ? Icons.play_arrow_rounded : Icons.stop_rounded, color: K.ink2, size: 20),
              title: stopped ? 'Start again' : 'Stop (no longer a customer)',
              sub: stopped ? 'Puts them back on their rounds' : 'Keeps their history and bills',
              onTap: () => _setStatus(stopped ? 'active' : 'stopped'),
            ),
            KRow(leading: const Icon(Icons.delete_outline_rounded, color: K.bad, size: 20), title: 'Delete customer', onTap: _delete),
          ]),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- vessels

/// The vessels a customer takes on each of their rounds. Saved as one set:
/// if the save fails, they keep the vessels they had.
Future<bool> editVessels(BuildContext context, Map<String, dynamic> c, List<Map<String, dynamic>> current) async {
  List<Map<String, dynamic>> kinds;
  try {
    kinds = await Api.instance.select('containers', columns: 'id,name,category,capacity_ml,active', where: {'active': 'eq.true'}, order: 'sort_order.asc,capacity_ml.asc');
  } on ApiError catch (e) {
    if (context.mounted) toast(context, e.message, bad: true);
    return false;
  }
  if (!context.mounted) return false;
  final slots = [if (c['delivery_slot'] != 'evening') 'morning', if (c['delivery_slot'] != 'morning') 'evening'];
  final counts = <String, int>{};
  for (final v in current) {
    counts['${v['slot']}|${v['container_id']}'] = toNum(v['quantity']).toInt();
  }
  num want(String slot) => toNum(c['delivery_slot'] == 'both' ? c['${slot}_quantity'] : c['milk_quantity']);
  num holds(String slot) => kinds.fold<num>(0, (a, k) => a + (counts['$slot|${k['id']}'] ?? 0) * toNum(k['capacity_ml']) / 1000);
  final saved = await showKSheet<bool>(context, title: 'Vessels for ${c['name']}', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (kinds.isEmpty) const Notice('No vessels yet. Add them in Settings.'),
          for (final slot in slots) ...[
            SectionTitle('${slotName(slot)}, ${litres(want(slot))}', top: 4,
                trailing: Pill(holds(slot) == want(slot) ? 'Holds ${litres(holds(slot))}' : 'Holds ${litres(holds(slot))} of ${litres(want(slot))}')),
            KGroup(children: [
              for (final k in kinds)
                KRow(
                  title: '${k['name']}',
                  sub: capacity(toNum(k['capacity_ml']).toInt()),
                  trailing: _Stepper(
                    value: counts['$slot|${k['id']}'] ?? 0,
                    onChanged: (n) => set(() => counts['$slot|${k['id']}'] = n),
                  ),
                ),
            ]),
            const SizedBox(height: Sp.md),
          ],
          KButton(
            label: 'Save vessels',
            icon: Icons.check_rounded,
            expand: true,
            onPressed: () async {
              final items = [
                for (final e in counts.entries)
                  if (e.value > 0 && slots.contains(e.key.split('|').first))
                    {'slot': e.key.split('|').first, 'container_id': e.key.split('|').last, 'quantity': e.value},
              ];
              try {
                await Api.instance.rpc('save_customer_vessels', {'customer_id': c['id'], 'items': items});
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } on ApiError catch (e) {
                // The delete and the insert are one: on a failure the old set stays.
                if (ctx.mounted) toast(ctx, '${e.message} Nothing was changed.', bad: true);
              }
            },
          ),
        ]);
      }));
  return saved == true;
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      RoundIcon(Icons.remove_rounded, size: 30, tooltip: 'One less', onTap: value > 0 ? () => onChanged(value - 1) : null),
      SizedBox(width: 26, child: Text('$value', textAlign: TextAlign.center, style: T.bodyStrong.merge(T.tabular))),
      RoundIcon(Icons.add_rounded, size: 30, tooltip: 'One more', onTap: value < 50 ? () => onChanged(value + 1) : null),
    ]);
  }
}

// ---------------------------------------------------------------- add or edit

class CustomerEditor extends StatefulWidget {
  const CustomerEditor({super.key, required this.farm, this.customer});
  final FarmRole farm;
  final Map<String, dynamic>? customer;

  @override
  State<CustomerEditor> createState() => _CustomerEditorState();
}

class _CustomerEditorState extends State<CustomerEditor> {
  Map<String, dynamic> get c => widget.customer ?? const {};
  late final _name = TextEditingController(text: c['name'] as String? ?? '');
  late final _phone = TextEditingController(text: localPhone(c['phone'] as String?));
  late String cc = (c['phone'] as String? ?? '91').length > 10 ? (c['phone'] as String).substring(0, (c['phone'] as String).length - 10) : '91';
  late final _building = TextEditingController(text: c['building'] as String? ?? '');
  late final _room = TextEditingController(text: c['room'] as String? ?? '');
  late final _address = TextEditingController(text: c['address'] as String? ?? '');
  late final _order = TextEditingController(text: c['route_order'] == null ? '' : '${c['route_order']}');
  late final _qty = TextEditingController(text: c['delivery_slot'] == 'both' || c['milk_quantity'] == null ? '' : _n(c['milk_quantity']));
  late final _am = TextEditingController(text: c['morning_quantity'] == null ? '' : _n(c['morning_quantity']));
  late final _pm = TextEditingController(text: c['evening_quantity'] == null ? '' : _n(c['evening_quantity']));
  late final _remarks = TextEditingController(text: c['remarks'] as String? ?? '');
  late String type = (c['customer_type'] as String?) ?? 'home';
  late String slot = (c['delivery_slot'] as String?) ?? 'morning';
  late DateTime start = parseDay(c['start_date']) ?? widget.farm.today;
  late String? staffId = c['delivery_staff_id'] as String?;
  List<Map<String, dynamic>> deliverers = const [];
  bool busy = false;
  String? error;

  static String _n(Object? v) {
    final n = toNum(v);
    return n == n.truncate() ? '${n.truncate()}' : '$n';
  }

  @override
  void initState() {
    super.initState();
    Api.instance.select('staff', columns: 'id,name,can_deliver,active', where: {'active': 'eq.true'}, order: 'name.asc').then((r) {
      if (mounted) setState(() => deliverers = r);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    for (final t in [_name, _phone, _building, _room, _address, _order, _qty, _am, _pm, _remarks]) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final phone = fullPhone(cc, _phone.text);
    num? q(TextEditingController t) => num.tryParse(t.text.trim().replaceAll(',', '.'));
    if (_name.text.trim().isEmpty) {
      setState(() => error = 'Give the customer a name.');
      return;
    }
    if (phone.isEmpty) {
      setState(() => error = 'Add their mobile number.');
      return;
    }
    if (slot == 'both' && ((q(_am) ?? 0) <= 0 || (q(_pm) ?? 0) <= 0)) {
      setState(() => error = 'Give the morning and the evening quantity.');
      return;
    }
    if (slot != 'both' && (q(_qty) ?? 0) <= 0) {
      setState(() => error = 'Give how many litres they take.');
      return;
    }
    final row = <String, dynamic>{
      'name': _name.text.trim(),
      'phone': phone,
      'customer_type': type,
      'building': _building.text.trim(),
      'room': _room.text.trim(),
      'address': _address.text.trim(),
      'route_order': int.tryParse(_order.text.trim()) ?? 0,
      'delivery_slot': slot,
      'milk_quantity': slot == 'both' ? (q(_am)! + q(_pm)!) : q(_qty),
      'morning_quantity': slot == 'both' ? q(_am) : null,
      'evening_quantity': slot == 'both' ? q(_pm) : null,
      'start_date': isoDay(start),
      'delivery_staff_id': staffId,
      'remarks': _remarks.text.trim(),
    };
    setState(() {
      busy = true;
      error = null;
    });
    try {
      Map<String, dynamic> saved;
      if (widget.customer == null) {
        saved = await Api.instance.insert('customers', row, columns: _cols);
      } else {
        saved = (await Api.instance.update('customers', row, where: {'id': 'eq.${c['id']}'}, columns: _cols)).first;
      }
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final num0 = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    final staffName = deliverers.where((s) => s['id'] == staffId).map((s) => '${s['name']}').firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(widget.customer == null ? 'New customer' : 'Edit ${c['name']}')),
      body: PageBody(maxWidth: 560, children: [
        if (error != null) ...[Notice(error!), const SizedBox(height: Sp.md)],
        KField(label: 'Name', controller: _name, caps: TextCapitalization.words, autofocus: widget.customer == null),
        const SizedBox(height: Sp.md),
        const Text('Mobile number', style: T.label),
        const SizedBox(height: 6),
        PhoneField(cc: cc, onCc: (v) => setState(() => cc = v), controller: _phone, autofocus: false),
        const SizedBox(height: Sp.md),
        Row(children: [
          Expanded(child: KField(label: 'Building', controller: _building, hint: 'Tower 1', caps: TextCapitalization.words)),
          const SizedBox(width: Sp.md),
          Expanded(child: KField(label: 'Room or flat', controller: _room, hint: '101')),
        ]),
        const SizedBox(height: Sp.md),
        KField(label: 'Address', controller: _address, maxLines: 2),
        const SizedBox(height: Sp.md),
        Row(children: [
          Expanded(
            child: KChoice(
              label: 'Type',
              value: typeLabel(type),
              onTap: () async {
                final p = await showPicker<String>(context, title: 'Type', selected: type, options: [for (final t in kCustomerTypes) PickOption(t, typeLabel(t))]);
                if (p != null) setState(() => type = p.value);
              },
            ),
          ),
          const SizedBox(width: Sp.md),
          Expanded(child: KField(label: 'Walking order', controller: _order, keyboard: TextInputType.number, formatters: [FilteringTextInputFormatter.digitsOnly])),
        ]),
        const SectionTitle('Milk'),
        KSegmented<String>(expand: true, items: const [('morning', 'Morning'), ('evening', 'Evening'), ('both', 'Both')], value: slot, onChanged: (v) => setState(() => slot = v)),
        const SizedBox(height: Sp.md),
        if (slot == 'both')
          Row(children: [
            Expanded(child: KField(label: 'Morning litres', controller: _am, keyboard: const TextInputType.numberWithOptions(decimal: true), formatters: num0)),
            const SizedBox(width: Sp.md),
            Expanded(child: KField(label: 'Evening litres', controller: _pm, keyboard: const TextInputType.numberWithOptions(decimal: true), formatters: num0)),
          ])
        else
          KField(label: 'Litres a day', controller: _qty, keyboard: const TextInputType.numberWithOptions(decimal: true), formatters: num0),
        const SizedBox(height: Sp.md),
        Row(children: [
          Expanded(
            child: KChoice(
              label: 'Starts on',
              value: dateLabel(start),
              icon: Icons.event_outlined,
              onTap: () async {
                final d = await pickDate(context, initial: start);
                if (d != null) setState(() => start = d);
              },
            ),
          ),
          const SizedBox(width: Sp.md),
          Expanded(
            child: KChoice(
              label: 'Delivered by',
              value: staffName ?? 'Anyone',
              onTap: () async {
                final p = await showPicker<String?>(context, title: 'Delivered by', selected: staffId, options: [
                  const PickOption<String?>(null, 'Anyone'),
                  for (final s in deliverers.where((s) => s['can_deliver'] == true || s['id'] == staffId)) PickOption<String?>(s['id'] as String, '${s['name']}'),
                ]);
                if (p != null) setState(() => staffId = p.value);
              },
            ),
          ),
        ]),
        const SizedBox(height: Sp.md),
        KField(label: 'Notes', controller: _remarks, maxLines: 3, hint: 'Leave at the door, ring twice...'),
        const SizedBox(height: Sp.xl),
        KButton(label: widget.customer == null ? 'Add customer' : 'Save', icon: Icons.check_rounded, expand: true, busy: busy, onPressed: _save),
        if (widget.customer == null) ...[
          const SizedBox(height: Sp.sm),
          Text('Next: set their vessels, so the packing list knows what to fill.', textAlign: TextAlign.center, style: T.small),
        ],
      ]),
    );
  }
}
