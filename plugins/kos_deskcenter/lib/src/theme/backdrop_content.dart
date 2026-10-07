import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/painting.dart';

/// NextKde glassInk follows the surface material, independently of light mode.
/// Only desktop card content uses these roles; opaque panels keep shell colors.
bool usesBackdropInk(ShellThemeData theme) =>
    theme.backdropBlurEnabled && theme.effectiveCardOpacity < 1;

Color backdropInk(ShellThemeData theme) =>
    usesBackdropInk(theme) ? const Color(0xFFFFFFFF) : theme.colors.textPrimary;

Color backdropSecondaryInk(ShellThemeData theme) => usesBackdropInk(theme)
    ? const Color(0xBDFFFFFF)
    : theme.colors.textSecondary;

Color backdropHairline(ShellThemeData theme) => usesBackdropInk(theme)
    ? const Color(0x1FFFFFFF)
    : theme.colors.hairlineSoft;

/// Detail panels use semantic shell ink even when the desktop uses glass ink.
ShellThemeData panelContentTheme(ShellThemeData theme) =>
    theme.copyWith(transparencyMode: ShellTransparencyMode.off);
