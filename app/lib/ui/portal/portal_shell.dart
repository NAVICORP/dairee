import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';

/// The customer portal: Home, Payment, Changes, Settings on a bottom bar.
class PortalShell extends StatefulWidget {
  const PortalShell({super.key});

  @override
  State<PortalShell> createState() => _PortalShellState();
}

class _PortalShellState extends State<PortalShell> {
  int tab = 0;
  Map<String, dynamic>? home;
  bool mustChange = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Portal.instance.call('portal_home');
      if (!mounted) return;
      setState(() {
        home = Map<String, dynamic>.from(r as Map);
        mustChange = false;
        error = null;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.status == 403 && e.message.contains('own password')) {
        setState(() => mustChange = true);
      } else {
        setState(() => error = e.message);
      }
    }
  }

  String get currency => '${home?['farm']?['currency'] ?? 'INR'}';

  @override
  Widget build(BuildContext context) {
    if (mustChange) return Scaffold(body: SafeArea(child: _ChangePassword(first: true, onDone: _load)));
    final h = home;
    if (h == null) {
      return Scaffold(
        body: SafeArea(
          child: error != null
              ? LoadFailed(message: error!, onRetry: _load)
              : const Loading(),
        ),
      );
    }
    final pages = [
      _Home(home: h, onRefresh: _load),
      _Payment(currency: currency),
      _Changes(home: h, onChanged: _load),
      _Settings(home: h),
    ];
    return Scaffold(
      body: IndexedStack(index: tab, children: pages),
      bottomNavigationBar: KNavBar(
        items: const [
          KNavItem(Icons.home_outlined, Icons.home_rounded, 'Home'),
          KNavItem(Icons.account_balance_wallet_outlined, Icons.account_balance_wallet_rounded, 'Payment'),
          KNavItem(Icons.event_note_outlined, Icons.event_note_rounded, 'Changes'),
          KNavItem(Icons.person_outline_rounded, Icons.person_rounded, 'Profile'),
        ],
        index: tab,
        onTap: (i) => setState(() => tab = i),
      ),
    );
  }
}

// ---------------------------------------------------------------- home

class _Home extends StatefulWidget {
  const _Home({required this.home, required this.onRefresh});
  final Map<String, dynamic> home;
  final Future<void> Function() onRefresh;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  Map<String, dynamic>? month;
  late DateTime showing = DateTime.parse('${widget.home['month']?['month'] ?? widget.home['today']}');

  Map<String, dynamic> get m => month ?? Map<String, dynamic>.from(widget.home['month'] as Map? ?? const {});

