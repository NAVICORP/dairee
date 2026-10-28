import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import 'theme.dart';

enum KButtonKind { primary, secondary, ghost, danger, blue }

/// A rounded button sized to its label (or full width when asked).
class KButton extends StatelessWidget {
  const KButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.kind = KButtonKind.primary,
    this.busy = false,
    this.expand = false,
    this.small = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final KButtonKind kind;
  final bool busy;
  final bool expand;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, side) = switch (kind) {
      KButtonKind.primary => (K.deep, Colors.white, BorderSide.none),
      KButtonKind.secondary => (K.surface, K.deep, const BorderSide(color: K.border2)),
      KButtonKind.ghost => (Colors.transparent, K.blue, BorderSide.none),
      KButtonKind.danger => (K.badBg, K.bad, BorderSide.none),
      KButtonKind.blue => (K.blue, Colors.white, BorderSide.none),
    };
    final enabled = onPressed != null && !busy;
    final h = small ? 38.0 : 44.0;
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2.4, color: fg))
        else if (icon != null)
          Icon(icon, size: small ? 16 : 18, color: fg),
        if (busy || icon != null) SizedBox(width: small ? 6 : 8),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
              style: T.button.copyWith(color: fg, fontSize: small ? 13 : 14)),
        ),
      ],
    );
    return Opacity(
      opacity: enabled || busy ? 1 : 0.45,
      child: Material(
        color: bg,
        shape: StadiumBorder(side: side),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled
              ? () {
                  HapticFeedback.selectionClick();
                  onPressed!();
                }
              : null,
          child: Container(height: h, padding: EdgeInsets.symmetric(horizontal: small ? 14 : 18), child: child),
        ),
      ),
    );
  }
}

/// A white card with a hairline border and a soft shadow.
class KCard extends StatelessWidget {
  const KCard({super.key, required this.child, this.padding = const EdgeInsets.all(Sp.lg), this.onTap, this.color = K.surface});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(K.r),
        border: Border.all(color: K.border),
        boxShadow: K.shadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(K.r),
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? Padding(padding: padding, child: child) : InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      ),
    );
  }
}

/// The deep navy card at the top of a screen.
class HeroCard extends StatelessWidget {
  const HeroCard({super.key, required this.child, this.padding = const EdgeInsetsDirectional.fromSTEB(18, 16, 18, 18)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(K.rLg),
        color: K.deep,
        boxShadow: const [BoxShadow(color: Color(0x660A1F44), blurRadius: 40, spreadRadius: -22, offset: Offset(0, 18))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        PositionedDirectional(
          end: -120,
          top: -110,
          child: Container(
            width: 320,
            height: 240,
            decoration: const BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Color(0x404C9BFF), Color(0x004C9BFF)])),
          ),
        ),
        Padding(padding: padding, child: child),
      ]),
    );
  }
}

/// A small rounded label, as wide as its words.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = K.brand100, this.fg = K.brand600, this.icon});
  final String text;
  final Color color;
  final Color fg;
  final IconData? icon;

  const Pill.warn(this.text, {super.key, this.icon})
      : color = K.warnBg,
        fg = K.warn;
  const Pill.bad(this.text, {super.key, this.icon})
      : color = K.badBg,
        fg = K.bad;
  const Pill.grey(this.text, {super.key, this.icon})
      : color = K.surface2,
        fg = K.ink2;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: fg), const SizedBox(width: 4)],
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.tiny.copyWith(color: fg))),
      ]),
    );
  }
}

/// A thin progress line that fills from the start side.
class ProgressLine extends StatelessWidget {
  const ProgressLine(this.value, {super.key, this.color = K.glow, this.track = const Color(0x24FFFFFF), this.height = 8});
  final double value;
  final Color color;
  final Color track;
  final double height;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.isFinite ? c.maxWidth : 200.0;
      return ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: Container(
          width: w,
          height: height,
          color: track,
          alignment: AlignmentDirectional.centerStart,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
            width: w * value.clamp(0, 1).toDouble(),
            height: height,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(height)),
          ),
        ),
      );
    });
  }
}

