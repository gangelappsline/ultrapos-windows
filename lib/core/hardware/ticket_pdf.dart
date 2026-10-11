import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../database/app_database.dart';
import '../database/daos/cash_dao.dart';
import '../database/daos/sales_dao.dart';
import '../domain/enums.dart';
import '../domain/report_models.dart';
import '../utils/formatters.dart';
import '../utils/money.dart';
import 'printer_config.dart';

/// Generación de documentos PDF.
///
/// Dos usos:
///  1. **Ticket en PDF**: el respaldo cuando no hay impresora térmica o cuando
///     falla. La venta ya está registrada; el cajero puede imprimir en una
///     láser, guardar el PDF o enviarlo por correo.
///  2. **Reportes**: A4 para contabilidad (cierre de caja, ventas por día,
///     inventario) y para el contador del negocio.
///
/// Se usa la fuente Helvetica incorporada (Latin-1): cubre tildes y ñ sin
/// empaquetar fuentes, y mantiene el PDF en pocos cientos de KB.
abstract final class TicketPdfBuilder {
  // --- Paleta corporativa en formato PDF -------------------------------------
  static const PdfColor _deepBlue = PdfColor.fromInt(0xFF0A2A4A);
  static const PdfColor _cyan = PdfColor.fromInt(0xFF00AEEF);
  static const PdfColor _orange = PdfColor.fromInt(0xFFFF6B00);
  static const PdfColor _grey = PdfColor.fromInt(0xFF64748B);
  static const PdfColor _lightGrey = PdfColor.fromInt(0xFFF5F7FA);

  // ---------------------------------------------------------------------------
  // Ticket de venta
  // ---------------------------------------------------------------------------