  Future<void> _go(int step) async {
    final next = DateTime(showing.year, showing.month + step, 1);
    try {
      final r = await Portal.instance.call('portal_deliveries', {'month': isoDay(next)});
      if (!mounted) return;
      setState(() {
        showing = next;
        month = Map<String, dynamic>.from(r as Map);
      });
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.home;
    final c = Map<String, dynamic>.from(h['customer'] as Map);
    final farm = Map<String, dynamic>.from(h['farm'] as Map);
    final acc = Map<String, dynamic>.from(h['account'] as Map);
    final cur = '${farm['currency']}';
    // What has happened so far; days still to come are on the Changes tab.
    final today = parseDay(h['today']) ?? dayOnly(DateTime.now());
    final days = (m['days'] as List? ?? const []).whereType<Map>().where((d) => !(parseDay(d['day'])?.isAfter(today) ?? false)).toList();
    final paused = toNum(m['paused_days']).toInt();
    final usual = [
      if (toNum(c['morning_quantity']) > 0) 'morning ${litres(c['morning_quantity'])}',
      if (toNum(c['evening_quantity']) > 0) 'evening ${litres(c['evening_quantity'])}',
    ];
    return Scaffold(
      appBar: AppBar(
        titleSpacing: Sp.xl,
        title: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${farm['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small.copyWith(color: K.blue, fontWeight: FontWeight.w800)),
          Text('${c['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.h3.copyWith(fontSize: 17)),
        ]),
      ),
      body: PageBody(
        onRefresh: () async {
          await widget.onRefresh();
          month = null;
        },
        children: [
          HeroCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                RoundIcon(Icons.chevron_left_rounded, dark: true, tooltip: 'Month before', onTap: () => _go(-1)),
                Expanded(
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.calendar_month_outlined, size: 17, color: K.heroText),
                    const SizedBox(width: 7),
                    Flexible(child: Text(monthLabel(showing), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.label.copyWith(color: K.heroText, fontSize: 14.5))),
                  ]),
                ),
                RoundIcon(Icons.chevron_right_rounded, dark: true, tooltip: 'Month after', onTap: () => _go(1)),
              ]),
              const SizedBox(height: Sp.lg),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(litres(m['delivered_liters']), style: T.amount),
              ),
              const SizedBox(height: Sp.xs),
              Text('delivered on ${m['delivered_days'] ?? 0} ${toNum(m['delivered_days']) == 1 ? 'day' : 'days'}${paused > 0 ? ', $paused ${paused == 1 ? 'day' : 'days'} paused' : ''}',
                  style: T.small.copyWith(color: K.heroText, fontWeight: FontWeight.w600)),
              const SizedBox(height: Sp.md),
              Container(height: 1, color: const Color(0x1FFFFFFF)),
              const SizedBox(height: Sp.md),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.water_drop_outlined, size: 15, color: K.heroText)),
                const SizedBox(width: Sp.sm),
                Expanded(
                  child: Text(usual.isEmpty ? 'No milk set for you yet' : 'Usually ${usual.join(', ')}', style: T.small.copyWith(color: K.heroText)),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: Sp.md + 2),
          Row(children: [
            Expanded(child: StatTile(money(toNum(acc['outstanding']), cur), 'To pay on bills', tone: toNum(acc['outstanding']) > 0 ? K.blue : null)),
            const SizedBox(width: Sp.sm),
            Expanded(child: StatTile(money(toNum(acc['credit']), cur), 'Your credit')),
          ]),
          const SizedBox(height: Sp.md + 2),
          KCard(
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: K.border)),
                child: QrImageView(data: 'dairee-customer:${c['qr_token']}', size: 76, padding: EdgeInsets.zero),
              ),
              const SizedBox(width: Sp.md + 2),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Your code', style: T.h3),
                  const SizedBox(height: 2),
                  Text(placeOf(c).isEmpty ? 'Show it to the farm to find you fast.' : '${placeOf(c)}. Show it to the farm to find you fast.', style: T.small),
                ]),
              ),
            ]),
          ),
          const SectionTitle('Deliveries'),
          if (days.isEmpty)
            const KCard(child: Text('Nothing this month yet.', style: T.small))
          else
            KGroup(children: [
              for (final d in days.reversed)
                KRow(
                  title: '${dayLabel(parseDay(d['day'])!)}, ${d['slot']}',
                  sub: d['paused'] == true
                      ? 'Paused'
                      : '${litres(d['delivered'] == true ? d['qty'] : d['due'])}${d['temporary'] == true ? ', changed for the day' : ''}${(d['notes'] ?? '') == '' ? '' : ', ${d['notes']}'}',
                  trailing: d['paused'] == true
                      ? const Pill.warn('Paused')
                      : d['delivered'] == true
                          ? const Pill('Delivered', icon: Icons.check_rounded)
                          : const Pill.grey('Not yet'),
                ),
            ]),
          const SizedBox(height: Sp.sm),
          Text('Only bills the farm has made count toward what you pay. Milk not billed yet is not added.', style: T.small),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- payment

class _Payment extends StatefulWidget {
  const _Payment({required this.currency});
  final String currency;

  @override
  State<_Payment> createState() => _PaymentState();
}

