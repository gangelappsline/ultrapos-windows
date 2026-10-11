import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../../domain/report_models.dart';
import '../../utils/money.dart';
import '../app_database.dart';
import '../tables/sales_tables.dart';

part 'reports_dao.g.dart';

/// Reportes y analítica.
///
/// Todas las consultas filtran `status = 'completed' AND deleted_at IS NULL`:
/// una venta anulada **no existe** para los totales (regla fiscal básica).
///
/// Las agrupaciones por día usan `'localtime'` de SQLite: el cajero piensa en
/// días y horas locales, no en UTC, y un cierre de día mal agrupado arruina la
/// conciliación. Los índices `idx_sales_created` e `idx_sales_session` cubren
/// estos rangos.
@DriftAccessor(tables: <Type>[Sales, SaleItems, SalePayments])
class ReportsDao extends DatabaseAccessor<AppDatabase> with _$ReportsDaoMixin {
  ReportsDao(AppDatabase db) : super(db);

  static const String _effectiveSalesFilter =
      "s.status = 'completed' AND s.deleted_at IS NULL";

  // ---------------------------------------------------------------------------
  // Resumen
  // ---------------------------------------------------------------------------

  /// Resumen de ventas del rango `[from, to]`.
  Future<SalesSummary> summaryFor(DateTime from, DateTime to) async {
    final int fromMs = DateTime(from.year, from.month, from.day).toUtc().millisecondsSinceEpoch;
    final int toMs = DateTime(to.year, to.month, to.day, 23, 59, 59, 999)
        .toUtc()
        .millisecondsSinceEpoch;

    final QueryRow row = await customSelect(
      '''
      SELECT COUNT(*)                          AS transaction_count,
             COALESCE(SUM(s.item_count), 0)    AS item_count,
             COALESCE(SUM(s.total), 0)         AS gross_total,
             COALESCE(SUM(s.taxable_base), 0)  AS net_total,
             COALESCE(SUM(s.tax_total), 0)     AS tax_total,
             COALESCE(SUM(s.discount_total), 0) AS discount_total,
             COALESCE(SUM(s.cost_total), 0)    AS cost_total
        FROM sales s
       WHERE $_effectiveSalesFilter
         AND s.created_at >= ? AND s.created_at <= ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(fromMs),
        Variable.withInt(toMs),
      ],
    ).getSingle();

    final QueryRow voidRow = await customSelect(
      '''
      SELECT COUNT(*)                AS void_count,
             COALESCE(SUM(total), 0) AS void_total
        FROM sales
       WHERE status = 'voided' AND deleted_at IS NULL
         AND created_at >= ? AND created_at <= ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(fromMs),
        Variable.withInt(toMs),
      ],
    ).getSingle();

