import 'package:flutter/widgets.dart';

/// Tokens de espaciado, radios y duraciones.
///
/// Una grilla de 4pt mantiene el ritmo vertical consistente en todas las
/// pantallas y facilita el diseño responsivo entre 1366x768 y 4K.
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 48;

  /// Padding estándar de tarjetas y paneles.
  static const EdgeInsets cardPadding = EdgeInsets.all(md + 2);

  /// Padding de pantalla completa.
  static const EdgeInsets screenPadding = EdgeInsets.all(lg);

  /// Alto de controles de escritorio (más compactos que en móvil).
  static const double controlHeight = 38;
  static const double controlHeightLarge = 48;
  static const double toolbarHeight = 56;
  static const double statusBarHeight = 30;
  static const double titleBarHeight = 40;
  static const double sidebarWidth = 216;
  static const double sidebarWidthCompact = 76;

  /// Ancho mínimo/máximo de columnas del carrito y del panel de totales.
  static const double cartPanelMinWidth = 420;
  static const double totalsPanelWidth = 320;
}

/// Radios de esquina (8-12 según la guía visual; 16 solo en tarjetas grandes).
abstract final class AppRadius {
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 10;
  static const double lg = 12;
  static const double xl = 16;
  static const double pill = 999;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// Duraciones de animación. En un POS las transiciones deben ser rápidas:
/// el cajero no espera animaciones.
abstract final class AppDurations {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 350);

  /// Intervalo del "debounce" del buscador de productos.
  static const Duration searchDebounce = Duration(milliseconds: 180);

  /// Refresco del reloj de la barra de estado.
  static const Duration clockTick = Duration(seconds: 1);

  /// Latido del motor de sincronización.
  static const Duration syncHeartbeat = Duration(seconds: 30);
}