class _PaymentState extends State<_Payment> {
  Map<String, dynamic>? data;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Portal.instance.call('portal_bills');
      if (mounted) {
        setState(() {
          data = Map<String, dynamic>.from(r as Map);
          error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    String m(Object? v) => money(toNum(v), widget.currency);
    return Scaffold(
      appBar: AppBar(titleSpacing: Sp.xl, title: const Text('Payment')),
      body: d == null
          ? (error != null ? LoadFailed(message: error!, onRetry: _load) : const Loading())
          : PageBody(onRefresh: _load, children: [
              Row(children: [
                Expanded(child: StatTile(m(d['outstanding']), 'To pay', tone: toNum(d['outstanding']) > 0 ? K.blue : null)),
                const SizedBox(width: Sp.sm),
                Expanded(child: StatTile(m(d['credit']), 'Your credit')),
              ]),
              if (toNum(d['credit']) > 0) ...[
                const SizedBox(height: Sp.sm),
                const Notice('Credit is money you paid in advance. Your next bill uses it by itself.', bad: false),
              ],
              const SectionTitle('Bills'),
              if ((d['bills'] as List? ?? const []).isEmpty)
                const KCard(child: Text('No bills yet.', style: T.small))
              else
                for (final b in (d['bills'] as List).whereType<Map>())
                  Padding(
                    padding: const EdgeInsets.only(bottom: Sp.sm),
                    child: KCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(periodLabel(parseDay(b['from'])!, parseDay(b['to'])!), style: T.bodyStrong)),
                          toNum(b['balance']) > 0 ? Pill.warn('To pay ${m(b['balance'])}') : const Pill('Paid', icon: Icons.check_rounded),
                        ]),
                        const SizedBox(height: 4),
                        Text('${b['number']}, ${litres(b['liters'])} at ${m(b['price'])} a litre', style: T.small),
                        const SizedBox(height: 8),
                        Wrap(spacing: 18, runSpacing: 6, children: [
                          _mini('Amount', m(b['net'])),
                          if (toNum(b['discount']) > 0) _mini('Discount', m(b['discount'])),
                          _mini('Paid', m(b['paid'])),
                          if (toNum(b['credit_applied']) > 0) _mini('Credit used', m(b['credit_applied'])),
                          _mini('Remaining', m(b['balance'])),
                        ]),
                      ]),
                    ),
                  ),
              const SectionTitle('Payments'),
              if ((d['payments'] as List? ?? const []).isEmpty)
                const KCard(child: Text('No payments yet.', style: T.small))
              else
                KGroup(children: [
                  for (final p in (d['payments'] as List).whereType<Map>())
                    KRow(
                      title: m(p['amount']),
                      sub: '${dayLabel(parseDay(p['date'])!)}, ${p['advance'] == true ? 'advance' : 'for ${p['bill_number'] ?? 'a bill'}'}',
                    ),
                ]),
            ]),
    );
  }

  Widget _mini(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(value, style: T.bodyStrong),
        Text(label, style: T.tiny),
      ]);
}

// ---------------------------------------------------------------- changes

class _Changes extends StatefulWidget {
  const _Changes({required this.home, required this.onChanged});
  final Map<String, dynamic> home;
  final Future<void> Function() onChanged;

  @override
  State<_Changes> createState() => _ChangesState();
}

class _ChangesState extends State<_Changes> {
  Map<String, dynamic> get changes => Map<String, dynamic>.from(widget.home['changes'] as Map? ?? const {});
  Map<String, dynamic> get farm => Map<String, dynamic>.from(widget.home['farm'] as Map);
  DateTime get today => parseDay(widget.home['today']) ?? dayOnly(DateTime.now());
  List<Map> get open => (widget.home['open_days'] as List? ?? const []).whereType<Map>().toList();

  /// Can this day and round still change? The server said so; the phone's clock is never asked.
  bool _open(DateTime d, String slot) {
    final x = open.where((o) => o['day'] == isoDay(d)).firstOrNull;
    if (x == null) return d.isAfter(addDays(today, open.length - 1));
    if (slot == 'both') return x['morning'] == true && x['evening'] == true;
    return x[slot] == true;
  }