/// Choices in a rounded pill: Morning, Evening.
class KSegmented<V> extends StatelessWidget {
  const KSegmented({super.key, required this.items, required this.value, required this.onChanged, this.expand = false});
  final List<(V, String)> items;
  final V value;
  final ValueChanged<V> onChanged;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    Widget item(V v, String label) => Semantics(
          button: true,
          selected: v == value,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              onChanged(v);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              constraints: const BoxConstraints(minHeight: 36),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: v == value ? K.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                boxShadow: v == value ? const [BoxShadow(color: Color(0x1A0A1F44), blurRadius: 6, offset: Offset(0, 2))] : null,
              ),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.label.copyWith(color: v == value ? K.deep : K.muted)),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: K.surface2, borderRadius: BorderRadius.circular(999), border: Border.all(color: K.border)),
      child: Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, children: [
        for (final (v, label) in items) expand ? Expanded(child: item(v, label)) : item(v, label),
      ]),
    );
  }
}

/// A round icon button. The circle can be small, but the place to tap is
/// always at least 44 across.
class RoundIcon extends StatelessWidget {
  const RoundIcon(this.icon, {super.key, this.onTap, this.dark = false, this.tooltip, this.size = 36, this.color});
  final IconData icon;
  final VoidCallback? onTap;
  final bool dark;
  final String? tooltip;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tap = math.max(44.0, size);
    final circle = Opacity(
      opacity: onTap == null ? 0.3 : 1,
      child: Material(
        color: dark ? const Color(0x1AFFFFFF) : K.surface,
        shape: CircleBorder(side: dark ? BorderSide.none : const BorderSide(color: K.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(width: size, height: size, child: Icon(icon, size: size * 0.5, color: color ?? (dark ? K.heroText : K.ink))),
        ),
      ),
    );
    final w = Semantics(
      button: true,
      enabled: onTap != null,
      label: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(width: tap, height: tap, child: Center(child: circle)),
      ),
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, excludeFromSemantics: true, child: w);
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: Sp.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(color: K.brand100, borderRadius: BorderRadius.circular(K.rMd + 2)),
          child: Icon(icon, color: K.blue, size: 23),
        ),
        const SizedBox(height: Sp.md + 2),
        Text(text, textAlign: TextAlign.center, style: T.body.copyWith(color: K.muted)),
        if (action != null) ...[const SizedBox(height: Sp.lg), action!],
      ]),
    );
  }
}

/// A message in a form, in red or calm blue.
class Notice extends StatelessWidget {
  const Notice(this.text, {super.key, this.bad = true});
  final String text;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final fg = bad ? K.bad : K.brand600;
    return Container(
      width: double.infinity,
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 14, 10),
      decoration: BoxDecoration(color: bad ? K.badBg : K.brand100, borderRadius: BorderRadius.circular(K.rSm)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(bad ? Icons.error_outline_rounded : Icons.info_outline_rounded, size: 17, color: fg)),
        const SizedBox(width: Sp.sm),
        Expanded(child: Text(text, style: T.small.copyWith(color: fg))),
      ]),
    );
  }
}

/// A title row for a section.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing, this.top = 18});
  final String text;
  final Widget? trailing;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(4, top, 4, 8),
      child: Row(children: [
        Expanded(child: Text(text, style: T.h3)),
        if (trailing != null) ...[const SizedBox(width: Sp.sm), trailing!],
      ]),
    );
  }
}

/// A row that opens a choice: a small label, the value, and a chevron.
class KChoice extends StatelessWidget {
  const KChoice({super.key, required this.label, required this.value, required this.onTap, this.icon});
  final String label;
  final String value;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: K.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: K.border2)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 9, 10, 9),
          child: Row(children: [
            if (icon != null) ...[Icon(icon, color: K.ink2, size: 19), const SizedBox(width: 10)],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: T.tiny),
                const SizedBox(height: 1),
                Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.bodyStrong),
              ]),
            ),
            const SizedBox(width: Sp.sm),
            const Icon(Icons.expand_more_rounded, color: K.muted, size: 20),
          ]),
        ),
      ),
    );
  }
}

