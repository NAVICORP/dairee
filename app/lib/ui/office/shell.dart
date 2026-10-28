import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/farm.dart';
import '../../core/format.dart';
import '../theme.dart';
import '../widgets.dart';
import 'changes.dart';
import 'customers.dart';
import 'herd.dart';
import 'payments.dart';
import 'preparation.dart';
import 'reports.dart';
import 'round.dart';
import 'settings.dart';
import 'staff.dart';
import 'staff_gate.dart';
import 'today.dart';
import 'wallboard.dart';

/// One page of the farm: a footer tab on phones, a line in the side bar on
/// wide screens, or a row under Farm on the Profile tab.
class FarmPage {
  const FarmPage(this.key, this.label, this.icon, this.iconOn, this.sub, this.build);
  final String key;
  final String label;
  final IconData icon;
  final IconData iconOn;
  final String sub;
  final Widget Function(FarmRole farm, void Function(String key) open) build;
}

/// The Today page has something to show: a round, the packing or requests.
bool hasToday(FarmRole f) => f.can('deliveries') || f.canDeliver || f.can('preparation') || f.can('pauses');

List<FarmPage> farmPages(FarmRole f) => [
      if (hasToday(f))
        FarmPage('today', 'Today', Icons.wb_sunny_outlined, Icons.wb_sunny_rounded, 'The rounds, the packing and requests',
            (f, open) => TodayPage(farm: f, open: open)),
      if (f.can('customers'))
        FarmPage('customers', 'Customers', Icons.people_outline_rounded, Icons.people_rounded, 'Who takes milk, how much and when',
            (f, open) => CustomersPage(farm: f)),
      if (f.can('payments'))
        FarmPage('payments', 'To collect', Icons.payments_outlined, Icons.payments_rounded, 'Bills, payments and who owes',
            (f, open) => PaymentsPage(farm: f)),
      if (f.can('preparation'))
        FarmPage('preparation', 'Packing', Icons.inventory_2_outlined, Icons.inventory_2_rounded, 'Milk and vessels to fill for each round',
            (f, open) => PreparationPage(farm: f)),
      if (f.can('pauses'))
        FarmPage('pauses', 'Pause / Stop', Icons.pause_circle_outline_rounded, Icons.pause_circle_rounded, 'Pauses, stops and requests from customers',
            (f, open) => ChangesPage(farm: f)),
      if (f.can('reports'))
        FarmPage('reports', 'Reports', Icons.insights_outlined, Icons.insights_rounded, 'Milk, customers and money over any days',
            (f, open) => ReportsPage(farm: f)),
      if (f.can('cows') || f.canCare)
        FarmPage('cows', 'Cows', Icons.pets_outlined, Icons.pets_rounded, 'The herd, milk yield and health', (f, open) => HerdPage(farm: f)),
      if (f.can('staff'))
        FarmPage('staff', 'Staff', Icons.badge_outlined, Icons.badge_rounded, 'Who works here and what each can open', (f, open) => StaffPage(farm: f)),
      if (f.can('settings'))
        FarmPage('settings', 'Settings', Icons.tune_outlined, Icons.tune_rounded, 'Farm details, milk price and vessels',
            (f, open) => SettingsPage(farm: f)),
    ];

/// The farm, like Kuree: on phones the first three pages are footer tabs with
/// Profile last, and the rest open from Profile; on wide screens every page
/// is in a side bar. Each tab keeps its own pile of opened screens, so the
/// footer stays below a customer's page and comes back as it was left.
class FarmShell extends StatefulWidget {
  const FarmShell({super.key, required this.farm, required this.reload});
  final FarmRole farm;
  final Future<void> Function() reload;

  @override
  State<FarmShell> createState() => _FarmShellState();
}

class _FarmShellState extends State<FarmShell> {
  late final List<FarmPage> pages = farmPages(widget.farm);
  final Map<String, GlobalKey<NavigatorState>> navs = {};
  final Set<String> seen = {};
  String? current;
  bool wide = false;

  static const _tabs = 3;

  GlobalKey<NavigatorState> _nav(String key) => navs.putIfAbsent(key, () => GlobalKey<NavigatorState>(debugLabel: key));

  /// What the footer or the side bar lists right now: page keys, Profile last.
  List<String> get _items => [for (final p in (wide ? pages : pages.take(_tabs))) p.key, 'profile'];

