import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/reports_dao.dart';
import '../../../core/domain/report_models.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/hardware/ticket_pdf.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/money.dart';

/// Exportación de reportes a archivos.
///
/// Se separa de la pantalla a propósito: la lógica de exportación se usa desde
/// tres sitios (reportes, cierre de caja e inventario) y siempre termina igual,
/// con un archivo en el disco del usuario que este puede abrir o enviar.
///
/// Formatos soportados:
///   * **PDF** — resumen ejecutivo listo para imprimir o enviar por correo.
///   * **CSV** — ventas línea a línea, con separador `;` y BOM UTF-8 para que
///     Excel en español lo abra en columnas sin pedir nada al usuario.
abstract final class ReportExporter {
  static const String _scope = 'export';

  /// Exporta el reporte de ventas del período indicado.
  ///
  /// Devuelve la ruta del archivo escrito, o `null` si el usuario canceló.
  static Future<String?> exportSalesReport({
    required AppDatabase database,
    required CompanyProfile company,
    required DateTime from,
    required DateTime to,
    required CurrencyFormat currency,
    bool asPdf = true,
  }) async {
    final SalesSummary summary = await database.reportsDao.summaryFor(from, to);
    final List<SaleItemExportRow> lines = await database.reportsDao.saleItemsForExport(
      from: from,
      to: to,
    );

    final String baseName =
        'ultrapos_ventas_${AppFormat.safeFileName('${AppFormat.stamp(from)}_${AppFormat.stamp(to)}')}';

    if (asPdf) {
      final List<TimeSeriesPoint> series =
          await database.reportsDao.salesByDay(from: from, to: to);
      final List<TopProductRow> top =
          await database.reportsDao.topProducts(from: from, to: to, limit: 20);
      final List<PaymentBreakdownRow> payments =
          await database.reportsDao.paymentBreakdown(from, to);
      final List<CategorySalesRow> categories =
          await database.reportsDao.salesByCategory(from, to);

      final Uint8List bytes = await TicketPdfBuilder.salesReport(
        company: company,
        summary: summary,
        series: series,
        topProducts: top,
        payments: payments,
        categories: categories,
        currency: currency,
        title: 'Reporte de ventas',
      );
      return saveBytes(bytes, suggestedName: '$baseName.pdf');
    }

    final String csv = CsvExporter.build(
      headers: <String>[
        'Folio',
        'Fecha',
        'Hora',
        'Cajero',
        'Cliente',
        'Producto',
        'SKU',
        'Cantidad',
        'Precio unitario',
        'Descuento',
        'Impuesto',
        'Total línea',
      ],
      rows: lines
          .map(
            (SaleItemExportRow row) => <String>[
              row.folio,
              AppFormat.shortDate(row.createdAt),
              AppFormat.clock(row.createdAt),
              row.userName,
              row.customerName ?? 'Consumidor Final',
              row.productName,
              row.sku,
              MoneyMath.quantityString(row.quantityMilli),
              MoneyMath.decimalString(row.unitPrice.cents, 2),
              MoneyMath.decimalString(row.discount.cents, 2),
              MoneyMath.decimalString(row.tax.cents, 2),
              MoneyMath.decimalString(row.lineTotal.cents, 2),
            ],
          )
          .toList(growable: false),
    );
    return saveText(csv, suggestedName: '$baseName.csv');
  }

  /// Exporta la valorización de inventario (para inventarios físicos y contables).
  static Future<String?> exportInventory({
    required AppDatabase database,
    required CompanyProfile company,
    required CurrencyFormat currency,
    bool asPdf = false,
  }) async {
    final List<InventoryValuationRow> rows =
        await database.reportsDao.inventoryValuation(limit: 5000);
    final String baseName = 'ultrapos_inventario_${AppFormat.safeFileName(AppFormat.stamp(DateTime.now()))}';

    if (asPdf) {
      final Uint8List bytes = await TicketPdfBuilder.inventoryReport(
        company: company,
        rows: rows,
        currency: currency,
      );
      return saveBytes(bytes, suggestedName: '$baseName.pdf');
    }

    final String csv = CsvExporter.build(
      headers: <String>[
        'SKU',
        'Producto',
        'Stock',
        'Mínimo',
        'Costo unitario',
        'Precio',
        'Valor a costo',
        'Valor a venta',
      ],
      rows: rows
          .map(
            (InventoryValuationRow row) => <String>[
              row.sku,
              row.name,
              MoneyMath.quantityString(row.stockMilli),
              MoneyMath.quantityString(row.minStockMilli),
              MoneyMath.decimalString(row.cost.cents, 2),
              MoneyMath.decimalString(row.price.cents, 2),
              MoneyMath.decimalString(row.costValue.cents, 2),
              MoneyMath.decimalString(row.retailValue.cents, 2),
            ],
          )
          .toList(growable: false),
    );
    return saveText(csv, suggestedName: '$baseName.csv');
  }

  /// Guarda texto (CSV) pidiendo la ubicación al usuario.
  static Future<String?> saveText(String content, {required String suggestedName}) async {
    final FileSaveLocation? location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(label: 'Texto separado por comas', extensions: <String>['csv']),
      ],
    );
    if (location == null) return null;
    final File file = File(location.path);
    await file.writeAsString(content, flush: true);
    Log.info(_scope, 'CSV guardado', data: <String, Object?>{'file': file.path});
    return file.path;
  }

  /// Guarda bytes (PDF) pidiendo la ubicación al usuario.
  static Future<String?> saveBytes(Uint8List bytes, {required String suggestedName}) async {
    final FileSaveLocation? location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(label: 'Documento PDF', extensions: <String>['pdf']),
      ],
    );
    if (location == null) return null;
    final File file = File(location.path);
    await file.writeAsBytes(bytes, flush: true);
    Log.info(_scope, 'PDF guardado', data: <String, Object?>{'file': file.path});
    return file.path;
  }

  /// Carpeta por defecto para respaldos y exportaciones.
  ///
  /// Se usa `Documents/UltraPOS` (visible para el usuario) en lugar de la
  /// carpeta de datos de la aplicación: un respaldo que el dueño no encuentra
  /// no sirve como respaldo.
  static Future<Directory> defaultExportDirectory() async {
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      final Directory target = Directory('${documents.path}${Platform.pathSeparator}UltraPOS');
      if (!await target.exists()) {
        await target.create(recursive: true);
      }
      return target;
    } on Object catch (error) {
      throw DatabaseFailure(
        message: 'No se pudo preparar la carpeta de exportación.',
        technicalDetail: '$error',
      );
    }
  }
}
