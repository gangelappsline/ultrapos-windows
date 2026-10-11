import 'dart:typed_data';

import '../database/app_database.dart';
import '../database/daos/sales_dao.dart';
import '../database/daos/settings_dao.dart';
import '../domain/enums.dart';
import '../errors/app_failure.dart';
import '../logging/app_logger.dart';
import '../utils/formatters.dart';
import 'escpos_ticket_builder.dart';
import 'printer_config.dart';
import 'printer_transport.dart';
import 'scanner_service.dart';
import 'ticket_pdf.dart';
import 'win_com.dart';

/// Resultado de una operación de hardware, listo para mostrar al cajero.
class HardwareReport {
  const HardwareReport({
    required this.success,
    required this.message,
    this.details = const <String, Object?>{},
  });

  final bool success;
  final String message;
  final Map<String, Object?> details;
}

/// Fachada única de hardware: impresora térmica, cajón de dinero y lector.
///
/// Principio de diseño: **el hardware nunca bloquea la venta**.
/// Si la impresora falla, la venta ya está en SQLite, se informa al cajero y se
/// ofrece reimprimir. Detener un cobro por una impresora apagada es un error
/// grave de diseño en un POS.
class HardwareManager {
  HardwareManager({required this.database});

  final AppDatabase database;

  static const String _scope = 'hardware';

  PrinterConfig? _cachedConfig;
  final BarcodeScannerDetector scanner = BarcodeScannerDetector();

  /// Configuración activa (se cachea; se recarga al guardar ajustes).
  Future<PrinterConfig> config() async {
    final PrinterConfig? cached = _cachedConfig;
    if (cached != null) return cached;
    final PrinterConfig loaded = await _loadConfig();
    _cachedConfig = loaded;
    return loaded;
  }

  Future<void> invalidateConfig() async {
    _cachedConfig = null;
  }

  Future<PrinterConfig> _loadConfig() async {
    final PrinterConfig loaded = await PrinterConfig.load(database);
    // Valores de arranque cómodos: la impresora predeterminada de Windows y
    // los puertos serie habituales, para no obligar a configurar a mano en el
    // primer inicio (la pantalla de configuración los confirma y los guarda).
    return loaded.copyWith(
      windowsPrinterName: (loaded.windowsPrinterName ?? '').isEmpty
          ? defaultWindowsPrinter()
          : loaded.windowsPrinterName,
      comPort: (loaded.comPort ?? '').isEmpty ? 'COM1' : loaded.comPort,
      drawerComPort: (loaded.drawerComPort ?? '').isEmpty ? 'COM2' : loaded.drawerComPort,
    );
  }

  Future<void> saveConfig(PrinterConfig config) async {
    await config.save(database);
    _cachedConfig = config;
    Log.info(_scope, 'Configuración de impresora actualizada', data: <String, Object?>{
      'type': config.type.storageKey,
      'destination': config.destinationLabel,
    });
  }

  // ---------------------------------------------------------------------------
  // Impresión
  // ---------------------------------------------------------------------------

  /// Imprime un ticket de venta.
  ///
  /// Nunca lanza: devuelve un informe. La venta ya se cobró.
  Future<HardwareReport> printSaleTicket({
    required SaleDetails details,
    required CompanyProfile company,
    bool reprint = false,
    bool openDrawer = false,
  }) async {
    final PrinterConfig config = await this.config();
    final CurrencyFormat currency = _currencyFor(company);

    if (config.type == PrinterType.pdf || config.type == PrinterType.none) {
      return _printPdfFallback(details: details, company: company, currency: currency, reprint: reprint);
    }

    final PrinterTransport? transport = createTransport(config);
    if (transport == null) {
      return HardwareReport(
        success: false,
        message: 'La impresora no está configurada. Revise Configuración > Impresora.',
      );
    }

    try {
      final EscPosTicketBuilder builder =
          EscPosTicketBuilder(config: config, currency: currency);
      final Uint8List bytes = await builder.buildSaleTicket(
        details: details,
        company: company,
        reprint: reprint,
        includeDrawerCommand: openDrawer,
        copies: config.printCopies.clamp(1, 3),
      );

      final PrintOutcome outcome = await sendWithRetry(transport, bytes);
      if (outcome.success) {
        await database.salesDao.markPrinted(details.sale.uuid);
        Log.info(_scope, 'Ticket impreso', data: <String, Object?>{
          'folio': details.sale.folio,
          'bytes': outcome.bytesSent,
        });
        return HardwareReport(
          success: true,
          message: 'Ticket ${details.sale.folio} impreso.',
          details: <String, Object?>{
            'bytes': outcome.bytesSent,
            'transport': outcome.transport,
            'duration_ms': outcome.durationMs,
          },
        );
      }

      // La impresora falló: se ofrece el respaldo en PDF, pero la venta sigue OK.
      return HardwareReport(
        success: false,
        message: '${outcome.errorMessage}\n\nLa venta quedó registrada. '
            'Puede imprimir el ticket en PDF desde el historial.',
        details: <String, Object?>{'transport': outcome.transport},
      );
    } on Object catch (error, stack) {
      Log.error(_scope, 'Fallo al imprimir ticket', error: error, stackTrace: stack);
      return HardwareReport(
        success: false,
        message: 'No se pudo imprimir: $error',
      );
    }
  }