/// A labelled text field.
class KField extends StatelessWidget {
  const KField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.keyboard,
    this.formatters,
    this.obscure = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.onSubmitted,
    this.onChanged,
    this.autofill,
    this.caps = TextCapitalization.sentences,
    this.prefix,
    this.suffix,
    this.enabled = true,
  });
  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboard;
  final List<TextInputFormatter>? formatters;
  final bool obscure;
  final bool autofocus;
  final int maxLines;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final Iterable<String>? autofill;
  final TextCapitalization caps;
  final String? prefix;
  final String? suffix;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsetsDirectional.only(start: 2, bottom: 6), child: Text(label, style: T.label)),
      TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: keyboard,
        inputFormatters: formatters,
        obscureText: obscure,
        autofocus: autofocus,
        maxLines: obscure ? 1 : maxLines,
        minLines: 1,
        textCapitalization: caps,
        autofillHints: autofill,
        style: T.bodyStrong,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        decoration: InputDecoration(hintText: hint, prefixText: prefix, suffixText: suffix),
      ),
    ]);
  }
}

/// A row with a label, a line under it, and a switch.
class KSwitchRow extends StatelessWidget {
  const KSwitchRow({super.key, required this.title, this.sub, required this.value, required this.onChanged});
  final String title;
  final String? sub;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      borderRadius: BorderRadius.circular(K.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: T.bodyStrong),
              if (sub != null) Text(sub!, style: T.small),
            ]),
          ),
          const SizedBox(width: Sp.md),
          Switch(value: value, onChanged: onChanged),
        ]),
      ),
    );
  }
}

/// A round avatar with initials.
class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 36, this.color = K.brand100, this.fg = K.brand600});
  final String name;
  final double size;
  final Color color;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(initials(name), style: TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w800, fontSize: size * 0.36, color: fg, letterSpacing: 0)),
    );
  }
}

/// A number with a label under it, for the tops of screens.
class Stat extends StatelessWidget {
  const Stat(this.value, this.label, {super.key, this.dark = false, this.big = false});
  final String value;
  final String label;
  final bool dark;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (big ? T.amount : T.h2).copyWith(color: dark ? Colors.white : K.ink, fontFeatures: const [FontFeature.tabularFigures()])),
      const SizedBox(height: 3),
      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small.copyWith(color: dark ? K.heroText : K.muted)),
    ]);
  }
}

/// A white tile with a number, for summaries.
class StatTile extends StatelessWidget {
  const StatTile(this.value, this.label, {super.key, this.tone});
  final String value;
  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: K.surface, borderRadius: BorderRadius.circular(K.rMd), border: Border.all(color: K.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.h2.copyWith(color: tone ?? K.ink, fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 2),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
      ]),
    );
  }
}

/// A list row: something at the start, a title and a line, something at the end.
class KRow extends StatelessWidget {
  const KRow({super.key, this.leading, required this.title, this.sub, this.trailing, this.onTap, this.padding});
  final Widget? leading;
  final String title;
  final String? sub;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: padding ?? const EdgeInsetsDirectional.fromSTEB(14, 10, 12, 10),
        child: Row(children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.bodyStrong),
              if (sub != null && sub!.isNotEmpty) Text(sub!, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.small),
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: Sp.sm), trailing!],
        ]),
      ),
    );
  }
}

/// A white group of rows with hairlines between them.
class KGroup extends StatelessWidget {
  const KGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: K.surface, borderRadius: BorderRadius.circular(K.r), border: Border.all(color: K.border)),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 14),
            children[i],
          ],
        ]),
      ),
    );
  }
}

/// The search field at the top of lists.
class SearchField extends StatelessWidget {
  const SearchField({super.key, required this.controller, this.hint = 'Search', this.onChanged});
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: T.bodyStrong,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search_rounded, size: 20, color: K.muted),
        suffixIcon: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => controller.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () {
                    controller.clear();
                    onChanged?.call('');
                  },
                ),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}

// ---------------------------------------------------------------- sheets and dialogs

