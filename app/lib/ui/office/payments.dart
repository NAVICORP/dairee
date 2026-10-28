import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';
import 'bill_pdf.dart';
import 'customers.dart';

enum _Tab { customers, bills, payments }

/// Bills, payments, credit and discounts. Every "what is owed" comes from the
/// database's one answer (bill_balances): nothing here does its own sums of
/// what a bill still needs.
class PaymentsPage extends StatefulWidget {
  const PaymentsPage({super.key, required this.farm});
  final FarmRole farm;

  @override
  State<PaymentsPage> createState() => _PaymentsPageState();
}

class _PaymentsPageState extends State<PaymentsPage> {
  _Tab tab = _Tab.customers;
  Map<String, dynamic>? summary;
  List<Map<String, dynamic>>? balances;
  List<Map<String, dynamic>>? bills;
  List<Map<String, dynamic>>? payments;
  Map<String, Map<String, dynamic>> customers = {};
  bool unpaidOnly = true;
  String? error;
  final _q = TextEditingController();

  FarmRole get f => widget.farm;

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
      final r = await Future.wait([
        Api.instance.rpc('money_summary'),
        Api.instance.rpc('customer_balances'),
        Api.instance.select('bill_balances', order: 'bill_date.desc,period_from.desc'),
        Api.instance.select('payments', columns: 'id,customer_id,amount,payment_date,payment_method,bill_id,counts_as_credit,receipt_number,notes,recorded_by',
            order: 'payment_date.desc,created_at.desc'),
        loadCustomers(),
      ]);
      if (!mounted) return;
      setState(() {
        summary = Map<String, dynamic>.from(r[0] as Map);
        balances = (r[1] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        bills = r[2] as List<Map<String, dynamic>>;
        payments = r[3] as List<Map<String, dynamic>>;
        customers = {for (final c in r[4] as List<Map<String, dynamic>>) c['id'] as String: c};
        error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  String _name(Object? id) => '${customers[id]?['name'] ?? 'Customer'}';

  Future<void> _generate() async {
    final today = f.today;
    final lastMonthStart = DateTime(today.year, today.month - 1, 1);
    final lastMonthEnd = DateTime(today.year, today.month, 0);
    var from = lastMonthStart, to = lastMonthEnd;
    final made = await showKSheet<Map<String, dynamic>>(context, title: 'Make bills', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
          var busy = false;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('A bill for every customer with milk delivered in the period, at the price of each day. Anyone already billed for any of those days is skipped.',
                style: T.small),
            const SizedBox(height: Sp.md),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (label, a, b) in [
                ('Last month', lastMonthStart, lastMonthEnd),
                ('This month so far', DateTime(today.year, today.month, 1), addDays(today, -1)),
                ('1 to 15', DateTime(today.year, today.month, 1), DateTime(today.year, today.month, 15)),
                ('16 to end', DateTime(lastMonthStart.year, lastMonthStart.month, 16), lastMonthEnd),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: from == a && to == b,
                  showCheckmark: false,
                  selectedColor: K.blue,
                  labelStyle: T.label.copyWith(color: from == a && to == b ? Colors.white : K.ink2),
                  backgroundColor: K.surface,
                  side: BorderSide(color: from == a && to == b ? K.blue : K.border2),
                  shape: const StadiumBorder(),
                  onSelected: (_) => set(() {
                    from = a;
                    to = b;
                  }),
                ),
            ]),
            const SizedBox(height: Sp.md),
            KChoice(
                label: 'Period',
                value: periodLabel(from, to),
                icon: Icons.date_range_rounded,
                onTap: () async {
                  final p = await pickPeriod(ctx, from: from, to: to);
                  if (p != null) {
                    set(() {
                      from = p.$1;
                      to = p.$2;
                    });
                  }
                }),
            const SizedBox(height: Sp.lg),
            StatefulBuilder(
              builder: (ctx2, set2) => KButton(
                label: 'Make the bills',
                icon: Icons.receipt_long_rounded,
                expand: true,
                busy: busy,
                onPressed: () async {
                  set2(() => busy = true);
                  try {
                    final r = await Api.instance.rpc('generate_bills', {'period_from': isoDay(from), 'period_to': isoDay(to)});
                    if (ctx.mounted) Navigator.of(ctx).pop(Map<String, dynamic>.from(r as Map));
                  } on ApiError catch (e) {
                    if (ctx.mounted) toast(ctx, e.message, bad: true);
                    set2(() => busy = false);
                  }
                },
              ),
            ),
          ]);
        }));
    if (made == null || !mounted) return;
    await _load();
    if (!mounted) return;
    final skipped = (made['skipped'] as List? ?? const []).whereType<Map>().toList();
    await showKSheet<void>(context, title: '${made['made']} bills made', builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (skipped.isEmpty) const Text('Nobody was skipped.', style: T.small) else Text('${skipped.length} skipped:', style: T.label),
          const SizedBox(height: Sp.sm),
          if (skipped.isNotEmpty)
            KGroup(children: [for (final s in skipped) KRow(title: '${s['name']}', sub: '${s['reason']}')]),
          const SizedBox(height: Sp.lg),
          KButton(label: 'Done', expand: true, onPressed: () => Navigator.of(ctx).pop()),
        ]));
  }

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Scaffold(
      appBar: AppBar(titleSpacing: Sp.xl, title: const Text('To collect'), actions: [
        IconButton(tooltip: 'Make bills', icon: const Icon(Icons.receipt_long_outlined), onPressed: _generate),
        const SizedBox(width: Sp.xs),
      ]),
      floatingActionButton: KFab(
        label: 'Record payment',
        icon: Icons.add_rounded,
        onPressed: () async {
          if (await recordPayment(context, f)) _load();
        },
      ),
      body: PageBody(onRefresh: _load, bottom: 112, children: [
        if (error != null && s == null)
          LoadFailed(message: error!, onRetry: _load)
        else if (s == null)
          const Padding(padding: EdgeInsets.all(40), child: Loading())
        else ...[
          Builder(builder: (context) {
            final billed = toNum(s['billed']);
            final owed = toNum(s['outstanding']);
            return HeroCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.payments_outlined, size: 17, color: K.heroText),
                  const SizedBox(width: 7),
                  Text('Still to collect on bills', style: T.label.copyWith(color: K.heroText, fontSize: 14.5)),
                ]),
                const SizedBox(height: Sp.lg),
                FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart, child: Text(f.money(owed), style: T.amount)),
                const SizedBox(height: Sp.xs),
                Text('of ${f.money(billed)} billed, ${s['unpaid_bills']} unpaid of ${s['bills']} bills',
                    style: T.small.copyWith(color: K.heroText, fontWeight: FontWeight.w600)),
                const SizedBox(height: Sp.md + 2),
                ProgressLine(billed <= 0 ? 0 : (billed - owed) / billed),
                const SizedBox(height: Sp.md),
                Row(children: [
                  Expanded(
                    child: Text('${f.money(toNum(s['collected']))} collected',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: T.label.copyWith(color: Colors.white)),
                  ),
                  const SizedBox(width: Sp.sm),
                  Text(owed > 0 ? '${f.money(owed)} to go' : 'All paid', style: T.small.copyWith(color: K.heroText)),
                ]),
                const SizedBox(height: Sp.md),
                Container(height: 1, color: const Color(0x1FFFFFFF)),
                const SizedBox(height: Sp.md),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.savings_outlined, size: 15, color: K.heroText)),
                  const SizedBox(width: Sp.sm),
                  Expanded(
                    child: Text(
                        '${f.money(toNum(s['credit_held']))} held as credit, ${f.money(toNum(s['credit_applied']))} of credit used, ${f.money(toNum(s['discounts']))} in discounts',
                        style: T.small.copyWith(color: K.heroText)),
                  ),
                ]),
              ]),
            );
          }),
          const SizedBox(height: Sp.md),
          KSegmented<_Tab>(
            expand: true,
            items: const [(_Tab.customers, 'Customers'), (_Tab.bills, 'Bills'), (_Tab.payments, 'Payments')],
            value: tab,
            onChanged: (v) => setState(() => tab = v),
          ),
          const SizedBox(height: Sp.md),
          SearchField(controller: _q, hint: 'Search a name', onChanged: (_) => setState(() {})),
          const SizedBox(height: Sp.md),
          ...switch (tab) {
            _Tab.customers => _customers(),
            _Tab.bills => _bills(),
            _Tab.payments => _payments(),
          },
        ],
      ]),
    );
  }

  bool _match(Object? customerId) {
    final t = _q.text.trim().toLowerCase();
    if (t.isEmpty) return true;
    final c = customers[customerId];
    return c != null && '${c['name']} ${placeOf(c)}'.toLowerCase().contains(t);
  }

  List<Widget> _customers() {
    final list = (balances ?? const []).where((b) => _match(b['customer_id']) && (toNum(b['outstanding']) > 0 || toNum(b['credit']) > 0 || _q.text.isNotEmpty)).toList();
    if (list.isEmpty) return [const EmptyState(icon: Icons.check_circle_outline_rounded, text: 'Nobody owes anything and nobody holds credit.')];
    return [
      KGroup(children: [
        for (final b in list)
          KRow(
            leading: Avatar('${b['name']}', size: 34),
            title: '${b['name']}',
            sub: [placeOf(b), if (b['last_payment'] != null) 'last paid ${shortDate(parseDay(b['last_payment'])!)}'].where((x) => x.isNotEmpty).join(', '),
            trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              if (toNum(b['outstanding']) > 0) Text(f.money(toNum(b['outstanding'])), style: T.bodyStrong),
              if (toNum(b['credit']) > 0) Pill('Credit ${f.money(toNum(b['credit']))}'),
            ]),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CustomerMoney(farm: f, customer: customers[b['customer_id']] ?? b)));
              _load();
            },
          ),
      ]),
    ];
  }

  List<Widget> _bills() {
    final list = (bills ?? const []).where((b) => _match(b['customer_id']) && (!unpaidOnly || toNum(b['balance_due']) > 0)).toList();
    return [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: KSegmented<bool>(items: const [(true, 'Unpaid'), (false, 'All')], value: unpaidOnly, onChanged: (v) => setState(() => unpaidOnly = v)),
      ),
      const SizedBox(height: Sp.md),
      if (list.isEmpty)
        EmptyState(icon: Icons.receipt_long_outlined, text: unpaidOnly ? 'No unpaid bills.' : 'No bills yet. Make them for a period with the bill button above.')
      else
        KGroup(children: [
          for (final b in list.take(400))
            KRow(
              title: _name(b['customer_id']),
              sub: '${b['bill_number']}, ${periodLabel(parseDay(b['period_from'])!, parseDay(b['period_to'])!)}',
              trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                Text(f.money(toNum(b['net_amount'])), style: T.bodyStrong),
                toNum(b['balance_due']) > 0 ? Pill.warn('Due ${f.money(toNum(b['balance_due']))}') : const Pill('Paid', icon: Icons.check_rounded),
              ]),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BillPage(farm: f, billId: b['bill_id'] as String)));
                _load();
              },
            ),
        ]),
    ];
  }

  List<Widget> _payments() {
    final list = (payments ?? const []).where((p) => _match(p['customer_id'])).toList();
    if (list.isEmpty) return [const EmptyState(icon: Icons.payments_outlined, text: 'No payments recorded yet.')];
    final numbers = {for (final b in bills ?? const <Map<String, dynamic>>[]) b['bill_id']: b['bill_number']};
    return [
      KGroup(children: [
        for (final p in list.take(400))
          KRow(
            title: _name(p['customer_id']),
            sub: '${dayLabel(parseDay(p['payment_date'])!)}, ${methodLabel('${p['payment_method']}')}, ${p['bill_id'] == null ? 'advance' : 'for ${numbers[p['bill_id']] ?? 'a bill'}'}',
            trailing: Text(f.money(toNum(p['amount'])), style: T.bodyStrong),
            onTap: () async {
              if (await recordPayment(context, f, existing: p)) _load();
            },
          ),
      ]),
    ];
  }
}

