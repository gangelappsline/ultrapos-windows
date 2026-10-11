import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

import '../database/daos/sales_dao.dart';
import '../database/daos/cash_dao.dart';
import '../database/app_database.dart';
import '../domain/enums.dart';
import '../utils/formatters.dart';
import '../utils/money.dart';
import 'printer_config.dart';

/// Genera los **bytes ESC/POS** del ticket.
///
/// Decisiones de diseño:
///  * Se usa `esc_pos_utils_plus` solo como *generador de bytes* (perfil de
///    capacidades y comandos). La transmisión la hace [PrinterTransport], para
///    poder enviar por spooler, red o serie con el mismo generador.
///  * El texto se normaliza a ASCII seguro: la mayoría de impresoras térmicas
///    económicas vienen con CP437 y muestran basura con tildes. Es preferible
///    un ticket legible ("Credito", "Nino") que un ticket con símbolos raros.
///    La configuración `printer.charset` permite forzar otro juego de
///    caracteres en equipos que sí lo soportan.
///  * El comando de apertura de cajón (`ESC p`) se añade **después del corte**
///    para que el cajón se abra incluso si el impresor está sin papel.
class EscPosTicketBuilder {
  EscPosTicketBuilder({
    required this.config,
    required this.currency,
  });

  final PrinterConfig config;
  final CurrencyFormat currency;

  static const int _width58 = 32;
  static const int _width80 = 48;

  /// Comando estándar de apertura de cajón (pin 2, 100 ms on / 200 ms off).
  static const List<int> drawerKickCommand = <int>[0x1B, 0x70, 0x00, 0x19, 0xFA];

  /// Comando de inicialización (limpia el buffer del impresor).
  static const List<int> initializeCommand = <int>[0x1B, 0x40];

  int get _charsPerLine =>
      config.paperWidth == PaperWidth.mm58 ? _width58 : _width80;

  /// Ticket de venta completo.
  Future<Uint8List> buildSaleTicket({
    required SaleDetails details,
    required CompanyProfile company,
    CurrencyFormat? currencyFormat,
    bool reprint = false,
    bool includeDrawerCommand = false,
    int copies = 1,
  }) async {
    final _TicketWriter writer = await _TicketWriter.create(
      charsPerLine: _charsPerLine,
      paperWidth: config.paperWidth,
      currency: currencyFormat ?? currency,
    );

    for (int copy = 0; copy < copies.clamp(1, 3); copy++) {
      await _writeSaleTicket(writer, details, company, reprint: reprint);
      if (copy < copies - 1) {
        writer
          ..feed(1)
          ..separator('=')
          ..line('COPIA')
          ..feed(1);
      }
    }

    if (config.autoCut) writer.fullCut();
    if (includeDrawerCommand && config.opensDrawerWithPrinter) writer.raw(drawerKickCommand);

    return writer.bytes;
  }

