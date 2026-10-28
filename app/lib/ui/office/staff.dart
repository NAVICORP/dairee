import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../start/welcome.dart' show PhoneField, fullPhone;
import '../theme.dart';
import '../widgets.dart';
import 'staff_gate.dart' show copyText;

const _cols = 'id,name,phone,email,active,auth_user_id,position,can_deliver,can_care,is_admin,permissions,profile_editing,created_at';

/// The people who work on the farm and what each may open.
class StaffPage extends StatefulWidget {
  const StaffPage({super.key, required this.farm});
  final FarmRole farm;

  @override
  State<StaffPage> createState() => _StaffPageState();
}

class _StaffPageState extends State<StaffPage> {
  List<Map<String, dynamic>>? list;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.instance.select('staff', columns: _cols, order: 'active.desc,is_admin.desc,name.asc');
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

  Future<void> _edit([Map<String, dynamic>? s]) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StaffEditor(farm: widget.farm, staff: s)));
    _load();
  }

  String _what(Map<String, dynamic> s) {
    if (s['is_admin'] == true) return 'Admin, every page';
    final parts = <String>[
      if (s['can_deliver'] == true) 'Delivers',
      if (s['can_care'] == true) 'Cares for cows',
      ...((s['permissions'] as List? ?? const []).map((p) => Me.instance.areas.where((a) => a.$1 == p).map((a) => a.$2).firstOrNull ?? '$p')),
    ];
    return parts.isEmpty ? 'No pages yet' : parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Staff')),
      floatingActionButton: KFab(label: 'New staff', icon: Icons.add_rounded, onPressed: () => _edit()),
      body: PageBody(onRefresh: _load, bottom: 112, children: [
        if (error != null && list == null)
          LoadFailed(message: error!, onRetry: _load)
        else if (list == null)
          const Padding(padding: EdgeInsets.all(40), child: Loading())
        else
          KGroup(children: [
            for (final s in list!)
              KRow(
                leading: Avatar('${s['name']}', size: 36, color: s['active'] == true ? K.brand100 : K.surface2, fg: s['active'] == true ? K.brand600 : K.muted),
                title: '${s['name']}${s['position'] == null ? '' : ', ${s['position']}'}',
                sub: '${_what(s)}\n${s['auth_user_id'] == null ? 'Has not signed in yet' : 'Signed in'}${s['active'] == true ? '' : ', switched off'}',
                trailing: const Icon(Icons.chevron_right_rounded, color: K.muted),
                onTap: () => _edit(s),
              ),
          ]),
        const SizedBox(height: Sp.md),
        const Notice('Staff sign in with a code to the WhatsApp number or email you add here. Once in, they can choose a password for their email under Profile.', bad: false),
      ]),
    );
  }
}

class StaffEditor extends StatefulWidget {
  const StaffEditor({super.key, required this.farm, this.staff});
  final FarmRole farm;
  final Map<String, dynamic>? staff;

  @override
  State<StaffEditor> createState() => _StaffEditorState();
}

class _StaffEditorState extends State<StaffEditor> {
  late Map<String, dynamic> s = Map<String, dynamic>.from(widget.staff ?? const {});
  late final _name = TextEditingController(text: s['name'] as String? ?? '');
  late final _phone = TextEditingController(text: localPhone(s['phone'] as String?));
  late final _email = TextEditingController(text: s['email'] as String? ?? '');
  late final _position = TextEditingController(text: s['position'] as String? ?? '');
  late String cc = (s['phone'] as String? ?? '91').length > 10 ? (s['phone'] as String).substring(0, (s['phone'] as String).length - 10) : '91';
  late bool deliver = s['can_deliver'] == true;
  late bool care = s['can_care'] == true;
  late bool admin = s['is_admin'] == true;
  late bool active = s['active'] != false;
  late bool profile = s['profile_editing'] == true;
  late Set<String> pages = {...(s['permissions'] as List? ?? const []).map((e) => '$e')};
  bool busy = false;
  String? error;

  bool get isNew => widget.staff == null;
  bool get iAmAdmin => widget.farm.isAdmin;

