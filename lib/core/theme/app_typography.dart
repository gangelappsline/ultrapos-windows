import 'package:flutter/material.dart';

/// Tipografía de UltraPOS.
///
/// Estrategia: **la app siempre compila**. La familia "Inter" se usa si está
/// empaquetada (ver pubspec.yaml, bloque `fonts` comentado) o instalada en el
/// sistema; en su defecto cae a "Segoe UI Variable Text" / "Segoe UI", la
/// fuente nativa de Windows 11/10, lo que refuerza la sensación de app nativa.
///
/// Escala pensada para escritorio (mínimo 1366x768) con densidad de información
/// alta pero legible a 60-80 cm de distancia.
abstract final class AppTypography {
  static const String fontFamily = 'Inter';

  static const List<String> fallback = <String>[
    'Segoe UI Variable Text',
    'Segoe UI',
    'Roboto',
    'Helvetica Neue',
    'Arial',
  ];

  static const List<String> numericFallback = <String>[
    'Inter',
    'Segoe UI Variable Text',
    'Segoe UI',
  ];

  /// Cifras tabulares: todos los dígitos ocupan el mismo ancho.
  ///
  /// Se aplica en columnas de dinero, cantidades y contadores. Sin esto, un
  /// `1` es más angosto que un `8` y las columnas de importes "bailan" al
  /// recorrer la lista, que es exactamente lo que delata a una app no nativa.
  static const List<FontFeature> tabularFigures = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// Título de la barra de ventana.
  static const TextStyle appBarTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    fontFamilyFallback: fallback,
  );

  /// Números grandes del dashboard (KPIs) y total a cobrar.
  static const TextStyle display = TextStyle(
    fontSize: 32,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    fontFamilyFallback: numericFallback,
  );

  static const TextStyle headline = TextStyle(
    fontSize: 24,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    fontFamilyFallback: fallback,
  );

  /// Encabezado de sección / módulo.
  static const TextStyle title = TextStyle(
    fontSize: 18,
    height: 1.25,
    fontWeight: FontWeight.w600,
    fontFamilyFallback: fallback,
  );

  static const TextStyle subtitle = TextStyle(
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w600,
    fontFamilyFallback: fallback,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w400,
    fontFamilyFallback: fallback,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w600,
    fontFamilyFallback: fallback,
  );

  /// Filas de tablas y listas densas (carrito, inventario).
  static const TextStyle table = TextStyle(
    fontSize: 13.5,
    height: 1.35,
    fontWeight: FontWeight.w400,
    fontFamilyFallback: fallback,
  );

  static const TextStyle tableStrong = TextStyle(
    fontSize: 13.5,
    height: 1.35,
    fontWeight: FontWeight.w600,
    fontFamilyFallback: fallback,
  );

  /// Botones.
  static const TextStyle button = TextStyle(
    fontSize: 14.5,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    fontFamilyFallback: fallback,
  );

  /// Botón COBRAR (jerarquía máxima).
  static const TextStyle buttonLarge = TextStyle(
    fontSize: 18,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
    fontFamilyFallback: fallback,
  );

  /// Etiquetas de campo, chips y ayudas.
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
    fontFamilyFallback: fallback,
  );

  static const TextStyle label = TextStyle(
    fontSize: 11.5,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    fontFamilyFallback: fallback,
  );

  /// Códigos de barras / SKU (monoespaciado para alineación).
  static const TextStyle monospace = TextStyle(
    fontSize: 13,
    height: 1.3,
    fontFamily: 'Consolas',
    fontFamilyFallback: <String>['Cascadia Mono', 'Courier New', 'monospace'],
  );

  /// Texto de atajos de teclado (barra de estado inferior).
  static const TextStyle shortcut = TextStyle(
    fontSize: 11.5,
    height: 1.2,
    fontWeight: FontWeight.w600,
    fontFamilyFallback: fallback,
  );
}