  Future<void> _writeSaleTicket(
    _TicketWriter writer,
    SaleDetails details,
    CompanyProfile company, {
    required bool reprint,
  }) async {
    final Sale sale = details.sale;

    writer
      ..initialize()
      ..feed(1);

    // --- Encabezado del negocio ---
    writer
      ..center(company.legalName, bold: true, doubleSize: true)
      ..center(company.receiptHeader.isEmpty ? null : company.receiptHeader);
    if (company.taxId.isNotEmpty) writer.center('RUC/NIT: ${company.taxId}');
    if (company.address.isNotEmpty) writer.center(company.address);
    if (company.phone.isNotEmpty) writer.center('Tel: ${company.phone}');
    writer
      ..separator('=')
      ..feed(1);

    // --- Identificación del ticket ---
    if (reprint) {
      writer
        ..line('*** REIMPRESION ***', align: TextAlignPos.center, bold: true)
        ..feed(1);
    }
    writer
      ..twoColumns('Ticket:', sale.folio, boldRight: true)
      ..twoColumns('Fecha:', AppFormat.dateTime(sale.createdAt))
      ..twoColumns('Cajero:', sale.userName);

    if (sale.cashSessionUuid != null) {
      writer.twoColumns('Turno:', _shortUuid(sale.cashSessionUuid!));
    }
    writer.twoColumns(
      'Cliente:',
      sale.customerName ?? 'Consumidor Final',
    );
    if ((sale.customerName ?? '').isNotEmpty && sale.customerUuid != null) {
      // El nombre ya se imprimió; aquí solo un aviso útil para créditos.
      if (sale.isCreditSale) writer.twoColumns('Condicion:', 'CREDITO');
    }
    if (sale.orderLabel != null && sale.orderLabel!.isNotEmpty) {
      writer.twoColumns('Pedido:', sale.orderLabel!);
    }

    writer
      ..separator()
      ..feed(1);

    // --- Detalle ---
    for (final SaleItem item in details.items) {
      writer.line(item.productName, bold: true);
      final String quantity = AppFormat.quantity(item.quantity);
      final String unitPrice = currency.money(item.unitPrice);
      writer.twoColumns(
        '  $quantity x $unitPrice',
        currency.money(item.lineTotal),
      );
      if (!item.discountAmount.isZero) {
        writer.twoColumns(
          '  Descuento',
          '-${currency.money(item.discountAmount)}',
        );
      }
      if (item.isExempt) writer.line('  (exento de impuesto)');
    }

    writer
      ..separator()
      ..feed(1);

    // --- Totales ---
    if (!sale.discountTotal.isZero) {
      writer.twoColumns('Subtotal', currency.money(sale.subtotal));
      writer.twoColumns('Descuento', '-${currency.money(sale.discountTotal)}');
    }
    if (!sale.taxTotal.isZero) {
      writer.twoColumns('Base imponible', currency.money(sale.taxableBase));
      writer.twoColumns('Impuesto', currency.money(sale.taxTotal));
    }
    writer
      ..separator('=')
      ..twoColumns(
        'TOTAL',
        currency.money(sale.total),
        boldLeft: true,
        boldRight: true,
        doubleRight: true,
      )
      ..feed(1);

    // --- Pagos ---
    for (final SalePayment payment in details.payments) {
      writer.twoColumns(payment.method.label, currency.money(payment.amount));
      if (payment.method == PaymentMethod.card && payment.cardLast4 != null) {
        writer.line('  Tarjeta ****${payment.cardLast4}');
      }
      if (payment.reference != null && payment.reference!.isNotEmpty) {
        writer.line('  Ref: ${payment.reference}');
      }
    }
    if (!sale.changeTotal.isZero) {
      writer
        ..separator()
        ..twoColumns('Cambio', currency.money(sale.changeTotal), boldRight: true);
    }

    if (sale.note != null && sale.note!.isNotEmpty) {
      writer
        ..separator()
        ..line('Nota: ${sale.note!}');
    }

    // --- Pie ---
    writer
      ..feed(1)
      ..separator('=')
      ..center(company.receiptFooter.isEmpty ? 'Gracias por su compra' : company.receiptFooter)
      ..feed(1)
      ..center('${details.items.length} articulo(s)')
      ..center('Documento generado por UltraPOS')
      ..feed(2);
  }

  /// Ticket de prueba (Configuración > Impresora).
  Future<Uint8List> buildTestTicket({
    required CompanyProfile company,
    bool includeDrawerCommand = true,
  }) async {
    final _TicketWriter writer = await _TicketWriter.create(
      charsPerLine: _charsPerLine,
      paperWidth: config.paperWidth,
      currency: currency,
    );

    writer
      ..initialize()
      ..feed(1)
      ..center('PRUEBA DE IMPRESION', bold: true, doubleSize: true)
      ..center(company.legalName)
      ..separator('=')
      ..line('Impresora : ${config.destinationLabel}')
      ..line('Tipo      : ${config.type.label}')
      ..line('Papel     : ${config.paperWidth.millimeters} mm')
      ..line('Caracteres: $_charsPerLine por linea')
      ..line('Charset   : ${config.charset}')
      ..separator()
      ..line('1234567890 ABCDEFGHIJKLMNOPQRSTUVWXYZ')
      ..line('abcdefghijklmnopqrstuvwxyz')
      ..line('! " # \$ % & / ( ) = ? * + - . , ; :')
      ..separator()
      ..center('Si lee estas lineas completas,')
      ..center('la impresora esta bien configurada.')
      ..feed(2);

    if (config.autoCut) writer.fullCut();
    if (includeDrawerCommand && config.opensDrawerWithPrinter) writer.raw(drawerKickCommand);
    return writer.bytes;
  }