String methodLabel(String m) => switch (m) { 'upi' => 'UPI', 'bank' => 'Bank', 'cash' => 'Cash', _ => 'Other' };

// ---------------------------------------------------------------- one customer's money

class CustomerMoney extends StatefulWidget {
  const CustomerMoney({super.key, required this.farm, required this.customer});
  final FarmRole farm;
  final Map<String, dynamic> customer;

  @override
  State<CustomerMoney> createState() => _CustomerMoneyState();
}

class _CustomerMoneyState extends State<CustomerMoney> {
  List<Map<String, dynamic>>? bills;
  List<Map<String, dynamic>> payments = const [];
  num credit = 0;

  String get id => (widget.customer['id'] ?? widget.customer['customer_id']) as String;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        Api.instance.select('bill_balances', where: {'customer_id': 'eq.$id'}, order: 'period_from.desc'),
        Api.instance.select('payments', columns: 'id,customer_id,amount,payment_date,payment_method,bill_id,receipt_number,notes', where: {'customer_id': 'eq.$id'}, order: 'payment_date.desc'),
        Api.instance.select('customer_credit', columns: 'held', where: {'customer_id': 'eq.$id'}),
      ]);
      if (!mounted) return;
      setState(() {
        bills = r[0];
        payments = r[1];
        credit = r[2].isEmpty ? 0 : toNum(r[2].first['held']);
      });
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.farm;
    final owed = (bills ?? const []).fold<num>(0, (a, b) => a + toNum(b['balance_due']));
    final numbers = {for (final b in bills ?? const <Map<String, dynamic>>[]) b['bill_id']: b['bill_number']};
    return Scaffold(
      appBar: AppBar(title: Text('${widget.customer['name']}'), actions: [
        IconButton(icon: const Icon(Icons.add_rounded), tooltip: 'Record a payment', onPressed: () async {
          if (await recordPayment(context, f, customer: widget.customer)) _load();
        }),
        const SizedBox(width: Sp.xs),
      ]),
      body: PageBody(onRefresh: _load, children: [
        Row(children: [
          Expanded(child: StatTile(f.money(owed), 'Owes on bills', tone: owed > 0 ? K.blue : null)),
          const SizedBox(width: Sp.sm),
          Expanded(child: StatTile(f.money(credit), 'Credit held')),
        ]),
        if (credit > 0) ...[
          const SizedBox(height: Sp.sm),
          const Notice('Credit is the customer\'s money, not income. The next bill takes it by itself. To correct it, change or delete the payment it came from.', bad: false),
        ],
        const SectionTitle('Bills'),
        if (bills == null)
          const Padding(padding: EdgeInsets.all(24), child: Loading())
        else if (bills!.isEmpty)
          const KCard(child: Text('No bills yet.', style: T.small))
        else
          KGroup(children: [
            for (final b in bills!)
              KRow(
                title: '${b['bill_number']}',
                sub: periodLabel(parseDay(b['period_from'])!, parseDay(b['period_to'])!),
                trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                  Text(f.money(toNum(b['net_amount'])), style: T.bodyStrong),
                  toNum(b['balance_due']) > 0 ? Pill.warn('Due ${f.money(toNum(b['balance_due']))}') : const Pill('Paid', icon: Icons.check_rounded),
                ]),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BillPage(farm: f, billId: b['bill_id'] as String)));
                  _load();
                },
              ),
          ]),
        const SectionTitle('Payments'),
        if (payments.isEmpty)
          const KCard(child: Text('No payments yet.', style: T.small))
        else
          KGroup(children: [
            for (final p in payments)
              KRow(
                title: f.money(toNum(p['amount'])),
                sub: '${dayLabel(parseDay(p['payment_date'])!)}, ${methodLabel('${p['payment_method']}')}, ${p['bill_id'] == null ? 'advance' : 'for ${numbers[p['bill_id']] ?? 'a bill'}'}',
                trailing: const Icon(Icons.chevron_right_rounded, color: K.muted),
                onTap: () async {
                  if (await recordPayment(context, f, existing: p, customer: widget.customer)) _load();
                },
              ),
          ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------- one bill

class BillPage extends StatefulWidget {
  const BillPage({super.key, required this.farm, required this.billId});
  final FarmRole farm;
  final String billId;

  @override
  State<BillPage> createState() => _BillPageState();
}

class _BillPageState extends State<BillPage> {
  Map<String, dynamic>? bal;
  Map<String, dynamic>? bill;
  Map<String, dynamic>? customer;
  List<Map<String, dynamic>> pays = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        Api.instance.select('bill_balances', where: {'bill_id': 'eq.${widget.billId}'}),
        Api.instance.select('bills', columns: 'id,customer_id,milk_price,total_liters,delivered_days,missed_days,paused_days,notes,created_by,credit_before',
            where: {'id': 'eq.${widget.billId}'}),
        Api.instance.select('payments', columns: 'id,customer_id,amount,payment_date,payment_method,bill_id,receipt_number,notes', where: {'bill_id': 'eq.${widget.billId}'}),
      ]);
      if (r[0].isEmpty) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final cs = await Api.instance.select('customers', columns: 'id,name,phone,building,room,address', where: {'id': 'eq.${r[1].first['customer_id']}'});
      if (!mounted) return;
      setState(() {
        bal = r[0].first;
        bill = r[1].first;
        pays = r[2];
        customer = cs.isEmpty ? {'name': 'Customer'} : cs.first;
      });
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _act(Future<void> Function() job, [String? said]) async {
    try {
      await job();
      await _load();
      if (said != null && mounted) toast(context, said);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message, bad: true);
    }
  }

  Future<void> _discount() async {
    final ctl = TextEditingController(text: toNum(bal!['discount_amount']) == 0 ? '' : '${bal!['discount_amount']}');
    final r = await showKSheet<String>(context, title: 'Discount', builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('A discount lowers what is owed. It is not a payment and never counts as collected.', style: T.small),
          const SizedBox(height: Sp.md),
          KField(label: 'Discount', controller: ctl, keyboard: const TextInputType.numberWithOptions(decimal: true), prefix: '${currencyOf(widget.farm.currency).symbol} ',
              formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
          const SizedBox(height: Sp.lg),
          KButton(label: 'Save', icon: Icons.check_rounded, expand: true, onPressed: () => Navigator.of(ctx).pop(ctl.text.trim())),
        ]));
    ctl.dispose();
    if (r == null) return;
    await _act(() => Api.instance.update('bills', {'discount_amount': num.tryParse(r) ?? 0}, where: {'id': 'eq.${widget.billId}'}, columns: 'id'), 'Discount saved');
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.farm;
    final b = bal;
    return Scaffold(
      appBar: AppBar(title: Text(b == null ? 'Bill' : '${b['bill_number']}'), actions: [
        if (b != null)
          IconButton(icon: const Icon(Icons.ios_share_rounded), tooltip: 'Share the bill', onPressed: () async {
            try {
              await shareBillPdf(farmName: f.name, currency: f.currency, balance: b, bill: bill!, customer: customer!);
            } catch (e) {
              if (context.mounted) toast(context, 'The bill could not be shared just now.', bad: true);
            }
          }),
        const SizedBox(width: Sp.xs),
      ]),
      body: b == null
          ? const Loading()
          : PageBody(onRefresh: _load, children: [
              KCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${customer?['name']}', style: T.h2),
                  Text(periodLabel(parseDay(b['period_from'])!, parseDay(b['period_to'])!), style: T.small),
                  const SizedBox(height: Sp.md),
                  Text('${bill!['delivered_days']} days delivered, ${bill!['missed_days']} missed, ${bill!['paused_days']} paused', style: T.small),
                  Text('${litres(bill!['total_liters'])} at ${f.money(toNum(bill!['milk_price']))} a litre', style: T.small),
                ]),
              ),
              const SizedBox(height: Sp.md),
              KGroup(children: [
                KRow(title: 'Total', trailing: Text(f.money(toNum(b['total_amount'])), style: T.bodyStrong)),
                KRow(title: 'Discount', sub: 'Tap to change', onTap: _discount, trailing: Text('- ${f.money(toNum(b['discount_amount']))}', style: T.bodyStrong)),
                KRow(title: 'Advance used', sub: 'Credit the customer had', trailing: Text('- ${f.money(toNum(b['credit_applied']))}', style: T.bodyStrong)),
                KRow(title: 'Paid against this bill', trailing: Text(f.money(toNum(b['amount_paid'])), style: T.bodyStrong)),
                KRow(
                    title: 'Balance due',
                    trailing: Text(f.money(toNum(b['balance_due'])), style: T.h3.copyWith(color: toNum(b['balance_due']) > 0 ? K.blue : K.ink))),
              ]),
              if ((bill!['notes'] as String? ?? '').isNotEmpty) ...[const SizedBox(height: Sp.sm), Notice('${bill!['notes']}', bad: false)],
              const SizedBox(height: Sp.md),
              Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
                if (toNum(b['balance_due']) > 0)
                  KButton(
                      label: 'Record a payment',
                      icon: Icons.add_circle_outline_rounded,
                      small: true,
                      onPressed: () async {
                        if (await recordPayment(context, f, customer: customer, billId: widget.billId, amount: toNum(b['balance_due']))) _load();
                      }),
                KButton(
                    label: 'Refresh from deliveries',
                    icon: Icons.refresh_rounded,
                    kind: KButtonKind.secondary,
                    small: true,
                    onPressed: () => _act(() => Api.instance.rpc('refresh_bill', {'bill_id': widget.billId}).then((_) {}), 'Bill updated')),
              ]),
              const SectionTitle('Payments on this bill'),
              if (pays.isEmpty)
                const KCard(child: Text('None yet.', style: T.small))
              else
                KGroup(children: [
                  for (final p in pays)
                    KRow(
                      title: f.money(toNum(p['amount'])),
                      sub: '${dayLabel(parseDay(p['payment_date'])!)}, ${methodLabel('${p['payment_method']}')}',
                      onTap: () async {
                        if (await recordPayment(context, f, existing: p, customer: customer)) _load();
                      },
                    ),
                ]),
              const SectionTitle('Manage'),
              KGroup(children: [
                KRow(
                  leading: const Icon(Icons.delete_outline_rounded, color: K.bad, size: 20),
                  title: 'Delete this bill',
                  sub: 'Payments made against it become the customer\'s credit',
                  onTap: () async {
                    if (!await confirm(context, title: 'Delete ${b['bill_number']}?', text: 'Payments against it stay, as credit for the next bill.', yes: 'Delete', danger: true)) {
                      return;
                    }
                    try {
                      await Api.instance.delete('bills', where: {'id': 'eq.${widget.billId}'});
                      if (context.mounted) Navigator.of(context).pop();
                    } on ApiError catch (e) {
                      if (context.mounted) toast(context, e.message, bad: true);
                    }
                  },
                ),
              ]),
            ]),
    );
  }
}