/// A rounded sheet from the bottom with a title and a close button.
Future<R?> showKSheet<R>(BuildContext context, {required String title, required Widget Function(BuildContext) builder, bool scroll = true}) {
  return showModalBottomSheet<R>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: K.paper,
    builder: (ctx) {
      final media = MediaQuery.of(ctx);
      final pad = EdgeInsets.fromLTRB(Sp.xl, Sp.sm, Sp.xl, Sp.xxl + media.padding.bottom);
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.92),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 10),
            Center(child: Container(width: 38, height: 5, decoration: BoxDecoration(color: K.border2, borderRadius: BorderRadius.circular(5)))),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(22, 8, 8, 4),
              child: Row(children: [
                Expanded(child: Text(title, style: T.h2)),
                RoundIcon(Icons.close_rounded, tooltip: 'Close', onTap: () => Navigator.of(ctx).pop(), size: 32),
              ]),
            ),
            Flexible(child: scroll ? SingleChildScrollView(padding: pad, child: builder(ctx)) : Padding(padding: pad, child: builder(ctx))),
          ]),
        ),
      );
    },
  );
}

class PickOption<V> {
  const PickOption(this.value, this.label, {this.sub, this.icon, this.trailing});
  final V value;
  final String label;
  final String? sub;
  final IconData? icon;
  final String? trailing;
}

/// A list to choose from, in a rounded sheet (instead of a dropdown).
Future<PickOption<V>?> showPicker<V>(BuildContext context,
    {required String title, required List<PickOption<V>> options, V? selected, bool search = false}) {
  final q = TextEditingController();
  return showKSheet<PickOption<V>>(
    context,
    title: title,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final t = q.text.trim().toLowerCase();
      final shown = t.isEmpty
          ? options
          : options.where((o) => o.label.toLowerCase().contains(t) || (o.sub ?? '').toLowerCase().contains(t)).toList();
      return Column(children: [
        if (search) ...[SearchField(controller: q, onChanged: (_) => set(() {})), const SizedBox(height: Sp.md)],
        if (shown.isEmpty) const Padding(padding: EdgeInsets.all(Sp.xl), child: Text('Nothing matches', style: T.small)),
        for (final o in shown.take(300))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: o.value == selected ? K.brand100 : K.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(K.rMd),
                side: BorderSide(color: o.value == selected ? K.brand200 : K.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => Navigator.of(ctx).pop(o),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(14, 9, 14, 9),
                  child: Row(children: [
                    if (o.icon != null) ...[
                      Container(
                        width: 30,
                        height: 30,
                        decoration: const BoxDecoration(color: K.surface2, shape: BoxShape.circle),
                        child: Icon(o.icon, size: 16, color: K.ink2),
                      ),
                      const SizedBox(width: Sp.md),
                    ],
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(o.label, style: T.bodyStrong),
                        if (o.sub != null) Text(o.sub!, style: T.small),
                      ]),
                    ),
                    if (o.trailing != null) ...[const SizedBox(width: Sp.sm), Text(o.trailing!, style: T.label.copyWith(color: K.muted))],
                    if (o.value == selected) ...[const SizedBox(width: Sp.sm), const Icon(Icons.check_rounded, color: K.blue, size: 20)],
                  ]),
                ),
              ),
            ),
          ),
      ]);
    }),
  );
}

Future<bool> confirm(BuildContext context, {required String title, required String text, String yes = 'Yes', String no = 'Cancel', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actionsPadding: const EdgeInsets.fromLTRB(Sp.lg, 0, Sp.lg, Sp.lg),
      actions: [
        KButton(label: no, kind: KButtonKind.ghost, small: true, onPressed: () => Navigator.of(ctx).pop(false)),
        KButton(label: yes, kind: danger ? KButtonKind.danger : KButtonKind.primary, small: true, onPressed: () => Navigator.of(ctx).pop(true)),
      ],
    ),
  );
  return r ?? false;
}

void toast(BuildContext context, String text, {bool bad = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(text),
    backgroundColor: bad ? K.bad : K.deep,
    duration: Duration(milliseconds: bad ? 4500 : 2600),
  ));
}

// ---------------------------------------------------------------- dates

/// A month of days to pick from, in a rounded sheet: never the system picker.
Future<DateTime?> pickDate(BuildContext context, {required DateTime initial, DateTime? first, DateTime? last, String title = 'Pick a day'}) {
  return showKSheet<DateTime>(context, title: title, builder: (ctx) => _Calendar(initial: initial, first: first, last: last, onPick: (d) => Navigator.of(ctx).pop(d)));
}

