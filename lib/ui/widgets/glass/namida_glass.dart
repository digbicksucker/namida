import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:namida/core/extensions.dart';

// ============================================================================
// NAMIDA · LIQUID GLASS
// ============================================================================
// A centralized, purely-visual glass layer. Nothing in this file knows about
// playback, navigation, settings or any other app logic — it only describes
// *how a surface looks*.
//
// The visual vocabulary is adopted from `liquid_glass_easy`:
//   • a translucent tint over a blurred backdrop (frosted acrylic),
//   • a light-diffusing gradient (brighter at the light origin),
//   • a thin edge highlight ("rim") that catches the light,
//   • depth via soft, low-opacity shadows instead of heavy elevation.
//
// It is implemented with Flutter's own compositing primitives instead of the
// package's real-time refraction shaders. Reasons, in order of importance:
//   1. a shader lens per surface costs a full offscreen pass + shader warmup,
//      which conflicts with the 60/120 FPS and "no shader compilation stutter"
//      requirements on mid-range Android devices,
//   2. every `BackdropFilter` here joins one shared backdrop group, so the
//      whole app pays for (at most) one blur pass per frame,
//   3. no new dependency, no bundled `.frag` assets, no APK growth.
//
// Everything is const-friendly and repaint-isolated.

/// Global kill switch + tuning knobs for the glass layer.
///
/// These are compile-time-ish constants on purpose: the glass layer is a look,
/// not a user-facing feature, so it deliberately adds no new settings entry.
abstract final class NamidaGlassConfig {
  const NamidaGlassConfig._();

  /// Master switch. Setting this to `false` makes every glass surface fall
  /// back to a plain, opaque-tinted surface with zero blur passes.
  static const enabled = true;

  /// Multiplies every blur sigma. Kept low: readability beats spectacle.
  static const blurScale = 1.0;

  /// Standard motion for glass highlights/pills — Material 3 easing, short.
  static const motionDuration = Duration(milliseconds: 320);
  static const motionCurve = Curves.easeOutCubic;

  /// Rim thickness. Sub-pixel on purpose so it reads as a light edge, not a
  /// border.
  static const rimWidth = 0.8;
}

/// How deep a surface sits in the glass stack. Higher levels blur more and
/// tint more, so a dialog over a sheet over the app still reads as layered.
enum NamidaGlassLevel {
  /// Chips, small buttons, list overlays.
  subtle,

  /// App bars, nav bars, cards — the default "chrome" glass.
  surface,

  /// Bottom sheets, side sheets, menus.
  elevated,

  /// Dialogs, snackbars — the topmost layer.
  overlay,
}

extension NamidaGlassLevelUtils on NamidaGlassLevel {
  /// Backdrop blur sigma for this level.
  double get blur {
    switch (this) {
      case NamidaGlassLevel.subtle:
        return 6.0 * NamidaGlassConfig.blurScale;
      case NamidaGlassLevel.surface:
        return 10.0 * NamidaGlassConfig.blurScale;
      case NamidaGlassLevel.elevated:
        return 14.0 * NamidaGlassConfig.blurScale;
      case NamidaGlassLevel.overlay:
        return 18.0 * NamidaGlassConfig.blurScale;
    }
  }

  /// How opaque the tint is. Deeper layers are denser so text stays readable
  /// no matter how busy the artwork behind them is.
  double get tintOpacity {
    switch (this) {
      case NamidaGlassLevel.subtle:
        return 0.30;
      case NamidaGlassLevel.surface:
        return 0.52;
      case NamidaGlassLevel.elevated:
        return 0.68;
      case NamidaGlassLevel.overlay:
        return 0.80;
    }
  }
}

/// Resolved glass colors for the current theme.
///
/// Exposed as a [ThemeExtension] so it is rebuilt exactly when Namida rebuilds
/// its theme (accent color change, light/dark switch, AMOLED toggle) and read
/// for free from any [BuildContext] — no globals, no extra listeners.
@immutable
class NamidaGlassTheme extends ThemeExtension<NamidaGlassTheme> {
  /// The opaque color a glass surface is tinted towards.
  final Color base;

  /// Warm/cool light that lands on the top-leading edge of a surface.
  final Color highlight;

  /// The thin lit edge drawn around a surface.
  final Color rim;

  /// Ambient occlusion under a surface — soft, never a hard drop shadow.
  final Color shade;

  /// Extra tint density for AMOLED, where transparency reads as grey haze.
  final double densityBoost;

  const NamidaGlassTheme({
    required this.base,
    required this.highlight,
    required this.rim,
    required this.shade,
    this.densityBoost = 0.0,
  });

