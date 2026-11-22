import 'package:flutter/material.dart';

/// Colors used across the app, after an electrical panel shop: steel greys for surfaces, one hazard yellow for the
/// action that matters on a screen, and status colors (green live, amber warning, red fault) kept for their meaning.
class Tokens extends ThemeExtension<Tokens> {
  const Tokens({
    required this.canvas,
    required this.gridDot,
    required this.panel,
    required this.border,
    required this.text,
    required this.textMuted,
    required this.accent,
    required this.accentSoft,
    required this.hazard,
    required this.onHazard,
    required this.plate,
    required this.onPlate,
    required this.run,
    required this.warning,
    required this.error,
    required this.deadWire,
    required this.hover,
  });

  final Color canvas;
  final Color gridDot;
  final Color panel;
  final Color border;
  final Color text;
  final Color textMuted;

  /// The accent as text, outline, selection and focus ring: burnt orange on light steel, hazard yellow on dark.
  final Color accent;
  final Color accentSoft;

  /// Hazard yellow fill for the one primary action of a screen, with dark ink on it.
  final Color hazard;
  final Color onHazard;

  /// Engraved nameplate: the dark plate behind screen titles and the app name.
  final Color plate;
  final Color onPlate;

  final Color run;
  final Color warning;
  final Color error;
  final Color deadWire;
  final Color hover;

  static const light = Tokens(
    canvas: Color(0xFFE9EBEC),
    gridDot: Color(0xFFCBD0D4),
    panel: Color(0xFFF7F8F8),
    border: Color(0xFFC3C9CD),
    text: Color(0xFF15191C),
    textMuted: Color(0xFF4F575E),
    accent: Color(0xFFA04A00),
    accentSoft: Color(0xFFF8EAD2),
    hazard: Color(0xFFF2A900),
    onHazard: Color(0xFF15191C),
    plate: Color(0xFF2B3035),
    onPlate: Color(0xFFE9EBEC),
    run: Color(0xFF1B7A4B),
    warning: Color(0xFF8A5A00),
    error: Color(0xFFB3261E),
    deadWire: Color(0xFF9AA2A9),
    hover: Color(0xFFE2E5E7),
  );

  static const dark = Tokens(
    canvas: Color(0xFF111315),
    gridDot: Color(0xFF282D31),
    panel: Color(0xFF1A1D20),
    border: Color(0xFF30353A),
    text: Color(0xFFE5E7E9),
    textMuted: Color(0xFF9AA2A9),
    accent: Color(0xFFF2A900),
    accentSoft: Color(0xFF33290F),
    hazard: Color(0xFFF2A900),
    onHazard: Color(0xFF15191C),
    plate: Color(0xFF2B3035),
    onPlate: Color(0xFFE5E7E9),
    run: Color(0xFF5CC48E),
    warning: Color(0xFFE5B04F),
    error: Color(0xFFF2857D),
    deadWire: Color(0xFF68717A),
    hover: Color(0xFF24282C),
  );

  @override
  Tokens copyWith() => this;

  @override
  Tokens lerp(ThemeExtension<Tokens>? other, double t) => t < 0.5 || other is! Tokens ? this : other;
}

/// Corner radii. Panel parts are square-edged, so labels and plates stay nearly sharp and only dialogs soften.
abstract final class Radii {
  /// Nameplates, tags, chips and small labels.
  static const double plate = 2;

  /// Buttons, inputs, list rows and cards.
  static const double control = 4;

  /// Dialogs and floating panels.
  static const double dialog = 8;
}

extension TokensContext on BuildContext {
  Tokens get tokens => Theme.of(this).extension<Tokens>()!;
}

/// Inter ships as a variable font, so weight is set through the `wght` axis. Chosen for running text and controls:
/// it stays legible at 11-13 px in dense panels.
TextStyle uiText(double size, Color color, {int weight = 400, double? height}) => TextStyle(
      fontFamily: 'Inter',
      fontSize: size,
      color: color,
      height: height,
      fontWeight: FontWeight.values[(weight ~/ 100) - 1],
      fontVariations: [FontVariation('wght', weight.toDouble())],
    );

/// Barlow Condensed for nameplates, device tags and screen titles: condensed DIN-like lettering, the way names are
/// printed on panel parts and wire markers. 600 or 700 only.
TextStyle plateText(double size, Color color, {int weight = 600, double? height}) => TextStyle(
      fontFamily: 'Barlow Condensed',
      fontSize: size,
      color: color,
      height: height,
      fontWeight: weight >= 700 ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: 0.2,
    );

/// A nameplate: light lettering on a dark steel plate, used for screen titles and the app name.
class Nameplate extends StatelessWidget {
  const Nameplate(this.text, {super.key, this.size = 15});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: size * 0.5, vertical: size * 0.12),
      decoration: BoxDecoration(color: tokens.plate, borderRadius: BorderRadius.circular(Radii.plate)),
      child: Text(text, style: plateText(size, tokens.onPlate, weight: 700, height: 1.2)),
    );
  }
}

ThemeData buildTheme(bool dark) {
  final tokens = dark ? Tokens.dark : Tokens.light;
  final focusRing = BorderSide(color: tokens.accent, width: 2);
  final control = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control));
  return ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: tokens.canvas,
    colorScheme: ColorScheme.fromSeed(
      seedColor: tokens.hazard,
      brightness: dark ? Brightness.dark : Brightness.light,
      primary: tokens.accent,
      onPrimary: dark ? tokens.onHazard : Colors.white,
      surface: tokens.panel,
      onSurface: tokens.text,
      onSurfaceVariant: tokens.textMuted,
      outline: tokens.border,
      error: tokens.error,
    ),
    extensions: [tokens],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    // A visible tint on whatever has keyboard focus (R-32), on top of the focus outlines set per button below.
    focusColor: tokens.accent.withValues(alpha: 0.22),
    hoverColor: tokens.hover,
    dividerColor: tokens.border,
    visualDensity: VisualDensity.compact,
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? tokens.border : tokens.hazard),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? tokens.textMuted : tokens.onHazard),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? tokens.textMuted : tokens.onHazard),
        overlayColor: WidgetStatePropertyAll(tokens.onHazard.withValues(alpha: 0.08)),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? BorderSide(color: tokens.text, width: 2) : null),
        shape: WidgetStatePropertyAll(control),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
        textStyle: WidgetStatePropertyAll(uiText(13, tokens.onHazard, weight: 650)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? tokens.textMuted.withValues(alpha: 0.6) : tokens.text),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? tokens.textMuted.withValues(alpha: 0.6) : tokens.text),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? focusRing : BorderSide(color: tokens.border)),
        shape: WidgetStatePropertyAll(control),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(tokens.accent),
        shape: WidgetStatePropertyAll(control),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? focusRing : null),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(control),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? focusRing : null),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.plate)),
      selectedColor: tokens.accentSoft,
      side: BorderSide(color: tokens.border),
      labelStyle: uiText(12.5, tokens.text),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
    ),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.plate))),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      textStyle: uiText(12, tokens.onPlate),
      decoration: BoxDecoration(color: tokens.plate, borderRadius: BorderRadius.circular(Radii.plate)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      hintStyle: uiText(13, tokens.textMuted),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.control),
        borderSide: BorderSide(color: tokens.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.control),
        borderSide: BorderSide(color: tokens.accent, width: 2),
      ),
    ),
  );
}