  /// Respaldo PDF: se abre el visor de Windows con el ticket.
  Future<HardwareReport> _printPdfFallback({
    required SaleDetails details,
    required CompanyProfile company,
    required CurrencyFormat currency,
    required bool reprint,
  }) async {
    try {
      final Uint8List bytes = await TicketPdfBuilder.receipt(
        details: details,
        company: company,
        currency: currency,
        reprint: reprint,
      );
      await TicketPdfBuilder.preview(bytes, name: 'Ticket ${details.sale.folio}');
      return HardwareReport(
        success: true,
        message: 'Ticket ${details.sale.folio} enviado al visor de impresión.',
      );
    } on Object catch (error) {
      return HardwareReport(
        success: false,
        message: 'No se pudo generar el PDF del ticket: $error',
      );
    }
  }

  /// Comprobante de cierre de caja.
  Future<HardwareReport> printCashClose({
    required CashSession session,
    required CashSessionSummary summary,
    required CompanyProfile company,
  }) async {
    final PrinterConfig config = await this.config();
    if (config.type == PrinterType.none) {
      return const HardwareReport(success: false, message: 'No hay impresora configurada.');
    }
    final CurrencyFormat currency = _currencyFor(company);
    try {
      final Uint8List bytes = await EscPosTicketBuilder(config: config, currency: currency)
          .buildCashCloseTicket(session: session, summary: summary, company: company);
      final PrinterTransport? transport = createTransport(config);
      if (transport == null) {
        await TicketPdfBuilder.preview(bytes, name: 'Cierre de caja');
        return const HardwareReport(success: true, message: 'Cierre generado.');
      }
      final PrintOutcome outcome = await sendWithRetry(transport, bytes);
      return HardwareReport(
        success: outcome.success,
        message: outcome.success
            ? 'Comprobante de cierre impreso.'
            : outcome.errorMessage ?? 'No se pudo imprimir el cierre.',
      );
    } on Object catch (error) {
      return HardwareReport(success: false, message: 'Error al imprimir el cierre: $error');
    }
  }

  /// Ticket de prueba (Configuración > Impresora > Probar).
  Future<HardwareReport> testPrint({required CompanyProfile company}) async {
    final PrinterConfig config = await this.config();
    if (!config.isUsable) {
      return const HardwareReport(
        success: false,
        message: 'Configure primero el tipo de impresora y su destino.',
      );
    }
    final CurrencyFormat currency = _currencyFor(company);

    if (config.type == PrinterType.pdf) {
      final Uint8List bytes =
          await EscPosTicketBuilder(config: config, currency: currency).buildTestTicket(company: company);
      await TicketPdfBuilder.preview(bytes, name: 'Prueba de impresión');
      return const HardwareReport(success: true, message: 'Prueba enviada al visor de Windows.');
    }

    final PrinterTransport? transport = createTransport(config);
    if (transport == null) {
      return const HardwareReport(success: false, message: 'Configuración de impresora incompleta.');
    }

    try {
      final Uint8List bytes = await EscPosTicketBuilder(config: config, currency: currency)
          .buildTestTicket(company: company);
      final PrintOutcome outcome = await sendWithRetry(transport, bytes);
      return HardwareReport(
        success: outcome.success,
        message: outcome.success
            ? 'Prueba enviada a ${config.destinationLabel}. '
                'Si no sale papel, revise la impresora físicamente.'
            : outcome.errorMessage ?? 'Fallo desconocido',
        details: <String, Object?>{'bytes': outcome.bytesSent, 'transport': outcome.transport},
      );
    } on Object catch (error) {
      return HardwareReport(success: false, message: '$error');
    }
  }