/// Two days, the first and the last, picked one after the other.
Future<(DateTime, DateTime)?> pickPeriod(BuildContext context, {required DateTime from, required DateTime to, String title = 'Pick the days'}) async {
  final a = await pickDate(context, initial: from, title: '$title: first day');
  if (a == null || !context.mounted) return null;
  final b = await pickDate(context, initial: to.isBefore(a) ? a : to, first: a, title: '$title: last day');
  if (b == null) return null;
  return (a, b);
}

class _Calendar extends StatefulWidget {
  const _Calendar({required this.initial, this.first, this.last, required this.onPick});
  final DateTime initial;
  final DateTime? first;
  final DateTime? last;
  final ValueChanged<DateTime> onPick;

  @override
  State<_Calendar> createState() => _CalendarState();
}

class _CalendarState extends State<_Calendar> {
  late DateTime month = DateTime(widget.initial.year, widget.initial.month);

  bool _ok(DateTime d) => (widget.first == null || !d.isBefore(dayOnly(widget.first!))) && (widget.last == null || !d.isAfter(dayOnly(widget.last!)));

  @override
  Widget build(BuildContext context) {
    final days = DateTime(month.year, month.month + 1, 0).day;
    final lead = DateTime(month.year, month.month, 1).weekday - 1;
    final today = dayOnly(DateTime.now());
    final picked = dayOnly(widget.initial);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        RoundIcon(Icons.chevron_left_rounded, tooltip: 'Previous month', onTap: () => setState(() => month = DateTime(month.year, month.month - 1))),
        Expanded(child: Text(monthLabel(month), textAlign: TextAlign.center, style: T.h3)),
        RoundIcon(Icons.chevron_right_rounded, tooltip: 'Next month', onTap: () => setState(() => month = DateTime(month.year, month.month + 1))),
      ]),
      const SizedBox(height: Sp.sm),
      Row(children: [for (final d in kDaysShort) Expanded(child: Center(child: Text(d.substring(0, 2), style: T.tiny)))]),
      const SizedBox(height: Sp.xs),
      GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 1.1,
        children: [
          for (var i = 0; i < lead; i++) const SizedBox.shrink(),
          for (var n = 1; n <= days; n++)
            Builder(builder: (context) {
              final d = DateTime(month.year, month.month, n);
              final ok = _ok(d);
              final sel = d == picked;
              final isToday = d == today;
              return Padding(
                padding: const EdgeInsets.all(2),
                child: Material(
                  color: sel ? K.blue : (isToday ? K.brand100 : Colors.transparent),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: ok ? () => widget.onPick(d) : null,
                    child: Center(
                      child: Text('$n',
                          style: T.bodyStrong.copyWith(color: sel ? Colors.white : (ok ? K.ink : K.border2), fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
      const SizedBox(height: Sp.sm),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (_ok(today)) KButton(label: 'Today', kind: KButtonKind.ghost, small: true, onPressed: () => widget.onPick(today)),
      ]),
    ]);
  }
}

/// A day with arrows either side: the date on show, and a tap for the calendar.
class DayStrip extends StatelessWidget {
  const DayStrip({super.key, required this.day, required this.today, required this.onChanged, this.trailing});
  final DateTime day;
  final DateTime today;
  final ValueChanged<DateTime> onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      RoundIcon(Icons.chevron_left_rounded, size: 34, tooltip: 'Day before', onTap: () => onChanged(addDays(day, -1))),
      Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () async {
            final d = await pickDate(context, initial: day);
            if (d != null) onChanged(d);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(children: [
              Text(relativeDay(day, today), style: T.h3),
              Text(dateLabel(day), style: T.small),
            ]),
          ),
        ),
      ),
      RoundIcon(Icons.chevron_right_rounded, size: 34, tooltip: 'Day after', onTap: () => onChanged(addDays(day, 1))),
      if (trailing != null) trailing!,
    ]);
  }
}

// ---------------------------------------------------------------- footer and loading

class KNavItem {
  const KNavItem(this.icon, this.iconOn, this.label);
  final IconData icon;
  final IconData iconOn;
  final String label;
}