  /// Corte de papel (F10 o botón de la interfaz).
  Future<Uint8List> buildPaperCut() async {
    final _TicketWriter writer = await _TicketWriter.create(
      charsPerLine: _charsPerLine,
      paperWidth: config.paperWidth,
      currency: currency,
    );
    writer.fullCut();
    return writer.bytes;
  }

  /// Reporte de cierre de caja en formato ticket (para el rollo, no para A4).
  Future<Uint8List> buildCashCloseTicket({
    required CashSession session,
    required CashSessionSummary summary,
    required CompanyProfile company,
    Map<int, int> denominations = const <int, int>{},
    bool includeDrawerCommand = true,
  }) async {
    final _TicketWriter writer = await _TicketWriter.create(
      charsPerLine: _charsPerLine,
      paperWidth: config.paperWidth,
      currency: currency,
    );

    writer
      ..initialize()
      ..feed(1)
      ..center(company.legalName, bold: true)
      ..center('CIERRE DE CAJA', bold: true, doubleSize: true)
      ..separator('=');

    writer
      ..twoColumns('Desde:', AppFormat.dateTime(session.openedAt))
      ..twoColumns('Hasta:', AppFormat.dateTime(session.closedAt ?? DateTime.now()))
      ..twoColumns('Abrio:', session.openedByName)
      ..twoColumns('Cerro:', session.closedByName ?? session.openedByName)
      ..twoColumns('Turno:', session.uuid.substring(0, 8).toUpperCase())
      ..separator()
      ..feed(1);

    writer
      ..twoColumns('Ventas', '${summary.salesCount}')
      ..twoColumns('Total vendido', currency.money(summary.grossTotal))
      ..twoColumns('Impuestos', currency.money(summary.taxTotal))
      ..twoColumns('Descuentos', currency.money(summary.discountTotal))
      ..separator()
      ..line('FORMAS DE PAGO', bold: true)
      ..twoColumns('Efectivo', currency.money(summary.totalCash))
      ..twoColumns('Tarjeta', currency.money(summary.totalCard))
      ..twoColumns('Transferencia', currency.money(summary.totalTransfer))
      ..twoColumns('Credito', currency.money(summary.totalCredit));
    if (!summary.totalOther.isZero) {
      writer.twoColumns('Otros', currency.money(summary.totalOther));
    }
    writer
      ..separator()
      ..line('ARQUEO', bold: true)
      ..twoColumns('Fondo inicial', currency.money(summary.openingAmount))
      ..twoColumns('Efectivo ventas', currency.money(summary.totalCash))
      ..twoColumns('Ingresos', currency.money(summary.deposits))
      ..twoColumns('Retiros', currency.money(summary.withdrawals))
      ..separator()
      ..twoColumns('ESPERADO', currency.money(summary.expectedCash), boldRight: true);
    if (summary.countedCash != null) {
      writer.twoColumns('CONTADO', currency.money(summary.countedCash!), boldRight: true);
      writer.twoColumns(
        'Diferencia',
        currency.money(summary.difference ?? Money.zero),
        boldRight: true,
      );
    }

    if (summary.voidCount > 0) {
      writer
        ..separator()
        ..twoColumns('Anulaciones', '${summary.voidCount}')
        ..twoColumns('Monto anulado', currency.money(summary.voidTotal));
    }

    // Desglose de billetes y monedas contados (valor en centavos -> cantidad).
    if (denominations.isNotEmpty) {
      writer
        ..separator()
        ..line('DESGLOSE DE EFECTIVO', bold: true);
      final List<int> values = denominations.keys.toList()..sort((int a, int b) => b - a);
      for (final int value in values) {
        final int count = denominations[value] ?? 0;
        if (count == 0) continue;
        writer.twoColumns(
          '${currency.money(Money(value))} x $count',
          currency.money(Money(value * count)),
        );
      }
    }

    writer
      ..separator('=')
      ..feed(1)
      ..line('Firma: ____________________')
      ..feed(1)
      ..center('UltraPOS')

      ..feed(2);

    if (config.autoCut) writer.fullCut();
    if (includeDrawerCommand && config.opensDrawerWithPrinter) writer.raw(drawerKickCommand);
    return writer.bytes;
  }