  Future<void> _run(Future<dynamic> Function() job, String said) async {
    try {
      await job();
      await widget.onChanged();
      if (mounted) toast(context, said);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _pause() async {
    var kind = 'tomorrow_only';
    var slot = 'both';
    var from = addDays(today, 1);
    var to = addDays(today, 3);
    await showKSheet<void>(context, title: 'Pause my milk', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
          final start = kind == 'today_only' ? today : (kind == 'tomorrow_only' ? addDays(today, 1) : from);
          final ok = _open(start, slot);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (k, label) in [('today_only', 'Today'), ('tomorrow_only', 'Tomorrow'), ('custom_range', 'From and to'), ('until_resumed', 'Until I resume')])
                ChoiceChip(
                  label: Text(label),
                  selected: kind == k,
                  showCheckmark: false,
                  selectedColor: K.blue,
                  labelStyle: T.label.copyWith(color: kind == k ? Colors.white : K.ink2),
                  backgroundColor: K.surface,
                  side: BorderSide(color: kind == k ? K.blue : K.border2),
                  shape: const StadiumBorder(),
                  onSelected: (_) => set(() => kind = k),
                ),
            ]),
            const SizedBox(height: Sp.md),
            if (kind == 'custom_range' || kind == 'until_resumed')
              Row(children: [
                Expanded(
                    child: KChoice(
                        label: 'From',
                        value: dayLabel(from),
                        onTap: () async {
                          final d = await pickDate(ctx, initial: from, first: today);
                          if (d != null) set(() => from = d);
                        })),
                if (kind == 'custom_range') ...[
                  const SizedBox(width: Sp.md),
                  Expanded(
                      child: KChoice(
                          label: 'To',
                          value: dayLabel(to.isBefore(from) ? from : to),
                          onTap: () async {
                            final d = await pickDate(ctx, initial: to.isBefore(from) ? from : to, first: from);
                            if (d != null) set(() => to = d);
                          })),
                ],
              ]),
            const SizedBox(height: Sp.md),
            KSegmented<String>(
                expand: true, items: const [('both', 'Both rounds'), ('morning', 'Morning'), ('evening', 'Evening')], value: slot, onChanged: (v) => set(() => slot = v)),
            const SizedBox(height: Sp.md),
            if (!ok) const Notice('That round is being packed or has gone. Pick a later day, or call the farm.'),
            const SizedBox(height: Sp.md),
            KButton(
              label: 'Pause',
              icon: Icons.pause_rounded,
              expand: true,
              onPressed: !ok
                  ? null
                  : () async {
                      Navigator.of(ctx).pop();
                      await _run(
                          () => Portal.instance.call('portal_pause', {
                                'kind': kind,
                                'from_date': isoDay(from),
                                'to_date': kind == 'custom_range' ? isoDay(to.isBefore(from) ? from : to) : null,
                                'slot': slot,
                              }),
                          'Paused');
                    },
            ),
          ]);
        }));
  }

  Future<void> _ask() async {
    List vessels = const [];
    try {
      vessels = await Portal.instance.call('portal_vessels') as List? ?? const [];
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
      return;
    }
    if (!mounted) return;
    final c = Map<String, dynamic>.from(widget.home['customer'] as Map);
    var day = addDays(today, 1);
    var slot = c['delivery_slot'] == 'evening' ? 'evening' : 'morning';
    final qty = TextEditingController();
    final note = TextEditingController();
    final counts = <String, int>{};
    await showKSheet<void>(context, title: 'Ask for a different amount', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
          final ok = _open(day, slot);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            KChoice(
                label: 'Day',
                value: relativeDay(day, today),
                icon: Icons.event_outlined,
                onTap: () async {
                  final d = await pickDate(ctx, initial: day, first: today);
                  if (d != null) set(() => day = d);
                }),
            const SizedBox(height: Sp.md),
            KSegmented<String>(expand: true, items: const [('morning', 'Morning'), ('evening', 'Evening')], value: slot, onChanged: (v) => set(() => slot = v)),
            const SizedBox(height: Sp.md),
            KField(
                label: 'Litres that day',
                controller: qty,
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
            if (vessels.isNotEmpty) ...[
              const SectionTitle('In', top: 12),
              KGroup(children: [
                for (final v in vessels.whereType<Map>())
                  KRow(
                    title: '${v['name']}',
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      RoundIcon(Icons.remove_rounded, size: 30, onTap: (counts[v['id']] ?? 0) > 0 ? () => set(() => counts[v['id'] as String] = (counts[v['id']] ?? 0) - 1) : null),
                      SizedBox(width: 24, child: Text('${counts[v['id']] ?? 0}', textAlign: TextAlign.center, style: T.bodyStrong)),
                      RoundIcon(Icons.add_rounded, size: 30, onTap: () => set(() => counts[v['id'] as String] = (counts[v['id']] ?? 0) + 1)),
                    ]),
                  ),
              ]),
            ],
            const SizedBox(height: Sp.md),
            KField(label: 'Note for the farm (optional)', controller: note, hint: 'Guests coming'),
            const SizedBox(height: Sp.md),
            if (!ok) const Notice('That round is being packed or has gone. Pick a later day.'),
            const SizedBox(height: Sp.md),
            KButton(
              label: 'Send the request',
              icon: Icons.send_rounded,
              expand: true,
              onPressed: !ok
                  ? null
                  : () async {
                      final q = num.tryParse(qty.text.trim());
                      if (q == null) {
                        toast(ctx, 'Give the litres for that day.', bad: true);
                        return;
                      }
                      Navigator.of(ctx).pop();
                      await _run(
                          () => Portal.instance.call('portal_request', {
                                'day': isoDay(day),
                                'slot': slot,
                                'quantity': q,
                                'vessels': [
                                  for (final e in counts.entries)
                                    if (e.value > 0) {'container_id': e.key, 'quantity': e.value}
                                ],
                                'note': note.text.trim(),
                              }),
                          'Sent to the farm');
                    },
            ),
          ]);
        }));
    qty.dispose();
    note.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ch = changes;
    final pauses = (ch['pauses'] as List? ?? const []).whereType<Map>().toList();
    final dates = (ch['pause_dates'] as List? ?? const []).whereType<Map>().toList();
    final temps = (ch['temporary'] as List? ?? const []).whereType<Map>().toList();
    final requests = (ch['requests'] as List? ?? const []).whereType<Map>().toList();
    final canPause = farm['customer_pause'] == true;
    final canAsk = farm['customer_requests'] == true;
    final paused = pauses.isNotEmpty || dates.isNotEmpty;
    return Scaffold(
      appBar: AppBar(titleSpacing: Sp.xl, title: const Text('Changes')),
      body: PageBody(onRefresh: widget.onChanged, children: [
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
          if (canPause) KButton(label: 'Pause my milk', icon: Icons.pause_rounded, small: true, onPressed: _pause),
          // A pause set by the farm can still be ended here.
          if (paused)
            KButton(
                label: 'Resume',
                icon: Icons.play_arrow_rounded,
                kind: KButtonKind.secondary,
                small: true,
                onPressed: () => _run(() => Portal.instance.call('portal_resume'), 'Your milk starts again')),
          if (canAsk) KButton(label: 'Different amount', icon: Icons.swap_horiz_rounded, kind: KButtonKind.secondary, small: true, onPressed: _ask),
        ]),
        if (!canPause && !canAsk) ...[
          const SizedBox(height: Sp.md),
          const Notice('Your farm takes changes by phone. Call them from Settings.', bad: false),
        ],
        const SectionTitle('Pauses'),
        if (!paused)
          const KCard(child: Text('Your milk is not paused.', style: T.small))
        else
          KGroup(children: [
            for (final p in pauses)
              KRow(
                title: p['to'] == null
                    ? 'From ${dayInSentence(parseDay(p['from'])!, today)}, until you resume'
                    : '${shortDate(parseDay(p['from'])!)} to ${shortDate(parseDay(p['to'])!)}',
                sub: [if (p['slot'] != 'both') '${p['slot']} only', if (p['set_by'] == 'office') 'set by the farm'].join(', '),
                trailing: RoundIcon(Icons.delete_outline_rounded, size: 32, tooltip: 'Remove',
                    onTap: () => _run(() => Portal.instance.call('portal_remove_pause', {'pause_id': p['id']}), 'Removed')),
              ),
            for (final d in dates)
              KRow(
                title: relativeDay(parseDay(d['day'])!, today),
                sub: [if (d['slot'] != 'both') '${d['slot']} only', if (d['set_by'] == 'office') 'set by the farm'].join(', '),
                trailing: RoundIcon(Icons.delete_outline_rounded, size: 32, tooltip: 'Remove',
                    onTap: () => _run(() => Portal.instance.call('portal_remove_pause', {'pause_id': d['id']}), 'Removed')),
              ),
          ]),
        const SectionTitle('Different amounts'),
        if (temps.isEmpty && requests.isEmpty)
          const KCard(child: Text('None coming up.', style: T.small))
        else
          KGroup(children: [
            for (final t in temps) KRow(title: '${litres(t['quantity'])} ${onDay(parseDay(t['day'])!, today)}', sub: '${t['slot']}, agreed', trailing: const Pill('Agreed')),
            for (final r in requests)
              KRow(
                title: '${litres(r['quantity'])} ${onDay(parseDay(r['day'])!, today)}',
                sub: '${r['slot']}${(r['decided_note'] ?? '') == '' ? '' : ', ${r['decided_note']}'}',
                trailing: r['status'] == 'pending'
                    ? KButton(
                        label: 'Withdraw',
                        kind: KButtonKind.ghost,
                        small: true,
                        onPressed: () => _run(() => Portal.instance.call('portal_withdraw_request', {'request_id': r['id']}), 'Withdrawn'))
                    : r['status'] == 'approved'
                        ? const Pill('Approved')
                        : const Pill.bad('Refused'),
              ),
          ]),
        const SizedBox(height: Sp.md),
        Text('Changes for a round close when the farm starts packing it '
            '(morning from ${timeOfDay(farm['morning_start'])}, evening from ${timeOfDay(farm['evening_start'])}).',
            style: T.small),
      ]),
    );
  }
}