// ---------------------------------------------------------------- recording a payment

/// Records (or corrects, or deletes) a payment. Money paid against a bill
/// beyond what it needs, and money not paid against any bill, is held as the
/// customer's credit by the database; the app never works that out itself.
Future<bool> recordPayment(BuildContext context, FarmRole farm,
    {Map<String, dynamic>? existing, Map<String, dynamic>? customer, String? billId, num? amount}) async {
  var c = customer;
  if (c == null && existing != null) {
    final cs = await Api.instance.select('customers', columns: 'id,name,building,room', where: {'id': 'eq.${existing['customer_id']}'});
    c = cs.isEmpty ? null : cs.first;
  }
  if (!context.mounted) return false;
  c ??= await pickCustomer(context, title: 'Who paid?');
  if (c == null || !context.mounted) return false;
  final cid = (c['id'] ?? c['customer_id']) as String;
  List<Map<String, dynamic>> unpaid;
  try {
    unpaid = await Api.instance.select('bill_balances', columns: 'bill_id,bill_number,period_from,period_to,balance_due,net_amount',
        where: {'customer_id': 'eq.$cid'}, order: 'period_from.asc');
  } on ApiError catch (e) {
    if (context.mounted) toast(context, e.message, bad: true);
    return false;
  }
  if (!context.mounted) return false;
  final amt = TextEditingController(text: existing != null ? '${existing['amount']}' : (amount != null && amount > 0 ? '$amount' : ''));
  final receipt = TextEditingController(text: existing?['receipt_number'] as String? ?? '');
  final notes = TextEditingController(text: existing?['notes'] as String? ?? '');
  var method = (existing?['payment_method'] as String?) ?? 'cash';
  var day = parseDay(existing?['payment_date']) ?? farm.today;
  String? bill = existing != null ? existing['bill_id'] as String? : (billId ?? unpaid.where((b) => toNum(b['balance_due']) > 0).map((b) => b['bill_id'] as String).firstOrNull);
  final name = '${c['name']}';
  final ok = await showKSheet<bool>(context, title: existing == null ? 'Payment from $name' : 'Payment from $name', builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final billText = bill == null
            ? 'No bill: keep as credit'
            : unpaid.where((b) => b['bill_id'] == bill).map((b) => '${b['bill_number']}, due ${farm.money(toNum(b['balance_due']))}').firstOrNull ?? 'A bill';
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KField(
              label: 'Amount',
              controller: amt,
              autofocus: existing == null,
              keyboard: const TextInputType.numberWithOptions(decimal: true),
              prefix: '${currencyOf(farm.currency).symbol} ',
              formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
          const SizedBox(height: Sp.md),
          Row(children: [
            Expanded(
              child: KChoice(
                  label: 'Paid on',
                  value: dayLabel(day),
                  onTap: () async {
                    final d = await pickDate(ctx, initial: day);
                    if (d != null) set(() => day = d);
                  }),
            ),
            const SizedBox(width: Sp.md),
            Expanded(
              child: KChoice(
                  label: 'How',
                  value: methodLabel(method),
                  onTap: () async {
                    final p = await showPicker<String>(ctx, title: 'How was it paid?', selected: method, options: [
                      for (final m in ['cash', 'upi', 'bank', 'other']) PickOption(m, methodLabel(m)),
                    ]);
                    if (p != null) set(() => method = p.value);
                  }),
            ),
          ]),
          const SizedBox(height: Sp.md),
          KChoice(
            label: 'Against',
            value: billText,
            icon: Icons.receipt_long_outlined,
            onTap: () async {
              final p = await showPicker<String?>(ctx, title: 'Against which bill?', selected: bill, options: [
                const PickOption<String?>(null, 'No bill: keep as credit', sub: 'Used by the next bill by itself'),
                for (final b in unpaid.reversed)
                  PickOption<String?>(b['bill_id'] as String, '${b['bill_number']}',
                      sub: '${periodLabel(parseDay(b['period_from'])!, parseDay(b['period_to'])!)}, due ${farm.money(toNum(b['balance_due']))}'),
              ]);
              if (p != null) set(() => bill = p.value);
            },
          ),
          const SizedBox(height: Sp.md),
          Row(children: [
            Expanded(child: KField(label: 'Receipt number', controller: receipt)),
            const SizedBox(width: Sp.md),
            Expanded(child: KField(label: 'Note', controller: notes)),
          ]),
          const SizedBox(height: Sp.lg),
          KButton(
            label: existing == null ? 'Record payment' : 'Save',
            icon: Icons.check_rounded,
            expand: true,
            onPressed: () async {
              final a = num.tryParse(amt.text.trim());
              if (a == null || a <= 0) {
                toast(ctx, 'Give the amount paid.', bad: true);
                return;
              }
              final row = {
                'customer_id': cid,
                'amount': a,
                'payment_date': isoDay(day),
                'payment_method': method,
                'bill_id': bill,
                'receipt_number': receipt.text.trim(),
                'notes': notes.text.trim(),
              };
              try {
                if (existing == null) {
                  await Api.instance.insert('payments', row, columns: 'id');
                } else {
                  await Api.instance.update('payments', row, where: {'id': 'eq.${existing['id']}'}, columns: 'id');
                }
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } on ApiError catch (e) {
                if (ctx.mounted) toast(ctx, e.message, bad: true);
              }
            },
          ),
          if (existing != null) ...[
            const SizedBox(height: Sp.sm),
            KButton(
              label: 'Delete this payment',
              kind: KButtonKind.danger,
              expand: true,
              onPressed: () async {
                if (!await confirm(ctx, title: 'Delete this payment?', text: 'Any bill it paid, or credit it gave, is worked out again.', yes: 'Delete', danger: true)) return;
                try {
                  await Api.instance.delete('payments', where: {'id': 'eq.${existing['id']}'});
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } on ApiError catch (e) {
                  if (ctx.mounted) toast(ctx, e.message, bad: true);
                }
              },
            ),
          ],
        ]);
      }));
  amt.dispose();
  receipt.dispose();
  notes.dispose();
  return ok == true;
}