  /// Ticket de venta en formato rollo 80 mm.
  static Future<Uint8List> receipt({
    required SaleDetails details,
    required CompanyProfile company,
    required CurrencyFormat currency,
    bool reprint = false,
  }) async {
    final pw.Document document = pw.Document(
      title: 'Ticket ${details.sale.folio}',
      author: company.legalName,
    );
    final Sale sale = details.sale;

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        build: (pw.Context context) => <pw.Widget>[
          pw.Center(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: <pw.Widget>[
                pw.Text(
                  company.legalName,
                  style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
                  textAlign: pw.TextAlign.center,
                ),
                if (company.taxId.isNotEmpty)
                  pw.Text('RUC/NIT: ${company.taxId}', style: const pw.TextStyle(fontSize: 8)),
                if (company.address.isNotEmpty)
                  pw.Text(company.address, style: const pw.TextStyle(fontSize: 8)),
                if (company.phone.isNotEmpty)
                  pw.Text('Tel: ${company.phone}', style: const pw.TextStyle(fontSize: 8)),
              ],
            ),
          ),
          pw.SizedBox(height: 6),
          _divider(),
          if (reprint)
            pw.Center(
              child: pw.Text(
                '*** REIMPRESIÓN ***',
                style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
              ),
            ),
          if (reprint) pw.SizedBox(height: 4),
          _kv('Ticket', sale.folio, bold: true),
          _kv('Fecha', AppFormat.dateTime(sale.createdAt)),
          _kv('Cajero', sale.userName),
          _kv('Cliente', sale.customerName ?? 'Consumidor Final'),
          if ((sale.orderLabel ?? '').isNotEmpty) _kv('Pedido', sale.orderLabel!),
          pw.SizedBox(height: 6),
          _divider(),
          pw.SizedBox(height: 4),
          ...details.items.map(_itemBlock),
          _divider(),
          pw.SizedBox(height: 4),
          if (!sale.discountTotal.isZero) _kv('Subtotal', currency.money(sale.subtotal)),
          if (!sale.discountTotal.isZero)
            _kv('Descuento', '-${currency.money(sale.discountTotal)}'),
          if (!sale.taxTotal.isZero) _kv('Base imponible', currency.money(sale.taxableBase)),
          if (!sale.taxTotal.isZero) _kv('Impuesto', currency.money(sale.taxTotal)),
          pw.Divider(color: _deepBlue, thickness: 0.8),
          _kv('TOTAL', currency.money(sale.total), bold: true, size: 13, color: _orange),
          pw.SizedBox(height: 6),
          ...details.payments.map(
            (SalePayment payment) => _kv(
              payment.method.label,
              currency.money(payment.amount),
            ),
          ),
          if (!sale.changeTotal.isZero)
            _kv('Cambio', currency.money(sale.changeTotal), bold: true),
          if ((sale.note ?? '').isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 4),
            pw.Text('Nota: ${sale.note}', style: const pw.TextStyle(fontSize: 8)),
          ],
          pw.SizedBox(height: 8),
          _divider(),
          pw.Center(
            child: pw.Text(
              company.receiptFooter.isEmpty ? '¡Gracias por su compra!' : company.receiptFooter,
              style: const pw.TextStyle(fontSize: 8),
              textAlign: pw.TextAlign.center,
            ),
          ),
          pw.Center(
            child: pw.Text(
              '${details.items.length} artículo(s) · UltraPOS',
              style: const pw.TextStyle(fontSize: 7, color: _grey),
            ),
          ),
        ],
      ),
    );
    return document.save();
  }

  static pw.Widget _itemBlock(SaleItem item) {
    final CurrencyFormat currency = CurrencyFormat();
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 3),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.Text(
            item.productName,
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: <pw.Widget>[
              pw.Text(
                '${AppFormat.quantity(item.quantity)} x ${currency.money(item.unitPrice)}',
                style: const pw.TextStyle(fontSize: 8, color: _grey),
              ),
              pw.Text(
                currency.money(item.lineTotal),
                style: const pw.TextStyle(fontSize: 9),
              ),
            ],
          ),
          if (!item.discountAmount.isZero)
            pw.Text(
              '  descuento -${currency.money(item.discountAmount)}',
              style: const pw.TextStyle(fontSize: 8, color: _orange),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Reportes A4
  // ---------------------------------------------------------------------------

  /// Reporte de ventas (diario, semanal o mensual).
  static Future<Uint8List> salesReport({
    required CompanyProfile company,
    required SalesSummary summary,
    required List<TimeSeriesPoint> series,
    required List<TopProductRow> topProducts,
    required List<PaymentBreakdownRow> payments,
    required List<CategorySalesRow> categories,
    required CurrencyFormat currency,
    String title = 'Reporte de ventas',
  }) async {
    final pw.Document document = pw.Document(title: title, author: company.legalName);

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (pw.Context context) => _reportHeader(
          company: company,
          title: title,
          subtitle: 'Del ${AppFormat.shortDate(summary.from)} al ${AppFormat.shortDate(summary.to)}',
        ),
        footer: (pw.Context context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Página ${context.pageNumber} de ${context.pagesCount} · Generado por UltraPOS',
            style: const pw.TextStyle(fontSize: 7, color: _grey),
          ),
        ),
        build: (pw.Context context) => <pw.Widget>[
          pw.SizedBox(height: 12),
          pw.Row(
            children: <pw.Widget>[
              _metricCard('Ventas', currency.money(summary.grossTotal), _cyan),
              _metricCard('Tickets', '${summary.transactionCount}', _deepBlue),
              _metricCard('Ticket promedio', currency.money(summary.averageTicket), _deepBlue),
              _metricCard('Impuestos', currency.money(summary.taxTotal), _grey),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            children: <pw.Widget>[
              _metricCard('Neto', currency.money(summary.netTotal), _deepBlue),
              _metricCard('Descuentos', currency.money(summary.discountTotal), _orange),
              _metricCard('Costo', currency.money(summary.costTotal), _grey),
              _metricCard('Utilidad', currency.money(summary.grossProfit), _cyan),
            ],
          ),
          pw.SizedBox(height: 18),
          _section('Evolución', subtitle: 'Monto vendido por período'),
          _table(
            headers: <String>['Período', 'Tickets', 'Monto'],
            rows: series
                .map((TimeSeriesPoint point) => <String>[
                      point.label,
                      '${point.count}',
                      currency.money(point.total),
                    ])
                .toList(growable: false),
            alignRight: const <int>{1, 2},
            currency: currency,
          ),
          pw.SizedBox(height: 16),
          _section('Productos más vendidos', subtitle: 'Por ingreso'),
          _table(
            headers: <String>['Producto', 'Cantidad', 'Ingreso'],
            rows: topProducts
                .map((TopProductRow row) => <String>[
                      row.productName,
                      AppFormat.quantity(Quantity(row.quantityMilli)),
                      currency.money(row.revenue),
                    ])
                .toList(growable: false),
            alignRight: const <int>{1, 2},
            currency: currency,
          ),
          pw.SizedBox(height: 16),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: <pw.Widget>[
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: <pw.Widget>[
                    _section('Formas de pago'),
                    _table(
                      headers: <String>['Método', 'Operaciones', 'Monto'],
                      rows: payments
                          .map((PaymentBreakdownRow row) => <String>[
                                row.method.label,
                                '${row.count}',
                                currency.money(row.amount),
                              ])
                          .toList(growable: false),
                      alignRight: const <int>{1, 2},
                      currency: currency,
                    ),
                  ],
                ),
              ),
              pw.SizedBox(width: 16),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: <pw.Widget>[
                    _section('Ventas por categoría'),
                    _table(
                      headers: <String>['Categoría', 'Cantidad', 'Monto'],
                      rows: categories
                          .map((CategorySalesRow row) => <String>[
                                row.categoryName,
                                AppFormat.quantity(Quantity(row.quantityMilli)),
                                currency.money(row.revenue),
                              ])
                          .toList(growable: false),
                      alignRight: const <int>{1, 2},
                      currency: currency,
                    ),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 16),
          if (!summary.voidTotal.isZero)
            pw.Text(
              'Anulaciones: ${summary.voidCount} por ${currency.money(summary.voidTotal)}',
              style: pw.TextStyle(fontSize: 9, color: _orange, fontWeight: pw.FontWeight.bold),
            ),
          pw.SizedBox(height: 24),
          _signatureLine(),
        ],
      ),
    );
    return document.save();
  }

  /// Reporte de cierre de caja (A4, para firma del cajero y del supervisor).
  static Future<Uint8List> cashSessionReport({
    required CashSession session,
    required CashSessionSummary summary,
    required CompanyProfile company,
    required CurrencyFormat currency,
    List<CashMovement> movements = const <CashMovement>[],
    List<CashierPerformanceRow> cashiers = const <CashierPerformanceRow>[],
    Map<int, int> denominations = const <int, int>{},
  }) async {
    final pw.Document document = pw.Document(
      title: 'Cierre de caja ${session.uuid}',
      author: company.legalName,
    );

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (pw.Context context) => _reportHeader(
          company: company,
          title: 'Cierre de caja',
          subtitle: 'Turno ${session.uuid.substring(0, 8).toUpperCase()} · '
              '${AppFormat.dateTime(session.openedAt)} → '
              '${AppFormat.dateTime(session.closedAt ?? DateTime.now())}',
        ),
        footer: (pw.Context context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Página ${context.pageNumber} de ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 7, color: _grey),
          ),
        ),
        build: (pw.Context context) => <pw.Widget>[
          pw.SizedBox(height: 12),
          pw.Row(
            children: <pw.Widget>[
              _metricCard('Total vendido', currency.money(summary.grossTotal), _cyan),
              _metricCard('Tickets', '${summary.transactionCount}', _deepBlue),
              _metricCard('Ticket promedio', currency.money(summary.averageTicket), _deepBlue),
              _metricCard(
                summary.isBalanced ? 'Cuadra' : 'Diferencia',
                currency.money(summary.difference ?? Money.zero),
                summary.isBalanced ? _cyan : _orange,
              ),
            ],
          ),
          pw.SizedBox(height: 18),
          _section('Arqueo de efectivo'),
          _table(
            headers: <String>['Concepto', 'Monto'],
            rows: <List<String>>[
              <String>['Fondo inicial', currency.money(summary.openingAmount)],
              <String>['Ventas en efectivo', currency.money(summary.totalCash)],
              <String>['Ingresos de efectivo', currency.money(summary.deposits)],
              <String>['Retiros de efectivo', currency.money(summary.withdrawals)],
              <String>['Gastos pagados', currency.money(summary.expenses)],
              <String>['Devoluciones', currency.money(summary.refunds)],
              <String>['Efectivo esperado', currency.money(summary.expectedCash)],
              <String>['Efectivo contado', currency.money(summary.countedCash ?? Money.zero)],
              <String>[
                'Diferencia',
                currency.money(summary.difference ?? Money.zero),
              ],
            ],
            alignRight: const <int>{1},
            currency: currency,
            highlightRows: const <int>{6, 7, 8},
          ),
          pw.SizedBox(height: 16),
          _section('Ventas por forma de pago'),
          _table(
            headers: <String>['Método', 'Monto'],
            rows: <List<String>>[
              <String>['Efectivo', currency.money(summary.totalCash)],
              <String>['Tarjeta', currency.money(summary.totalCard)],
              <String>['Transferencia', currency.money(summary.totalTransfer)],
              <String>['Crédito', currency.money(summary.totalCredit)],
              <String>['Otros', currency.money(summary.totalOther)],
            ],
            alignRight: const <int>{1},
            currency: currency,
          ),
          if (denominations.isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 16),
            _section('Desglose de efectivo contado'),
            _table(
              headers: <String>['Denominación', 'Cantidad', 'Subtotal'],
              rows: (denominations.keys.toList()..sort((int a, int b) => b - a))
                  .map((int value) => <String>[
                        currency.money(Money(value)),
                        '${denominations[value]}',
                        currency.money(Money(value * (denominations[value] ?? 0))),
                      ])
                  .toList(growable: false),
              alignRight: const <int>{1, 2},
              currency: currency,
            ),
          ],
          if (movements.isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 16),
            _section('Movimientos de caja'),
            _table(
              headers: <String>['Hora', 'Tipo', 'Motivo', 'Monto'],
              rows: movements
                  .map((CashMovement movement) => <String>[
                        AppFormat.time(movement.createdAt),
                        movement.type.label,
                        movement.reason,
                        currency.money(movement.amount),
                      ])
                  .toList(growable: false),
              alignRight: const <int>{3},
              currency: currency,
            ),
          ],
          if (cashiers.isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 16),
            _section('Ventas por cajero'),
            _table(
              headers: <String>['Cajero', 'Tickets', 'Monto'],
              rows: cashiers
                  .map((CashierPerformanceRow row) => <String>[
                        row.userName,
                        '${row.transactionCount}',
                        currency.money(row.total),
                      ])
                  .toList(growable: false),
              alignRight: const <int>{1, 2},
              currency: currency,
            ),
          ],
          pw.SizedBox(height: 28),
          _signatureLine(),
        ],
      ),
    );
    return document.save();
  }

  /// Reporte de inventario (valorización y alertas de stock).
  ///
  /// [rows] viene de `ReportsDao.inventoryValuation()`: una fila por producto.
  /// Los totales se calculan aquí para que el PDF y la pantalla muestren
  /// exactamente los mismos números (una sola fuente de verdad).
  static Future<Uint8List> inventoryReport({
    required CompanyProfile company,
    required List<InventoryValuationRow> rows,
    required CurrencyFormat currency,
  }) async {
    final pw.Document document = pw.Document(title: 'Inventario', author: company.legalName);

    Money costValue = Money.zero;
    Money retailValue = Money.zero;
    int belowMinimum = 0;
    int outOfStock = 0;
    int unitsMilli = 0;

    for (final InventoryValuationRow row in rows) {
      final Quantity stock = Quantity(row.stockMilli);
      costValue += stock.priceFor(row.cost);
      retailValue += stock.priceFor(row.price);
      unitsMilli += row.stockMilli;
      if (row.stockMilli <= 0) {
        outOfStock++;
      } else if (row.stockMilli < row.minStockMilli) {
        belowMinimum++;
      }
    }

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (pw.Context context) => _reportHeader(
          company: company,
          title: 'Inventario valorizado',
          subtitle: 'Al ${AppFormat.shortDate(DateTime.now())} · ${rows.length} productos',
        ),
        footer: (pw.Context context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Página ${context.pageNumber} de ${context.pagesCount} · UltraPOS',
            style: const pw.TextStyle(fontSize: 7, color: _grey),
          ),
        ),
        build: (pw.Context context) => <pw.Widget>[
          pw.SizedBox(height: 12),
          pw.Row(
            children: <pw.Widget>[
              _metricCard('Productos', '${rows.length}', _deepBlue),
              _metricCard('Unidades', AppFormat.quantity(Quantity(unitsMilli)), _deepBlue),
              _metricCard('Valor a costo', currency.money(costValue), _grey),
              _metricCard('Valor a venta', currency.money(retailValue), _cyan),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            children: <pw.Widget>[
              _metricCard('Utilidad potencial', currency.money(retailValue - costValue), _cyan),
              _metricCard('Bajo mínimo', '$belowMinimum', _orange),
              _metricCard('Agotados', '$outOfStock', _orange),
            ],
          ),
          pw.SizedBox(height: 18),
          _section('Detalle de existencias'),
          _table(
            headers: <String>['SKU', 'Producto', 'Stock', 'Mínimo', 'Costo', 'Precio'],
            rows: rows
                .map((InventoryValuationRow row) => <String>[
                      row.sku,
                      row.name,
                      MoneyMath.quantityString(row.stockMilli),
                      MoneyMath.quantityString(row.minStockMilli),
                      currency.money(row.cost),
                      currency.money(row.price),
                    ])
                .toList(growable: false),
            alignRight: const <int>{2, 3, 4, 5},
            currency: currency,
          ),
        ],
      ),
    );
    return document.save();
  }

  // ---------------------------------------------------------------------------
  // Impresión / guardado
  // ---------------------------------------------------------------------------

  /// Muestra el diálogo de impresión de Windows con el PDF indicado.
  ///
  /// Es el respaldo universal: funciona con cualquier impresora instalada,
  /// incluso si no es térmica ni habla ESC/POS.
  static Future<bool> print({
    required Uint8List bytes,
    required String jobName,
    String? printerName,
  }) async {
    try {
      if (printerName != null && printerName.isNotEmpty) {
        await Printing.directPrintPdf(
          printer: Printer(url: printerName),
          name: jobName,
          onLayout: (PdfPageFormat format) async => bytes,
        );
      } else {
        await Printing.layoutPdf(
          name: jobName,
          onLayout: (PdfPageFormat format) async => bytes,
        );
      }
      return true;
    } on Object {
      return false;
    }
  }

  /// Abre el visor de impresión de Windows con el documento.
  ///
  /// Es el respaldo cuando falla la impresora térmica: el cajero ve el ticket y
  /// decide imprimirlo en otra impresora o guardarlo como PDF.
  static Future<bool> preview(Uint8List bytes, {required String name}) =>
      print(bytes: bytes, jobName: name);

  /// Impresoras disponibles para el respaldo PDF.
  static Future<List<Printer>> printers() async {
    try {
      return await Printing.listPrinters();
    } on Object {
      return const <Printer>[];
    }
  }

  // ---------------------------------------------------------------------------
  // Utilidades de maquetación
  // ---------------------------------------------------------------------------

  static pw.Widget _reportHeader({
    required CompanyProfile company,
    required String title,
    String? subtitle,
  }) =>
      pw.Container(
        padding: const pw.EdgeInsets.only(bottom: 8),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _deepBlue, width: 1.2)),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: <pw.Widget>[
                  pw.Text(
                    company.legalName,
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                      color: _deepBlue,
                    ),
                  ),
                  if (company.taxId.isNotEmpty)
                    pw.Text('RUC/NIT: ${company.taxId}', style: const pw.TextStyle(fontSize: 9)),
                  if (company.address.isNotEmpty)
                    pw.Text(company.address, style: const pw.TextStyle(fontSize: 9)),
                  pw.Text(
                    <String>[
                      if (company.phone.isNotEmpty) 'Tel: ${company.phone}',
                      if (company.email.isNotEmpty) company.email,
                    ].join(' · '),
                    style: const pw.TextStyle(fontSize: 9, color: _grey),
                  ),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: <pw.Widget>[
                pw.Text(
                  title,
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: _cyan,
                  ),
                ),
                if (subtitle != null)
                  pw.Text(subtitle, style: const pw.TextStyle(fontSize: 9, color: _grey)),
              ],
            ),
          ],
        ),
      );

  static pw.Widget _metricCard(String label, String value, PdfColor color) => pw.Expanded(
        child: pw.Container(
          margin: const pw.EdgeInsets.only(right: 6),
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            color: _lightGrey,
            borderRadius: pw.BorderRadius.circular(6),
            border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: <pw.Widget>[
              pw.Text(
                label.toUpperCase(),
                style: const pw.TextStyle(fontSize: 7, color: _grey),
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                value,
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );

  static pw.Widget _section(String title, {String? subtitle}) => pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 6),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Text(
              title,
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
                color: _deepBlue,
              ),
            ),
            if (subtitle != null)
              pw.Text(subtitle, style: const pw.TextStyle(fontSize: 8, color: _grey)),
          ],
        ),
      );

  /// Tabla con encabezado azul y filas alternas.
  ///
  /// Se construye a mano (sin `TableHelper`) para controlar el estilo y evitar
  /// dependencias frágiles entre versiones del paquete `pdf`.
  static pw.Widget _table({
    required List<String> headers,
    required List<List<String>> rows,
    Set<int> alignRight = const <int>{},
    Set<int> highlightRows = const <int>{},
    CurrencyFormat? currency,
  }) {
    pw.Widget cell(
      String text, {
      required bool header,
      bool right = false,
      bool highlight = false,
      bool bold = false,
    }) =>
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          alignment: right ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
          child: pw.Text(
            text,
            style: pw.TextStyle(
              fontSize: header ? 8 : 9,
              color: header ? PdfColors.white : (bold || highlight ? _deepBlue : PdfColors.black),
              fontWeight: header || bold || highlight ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        );

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      columnWidths: <int, pw.TableColumnWidth>{
        for (int i = 0; i < headers.length; i++)
          i: alignRight.contains(i) ? const pw.IntrinsicColumnWidth() : const pw.FlexColumnWidth(),
      },
      children: <pw.TableRow>[
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _deepBlue),
          children: headers
              .asMap()
              .entries
              .map((MapEntry<int, String> entry) => cell(
                    entry.value,
                    header: true,
                    right: alignRight.contains(entry.key),
                  ))
              .toList(growable: false),
        ),
        ...rows.asMap().entries.map(
              (MapEntry<int, List<String>> entry) => pw.TableRow(
                decoration: pw.BoxDecoration(
                  color: entry.key.isEven ? PdfColors.white : _lightGrey,
                ),
                children: entry.value
                    .asMap()
                    .entries
                    .map((MapEntry<int, String> cellEntry) => cell(
                          cellEntry.value,
                          header: false,
                          right: alignRight.contains(cellEntry.key),
                          highlight: highlightRows.contains(entry.key),
                        ))
                    .toList(growable: false),
              ),
            ),
      ],
    );
  }

  static pw.Widget _divider() => pw.Container(
        margin: const pw.EdgeInsets.symmetric(vertical: 3),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _grey, width: 0.6)),
        ),
        height: 1,
      );

  static pw.Widget _kv(
    String label,
    String value, {
    bool bold = false,
    double size = 9,
    PdfColor? color,
  }) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Text(
              label,
              style: pw.TextStyle(fontSize: size - 1, color: _grey),
            ),
            pw.Flexible(
              child: pw.Text(
                value,
                textAlign: pw.TextAlign.right,
                style: pw.TextStyle(
                  fontSize: size,
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                  color: color ?? PdfColors.black,
                ),
              ),
            ),
          ],
        ),
      );

  static pw.Widget _signatureLine() => pw.Column(
        children: <pw.Widget>[
          pw.SizedBox(height: 40),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
            children: <pw.Widget>[
              _signature('Cajero'),
              _signature('Supervisor / Administrador'),
            ],
          ),
        ],
      );

  static pw.Widget _signature(String label) => pw.Column(
        children: <pw.Widget>[
          pw.Container(width: 160, height: 1, color: PdfColors.grey600),
          pw.SizedBox(height: 3),
          pw.Text(label, style: const pw.TextStyle(fontSize: 8, color: _grey)),
        ],
      );
}