// ---------------------------------------------------------------- settings

class _Settings extends StatelessWidget {
  const _Settings({required this.home});
  final Map<String, dynamic> home;

  @override
  Widget build(BuildContext context) {
    final c = Map<String, dynamic>.from(home['customer'] as Map);
    final farm = Map<String, dynamic>.from(home['farm'] as Map);
    final place = [placeOf(c), c['address'] ?? ''].where((x) => '$x'.isNotEmpty).join(', ');
    return Scaffold(
      appBar: AppBar(titleSpacing: Sp.xl, title: const Text('Profile')),
      body: PageBody(bottom: 40, children: [
        KCard(
          child: Row(children: [
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: K.deep, shape: BoxShape.circle),
              child: Text(initials('${c['name']}'), style: T.h3.copyWith(color: K.heroText)),
            ),
            const SizedBox(width: Sp.md + 2),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${c['name']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: T.h3),
                Text(prettyPhone(c['phone'] as String?), style: T.small),
                if (place.isNotEmpty) Text(place, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.small),
              ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Sp.sm, Sp.sm, Sp.sm, 0),
          child: Text('To change these, ask ${farm['name']}.', style: T.small),
        ),
        const GroupLabel('Your farm'),
        LinkGroup([
          LinkRow(Icons.storefront_outlined, '${farm['name']}', null, value: farm['phone'] == null ? null : prettyPhone(farm['phone'] as String?)),
          if (farm['phone'] != null) LinkRow(Icons.call_rounded, 'Call the farm', () => launchUrl(Uri.parse('tel:+${farm['phone']}'))),
        ]),
        const GroupLabel('Legal'),
        LinkGroup([
          LinkRow(Icons.privacy_tip_outlined, 'Privacy', () => launchUrl(Uri.parse(kPrivacyUrl), mode: LaunchMode.externalApplication)),
          LinkRow(Icons.description_outlined, 'Terms', () => launchUrl(Uri.parse(kTermsUrl), mode: LaunchMode.externalApplication)),
        ]),
        const GroupLabel('Account'),
        LinkGroup([
          LinkRow(
            Icons.password_rounded,
            'Change my password',
            () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(appBar: AppBar(title: const Text('Change password')), body: _ChangePassword(first: false, onDone: () async {})))),
          ),
          LinkRow(Icons.logout_rounded, 'Sign out', () async {
            if (await confirm(context, title: 'Sign out?', text: 'You will need your number and password to sign in again.', yes: 'Sign out')) {
              await Portal.instance.signOut();
            }
          }),
        ]),
      ]),
    );
  }
}