    final QueryRow itemRow = await customSelect(
      '''
      SELECT COALESCE(SUM(i.quantity), 0) AS quantity_milli
        FROM sale_items i
        JOIN sales s ON s.id = i.sale_id
       WHERE $_effectiveSalesFilter AND i.deleted_at IS NULL
         AND s.created_at >= ? AND s.created_at <= ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(fromMs),
        Variable.withInt(toMs),
      ],
    ).getSingle();

    final QueryRow creditRow = await customSelect(
      '''
      SELECT COALESCE(SUM(p.amount), 0) AS credit_total
        FROM sale_payments p
        JOIN sales s ON s.id = p.sale_id
       WHERE $_effectiveSalesFilter AND p.deleted_at IS NULL AND p.method = 'credit'
         AND s.created_at >= ? AND s.created_at <= ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(fromMs),
        Variable.withInt(toMs),
      ],
    ).getSingle();

    return SalesSummary(
      from: from,
      to: to,
      transactionCount: row.read<int>('transaction_count'),
      itemCount: row.read<int>('item_count'),
      quantityMilli: itemRow.read<int>('quantity_milli'),
      grossTotal: Money(row.read<int>('gross_total')),
      netTotal: Money(row.read<int>('net_total')),
      taxTotal: Money(row.read<int>('tax_total')),
      discountTotal: Money(row.read<int>('discount_total')),
      costTotal: Money(row.read<int>('cost_total')),
      voidCount: voidRow.read<int>('void_count'),
      voidTotal: Money(voidRow.read<int>('void_total')),
      creditTotal: Money(creditRow.read<int>('credit_total')),
    );
  }

  /// Resumen del día de hoy, reactivo (KPIs del dashboard).
  Stream<SalesSummary> watchTodaySummary() {
    final (DateTime from, DateTime to) = dayRange(DateTime.now());
    return watchSummaryFor(from, to);
  }

  /// Resumen de un rango, como flujo (se refresca al cobrar una venta).
  Stream<SalesSummary> watchSummaryFor(DateTime from, DateTime to) {
    final int fromMs = DateTime(from.year, from.month, from.day).toUtc().millisecondsSinceEpoch;
    final int toMs = DateTime(to.year, to.month, to.day, 23, 59, 59, 999)
        .toUtc()
        .millisecondsSinceEpoch;

    return customSelect(
      '''
      SELECT COUNT(*)                          AS transaction_count,
             COALESCE(SUM(s.item_count), 0)    AS item_count,
             COALESCE(SUM(s.total), 0)         AS gross_total,
             COALESCE(SUM(s.taxable_base), 0)  AS net_total,
             COALESCE(SUM(s.tax_total), 0)     AS tax_total,
             COALESCE(SUM(s.discount_total), 0) AS discount_total,
             COALESCE(SUM(s.cost_total), 0)    AS cost_total
        FROM sales s
       WHERE $_effectiveSalesFilter
         AND s.created_at >= ? AND s.created_at <= ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(fromMs),
        Variable.withInt(toMs),
      ],
      readsFrom: {sales},
    ).watchSingle().map((QueryRow row) {
      return SalesSummary(
        from: from,
        to: to,
        transactionCount: row.read<int>('transaction_count'),
        itemCount: row.read<int>('item_count'),
        quantityMilli: 0,
        grossTotal: Money(row.read<int>('gross_total')),
        netTotal: Money(row.read<int>('net_total')),
        taxTotal: Money(row.read<int>('tax_total')),
        discountTotal: Money(row.read<int>('discount_total')),
        costTotal: Money(row.read<int>('cost_total')),
        voidCount: 0,
        voidTotal: Money.zero,
        creditTotal: Money.zero,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Series temporales (gráficos)
  // ---------------------------------------------------------------------------

  Future<List<TimeSeriesPoint>> salesByDay({required DateTime from, required DateTime to}) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT date(s.created_at / 1000, 'unixepoch', 'localtime') AS bucket,
             COALESCE(SUM(s.total), 0)                            AS total,
             COUNT(*)                                             AS count
        FROM sales s
       WHERE $_effectiveSalesFilter
         AND s.created_at >= ? AND s.created_at <= ?
       GROUP BY bucket
       ORDER BY bucket;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(DateTime(from.year, from.month, from.day).toUtc().millisecondsSinceEpoch),
        Variable.withInt(
          DateTime(to.year, to.month, to.day, 23, 59, 59, 999).toUtc().millisecondsSinceEpoch,
        ),
      ],
    ).get();

    return rows
        .map((QueryRow row) => TimeSeriesPoint(
              bucket: DateTime.parse(row.read<String>('bucket')),
              total: Money(row.read<int>('total')),
              count: row.read<int>('count'),
            ))
        .toList(growable: false);
  }

  Future<List<TimeSeriesPoint>> salesByHour({required DateTime day}) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT CAST(strftime('%H', s.created_at / 1000, 'unixepoch', 'localtime') AS INTEGER) AS bucket,
             COALESCE(SUM(s.total), 0) AS total,
             COUNT(*)                  AS count
        FROM sales s
       WHERE $_effectiveSalesFilter
         AND s.created_at >= ? AND s.created_at <= ?
       GROUP BY bucket
       ORDER BY bucket;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(DateTime(day.year, day.month, day.day).toUtc().millisecondsSinceEpoch),
        Variable.withInt(
          DateTime(day.year, day.month, day.day, 23, 59, 59, 999).toUtc().millisecondsSinceEpoch,
        ),
      ],
    ).get();

    return rows
        .map((QueryRow row) {
          final int hour = row.read<int>('bucket');
          return TimeSeriesPoint(
            bucket: DateTime(day.year, day.month, day.day, hour),
            total: Money(row.read<int>('total')),
            count: row.read<int>('count'),
            label: '${hour.toString().padLeft(2, '0')}:00',
          );
        })
        .toList(growable: false);
  }

  Future<List<TimeSeriesPoint>> salesByMonth({required int year}) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT strftime('%Y-%m', s.created_at / 1000, 'unixepoch', 'localtime') AS bucket,
             COALESCE(SUM(s.total), 0) AS total,
             COUNT(*)                  AS count
        FROM sales s
       WHERE $_effectiveSalesFilter
         AND s.created_at >= ? AND s.created_at <= ?
       GROUP BY bucket
       ORDER BY bucket;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(DateTime(year, 1, 1).toUtc().millisecondsSinceEpoch),
        Variable.withInt(DateTime(year, 12, 31, 23, 59, 59, 999).toUtc().millisecondsSinceEpoch),
      ],
    ).get();

    return rows
        .map((QueryRow row) => TimeSeriesPoint(
              bucket: DateTime.parse('${row.read<String>('bucket')}-01'),
              total: Money(row.read<int>('total')),
              count: row.read<int>('count'),
              label: row.read<String>('bucket'),
            ))
        .toList(growable: false);
  }

  /// Mapa de calor día-de-la-semana x hora (los últimos [days] días).
  Future<List<WeekdayHourSalesRow>> weekdayHourHeatmap({int days = 90}) async {
    final DateTime to = DateTime.now();
    final DateTime from = to.subtract(Duration(days: days));
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT CAST(strftime('%w', s.created_at / 1000, 'unixepoch', 'localtime') AS INTEGER) AS weekday,
             CAST(strftime('%H', s.created_at / 1000, 'unixepoch', 'localtime') AS INTEGER) AS hour,
             COALESCE(SUM(s.total), 0) AS total,
             COUNT(*)                  AS count
        FROM sales s
       WHERE $_effectiveSalesFilter
         AND s.created_at >= ? AND s.created_at <= ?
       GROUP BY weekday, hour
       ORDER BY weekday, hour;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(from.toUtc().millisecondsSinceEpoch),
        Variable.withInt(to.toUtc().millisecondsSinceEpoch),
      ],
    ).get();

    return rows
        .map((QueryRow row) => WeekdayHourSalesRow(
              weekday: row.read<int>('weekday'),
              hour: row.read<int>('hour'),
              total: Money(row.read<int>('total')),
              count: row.read<int>('count'),
            ))
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Rankings
  // ---------------------------------------------------------------------------

  /// Productos más vendidos. [orderBy] permite alternar entre unidades
  /// (`quantity`) y facturación (`revenue`), que dan listas muy distintas y
  /// responden a preguntas distintas del dueño del negocio.
  Future<List<TopProductRow>> topProducts({
    required DateTime from,
    required DateTime to,
    int limit = 20,
    TopProductOrder orderBy = TopProductOrder.revenue,
  }) async {
    final String order = switch (orderBy) {
      TopProductOrder.revenue => 'revenue DESC',
      TopProductOrder.quantity => 'quantity DESC',
      TopProductOrder.profit => 'profit DESC',
    };
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT i.product_uuid                          AS product_uuid,
             i.product_name                          AS product_name,
             COALESCE(SUM(i.quantity), 0)            AS quantity,
             COALESCE(SUM(i.line_total), 0)          AS revenue,
             COALESCE(SUM((i.unit_cost * i.quantity) / 1000), 0) AS cost,
             COALESCE(SUM(i.line_total - ((i.unit_cost * i.quantity) / 1000)), 0) AS profit,
             COUNT(*)                                AS lines
        FROM sale_items i
        JOIN sales s ON s.id = i.sale_id
       WHERE $_effectiveSalesFilter
         AND i.deleted_at IS NULL
         AND s.created_at >= ? AND s.created_at <= ?
       GROUP BY i.product_uuid, i.product_name
       ORDER BY $order
       LIMIT ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(DateTime(from.year, from.month, from.day).toUtc().millisecondsSinceEpoch),
        Variable.withInt(
          DateTime(to.year, to.month, to.day, 23, 59, 59, 999).toUtc().millisecondsSinceEpoch,
        ),
        Variable.withInt(limit),
      ],
    ).get();

    return rows
        .map((QueryRow row) => TopProductRow(
              productUuid: row.readNullable<String>('product_uuid'),
              productName: row.read<String>('product_name'),
              quantityMilli: row.read<int>('quantity'),
              revenue: Money(row.read<int>('revenue')),
              cost: Money(row.read<int>('cost')),
              lines: row.read<int>('lines'),
            ))
        .toList(growable: false);
  }

  Future<List<PaymentBreakdownRow>> paymentBreakdown({
    required DateTime from,
    required DateTime to,
  }) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT p.method                     AS method,
             COALESCE(SUM(p.amount), 0)   AS amount,
             COUNT(*)                     AS count
        FROM sale_payments p
        JOIN sales s ON s.id = p.sale_id
       WHERE $_effectiveSalesFilter
         AND p.deleted_at IS NULL
         AND s.created_at >= ? AND s.created_at <= ?
       GROUP BY p.method
       ORDER BY amount DESC;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(DateTime(from.year, from.month, from.day).toUtc().millisecondsSinceEpoch),
        Variable.withInt(
          DateTime(to.year, to.month, to.day, 23, 59, 59, 999).toUtc().millisecondsSinceEpoch,
        ),
      ],
    ).get();

    return rows
        .map((QueryRow row) => PaymentBreakdownRow(
              method: PaymentMethod.fromStorage(row.read<String>('method')),
              amount: Money(row.read<int>('amount')),
              count: row.read<int>('count'),
            ))
        .toList(growable: false);
  }

  Future<List<CategorySalesRow>> salesByCategory({
    required DateTime from,
    required DateTime to,
    int limit = 15,
  }) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT c.id                              AS category_id,
             COALESCE(c.name, 'Sin categoría') AS category_name,
             COALESCE(SUM(i.line_total), 0)    AS revenue,
             COALESCE(SUM(i.quantity), 0)      AS quantity
        FROM sale_items i
        JOIN sales s ON s.id = i.sale_id
        LEFT JOIN products p ON p.id = i.product_id
        LEFT JOIN categories c ON c.id = p.category_id
       WHERE $_effectiveSalesFilter
         AND i.deleted_at IS NULL
         AND s.created_at >= ? AND s.created_at <= ?
       GROUP BY c.id, c.name
       ORDER BY revenue DESC
       LIMIT ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(DateTime(from.year, from.month, from.day).toUtc().millisecondsSinceEpoch),
        Variable.withInt(
          DateTime(to.year, to.month, to.day, 23, 59, 59, 999).toUtc().millisecondsSinceEpoch,
        ),
        Variable.withInt(limit),
      ],
    ).get();

    return rows
        .map((QueryRow row) => CategorySalesRow(
              categoryId: row.readNullable<int>('category_id'),
              categoryName: row.read<String>('category_name'),
              revenue: Money(row.read<int>('revenue')),
              quantityMilli: row.read<int>('quantity'),
            ))
        .toList(growable: false);
  }

  Future<List<CashierPerformanceRow>> salesByCashier({
    required DateTime from,
    required DateTime to,
  }) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT s.user_name                        AS user_name,
             COUNT(*)                           AS transaction_count,
             COALESCE(SUM(s.total), 0)          AS total,
             COALESCE(SUM(s.discount_total), 0) AS discount_total
        FROM sales s
       WHERE $_effectiveSalesFilter
         AND s.created_at >= ? AND s.created_at <= ?
       GROUP BY s.user_name
       ORDER BY total DESC;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(DateTime(from.year, from.month, from.day).toUtc().millisecondsSinceEpoch),
        Variable.withInt(
          DateTime(to.year, to.month, to.day, 23, 59, 59, 999).toUtc().millisecondsSinceEpoch,
        ),
      ],
    ).get();

    final List<QueryRow> voids = await customSelect(
      '''
      SELECT voided_by_name AS user_name, COUNT(*) AS void_count
        FROM sales
       WHERE status = 'voided' AND deleted_at IS NULL
         AND created_at >= ? AND created_at <= ?
       GROUP BY voided_by_name;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(DateTime(from.year, from.month, from.day).toUtc().millisecondsSinceEpoch),
        Variable.withInt(
          DateTime(to.year, to.month, to.day, 23, 59, 59, 999).toUtc().millisecondsSinceEpoch,
        ),
      ],
    ).get();

    int voidCountFor(String name) => voids
        .where((QueryRow r) => r.readNullable<String>('user_name') == name)
        .map((QueryRow r) => r.read<int>('void_count'))
        .fold(0, (int a, int b) => a + b);

    return rows
        .map((QueryRow row) => CashierPerformanceRow(
              userName: row.read<String>('user_name'),
              transactionCount: row.read<int>('transaction_count'),
              total: Money(row.read<int>('total')),
              discountTotal: Money(row.read<int>('discount_total')),
              voidCount: voidCountFor(row.read<String>('user_name')),
            ))
        .toList(growable: false);
  }

  Future<List<CustomerRankingRow>> topCustomers({
    required DateTime from,
    required DateTime to,
    int limit = 20,
  }) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT s.customer_uuid                    AS customer_uuid,
             COALESCE(s.customer_name, 'Consumidor Final') AS customer_name,
             COUNT(*)                           AS transaction_count,
             COALESCE(SUM(s.total), 0)          AS total
        FROM sales s
       WHERE $_effectiveSalesFilter
         AND s.created_at >= ? AND s.created_at <= ?
       GROUP BY customer_uuid
       ORDER BY total DESC
       LIMIT ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(DateTime(from.year, from.month, from.day).toUtc().millisecondsSinceEpoch),
        Variable.withInt(
          DateTime(to.year, to.month, to.day, 23, 59, 59, 999).toUtc().millisecondsSinceEpoch,
        ),
        Variable.withInt(limit),
      ],
    ).get();

    return rows
        .map((QueryRow row) => CustomerRankingRow(
              customerUuid: row.readNullable<String>('customer_uuid'),
              customerName: row.read<String>('customer_name'),
              transactionCount: row.read<int>('transaction_count'),
              total: Money(row.read<int>('total')),
            ))
        .toList(growable: false);
  }

  /// Inventario valorizado (a costo y a precio de venta).
  Future<List<InventoryValuationRow>> inventoryValuation({int limit = 500}) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT uuid, name, sku, stock, min_stock, cost, price
        FROM products
       WHERE deleted_at IS NULL AND is_active = 1
       ORDER BY name
       LIMIT ?;
      ''',
      variables: <Variable<Object>>[Variable.withInt(limit)],
    ).get();

    return rows
        .map((QueryRow row) => InventoryValuationRow(
              productUuid: row.read<String>('uuid'),
              name: row.read<String>('name'),
              sku: row.read<String>('sku'),
              stockMilli: row.read<int>('stock'),
              minStockMilli: row.read<int>('min_stock'),
              cost: Money(row.read<int>('cost')),
              price: Money(row.read<int>('price')),
            ))
        .toList(growable: false);
  }

  /// Ventas crudas para exportación (PDF/CSV) y para la vista de detalle.
  Future<List<Sale>> salesForExport({
    required DateTime from,
    required DateTime to,
    int limit = 5000,
  }) =>
      (select(sales)
            ..where((t) =>
                t.deletedAt.isNull() &
                t.status.equalsValue(SaleStatus.completed) &
                t.createdAt.isBiggerOrEqualValue(
                  DateTime(from.year, from.month, from.day).toUtc(),
                ) &
                t.createdAt.isSmallerOrEqualValue(
                  DateTime(to.year, to.month, to.day, 23, 59, 59, 999).toUtc(),
                ))
            ..orderBy(<OrderingTerm Function($SalesTable)>[
              (t) => OrderingTerm(expression: t.createdAt),
            ])
            ..limit(limit))
          .get();

  /// Líneas de venta proyectadas para exportación (PDF/CSV).
  ///
  /// Se devuelve una proyección ligera y explícita en lugar de entidades de
  /// Drift completas: exportar 20.000 líneas no debe materializar 20.000
  /// objetos pesados ni bloquear la UI.
  Future<List<SaleItemExportRow>> saleItemsForExport({
    required DateTime from,
    required DateTime to,
    int limit = 20000,
  }) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT s.folio                       AS folio,
             s.created_at                  AS created_at,
             s.user_name                   AS user_name,
             s.customer_name               AS customer_name,
             i.product_name                AS product_name,
             i.sku                         AS sku,
             i.quantity                    AS quantity,
             i.unit_price                  AS unit_price,
             i.discount_amount             AS discount_amount,
             i.tax_amount                  AS tax_amount,
             i.line_total                  AS line_total
        FROM sale_items i
        JOIN sales s ON s.id = i.sale_id
       WHERE $_effectiveSalesFilter
         AND i.deleted_at IS NULL
         AND s.created_at >= ? AND s.created_at <= ?
       ORDER BY s.created_at, i.line_number
       LIMIT ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(DateTime(from.year, from.month, from.day).toUtc().millisecondsSinceEpoch),
        Variable.withInt(
          DateTime(to.year, to.month, to.day, 23, 59, 59, 999).toUtc().millisecondsSinceEpoch,
        ),
        Variable.withInt(limit),
      ],
    ).get();

    return rows
        .map((QueryRow row) => (
              folio: row.read<String>('folio'),
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                row.read<int>('created_at'),
                isUtc: true,
              ).toLocal(),
              userName: row.read<String>('user_name'),
              customerName: row.readNullable<String>('customer_name'),
              productName: row.read<String>('product_name'),
              sku: row.read<String>('sku'),
              quantityMilli: row.read<int>('quantity'),
              unitPrice: Money(row.read<int>('unit_price')),
              discount: Money(row.read<int>('discount_amount')),
              tax: Money(row.read<int>('tax_amount')),
              lineTotal: Money(row.read<int>('line_total')),
            ))
        .toList(growable: false);
  }

  /// Rango de un día completo (00:00:00 - 23:59:59.999) en hora local.
  static (DateTime from, DateTime to) dayRange(DateTime day) => (
        DateTime(day.year, day.month, day.day),
        DateTime(day.year, day.month, day.day, 23, 59, 59, 999),
      );

  /// Rango de la semana en curso (lunes a domingo).
  static (DateTime from, DateTime to) weekRange(DateTime day) {
    final DateTime monday = DateTime(day.year, day.month, day.day)
        .subtract(Duration(days: day.weekday - DateTime.monday));
    return (monday, monday.add(const Duration(days: 7)).subtract(const Duration(seconds: 1)));
  }

  /// Rango del mes en curso.
  static (DateTime from, DateTime to) monthRange(DateTime day) => (
        DateTime(day.year, day.month, 1),
        DateTime(day.year, day.month + 1, 1).subtract(const Duration(seconds: 1)),
      );
}

/// Criterio de ordenamiento del ranking de productos.
enum TopProductOrder { revenue, quantity, profit }

/// Proyección ligera de una línea de venta para exportación.
typedef SaleItemExportRow = ({
  String folio,
  DateTime createdAt,
  String userName,
  String? customerName,
  String productName,
  String sku,
  int quantityMilli,
  Money unitPrice,
  Money discount,
  Money tax,
  Money lineTotal,
});
