import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Liquid glass, after Apple's 2025 design language: a see-through layer that
/// floats over the app, blurs and bends what passes under it, and catches the
/// light along its rim.
///
/// It belongs to the navigation layer only: the footer, the add buttons,
/// header buttons, the Morning / Evening pills, action bars and sheets. Lists,
/// cards and figures stay solid, so the round always reads clearly. With
/// Increase contrast turned on, every glass surface becomes a plain solid one.
enum GlassTone {
  /// Frosted white with a hint of ice blue, for controls on the light pages.
  light,

  /// Blue glass with white on it, for the main action (the add buttons, the
  /// chosen pill).
  blue,

  /// Clear glass for controls that sit on the deep navy cards.
  dark,

  /// An ice-blue drop inside other glass: the chosen footer tab.
  ice,

  /// Thick frosted glass for sheets, so their text reads as clearly as a page.
  sheet,
}

/// True when glass should give way to solid surfaces.
bool glassOff(BuildContext context) => MediaQuery.highContrastOf(context);

class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 999,
    this.borderRadius,
    this.tone = GlassTone.light,
    this.blur = 0,
    this.shadow = true,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;

  /// The corner radius; 999 makes a capsule or a circle.
  final double radius;

  /// Corners that differ, such as a sheet's rounded top. Wins over [radius].
  final BorderRadius? borderRadius;
  final GlassTone tone;

  /// How much of what is behind is blurred. 0 for glass that sits on a plain
  /// page (nothing moves under it), so it costs nothing to draw.
  final double blur;
  final bool shadow;
  final EdgeInsetsGeometry padding;

  static List<Color> _fill(GlassTone tone) => switch (tone) {
        GlassTone.light => const [Color(0xD6FFFFFF), Color(0x9EF1F6FF), Color(0xB8FFFFFF)],
        GlassTone.blue => const [Color(0xF2468FF2), Color(0xF21064D9), Color(0xF70B50B4)],
        GlassTone.dark => const [Color(0x2EFFFFFF), Color(0x14FFFFFF), Color(0x1FFFFFFF)],
        GlassTone.ice => const [Color(0xF5E6F0FF), Color(0xE6D1E3FC), Color(0xEDDDEBFE)],
        GlassTone.sheet => const [Color(0xF5FBFCFF), Color(0xEBF2F6FC), Color(0xF2F8FAFF)],
      };

  static Color _solid(GlassTone tone) => switch (tone) {
        GlassTone.light => K.surface,
        GlassTone.blue => K.blue,
        GlassTone.dark => const Color(0x26FFFFFF),
        GlassTone.ice => K.brand100,
        GlassTone.sheet => K.paper,
      };

  @override
  Widget build(BuildContext context) {
    final off = glassOff(context);
    final r = borderRadius ?? BorderRadius.circular(radius);
    Widget body = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        color: off ? _solid(tone) : null,
        border: off && (tone == GlassTone.light || tone == GlassTone.ice) ? Border.all(color: K.border2) : null,
        gradient: off
            ? null
            : LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: _fill(tone), stops: const [0, 0.55, 1]),
      ),
      child: Padding(padding: padding, child: child),
    );
    if (!off) body = CustomPaint(foregroundPainter: _GlassRim(r, tone), child: body);
    if (!off && blur > 0) {
      body = BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: body);
    }
    body = ClipRRect(borderRadius: r, child: body);
    if (shadow) body = CustomPaint(painter: _GlassShadow(r, tone, strong: blur > 0), child: body);
    return body;
  }
}

/// The light along the rim: bright at the top left where the light comes
/// from, faint along the sides, and a second, softer catch at the bottom
/// right where it bends through. A sheen across the top half sells the
/// thickness of the glass.
class _GlassRim extends CustomPainter {
  _GlassRim(this.radius, this.tone);
  final BorderRadius radius;
  final GlassTone tone;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = radius.toRRect(rect);
    final (top, side, low, sheen) = switch (tone) {
      GlassTone.light => (0.95, 0.30, 0.70, 0.55),
      GlassTone.blue => (0.70, 0.12, 0.40, 0.30),
      GlassTone.dark => (0.55, 0.08, 0.28, 0.16),
      GlassTone.ice => (0.95, 0.35, 0.60, 0.50),
      GlassTone.sheet => (1.0, 0.0, 0.0, 0.0),
    };
    final white = Colors.white;
    // The sheen: a soft white wash over the top half, gone by the middle.
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * 0.55),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [white.withValues(alpha: sheen), white.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.55)),
    );
    canvas.restore();
    // The rim.
    canvas.drawRRect(
      rr.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [white.withValues(alpha: top), white.withValues(alpha: side), white.withValues(alpha: low)],
          stops: const [0, 0.5, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassRim old) => old.radius != radius || old.tone != tone;
}