class _ChangePassword extends StatefulWidget {
  const _ChangePassword({required this.first, required this.onDone});
  final bool first;
  final Future<void> Function() onDone;

  @override
  State<_ChangePassword> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends State<_ChangePassword> {
  final _old = TextEditingController();
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    _old.dispose();
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_a.text.length < 6) {
      setState(() => error = 'Choose a password of at least 6 characters.');
      return;
    }
    if (_a.text != _b.text) {
      setState(() => error = 'The two new passwords are not the same.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Portal.instance.call('portal_change_password', {'old_password': _old.text, 'new_password': _a.text});
      if (!mounted) return;
      if (widget.first) {
        await widget.onDone();
      } else {
        toast(context, 'Password changed');
        Navigator.of(context).pop();
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Sp.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.first) ...[
              const Text('Choose your password', style: T.display),
              const SizedBox(height: 6),
              Text('The farm gave you a temporary one. Pick your own to see your milk and bills.', style: T.body.copyWith(color: K.muted)),
              const SizedBox(height: Sp.xl),
            ],
            KCard(
              padding: const EdgeInsets.all(Sp.xl),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (error != null) ...[Notice(error!), const SizedBox(height: Sp.md)],
                KField(label: widget.first ? 'Password from the farm' : 'Current password', controller: _old, obscure: true, caps: TextCapitalization.none),
                const SizedBox(height: Sp.md),
                KField(label: 'New password', controller: _a, obscure: true, caps: TextCapitalization.none, autofill: const [AutofillHints.newPassword]),
                const SizedBox(height: Sp.md),
                KField(label: 'Once more', controller: _b, obscure: true, caps: TextCapitalization.none, onSubmitted: (_) => _save()),
                const SizedBox(height: Sp.lg),
                KButton(label: 'Save my password', icon: Icons.check_rounded, expand: true, busy: busy, onPressed: _save),
                if (widget.first) ...[
                  const SizedBox(height: Sp.xs),
                  Center(child: KButton(label: 'Sign out', kind: KButtonKind.ghost, small: true, onPressed: () => Portal.instance.signOut())),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