/// Exportación a CSV (Excel-friendly).
///
/// Decisiones:
///  * Separador `;` y BOM UTF-8: es lo que abre correctamente Excel en español
///    (con `,` metería todo en una columna; sin BOM las tildes salen rotas).
///  * Sin fórmulas: los valores se escapan para que un nombre con `"` no rompa
///    la fila, y se evita la inyección de fórmulas prefijando con `'` los textos
///    que empiezan por `=`, `+`, `-` o `@`.
abstract final class CsvExporter {
  static const String _separator = ';';
  static const String _bom = '\uFEFF';

  /// Construye el CSV a partir de encabezados y filas.
  static String build({
    required List<String> headers,
    required List<List<String>> rows,
  }) {
    final StringBuffer buffer = StringBuffer(_bom);
    buffer.writeln(headers.map(_escape).join(_separator));
    for (final List<String> row in rows) {
      buffer.writeln(row.map(_escape).join(_separator));
    }
    return buffer.toString();
  }

  /// Filas de ventas por período.
  static String salesSeries(List<TimeSeriesPoint> points) => build(
        headers: <String>['Período', 'Clave', 'Tickets', 'Monto'],
        rows: points
            .map((TimeSeriesPoint point) => <String>[
                  point.label,
                  AppFormat.stamp(point.bucket),
                  '${point.count}',
                  MoneyMath.decimalString(point.total.cents, 2),
                ])
            .toList(growable: false),
      );