  @override
  void dispose() {
    for (final t in [_name, _phone, _email, _position]) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final phone = _phone.text.trim().isEmpty ? null : fullPhone(cc, _phone.text);
    final email = _email.text.trim().toLowerCase();
    if (_name.text.trim().isEmpty) {
      setState(() => error = 'Give a name.');
      return;
    }
    if ((phone == null || phone.isEmpty) && email.isEmpty) {
      setState(() => error = 'Add a WhatsApp number or an email, so they can sign in.');
      return;
    }
    final row = <String, dynamic>{
      'name': _name.text.trim(),
      'phone': phone == null || phone.isEmpty ? null : phone,
      'email': email.isEmpty ? null : email,
      'position': _position.text.trim().isEmpty ? null : _position.text.trim(),
      'can_deliver': deliver,
      'can_care': care,
      'active': active,
      // Only an admin changes what somebody may do; the database refuses it from anyone else.
      if (iAmAdmin) ...{'is_admin': admin, 'permissions': pages.toList(), 'profile_editing': profile},
    };
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (isNew) {
        s = await Api.instance.insert('staff', row, columns: _cols);
      } else {
        s = (await Api.instance.update('staff', row, where: {'id': 'eq.${s['id']}'}, columns: _cols)).first;
      }
      if (!mounted) return;
      toast(context, 'Saved');
      if (isNew) {
        await _details();
        if (mounted) Navigator.of(context).pop();
      } else {
        setState(() {});
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// The message for a chat: blank lines between the parts, because it is read
  /// in a chat bubble and the number is what gets retyped. Staff sign in with a
  /// code; nobody at the farm ever knows their password.
  String _message() {
    final b = StringBuffer('Dairee, your account at ${widget.farm.name}\n$kLoginUrl\n\n');
    if (s['phone'] != null) {
      b.write('Mobile number: ${localPhone(s['phone'] as String?)}\n\nSign in with WhatsApp: a code comes to this number.');
    } else {
      b.write('Email: ${s['email']}\n\nSign in with your email: a code comes to it.');
    }
    return b.toString();
  }

  Future<void> _details() async {
    final msg = _message();
    await showKSheet<void>(context, title: 'Login details', builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KCard(child: SelectableText(msg, style: T.body)),
          const SizedBox(height: Sp.lg),
          KButton(label: 'Copy login details', icon: Icons.copy_rounded, expand: true, onPressed: () => copyText(ctx, msg, 'Login details copied')),
          if (s['phone'] != null) ...[
            const SizedBox(height: Sp.sm),
            KButton(
              label: 'Send on WhatsApp',
              icon: Icons.chat_rounded,
              kind: KButtonKind.secondary,
              expand: true,
              onPressed: () => launchUrl(Uri.parse('https://api.whatsapp.com/send?phone=${s['phone']}&text=${Uri.encodeComponent(msg)}'), mode: LaunchMode.externalApplication),
            ),
          ],
        ]));
  }

  Future<void> _delete() async {
    if (!await confirm(context, title: 'Remove ${s['name']}?', text: 'They can no longer open this farm. Their past ticks and records stay.', yes: 'Remove', danger: true)) return;
    try {
      await Api.instance.delete('staff', where: {'id': 'eq.${s['id']}'});
      if (mounted) Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final areas = Me.instance.areas;
    final me = s['id'] == widget.farm.staffId;
    return Scaffold(
      appBar: AppBar(title: Text(isNew ? 'New staff' : '${s['name']}')),
      body: PageBody(maxWidth: 560, children: [
        if (error != null) ...[Notice(error!), const SizedBox(height: Sp.md)],
        KField(label: 'Name', controller: _name, caps: TextCapitalization.words, autofocus: isNew),
        const SizedBox(height: Sp.md),
        KField(label: 'Job title', controller: _position, hint: 'Delivery, Office, Farm hand', caps: TextCapitalization.words),
        const SizedBox(height: Sp.md),
        const Text('WhatsApp number', style: T.label),
        const SizedBox(height: 6),
        PhoneField(cc: cc, onCc: (v) => setState(() => cc = v), controller: _phone, autofocus: false),
        const SizedBox(height: Sp.md),
        KField(label: 'Email', controller: _email, keyboard: TextInputType.emailAddress, caps: TextCapitalization.none),
        const SectionTitle('Work'),
        KCard(
          padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
          child: Column(children: [
            KSwitchRow(title: 'Delivers milk', sub: 'Sees the round and ticks it off. Never sees money.', value: deliver, onChanged: (v) => setState(() => deliver = v)),
            const Divider(),
            KSwitchRow(title: 'Cares for cows', sub: 'Adds milk, health and breeding records', value: care, onChanged: (v) => setState(() => care = v)),
            const Divider(),
            KSwitchRow(title: 'Can open Dairee', sub: 'Switch off to stop someone without deleting them', value: active, onChanged: me ? null : (v) => setState(() => active = v)),
          ]),
        ),
        SectionTitle('Pages', trailing: iAmAdmin ? null : const Pill.grey('Admins only')),
        KCard(
          padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
          child: Column(children: [
            KSwitchRow(
              title: 'Admin',
              sub: 'Opens every page, including ones added later, and manages staff',
              value: admin,
              onChanged: iAmAdmin && !me ? (v) => setState(() => admin = v) : null,
            ),
            if (!admin) ...[
              for (final a in areas) ...[
                const Divider(),
                KSwitchRow(
                  title: a.$2,
                  sub: a.$1 == 'payments' ? 'Bills, payments and prices: money' : null,
                  value: pages.contains(a.$1),
                  onChanged: iAmAdmin ? (v) => setState(() => v ? pages.add(a.$1) : pages.remove(a.$1)) : null,
                ),
              ],
              const Divider(),
              KSwitchRow(title: 'Can edit their own profile', value: profile, onChanged: iAmAdmin ? (v) => setState(() => profile = v) : null),
            ],
          ]),
        ),
        const SizedBox(height: Sp.xl),
        KButton(label: isNew ? 'Add and get login details' : 'Save', icon: Icons.check_rounded, expand: true, busy: busy, onPressed: _save),
        if (!isNew) ...[
          const SectionTitle('Signing in'),
          KGroup(children: [
            KRow(
              title: s['auth_user_id'] == null ? 'Has not signed in yet' : 'Has signed in',
              sub: 'Signs in with a code to their number or email',
            ),
            KRow(leading: const Icon(Icons.copy_rounded, color: K.ink2, size: 20), title: 'Copy login details', onTap: () => _details()),
          ]),
          if (!me) ...[
            const SectionTitle('Manage'),
            KGroup(children: [KRow(leading: const Icon(Icons.delete_outline_rounded, color: K.bad, size: 20), title: 'Remove from the farm', onTap: _delete)]),
          ],
        ],
      ]),
    );
  }
}