  /// Derives the glass palette from Namida's own theme inputs, so glass always
  /// inherits the active accent color, brightness and AMOLED preference.
  factory NamidaGlassTheme.fromColors({
    required Color accent,
    required bool light,
    required bool pitchBlack,
  }) {
    if (light) {
      return NamidaGlassTheme(
        base: Color.alphaBlend(accent.withAlpha(28), const Color(0xFFFFFFFF)),
        highlight: const Color(0xFFFFFFFF).withOpacityExt(0.55),
        rim: const Color(0xFFFFFFFF).withOpacityExt(0.65),
        shade: const Color(0xFF404040).withOpacityExt(0.10),
      );
    }
    if (pitchBlack) {
      // AMOLED: keep it near-black, let the rim do the work.
      return NamidaGlassTheme(
        base: Color.alphaBlend(accent.withAlpha(10), const Color(0xFF000000)),
        highlight: const Color(0xFFFFFFFF).withOpacityExt(0.06),
        rim: const Color(0xFFFFFFFF).withOpacityExt(0.14),
        shade: const Color(0xFF000000).withOpacityExt(0.45),
        densityBoost: 0.12,
      );
    }
    return NamidaGlassTheme(
      base: Color.alphaBlend(accent.withAlpha(26), const Color(0xFF121212)),
      highlight: const Color(0xFFFFFFFF).withOpacityExt(0.12),
      rim: const Color(0xFFFFFFFF).withOpacityExt(0.18),
      shade: const Color(0xFF000000).withOpacityExt(0.30),
    );
  }

  /// Never-null lookup: falls back to a palette derived from the ambient
  /// [ThemeData] so a glass widget can be dropped anywhere, including inside
  /// isolated `Theme(...)` subtrees that don't carry the extension.
  static NamidaGlassTheme of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NamidaGlassTheme>() ?? resolveFrom(theme);
  }

  /// Best-effort palette for an arbitrary [ThemeData].
  static NamidaGlassTheme resolveFrom(ThemeData theme) {
    final light = theme.brightness == Brightness.light;
    final scaffold = theme.scaffoldBackgroundColor;
    final pitchBlack = !light && scaffold.r + scaffold.g + scaffold.b < 0.06;
    return NamidaGlassTheme.fromColors(
      accent: theme.colorScheme.primary,
      light: light,
      pitchBlack: pitchBlack,
    );
  }

  /// The tint fill for [level], optionally overriding the base color.
  Color tint(NamidaGlassLevel level, {Color? color, double multiplier = 1.0}) {
    final opacity = (level.tintOpacity + densityBoost) * multiplier;
    return (color ?? base).withOpacityExt(opacity.clampDouble(0.0, 1.0));
  }

  @override
  NamidaGlassTheme copyWith({
    Color? base,
    Color? highlight,
    Color? rim,
    Color? shade,
    double? densityBoost,
  }) {
    return NamidaGlassTheme(
      base: base ?? this.base,
      highlight: highlight ?? this.highlight,
      rim: rim ?? this.rim,
      shade: shade ?? this.shade,
      densityBoost: densityBoost ?? this.densityBoost,
    );
  }

  @override
  NamidaGlassTheme lerp(covariant NamidaGlassTheme? other, double t) {
    if (other == null) return this;
    return NamidaGlassTheme(
      base: Color.lerp(base, other.base, t) ?? base,
      highlight: Color.lerp(highlight, other.highlight, t) ?? highlight,
      rim: Color.lerp(rim, other.rim, t) ?? rim,
      shade: Color.lerp(shade, other.shade, t) ?? shade,
      densityBoost: lerpDouble(densityBoost, other.densityBoost, t) ?? densityBoost,
    );
  }
}

/// The one and only frosted-glass surface in the app.
///
/// Renders, cheaply and in this order:
///   1. a single grouped [BackdropFilter] blurring whatever is behind,
///   2. one gradient fill that carries both the tint *and* the light
///      diffusion (no second overlay layer, no extra `saveLayer`),
///   3. a hairline rim,
///   4. optional soft depth shadows drawn outside the clip.
///
/// Wrap any existing widget with it; it never changes layout, hit-testing or
/// child semantics.
class NamidaGlass extends StatelessWidget {
  final Widget child;

  /// Depth of the surface — drives blur strength and tint density.
  final NamidaGlassLevel level;

  /// Corner rounding. Ignored when [shape] is [BoxShape.circle].
  final BorderRadius? borderRadius;

  final BoxShape shape;

  /// Set to `false` to render the plain fallback surface (no blur pass).
  final bool enabled;

  /// Overrides the tinted-towards color (defaults to the theme's glass base).
  final Color? color;

  /// Scales the tint density, e.g. `1.15` for surfaces that sit over artwork.
  final double opacityMultiplier;

  /// Draws the lit edge.
  final bool rim;

  /// Draws soft depth shadows behind the surface.
  final bool shadow;

