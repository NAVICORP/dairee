import 'package:flutter/material.dart';

import '../../core/api.dart';
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
import 'wallboard.dart';

class _Page {
  const _Page(this.key, this.label, this.icon, this.iconOn, this.build);
  final String key;
  final String label;
  final IconData icon;
  final IconData iconOn;
  final Widget Function(FarmRole) build;
}

List<_Page> _pagesFor(FarmRole f) => [
      if (f.can('deliveries') || f.canDeliver)
        _Page('deliveries', 'Round', Icons.local_shipping_outlined, Icons.local_shipping_rounded,
            (f) => RoundPage(farm: f, office: f.can('deliveries'))),
      if (f.can('preparation')) _Page('preparation', 'Packing', Icons.inventory_2_outlined, Icons.inventory_2_rounded, (f) => PreparationPage(farm: f)),
      if (f.can('customers')) _Page('customers', 'Customers', Icons.people_outline_rounded, Icons.people_rounded, (f) => CustomersPage(farm: f)),
      if (f.can('pauses')) _Page('pauses', 'Pause / Stop', Icons.pause_circle_outline_rounded, Icons.pause_circle_rounded, (f) => ChangesPage(farm: f)),
      if (f.can('payments')) _Page('payments', 'Payments', Icons.account_balance_wallet_outlined, Icons.account_balance_wallet_rounded, (f) => PaymentsPage(farm: f)),
      if (f.can('reports')) _Page('reports', 'Reports', Icons.insights_outlined, Icons.insights_rounded, (f) => ReportsPage(farm: f)),
      if (f.can('cows') || f.canCare) _Page('cows', 'Cows', Icons.pets_outlined, Icons.pets_rounded, (f) => HerdPage(farm: f)),
      if (f.can('staff')) _Page('staff', 'Staff', Icons.badge_outlined, Icons.badge_rounded, (f) => StaffPage(farm: f)),
      if (f.can('settings')) _Page('settings', 'Settings', Icons.tune_outlined, Icons.tune_rounded, (f) => SettingsPage(farm: f)),
    ];

/// The farm: its pages in a footer on phones, in a side bar on wide screens.
/// Each page keeps its own pile of opened screens, so the footer stays below
/// a customer's page and comes back as it was left.
class FarmShell extends StatefulWidget {
  const FarmShell({super.key, required this.farm, required this.reload});
  final FarmRole farm;
  final Future<void> Function() reload;

  @override
  State<FarmShell> createState() => _FarmShellState();
}

class _FarmShellState extends State<FarmShell> {
  late final List<_Page> pages = _pagesFor(widget.farm);
  late final List<GlobalKey<NavigatorState>> navs = List.generate(pages.length + 1, (i) => GlobalKey<NavigatorState>(debugLabel: 'page $i'));
  final Set<int> seen = {0};
  int index = 0;

  static const _phoneTabs = 4;

  void _select(int i) {
    if (i == index) {
      final nav = navs[i].currentState;
      if (nav != null && nav.canPop()) nav.popUntil((r) => r.isFirst);
      return;
    }
    setState(() {
      index = i;
      seen.add(i);
    });
  }

  Widget _stack(int i, Widget root) => Navigator(
        key: navs[i],
        onGenerateRoute: (s) => MaterialPageRoute<void>(settings: s, builder: (_) => root),
      );

  void _openPage(String key) {
    final i = pages.indexWhere((p) => p.key == key);
    if (i >= 0) _select(i);
  }