  /// Corte de papel manual (F10 o botón en la barra de la caja).
  Future<HardwareReport> cutPaper() async {
    final PrinterConfig config = await this.config();
    final PrinterTransport? transport = createTransport(config);
    if (transport == null) {
      return const HardwareReport(success: false, message: 'No hay impresora térmica configurada.');
    }
    try {
      final Uint8List bytes =
          await EscPosTicketBuilder(config: config, currency: const CurrencyFormat()).buildPaperCut();
      final PrintOutcome outcome = await transport.send(bytes);
      return HardwareReport(
        success: outcome.success,
        message: outcome.success ? 'Corte enviado.' : outcome.errorMessage ?? 'Fallo al cortar.',
      );
    } on Object catch (error) {
      return HardwareReport(success: false, message: '$error');
    }
  }

  // ---------------------------------------------------------------------------
  // Cajón de dinero
  // ---------------------------------------------------------------------------

  /// Abre el cajón. Devuelve un informe; **nunca** lanza una excepción.
  Future<HardwareReport> openCashDrawer() async {
    final PrinterConfig config = await this.config();

    switch (config.drawer) {
      case DrawerType.none:
        return const HardwareReport(
          success: false,
          message: 'No hay cajón de dinero configurado.',
        );
      case DrawerType.serial:
        try {
          final String port = config.drawerComPort ?? '';
          if (port.isEmpty) {
            return const HardwareReport(
              success: false,
              message: 'El cajón serie no tiene puerto configurado (Configuración > Cajón).',
            );
          }
          WinCom.write(
            Uint8List.fromList(kOpenDrawerCommand),
            port: port,
            baudRate: config.comBaudRate,
          );
          return HardwareReport(
            success: true,
            message: 'Cajón abierto ($port).',
          );
        } on Object catch (error) {
          return HardwareReport(success: false, message: '$error');
        }
      case DrawerType.printer:
        final PrinterTransport? transport = createTransport(config);
        if (transport == null) {
          return const HardwareReport(
            success: false,
            message: 'El cajón está conectado a la impresora, pero no hay impresora configurada.',
          );
        }
        final PrintOutcome outcome =
            await transport.send(Uint8List.fromList(kOpenDrawerCommand));
        return HardwareReport(
          success: outcome.success,
          // Nota de soporte: si el cajón no abre, casi siempre es la impresora
          // apagada o el cable RJ11 mal conectado.
          message: outcome.success
              ? 'Cajón abierto.'
              : outcome.errorMessage ?? 'No se pudo abrir el cajón.',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // Diagnóstico
  // ---------------------------------------------------------------------------

  /// Estado del hardware para la pantalla de configuración.
  Future<Map<String, Object?>> diagnostics() async {
    final PrinterConfig config = await this.config();
    return <String, Object?>{
      'printer_type': config.type.label,
      'printer_destination': config.destinationLabel,
      'printer_ready': config.isUsable,
      'paper_width': '${config.paperWidth.millimeters} mm',
      'charset': config.charset,
      'drawer': config.drawer.label,
      'windows_printers': availableWindowsPrinters(),
      'com_ports': availableComPorts(),
      'default_printer': defaultWindowsPrinter(),
    };
  }

  /// Comprueba si la impresora de red responde (ping TCP al puerto 9100).
  Future<bool> probeNetworkPrinter() async {
    final PrinterConfig config = await this.config();
    if (config.type != PrinterType.network) return false;
    return NetworkPrinterTransport(
      host: config.networkHost,
      port: config.networkPort,
    ).probe();
  }

  CurrencyFormat _currencyFor(CompanyProfile company) => CurrencyFormat(
        code: company.currencyCode,
        symbol: company.currencySymbol,
      );

  Future<void> dispose() => scanner.dispose();
}

/// Traduce un [HardwareReport] fallido a una excepción mostrable.
HardwareFailure asFailure(HardwareReport report, {String device = 'printer'}) =>
    HardwareFailure(message: report.message, device: device);
