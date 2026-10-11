import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/app_database.dart';

/// Tipo de impresora configurada.
enum PrinterType {
  /// Impresora instalada en Windows (se envía RAW por el spooler).
  windowsSpool('windows_spool', 'Impresora de Windows'),
  /// Impresora de red ESC/POS (socket 9100).
  network('network', 'Impresora de red (IP)'),
  /// Impresora conectada a un puerto serie (COM).
  serial('serial', 'Puerto serie (COM)'),
  /// Sin impresora: el ticket se genera en PDF.
  pdf('pdf', 'Solo PDF (sin impresora)'),
  none('none', 'Sin impresora');

  const PrinterType(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static PrinterType fromStorage(String? key) => PrinterType.values.firstWhere(
        (PrinterType type) => type.storageKey == key,
        orElse: () => PrinterType.none,
      );
}

/// Ancho de papel soportado.
enum PaperWidth {
  mm58('58', 58, 32),
  mm80('80', 80, 48);

  const PaperWidth(this.storageKey, this.millimeters, this.charsPerLine);

  final String storageKey;
  final int millimeters;

  /// Caracteres por línea en la fuente A (la usada por defecto).
  ///
  /// El ancho útil real de la mayoría de cabezales es 48 mm (58 mm) y 72 mm
  /// (80 mm): imprimir más caracteres provoca cortes de línea en el ticket.
  final int charsPerLine;

  static PaperWidth fromStorage(String? key) => PaperWidth.values.firstWhere(
        (PaperWidth width) => width.storageKey == key,
        orElse: () => PaperWidth.mm80,
      );
}

/// Modo de apertura del cajón de dinero.
enum DrawerType {
  /// El cajón cuelga de la impresora (RJ11): se abre con el comando ESC/POS.
  printer('printer', 'Conectado a la impresora'),
  /// El cajón está conectado a un puerto serie propio.
  serial('serial', 'Puerto serie (COM)'),
  /// No hay cajón (solo para demos y pruebas).
  none('none', 'Sin cajón');

  const DrawerType(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static DrawerType fromStorage(String? key) => DrawerType.values.firstWhere(
        (DrawerType type) => type.storageKey == key,
        orElse: () => DrawerType.printer,
      );
}

/// Configuración de impresora/cajón leída de `app_settings`.
@immutable
class PrinterConfig {
  const PrinterConfig({
    required this.type,
    this.windowsPrinterName,
    this.networkHost,
    this.networkPort = 9100,
    this.comPort,
    this.comBaudRate = 9600,
    this.paperWidth = PaperWidth.mm80,
    this.charset = 'CP850',
    this.printAutomatically = true,
    this.printCopies = 1,
    this.drawer = DrawerType.printer,
    this.drawerComPort,
    this.openDrawerOnCashPayment = true,
    this.autoCut = true,
    this.headerLines = 0,
  });

  static const PrinterConfig none = PrinterConfig(type: PrinterType.none);

  final PrinterType type;
  final String? windowsPrinterName;
  final String? networkHost;
  final int networkPort;
  final String? comPort;
  final int comBaudRate;
  final PaperWidth paperWidth;

  /// Juego de caracteres (afecta a tildes y a la letra ñ).
  final String charset;

  final bool printAutomatically;
  final int printCopies;
  final DrawerType drawer;
  final String? drawerComPort;
  final bool openDrawerOnCashPayment;
  final bool autoCut;

  /// Líneas en blanco antes del encabezado (según la instalación del rollo).
  final int headerLines;

  bool get isUsable => type != PrinterType.none;

  /// Destino legible para la interfaz ("HP LaserJet", "192.168.1.50:9100", "COM3").
  String get destinationLabel => switch (type) {
        PrinterType.windowsSpool => windowsPrinterName ?? '(predeterminada)',
        PrinterType.network => networkHost == null ? '—' : '$networkHost:$networkPort',
        PrinterType.serial => comPort ?? '—',
        PrinterType.pdf => 'PDF',
        PrinterType.none => 'Sin impresora',
      };

  /// Máximo de caracteres por línea, con una columna de margen de seguridad.
  int get charsPerLine => paperWidth.charsPerLine;

  bool get opensDrawerWithPrinter =>
      drawer == DrawerType.printer && type != PrinterType.none && type != PrinterType.pdf;

  bool get opensDrawerWithSerial =>
      drawer == DrawerType.serial && (drawerComPort ?? '').isNotEmpty;