  @override
  Widget build(BuildContext context) {
    final farm = widget.farm;
    // Delivery staff with no office pages: one screen, the round.
    if (farm.roundOnly) return RoundOnly(farm: farm);
    final wide = MediaQuery.sizeOf(context).width >= 980;
    final more = MorePage(
      farm: farm,
      pages: [for (final p in (wide ? const <_Page>[] : pages.skip(_phoneTabs))) (p.key, p.label, p.icon)],
      onOpen: _openPage,
      reload: widget.reload,
    );
    final children = [
      for (var i = 0; i < pages.length; i++) seen.contains(i) ? _stack(i, pages[i].build(farm)) : const SizedBox.shrink(),
      seen.contains(pages.length) ? _stack(pages.length, more) : const SizedBox.shrink(),
    ];
    final stack = IndexedStack(index: index, children: children);
    final pop = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = navs[index].currentState;
        if (nav != null && nav.canPop()) {
          nav.maybePop();
        } else if (index != 0) {
          _select(0);
        }
      },
      child: stack,
    );
    if (wide) {
      return Scaffold(
        body: Row(children: [
          _SideBar(
            farm: farm,
            items: [for (final p in pages) KNavItem(p.icon, p.iconOn, p.label), const KNavItem(Icons.more_horiz_rounded, Icons.more_horiz_rounded, 'More')],
            index: index,
            onTap: _select,
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pop),
        ]),
      );
    }
    final shown = pages.take(_phoneTabs).toList();
    final moreIndex = pages.length;
    final barIndex = index < shown.length ? index : shown.length;
    return Scaffold(
      body: pop,
      bottomNavigationBar: KNavBar(
        items: [for (final p in shown) KNavItem(p.icon, p.iconOn, p.label), const KNavItem(Icons.menu_rounded, Icons.menu_rounded, 'More')],
        index: barIndex,
        onTap: (i) => _select(i < shown.length ? i : moreIndex),
      ),
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
      width: 232,
      color: K.surface,
      child: SafeArea(
        right: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 12, 14),
            child: Row(children: [
              const DaireeMark(size: 32, radius: 0.3),
              const SizedBox(width: 10),
              Expanded(child: Text(farm.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.h3)),
            ]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
              for (var i = 0; i < items.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Material(
                    color: i == index ? K.brand100 : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onTap(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(children: [
                          Icon(i == index ? items[i].iconOn : items[i].icon, size: 20, color: i == index ? K.brand600 : K.muted),
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
            padding: const EdgeInsets.fromLTRB(18, 8, 12, 16),
            child: Text(farm.staffName, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
          ),
        ]),
      ),
    );
  }
}

/// The rest: pages that do not fit the footer, the wall board, other farms,
/// and the account.
class MorePage extends StatelessWidget {
  const MorePage({super.key, required this.farm, required this.pages, required this.onOpen, required this.reload});
  final FarmRole farm;
  final List<(String, String, IconData)> pages;
  final ValueChanged<String> onOpen;
  final Future<void> Function() reload;

  @override
  Widget build(BuildContext context) {
    final me = Me.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: PageBody(children: [
        KCard(
          child: Row(children: [
            Avatar(farm.staffName, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(farm.staffName, style: T.h3),
                Text([farm.name, if (farm.isAdmin) 'Admin'].join(', '), style: T.small),
                if (me.phone != null || me.email != null) Text(me.phone != null ? prettyPhone(me.phone) : me.email!, style: T.small),
              ]),
            ),
          ]),
        ),
        if (pages.isNotEmpty) ...[
          const SectionTitle('Pages'),
          KGroup(children: [
            for (final p in pages)
              KRow(
                leading: Icon(p.$3, color: K.ink2, size: 21),
                title: p.$2,
                trailing: const Icon(Icons.chevron_right_rounded, color: K.muted),
                onTap: () => onOpen(p.$1),
              ),
          ]),
        ],
        if (farm.can('deliveries')) ...[
          const SectionTitle('On the wall'),
          KGroup(children: [
            KRow(
              leading: const Icon(Icons.tv_rounded, color: K.ink2, size: 21),
              title: 'Wall board',
              sub: 'Today\'s rounds, full screen, for a screen in the office',
              trailing: const Icon(Icons.chevron_right_rounded, color: K.muted),
              onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => WallBoard(farm: farm))),
            ),
          ]),
        ],
        if (me.farms.length > 1) ...[
          const SectionTitle('Your farms'),
          KGroup(children: [
            for (final f in me.farms)
              KRow(
                leading: Avatar(f.name, size: 32),
                title: f.name,
                sub: f.isAdmin ? 'Admin' : f.staffName,
                trailing: f.id == farm.id ? const Icon(Icons.check_rounded, color: K.blue) : null,
                onTap: f.id == farm.id ? null : () => me.switchTo(f),
              ),
          ]),
        ],
        const SectionTitle('Account'),
        KGroup(children: [
          KRow(
            leading: const Icon(Icons.refresh_rounded, color: K.ink2, size: 21),
            title: 'Refresh my pages',
            sub: 'After an admin changes what you can open',
            onTap: reload,
          ),
          if (Me.instance.email != null)
            KRow(
              leading: const Icon(Icons.password_rounded, color: K.ink2, size: 21),
              title: 'Choose a password',
              sub: 'Sign in with your email and a password, no code',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SetPassword())),
            ),
          KRow(
            leading: const Icon(Icons.logout_rounded, color: K.ink2, size: 21),
            title: 'Sign out',
            onTap: () async {
              if (await confirm(context, title: 'Sign out?', text: 'You can sign in again any time.', yes: 'Sign out')) {
                Me.instance.clear();
                await Api.instance.signOut();
              }
            },
          ),
          KRow(
            leading: const Icon(Icons.person_remove_outlined, color: K.bad, size: 21),
            title: 'Delete my account',
            sub: 'Leave every farm and delete your Dairee account',
            onTap: () => deleteMyAccount(context),
          ),
        ]),
      ]),
    );
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
