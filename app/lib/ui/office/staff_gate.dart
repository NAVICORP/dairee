import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';
import 'shell.dart';

/// After a staff sign-in: who is this, which farm, and what may they open.
class StaffGate extends StatefulWidget {
  const StaffGate({super.key});

  @override
  State<StaffGate> createState() => _StaffGateState();
}

class _StaffGateState extends State<StaffGate> {
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    Me.instance.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    Me.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await Me.instance.load();
    } on ApiError catch (e) {
      error = e.message;
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (loading && Me.instance.farm == null) return const Scaffold(body: Loading());
    if (error != null && Me.instance.farm == null) {
      return Scaffold(
        body: SafeArea(
          child: LoadFailed(message: error!, onRetry: _load),
        ),
      );
    }
    final farm = Me.instance.farm;
    if (farm == null) return StartFarm(onMade: _load);
    if (farm.nothing) return _NoPages(farm: farm, onRetry: _load);
    return FarmShell(key: ValueKey('${farm.id}|${farm.isAdmin}|${farm.canDeliver}|${farm.canCare}|${farm.permissions.join(',')}'), farm: farm, reload: _load);
  }
}

/// Signed in, but no farm yet: start one, or ask a farm to add you.
class StartFarm extends StatefulWidget {
  const StartFarm({super.key, required this.onMade});
  final Future<void> Function() onMade;

  @override
  State<StartFarm> createState() => _StartFarmState();
}

class _StartFarmState extends State<StartFarm> {
  final _farm = TextEditingController();
  final _name = TextEditingController();
  String currency = 'INR';
  bool busy = false;
  String? error;

  @override
  void dispose() {
    _farm.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _make() async {
    if (_farm.text.trim().isEmpty) {
      setState(() => error = 'Give your farm a name.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await Api.instance.rpc('create_farm', {
        'name': _farm.text.trim(),
        'currency': currency,
        'my_name': _name.text.trim(),
      });
      if (r is Map) await Api.instance.chooseFarm(r['farm_id'] as String?);
      await widget.onMade();
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = Me.instance;
    final who = me.phone != null ? prettyPhone(me.phone) : (me.email ?? '');
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Sp.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Start your farm', style: T.display),
                const SizedBox(height: 6),
                if (who.isNotEmpty) Text('You are signed in as $who.', style: T.body.copyWith(color: K.muted)),
                const SizedBox(height: Sp.xl),
                KCard(
                  padding: const EdgeInsets.all(Sp.xl),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (error != null) ...[Notice(error!), const SizedBox(height: Sp.md)],
                    KField(label: 'Farm name', controller: _farm, hint: 'Green Meadows Dairy', caps: TextCapitalization.words),
                    const SizedBox(height: Sp.md),
                    KField(label: 'Your name', controller: _name, hint: 'As your staff will see it', caps: TextCapitalization.words),
                    const SizedBox(height: Sp.md),
                    KChoice(
                      label: 'Currency',
                      value: '${currencyOf(currency).symbol}  ${currencyOf(currency).code}',
                      onTap: () async {
                        final p = await showPicker<String>(context,
                            title: 'Currency', selected: currency, options: [for (final c in kCurrencies) PickOption(c.code, c.code, trailing: c.symbol)]);
                        if (p != null) setState(() => currency = p.value);
                      },
                    ),
                    const SizedBox(height: Sp.lg),
                    KButton(label: 'Start the farm', icon: Icons.arrow_forward_rounded, expand: true, busy: busy, onPressed: _make),
                  ]),
                ),
                const SizedBox(height: Sp.lg),
                KCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Joining a farm instead?', style: T.h3),
                    const SizedBox(height: 4),
                    Text('Ask the farm\'s office to add you with ${me.phone != null ? 'this number' : 'this email'}, then tap Check again.', style: T.small),
                    const SizedBox(height: Sp.md),
                    Row(children: [
                      KButton(label: 'Check again', icon: Icons.refresh_rounded, kind: KButtonKind.secondary, small: true, onPressed: widget.onMade),
                      const SizedBox(width: Sp.sm),
                      KButton(label: 'Sign out', kind: KButtonKind.ghost, small: true, onPressed: () => Api.instance.signOut()),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A password for the signed-in person's email, so they can sign in without
/// waiting for a code. Nobody else ever sets it.
class SetPassword extends StatefulWidget {
  const SetPassword({super.key});

  @override
  State<SetPassword> createState() => _SetPasswordState();
}

class _SetPasswordState extends State<SetPassword> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_a.text.length < 8) {
      setState(() => error = 'Choose a password of at least 8 characters.');
      return;
    }
    if (_a.text != _b.text) {
      setState(() => error = 'The two passwords are not the same.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Api.instance.setPassword(_a.text);
      if (!mounted) return;
      toast(context, 'Password saved');
      Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a password')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Sp.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Next time, sign in with ${Me.instance.email ?? 'your email'} and this password instead of a code.',
                    style: T.body.copyWith(color: K.muted)),
                const SizedBox(height: Sp.lg),
                KCard(
                  padding: const EdgeInsets.all(Sp.xl),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (error != null) ...[Notice(error!), const SizedBox(height: Sp.md)],
                    KField(label: 'New password', controller: _a, obscure: true, caps: TextCapitalization.none, autofill: const [AutofillHints.newPassword]),
                    const SizedBox(height: Sp.md),
                    KField(label: 'Once more', controller: _b, obscure: true, caps: TextCapitalization.none, onSubmitted: (_) => _save()),
                    const SizedBox(height: Sp.lg),
                    KButton(label: 'Save my password', icon: Icons.check_rounded, expand: true, busy: busy, onPressed: _save),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _NoPages extends StatelessWidget {
  const _NoPages({required this.farm, required this.onRetry});
  final FarmRole farm;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: EmptyState(
            icon: Icons.lock_outline_rounded,
            text: 'You are on ${farm.name}, but no pages are open to you yet. Ask an admin to tick the pages you need.',
            action: Wrap(spacing: Sp.sm, children: [
              KButton(label: 'Check again', icon: Icons.refresh_rounded, kind: KButtonKind.secondary, small: true, onPressed: onRetry),
              KButton(label: 'Sign out', kind: KButtonKind.ghost, small: true, onPressed: () => Api.instance.signOut()),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Copies text and says so.
Future<void> copyText(BuildContext context, String text, [String said = 'Copied']) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) toast(context, said);
}