  void _select(String key) {
    if (key == current) {
      final nav = navs[key]?.currentState;
      if (nav != null && nav.canPop()) nav.popUntil((r) => r.isFirst);
      return;
    }
    setState(() {
      current = key;
      seen.add(key);
    });
  }

  /// Opens a page: its tab when it has one, otherwise on top of the tab on show.
  void _open(String key) {
    if (_items.contains(key)) {
      _select(key);
      return;
    }
    final p = pages.where((p) => p.key == key).firstOrNull;
    final nav = navs[current]?.currentState;
    if (p == null || nav == null) return;
    nav.push(MaterialPageRoute<void>(builder: (_) => p.build(widget.farm, _open)));
  }

  Widget _stack(String key) {
    final Widget root;
    if (key == 'profile') {
      root = ProfilePage(
        farm: widget.farm,
        pages: wide ? const [] : pages.skip(_tabs).toList(),
        open: _open,
        reload: widget.reload,
      );
    } else {
      root = pages.firstWhere((p) => p.key == key).build(widget.farm, _open);
    }
    return Navigator(
      key: _nav(key),
      onGenerateRoute: (s) => MaterialPageRoute<void>(settings: s, builder: (_) => root),
    );
  }

  @override
  Widget build(BuildContext context) {
    final farm = widget.farm;
    // Delivery staff with no office pages: one screen, the round.
    if (farm.roundOnly) return RoundOnly(farm: farm);
    wide = MediaQuery.sizeOf(context).width >= 980;
    final items = _items;
    if (current == null || !items.contains(current)) {
      current = items.first;
    }
    seen.add(current!);
    final index = items.indexOf(current!);
    final stack = IndexedStack(
      index: index,
      sizing: StackFit.expand,
      children: [for (final k in items) seen.contains(k) ? _stack(k) : const SizedBox.shrink()],
    );
    final pop = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = navs[current]?.currentState;
        if (nav != null && nav.canPop()) {
          nav.maybePop();
        } else if (index != 0) {
          _select(items.first);
        }
      },
      child: stack,
    );
    final navItems = [
      for (final p in (wide ? pages : pages.take(_tabs))) KNavItem(p.icon, p.iconOn, p.label),
      const KNavItem(Icons.person_outline_rounded, Icons.person_rounded, 'Profile'),
    ];
    if (wide) {
      return Scaffold(
        body: Row(children: [
          _SideBar(farm: farm, items: navItems, index: index, onTap: (i) => _select(items[i])),
          const VerticalDivider(width: 1),
          Expanded(child: pop),
        ]),
      );
    }
    return Scaffold(
      body: pop,
      bottomNavigationBar: KNavBar(items: navItems, index: index, onTap: (i) => _select(items[i])),
    );
  }
}

