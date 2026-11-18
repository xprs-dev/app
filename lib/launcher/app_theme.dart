// The app's theme: plain black and white.
//
// Material 3 derives every accent from a seed colour, and any seed gives the
// lavender/periwinkle tints the person did not want on switches, tabs, section
// titles and buttons. This scheme is written out by hand instead: white is the
// accent, greys are the containers, and the only colours left are the ones
// that MEAN something (error red, the app tiles' own swatches, status chips).
//
// The background is true black, not M3's dark surface: the launcher is mostly
// full-bleed imagery over empty space, and on OLED the empty space should cost
// nothing to light. `surface` stays a hair above black so cards, the all-apps
// sheet and the module bars still read as lifted rather than dissolving into
// the background.
import 'package:flutter/material.dart';

/// The scheme, public so charts and painters take their inks from it rather
/// than inventing their own greys.
const ColorScheme xprsMonochrome = ColorScheme(
  brightness: Brightness.dark,
  primary: Colors.white,
  onPrimary: Colors.black,
  primaryContainer: Color(0xFF2C2C2C),
  onPrimaryContainer: Colors.white,
  secondary: Color(0xFFBDBDBD),
  onSecondary: Colors.black,
  secondaryContainer: Color(0xFF262626),
  onSecondaryContainer: Colors.white,
  tertiary: Color(0xFFE0E0E0),
  onTertiary: Colors.black,
  tertiaryContainer: Color(0xFF333333),
  onTertiaryContainer: Colors.white,
  error: Color(0xFFFF6B6B),
  onError: Colors.black,
  errorContainer: Color(0xFF5C1A1A),
  onErrorContainer: Color(0xFFFFDAD6),
  surface: Color(0xFF0C0C0C),
  onSurface: Colors.white,
  surfaceDim: Color(0xFF0C0C0C),
  surfaceBright: Color(0xFF2E2E2E),
  surfaceContainerLowest: Colors.black,
  surfaceContainerLow: Color(0xFF141414),
  surfaceContainer: Color(0xFF1A1A1A),
  surfaceContainerHigh: Color(0xFF222222),
  surfaceContainerHighest: Color(0xFF2B2B2B),
  onSurfaceVariant: Color(0xFFB0B0B0),
  outline: Color(0xFF6E6E6E),
  outlineVariant: Color(0xFF3A3A3A),
  shadow: Colors.black,
  scrim: Colors.black,
  inverseSurface: Color(0xFFEDEDED),
  onInverseSurface: Colors.black,
  inversePrimary: Colors.black,
  surfaceTint: Colors.transparent,
);

ThemeData xprsTheme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: xprsMonochrome,
      scaffoldBackgroundColor: Colors.black,
      canvasColor: Colors.black,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      // A white thumb on a white track disappears; the "on" switch is a black
      // thumb on white, the "off" one a grey thumb on a dark track.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? Colors.black
                : const Color(0xFF8A8A8A)),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? Colors.white
                : const Color(0xFF262626)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: Colors.white,
        linearTrackColor: Color(0xFF2B2B2B),
      ),
    );