  /// Filas de productos vendidos.
  static String topProducts(List<TopProductRow> rows) => build(
        headers: <String>['Producto', 'Cantidad', 'Ingreso', 'Costo'],
        rows: rows
            .map((TopProductRow row) => <String>[
                  row.productName,
                  MoneyMath.quantityString(row.quantityMilli),
                  MoneyMath.decimalString(row.revenue.cents, 2),
                  MoneyMath.decimalString(row.cost.cents, 2),
                ])
            .toList(growable: false),
      );

  /// Filas de inventario.
  static String inventory(List<Product> products) => build(
        headers: <String>[
          'SKU',
          'Código de barras',
          'Producto',
          'Stock',
          'Mínimo',
          'Costo',
          'Precio',
          'Activo',
        ],
        rows: products
            .map((Product product) => <String>[
                  product.sku,
                  product.barcode,
                  product.name,
                  MoneyMath.quantityString(product.stock.milli),
                  MoneyMath.quantityString(product.minStock.milli),
                  MoneyMath.decimalString(product.cost.cents, 2),
                  MoneyMath.decimalString(product.price.cents, 2),
                  product.isActive ? 'Sí' : 'No',
                ])
            .toList(growable: false),
      );

  /// Escape de un campo CSV.
  static String _escape(String value) {
    String text = value.replaceAll('\r\n', ' ').replaceAll('\n', ' ');
    // Anti-inyección de fórmulas (Excel/LibreOffice).
    if (text.isNotEmpty && '=+-@'.contains(text[0])) {
      text = "'$text";
    }
    if (text.contains(_separator) || text.contains('"')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }
}