class _SideBar extends StatelessWidget {
  const _SideBar({required this.farm, required this.items, required this.index, required this.onTap});
  final FarmRole farm;
  final List<KNavItem> items;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      color: K.surface,
      child: SafeArea(
        right: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 14, 6),
            child: Row(children: [
              const DaireeMark(size: 30),
              const SizedBox(width: 10),
              Text('Dairee', style: T.h2.copyWith(fontSize: 21)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 14, 14),
            child: Text(farm.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.small.copyWith(color: K.blue, fontWeight: FontWeight.w800)),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
              for (var i = 0; i < items.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Material(
                    color: i == index ? K.brand100 : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => onTap(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                        child: Row(children: [
                          Icon(i == index ? items[i].iconOn : items[i].icon, size: 21, color: i == index ? K.brand600 : K.muted),
                          const SizedBox(width: 12),
                          Expanded(child: Text(items[i].label, style: T.bodyStrong.copyWith(color: i == index ? K.ink : K.ink2))),
                        ]),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 14, 18),
            child: Row(children: [
              Avatar(farm.staffName, size: 30, color: K.deep, fg: K.heroText),
              const SizedBox(width: 10),
              Expanded(child: Text(farm.staffName, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.label)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// You and the farm, like Kuree's Profile tab: who is signed in, the farm's
/// other pages, help, the legal pages and the account, in labelled groups.
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, required this.farm, required this.pages, required this.open, required this.reload});
  final FarmRole farm;

  /// Pages with no tab of their own (phones only).
  final List<FarmPage> pages;
  final void Function(String key) open;
  final Future<void> Function() reload;

  @override
  Widget build(BuildContext context) {
    final me = Me.instance;
    final contact = me.phone != null ? prettyPhone(me.phone) : (me.email ?? '');
    return Scaffold(
      appBar: AppBar(titleSpacing: Sp.xl, title: const Text('Profile')),
      body: PageBody(onRefresh: reload, bottom: 40, children: [
        KCard(
          child: Row(children: [
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: K.deep, shape: BoxShape.circle),
              child: Text(initials(farm.staffName.isEmpty ? 'D' : farm.staffName), style: T.h3.copyWith(color: K.heroText)),
            ),
            const SizedBox(width: Sp.md + 2),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(farm.staffName.isEmpty ? 'No name yet' : farm.staffName, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.h3),
                Text([farm.name, if (farm.isAdmin) 'Admin'].join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
                if (contact.isNotEmpty) Text(contact, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
              ]),
            ),
          ]),
        ),
        const GroupLabel('Farm'),
        LinkGroup([
          for (final p in pages) LinkRow(p.icon, p.label, () => open(p.key), sub: p.sub),
          if (farm.can('deliveries'))
            LinkRow(Icons.tv_rounded, 'Wall board', () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => WallBoard(farm: farm))),
                sub: 'Today\'s rounds, full screen, for the office'),
          if (me.farms.length > 1) LinkRow(Icons.swap_horiz_rounded, 'Switch farm', () => switchFarm(context, farm), value: farm.name),
          LinkRow(Icons.refresh_rounded, 'Refresh my pages', reload, sub: 'After an admin changes what you can open'),
        ]),
        const GroupLabel('Help'),
        LinkGroup([
          LinkRow(Icons.support_agent_rounded, 'Help and support', () => launchUrl(Uri.parse(kSupportUrl), mode: LaunchMode.externalApplication)),
          LinkRow(Icons.mail_outline_rounded, 'Contact', () => launchUrl(Uri.parse('mailto:$kSupportEmail?subject=Dairee'))),
        ]),
        const GroupLabel('Legal'),
        LinkGroup([
          LinkRow(Icons.privacy_tip_outlined, 'Privacy', () => launchUrl(Uri.parse(kPrivacyUrl), mode: LaunchMode.externalApplication)),
          LinkRow(Icons.description_outlined, 'Terms', () => launchUrl(Uri.parse(kTermsUrl), mode: LaunchMode.externalApplication)),
        ]),
        const GroupLabel('Account'),
        LinkGroup([
          if (me.email != null)
            LinkRow(Icons.password_rounded, 'Choose a password', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SetPassword())),
                sub: 'Sign in with your email and a password, no code'),
          LinkRow(Icons.logout_rounded, 'Sign out', () => signOut(context)),
          LinkRow(Icons.delete_outline_rounded, 'Delete account', () => deleteMyAccount(context), bad: true),
        ]),
      ]),
    );
  }
}

/// The farms this person works for, to pick another.
Future<void> switchFarm(BuildContext context, FarmRole farm) async {
  final me = Me.instance;
  final pick = await showPicker<String>(context, title: 'Your farms', selected: farm.id, options: [
    for (final f in me.farms) PickOption(f.id, f.name, sub: f.isAdmin ? 'Admin' : f.staffName, icon: Icons.storefront_outlined),
  ]);
  if (pick == null || pick.value == farm.id) return;
  me.switchTo(me.farms.firstWhere((f) => f.id == pick.value));
}

Future<void> signOut(BuildContext context) async {
  if (await confirm(context, title: 'Sign out?', text: 'You can sign in again any time.', yes: 'Sign out')) {
    Me.instance.clear();
    await Api.instance.signOut();
  }
}

Future<void> deleteMyAccount(BuildContext context) async {
  final ok = await confirm(context,
      title: 'Delete your account?',
      text: 'You leave every farm you work for. A farm where you are the only person working is deleted with all its records. This cannot be undone.',
      yes: 'Delete',
      danger: true);
  if (!ok) return;
  try {
    await Api.instance.deleteAccount();
    Me.instance.clear();
  } on ApiError catch (e) {
    if (context.mounted) toast(context, e.message, bad: true);
  }
}