  static String _shortUuid(String uuid) =>
      uuid.length <= 8 ? uuid.toUpperCase() : uuid.substring(0, 8).toUpperCase();
}

/// Alineaciones admitidas por el escritor de tickets.
enum TextAlignPos { left, center, right }

/// Escritor de tickets con envoltura de línea manual.
///
/// `esc_pos_utils_plus` no envuelve texto: si una línea excede el ancho del
/// papel, la impresora corta la palabra donde caiga. Aquí se calcula el ancho
/// (y se tiene en cuenta que el doble tamaño reduce a la mitad los caracteres
/// por línea) para que el ticket siempre sea legible.
class _TicketWriter {
  _TicketWriter._({
    required this.charsPerLine,
    required this.paperWidth,
    required this.currency,
    required Generator generator,
  }) : _generator = generator;

  static Future<_TicketWriter> create({
    required int charsPerLine,
    required PaperWidth paperWidth,
    required CurrencyFormat currency,
  }) async {
    final CapabilityProfile profile = await CapabilityProfile.load();
    final PaperSize size = paperWidth == PaperWidth.mm58 ? PaperSize.mm58 : PaperSize.mm80;
    return _TicketWriter._(
      charsPerLine: charsPerLine,
      paperWidth: paperWidth,
      currency: currency,
      generator: Generator(size, profile),
    );
  }

  final int charsPerLine;
  final PaperWidth paperWidth;
  final CurrencyFormat currency;
  final Generator _generator;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  void _write(List<int> bytes) => _buffer.add(bytes);

  int get _effectiveWidth => charsPerLine;

  /// Inicializa el impresor (limpia comandos a medio procesar).
  void initialize() => _write(EscPosTicketBuilder.initializeCommand);

  /// Añade bytes en crudo (comandos ESC/POS específicos).
  void raw(List<int> bytes) => _write(bytes);

  void feed([int lines = 1]) => _write(_generator.feed(lines));

  /// Línea de texto con envoltura manual.
  void line(
    String text, {
    TextAlignPos align = TextAlignPos.left,
    bool bold = false,
    bool underline = false,
    bool doubleSize = false,
  }) {
    final int width = doubleSize ? (_effectiveWidth ~/ 2) : _effectiveWidth;
    for (final String chunk in _wrap(_sanitize(text), width)) {
      _write(
        _generator.text(
          chunk,
          styles: PosStyles(
            align: _align(align),
            bold: bold,
            underline: underline,
            height: doubleSize ? PosTextSize.size2 : PosTextSize.size1,
            width: doubleSize ? PosTextSize.size2 : PosTextSize.size1,
          ),
        ),
      );
    }
  }

  void center(String? text, {bool bold = false, bool doubleSize = false}) {
    if (text == null || text.trim().isEmpty) return;
    line(text, align: TextAlignPos.center, bold: bold, doubleSize: doubleSize);
  }