  /// Where the light comes from. Drives the gradient + rim asymmetry.
  final AlignmentGeometry lightSource;

  final Clip clipBehavior;

  const NamidaGlass({
    super.key,
    required this.child,
    this.level = NamidaGlassLevel.surface,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
    this.enabled = true,
    this.color,
    this.opacityMultiplier = 1.0,
    this.rim = true,
    this.shadow = false,
    this.lightSource = Alignment.topLeft,
    this.clipBehavior = Clip.antiAlias,
  });

  /// Fully rounded capsule variant — nav pills, chips, floating controls.
  const NamidaGlass.pill({
    super.key,
    required this.child,
    this.level = NamidaGlassLevel.subtle,
    this.enabled = true,
    this.color,
    this.opacityMultiplier = 1.0,
    this.rim = true,
    this.shadow = false,
    this.lightSource = Alignment.topLeft,
    this.clipBehavior = Clip.antiAlias,
  }) : borderRadius = const BorderRadius.all(Radius.circular(999.0)),
       shape = BoxShape.rectangle;

  /// One shared backdrop group for the entire app: sibling/stacked glass
  /// surfaces reuse the same blurred backdrop texture instead of each
  /// triggering their own read-back.
  static final _backdropGroupKey = BackdropKey();

  BoxDecoration _buildDecoration(NamidaGlassTheme glass) {
    final tint = glass.tint(level, color: color, multiplier: opacityMultiplier);
    return BoxDecoration(
      shape: shape,
      borderRadius: shape == BoxShape.circle ? null : borderRadius,
      // A single 3-stop gradient does the job of a tint layer *and* a light
      // diffusion layer, halving the number of painted layers.
      gradient: LinearGradient(
        begin: lightSource,
        end: -(lightSource.resolve(TextDirection.ltr)),
        colors: [
          Color.alphaBlend(glass.highlight, tint),
          tint,
          tint.withOpacityExt((tint.a * 0.92).clampDouble(0.0, 1.0)),
        ],
        stops: const [0.0, 0.55, 1.0],
      ),
      border: rim ? Border.all(color: glass.rim, width: NamidaGlassConfig.rimWidth) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final glass = NamidaGlassTheme.of(context);
    final decoration = _buildDecoration(glass);
    final isCircle = shape == BoxShape.circle;

    if (!enabled || !NamidaGlassConfig.enabled) {
      // Fallback: same silhouette, fully opaque, zero blur passes.
      return DecoratedBox(
        decoration: decoration.copyWith(
          gradient: null,
          color: Color.alphaBlend(
            glass.tint(level, color: color, multiplier: opacityMultiplier),
            glass.base,
          ),
        ),
        child: child,
      );
    }

    Widget surface = BackdropFilter(
      backdropGroupKey: _backdropGroupKey,
      filter: ImageFilter.blur(sigmaX: level.blur, sigmaY: level.blur, tileMode: TileMode.clamp),
      child: DecoratedBox(
        decoration: decoration,
        child: child,
      ),
    );

    surface = isCircle
        ? ClipOval(clipBehavior: clipBehavior, child: surface)
        : ClipRRect(
            clipBehavior: clipBehavior,
            borderRadius: borderRadius ?? BorderRadius.zero,
            child: surface,
          );

    // Isolate the blur so unrelated repaints upstream don't re-run it.
    surface = RepaintBoundary(child: surface);

    if (shadow) {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          shape: shape,
          borderRadius: isCircle ? null : borderRadius,
          boxShadow: [
            BoxShadow(color: glass.shade, blurRadius: 18.0, offset: const Offset(0, 6)),
          ],
        ),
        child: surface,
      );
    }

    return surface;
  }
}

/// A glass highlight that fades in/out between selection states.
///
/// Used for selection affordances (nav bar indicator, segmented tabs). It only
/// animates transform-ish and opacity properties, never blur sigma, so the
/// backdrop pass is untouched frame-to-frame.
class NamidaGlassHighlight extends StatelessWidget {
  final Widget? child;
  final bool visible;
  final Color? color;
  final BorderRadius borderRadius;

  const NamidaGlassHighlight({
    super.key,
    this.child,
    this.visible = true,
    this.color,
    this.borderRadius = const BorderRadius.all(Radius.circular(999.0)),
  });

  @override
  Widget build(BuildContext context) {
    final glass = NamidaGlassTheme.of(context);
    return AnimatedOpacity(
      duration: NamidaGlassConfig.motionDuration,
      curve: NamidaGlassConfig.motionCurve,
      opacity: visible ? 1.0 : 0.0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          color: color ?? glass.rim.withOpacityExt(0.15),
          border: Border.all(color: glass.rim, width: NamidaGlassConfig.rimWidth),
        ),
        child: child,
      ),
    );
  }
}
