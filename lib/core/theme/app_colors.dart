import 'package:flutter/material.dart';

/// Paleta oficial de UltraPOS.
///
/// Origen: identidad visual del logo (azul profundo + cian + naranja de acción).
/// Regla de uso:
///   * [deepBlue]  -> navegación, headers, texto principal, marca.
///   * [cyan]      -> acento: acciones secundarias, iconos activos, gráficos.
///   * [orange]    -> venta: botón "COBRAR", totales, alertas de stock bajo.
///   * [surface]   -> fondos de pantalla, tarjetas y modales.
///   * [red]       -> errores, anulaciones, diferencias de caja.
abstract final class AppColors {
  // --- Marca (valores exactos solicitados) ---------------------------------
  static const Color deepBlue = Color(0xFF0A2A4A);
  static const Color cyan = Color(0xFF00AEEF);
  static const Color orange = Color(0xFFFF6B00);
  static const Color surface = Color(0xFFF5F7FA);
  static const Color red = Color(0xFFE53935);

  // --- Derivados de la marca (escala tonal) --------------------------------
  static const Color deepBlueDark = Color(0xFF061C33);
  static const Color deepBlue800 = Color(0xFF0E3560);
  static const Color deepBlue600 = Color(0xFF14477C);
  static const Color deepBlue100 = Color(0xFFE3EAF3);

  static const Color cyanDark = Color(0xFF0086B8);
  static const Color cyanLight = Color(0xFF5FD0F7);
  static const Color cyanSurface = Color(0xFFE5F7FD);

  static const Color orangeDark = Color(0xFFCC5500);
  static const Color orangeLight = Color(0xFFFFF0E5);
  static const Color orangeSurface = Color(0xFFFFF6EF);

  static const Color redDark = Color(0xFFB3211E);
  static const Color redSurface = Color(0xFFFDECEA);

  // --- Semánticos adicionales (estados del sistema) ------------------------
  static const Color success = Color(0xFF2E7D32);
  static const Color successSurface = Color(0xFFE8F5E9);
  static const Color warning = Color(0xFFF9A825);
  static const Color warningSurface = Color(0xFFFFF8E1);

  // --- Neutros --------------------------------------------------------------
  static const Color white = Color(0xFFFFFFFF);

  // Tonos de blanco sobre el azul profundo de la navegación. Se definen aquí
  // (y no se usan los de Material) para que el contraste sea el elegido por
  // diseño y no cambie entre versiones del SDK.
  static const Color white90 = Color(0xE6FFFFFF);
  static const Color white70 = Color(0xB3FFFFFF);
  static const Color white54 = Color(0x8AFFFFFF);
  static const Color white38 = Color(0x61FFFFFF);
  static const Color white24 = Color(0x3DFFFFFF);
  static const Color white12 = Color(0x1FFFFFFF);
  static const Color grey50 = Color(0xFFF8FAFC);
  static const Color grey100 = Color(0xFFEEF2F6);
  static const Color grey200 = Color(0xFFE1E7EF);
  static const Color grey300 = Color(0xFFCBD5E1);
  static const Color grey400 = Color(0xFF94A3B8);
  static const Color grey500 = Color(0xFF64748B);
  static const Color grey600 = Color(0xFF475569);
  static const Color grey700 = Color(0xFF334155);
  static const Color grey900 = Color(0xFF1E293B);

  // --- Alias semánticos usados por el ThemeData ----------------------------
  static const Color background = surface;
  static const Color card = white;
  static const Color border = grey200;
  static const Color textPrimary = deepBlue;
  static const Color textSecondary = grey600;
  static const Color textHint = grey400;
  static const Color divider = grey200;
  static const Color disabled = grey300;

  /// Sombra sutil estándar de tarjetas (elevación "nativa", no dramática).
  static const List<BoxShadow> cardShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x140A2A4A),
      blurRadius: 12,
      offset: Offset(0, 2),
    ),
  ];

  /// Sombra del botón principal (COBRAR) para darle jerarquía visual.
  static const List<BoxShadow> accentShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x40FF6B00),
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  ];

  /// Degradado de cabecera (barra de título y encabezados de módulo).
  static const LinearGradient headerGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: <Color>[deepBlue, deepBlue600],
  );

  /// Degradado de la tarjeta de totales (foco de venta).
  static const LinearGradient totalGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[deepBlue, deepBlue800],
  );

  /// Color de acento por estado de sincronización.
  static Color forSyncState(bool online, int pendingCount) {
    if (!online) return warning;
    if (pendingCount > 0) return orange;
    return success;
  }
}