  /// Dos columnas (etiqueta a la izquierda, valor a la derecha).
  void twoColumns(
    String left,
    String right, {
    bool boldLeft = false,
    bool boldRight = false,
    bool doubleRight = false,
  }) {
    // Con tamaño doble, el ancho útil se reduce a la mitad.
    final int width = doubleRight ? (_effectiveWidth ~/ 2) : _effectiveWidth;
    final String leftText = _sanitize(left);
    final String rightText = _sanitize(right);

    // Si no caben en una línea, se imprime la etiqueta y el valor debajo
    // alineado a la derecha: un importe nunca se recorta (es un dato fiscal).
    if (leftText.length + rightText.length + 1 > width) {
      line(leftText, bold: boldLeft);
      line(rightText, align: TextAlignPos.right, bold: boldRight, doubleSize: doubleRight);
      return;
    }

    final int spaces = width - rightText.length - leftText.length;
    final String padded = leftText + ' ' * (spaces > 0 ? spaces : 0) + rightText;
    _write(
      _generator.text(
        padded,
        styles: PosStyles(
          bold: boldLeft || boldRight,
          height: doubleRight ? PosTextSize.size2 : PosTextSize.size1,
          width: doubleRight ? PosTextSize.size2 : PosTextSize.size1,
        ),
      ),
    );
  }

  void separator([String char = '-']) {
    final String line = char * _effectiveWidth;
    _write(_generator.text(line));
  }

  /// Corte total de papel.
  void fullCut() => _write(_generator.cut());

  /// Bytes finales del ticket.
  Uint8List get bytes => _buffer.toBytes();

  static PosAlign _align(TextAlignPos align) => switch (align) {
        TextAlignPos.left => PosAlign.left,
        TextAlignPos.center => PosAlign.center,
        TextAlignPos.right => PosAlign.right,
      };

  /// Normaliza el texto a ASCII seguro (ver nota de la clase).
  static String _sanitize(String input) {
    const Map<String, String> replacements = <String, String>{
      'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a',
      'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
      'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
      'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o',
      'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
      'ñ': 'n', 'ç': 'c',
      'Á': 'A', 'À': 'A', 'Ä': 'A', 'Â': 'A', 'Ã': 'A',
      'É': 'E', 'È': 'E', 'Ë': 'E', 'Ê': 'E',
      'Í': 'I', 'Ì': 'I', 'Ï': 'I', 'Î': 'I',
      'Ó': 'O', 'Ò': 'O', 'Ö': 'O', 'Ô': 'O', 'Õ': 'O',
      'Ú': 'U', 'Ù': 'U', 'Ü': 'U', 'Û': 'U',
      'Ñ': 'N', 'Ç': 'C',
      '¿': '?', '¡': '!', '·': '.', '\u00a0': ' ',
    };

    final StringBuffer buffer = StringBuffer();
    for (final int rune in input.runes) {
      final String char = String.fromCharCode(rune);
      final String? replacement = replacements[char];
      if (replacement != null) {
        buffer.write(replacement);
      } else if (rune >= 32 && rune < 127) {
        buffer.write(char);
      } else if (rune == 9 || rune == 10 || rune == 13) {
        buffer.write(' ');
      } else if (rune > 127) {
        // Cualquier otro carácter fuera de ASCII se omite en lugar de ensuciar
        // el ticket con bytes que la impresora no sabe representar.
        buffer.write('?');
      }
    }
    return buffer.toString();
  }

  /// Envuelve el texto respetando palabras.
  static List<String> _wrap(String text, int width) {
    if (text.length <= width) return <String>[text];
    final List<String> lines = <String>[];
    for (final String paragraph in text.split('\n')) {
      final List<String> words = paragraph.split(' ');
      final StringBuffer current = StringBuffer();
      for (final String word in words) {
        // Palabra más larga que la línea (código de barras, uuid): se parte.
        if (word.length > width) {
          if (current.isNotEmpty) {
            lines.add(current.toString());
            current.clear();
          }
          for (int i = 0; i < word.length; i += width) {
            final String piece =
                word.substring(i, (i + width).clamp(0, word.length));
            if (piece.length == width) {
              lines.add(piece);
            } else {
              current.write(piece);
            }
          }
          continue;
        }
        final int projected = current.isEmpty ? word.length : current.length + 1 + word.length;
        if (projected > width) {
          lines.add(current.toString());
          current
            ..clear()
            ..write(word);
        } else {
          if (current.isNotEmpty) current.write(' ');
          current.write(word);
        }
      }
      if (current.isNotEmpty) lines.add(current.toString());
    }
    return lines.isEmpty ? <String>[''] : lines;
  }
}