/// A soft shadow drawn only outside the glass, so it never greys the glass.
class _GlassShadow extends CustomPainter {
  _GlassShadow(this.radius, this.tone, {required this.strong});
  final BorderRadius radius;
  final GlassTone tone;
  final bool strong;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = radius.toRRect(rect);
    final colour = tone == GlassTone.blue ? K.brand600 : K.deep;
    canvas.save();
    canvas.clipPath(Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(80))
      ..addRRect(rr));
    canvas.drawRRect(
      rr.shift(Offset(0, strong ? 10 : 4)),
      Paint()
        ..color = colour.withValues(alpha: tone == GlassTone.blue ? 0.30 : (strong ? 0.16 : 0.08))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, strong ? 18 : 8),
    );
    canvas.drawRRect(
      rr.shift(const Offset(0, 1)),
      Paint()
        ..color = colour.withValues(alpha: 0.06)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassShadow old) => old.radius != radius || old.tone != tone || old.strong != strong;
}

/// Only the light on glass (rim and sheen), for buttons that keep their own
/// solid colour, such as Save: it makes them read as polished glass.
class GlassRim extends StatelessWidget {
  const GlassRim({super.key, required this.child, this.tone = GlassTone.dark, this.radius = 999});
  final Widget child;
  final GlassTone tone;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (glassOff(context)) return child;
    return CustomPaint(foregroundPainter: _GlassRim(BorderRadius.circular(radius), tone), child: child);
  }
}

/// The give of glass under a finger: it sinks a little while pressed and
/// springs back with a small bounce when let go.
class GlassPress extends StatefulWidget {
  const GlassPress({super.key, required this.child, this.onTap, this.label, this.depth = 0.92});
  final Widget child;
  final VoidCallback? onTap;
  final String? label;
  final double depth;

  @override
  State<GlassPress> createState() => _GlassPressState();
}

class _GlassPressState extends State<GlassPress> {
  bool down = false;

  void _set(bool v) {
    if (widget.onTap == null || down == v) return;
    setState(() => down = v);
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapCancel: () => _set(false),
        onTapUp: (_) => _set(false),
        onTap: widget.onTap == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                widget.onTap!();
              },
        child: AnimatedScale(
          scale: down && !still ? widget.depth : 1,
          duration: Duration(milliseconds: down ? 90 : 420),
          curve: down ? Curves.easeOut : Curves.elasticOut,
          child: widget.child,
        ),
      ),
    );
  }
}

/// A round add button as blue glass: it floats over the list, and the list
/// shows through it, blurred, as it scrolls past.
class GlassFab extends StatelessWidget {
  const GlassFab({super.key, required this.icon, required this.onPressed, this.tooltip, this.size = 60});
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final button = GlassPress(
      label: tooltip,
      onTap: onPressed,
      depth: 0.9,
      child: SizedBox(
        width: size,
        height: size,
        child: Glass(tone: GlassTone.blue, blur: 16, child: Center(child: Icon(icon, size: size * 0.46, color: Colors.white))),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Soft light behind glass that has nothing colourful under it, such as the
/// side bar on a computer: blue, sky and a touch of warm light, blurred into
/// the page colour.
class AmbientLight extends StatelessWidget {
  const AmbientLight({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (glassOff(context)) return ColoredBox(color: K.paper, child: child);
    return CustomPaint(painter: _Ambient(), child: child);
  }
}

class _Ambient extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = K.paper);
    void blob(Offset c, double r, Color colour) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(colors: [colour, colour.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    final m = math.max(size.width, size.height);
    blob(Offset(size.width * 0.05, size.height * 0.12), m * 0.32, K.sky.withValues(alpha: 0.45));
    blob(Offset(size.width * 0.18, size.height * 0.62), m * 0.30, const Color(0xFFFFB48A).withValues(alpha: 0.30));
    blob(Offset(size.width * 0.02, size.height * 0.95), m * 0.28, K.blue.withValues(alpha: 0.32));
    blob(Offset(size.width * 0.9, size.height * 0.05), m * 0.22, K.glow.withValues(alpha: 0.35));
  }

  @override
  bool shouldRepaint(_Ambient old) => false;
}