  PrinterConfig copyWith({
    PrinterType? type,
    String? windowsPrinterName,
    String? networkHost,
    int? networkPort,
    String? comPort,
    int? comBaudRate,
    PaperWidth? paperWidth,
    String? charset,
    bool? printAutomatically,
    int? printCopies,
    DrawerType? drawer,
    String? drawerComPort,
    bool? openDrawerOnCashPayment,
    bool? autoCut,
    int? headerLines,
  }) =>
      PrinterConfig(
        type: type ?? this.type,
        windowsPrinterName: windowsPrinterName ?? this.windowsPrinterName,
        networkHost: networkHost ?? this.networkHost,
        networkPort: networkPort ?? this.networkPort,
        comPort: comPort ?? this.comPort,
        comBaudRate: comBaudRate ?? this.comBaudRate,
        paperWidth: paperWidth ?? this.paperWidth,
        charset: charset ?? this.charset,
        printAutomatically: printAutomatically ?? this.printAutomatically,
        printCopies: printCopies ?? this.printCopies,
        drawer: drawer ?? this.drawer,
        drawerComPort: drawerComPort ?? this.drawerComPort,
        openDrawerOnCashPayment: openDrawerOnCashPayment ?? this.openDrawerOnCashPayment,
        autoCut: autoCut ?? this.autoCut,
        headerLines: headerLines ?? this.headerLines,
      );

  /// Claves de `app_settings` que se sincronizan **solo dentro del equipo**.
  ///
  /// La configuración de impresora es local por naturaleza: la caja 2 puede
  /// tener una impresora distinta de la caja 1. Se guarda con
  /// `syncToCloud: false` para no propagar hardware entre terminales.
  static const String _kType = 'printer.type';
  static const String _kName = 'printer.windows_name';
  static const String _kHost = 'printer.network_host';
  static const String _kPort = 'printer.network_port';
  static const String _kCom = 'printer.com_port';
  static const String _kBaud = 'printer.com_baud';
  static const String _kPaper = 'printer.paper_width';
  static const String _kCharset = 'printer.charset';
  static const String _kAuto = 'printer.auto_print';
  static const String _kCopies = 'printer.copies';
  static const String _kDrawer = 'drawer.type';
  static const String _kDrawerCom = 'drawer.com_port';
  static const String _kDrawerOpen = 'drawer.open_on_cash';

  /// Lee la configuración desde `app_settings`.
  static Future<PrinterConfig> load(AppDatabase database) async {
    final AppDatabase db = database;
    final dao = db.settingsDao;
    return PrinterConfig(
      type: PrinterType.fromStorage(await dao.rawValue(_kType)),
      windowsPrinterName: await dao.rawValue(_kName),
      networkHost: await dao.rawValue(_kHost),
      networkPort: int.tryParse(await dao.rawValue(_kPort) ?? '') ?? 9100,
      comPort: await dao.rawValue(_kCom),
      comBaudRate: int.tryParse(await dao.rawValue(_kBaud) ?? '') ?? 9600,
      paperWidth: PaperWidth.fromStorage(await dao.rawValue(_kPaper)),
      charset: await dao.rawValue(_kCharset) ?? 'CP850',
      printAutomatically: (await dao.rawValue(_kAuto)) != 'false',
      printCopies: int.tryParse(await dao.rawValue(_kCopies) ?? '') ?? 1,
      drawer: DrawerType.fromStorage(await dao.rawValue(_kDrawer)),
      drawerComPort: await dao.rawValue(_kDrawerCom),
      openDrawerOnCashPayment: (await dao.rawValue(_kDrawerOpen)) != 'false',
    );
  }

  /// Guarda la configuración en `app_settings` (local, sin sincronizar).
  Future<void> save(AppDatabase database) async {
    final dao = database.settingsDao;
    await dao.setValue(_kType, type.storageKey, syncToCloud: false);
    await dao.setValue(_kName, windowsPrinterName ?? '', syncToCloud: false);
    await dao.setValue(_kHost, networkHost ?? '', syncToCloud: false);
    await dao.setValue(_kPort, '$networkPort', syncToCloud: false);
    await dao.setValue(_kCom, comPort ?? '', syncToCloud: false);
    await dao.setValue(_kBaud, '$comBaudRate', syncToCloud: false);
    await dao.setValue(_kPaper, paperWidth.storageKey, syncToCloud: false);
    await dao.setValue(_kCharset, charset, syncToCloud: false);
    await dao.setValue(_kAuto, printAutomatically ? 'true' : 'false', syncToCloud: false);
    await dao.setValue(_kCopies, '$printCopies', syncToCloud: false);
    await dao.setValue(_kDrawer, drawer.storageKey, syncToCloud: false);
    await dao.setValue(_kDrawerCom, drawerComPort ?? '', syncToCloud: false);
    await dao.setValue(
      _kDrawerOpen,
      openDrawerOnCashPayment ? 'true' : 'false',
      syncToCloud: false,
    );
  }
}

/// Utilidad: detecta si la aplicación corre en Windows.
///
/// UltraPOS es de escritorio Windows, pero el código debe poder compilarse y
/// testearse en el CI de Linux/macOS: ninguna llamada FFI se ejecuta si no
/// estamos en Windows.
bool get isWindows => !kIsWeb && Platform.isWindows;