/// The footer with the main pages: the chosen one sits in a soft blue pill.
class KNavBar extends StatelessWidget {
  const KNavBar({super.key, required this.items, required this.index, required this.onTap});
  final List<KNavItem> items;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(color: K.surface, border: Border(top: BorderSide(color: K.border))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: i == index,
                  label: items[i].label,
                  child: InkWell(
                    onTap: () {
                      if (i != index) HapticFeedback.selectionClick();
                      onTap(i);
                    },
                    child: ExcludeSemantics(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 52,
                          height: 28,
                          decoration: BoxDecoration(color: i == index ? K.brand100 : Colors.transparent, borderRadius: BorderRadius.circular(999)),
                          child: Icon(i == index ? items[i].iconOn : items[i].icon, size: 21, color: i == index ? K.brand600 : K.muted),
                        ),
                        const SizedBox(height: 3),
                        Text(items[i].label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: T.tiny.copyWith(fontSize: 11.5, color: i == index ? K.ink : K.muted, fontWeight: i == index ? FontWeight.w700 : FontWeight.w600)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)));
}

/// Something did not load: what happened, and a way to try again.
class LoadFailed extends StatelessWidget {
  const LoadFailed({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: EmptyState(
        icon: Icons.wifi_off_rounded,
        text: message,
        action: KButton(label: 'Try again', icon: Icons.refresh_rounded, kind: KButtonKind.secondary, onPressed: onRetry),
      ),
    );
  }
}

/// A page's body: a centred column no wider than reads well on a laptop.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.onRefresh, this.maxWidth = 760, this.bottom = 32});
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final double maxWidth;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      padding: EdgeInsets.fromLTRB(Sp.page, Sp.sm, Sp.page, bottom),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ],
    );
    return onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, color: K.blue, child: list);
  }
}

/// Dairee's mark, drawn in code from the same geometry as tools/brand.py: the
/// letter D whose counter is a drop of milk, white on a blue tile. Drawn, not
/// loaded, so it is there on the very first frame, at any size.
class DaireeMark extends StatelessWidget {
  const DaireeMark({super.key, this.size = 40, this.radius = 0.22});
  final double size;

  /// Corner rounding of the tile, as a share of its side.
  final double radius;

  @override
  Widget build(BuildContext context) =>
      Semantics(label: 'Dairee', image: true, child: CustomPaint(size: Size.square(size), painter: _MarkPainter(radius)));
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.radius);
  final double radius;

  static Path mark() {
    const h = 540.0, a = 200.0, r = h / 2, w = a + r, stem = 150.0, corner = 36.0;
    const dropR = 124.0, dropTop = 100.0, dropBottom = 110.0;
    const x0 = (1024 - w) / 2, y0 = (1024 - h) / 2;
    final d = Path()
      ..moveTo(x0 + corner, y0)
      ..lineTo(x0 + a, y0)
      ..arcToPoint(const Offset(x0 + a, y0 + h), radius: const Radius.circular(r))
      ..lineTo(x0 + corner, y0 + h)
      ..quadraticBezierTo(x0, y0 + h, x0, y0 + h - corner)
      ..lineTo(x0, y0 + corner)
      ..quadraticBezierTo(x0, y0, x0 + corner, y0)
      ..close();
    const cx = x0 + stem + (w - stem) / 2 - 16;
    const cy = y0 + h - dropBottom - dropR;
    const tip = y0 + dropTop;
    const dist = cy - tip;
    final len = math.sqrt(dist * dist - dropR * dropR);
    final px = cx + dropR * len / dist;
    const py = cy - dropR * dropR / dist;
    final vx = px - cx, vy = py - tip;
    final n = math.sqrt(vx * vx + vy * vy);
    final qx = (cx + px) / 2 + (vy / n) * len * 0.03;
    final qy = (tip + py) / 2 - (vx / n) * len * 0.03;
    final drop = Path()
      ..moveTo(cx, tip)
      ..quadraticBezierTo(qx, qy, px, py)
      ..arcToPoint(Offset(2 * cx - px, py), radius: const Radius.circular(dropR), largeArc: true)
      ..quadraticBezierTo(2 * cx - qx, qy, cx, tip)
      ..close();
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addPath(d, Offset.zero)
      ..addPath(drop, Offset.zero);
  }

  static final Path _mark = mark();

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 1024;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.width * radius)), Paint()..color = K.blue);
    canvas.save();
    canvas.scale(k);
    canvas.drawPath(_mark, Paint()..color = Colors.white);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => old.radius != radius;
}
