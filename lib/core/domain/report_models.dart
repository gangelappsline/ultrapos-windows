import 'package:flutter/foundation.dart';

import '../utils/money.dart';
import 'enums.dart';

/// Modelos de reportes (núcleo compartido).
///
/// Viven en `core/domain` y no dentro de `features/reports` porque los consumen
/// la capa de datos (DAOs), la de reportes y la de exportación (PDF/CSV). Es la
/// única forma de evitar que el DAO dependa de la UI.
library;

/// Resumen de ventas de un rango de fechas.
@immutable
class SalesSummary {
  const SalesSummary({
    required this.from,
    required this.to,
    required this.transactionCount,
    required this.itemCount,
    required this.quantityMilli,
    required this.grossTotal,
    required this.netTotal,
    required this.taxTotal,
    required this.discountTotal,
    required this.costTotal,
    required this.voidCount,
    required this.voidTotal,
    required this.creditTotal,
  });

  final DateTime from;
  final DateTime to;
  final int transactionCount;
  final int itemCount;
  final int quantityMilli;

  /// Suma de los totales de las ventas (lo que pagó el cliente).
  final Money grossTotal;

  /// Suma de bases imponibles netas.
  final Money netTotal;
  final Money taxTotal;
  final Money discountTotal;

  /// Costo de los bienes vendidos.
  final Money costTotal;

  final int voidCount;
  final Money voidTotal;

  /// Importe vendido a crédito (pendiente de cobro).
  final Money creditTotal;

  static SalesSummary empty(DateTime from, DateTime to) => SalesSummary(
        from: from,
        to: to,
        transactionCount: 0,
        itemCount: 0,
        quantityMilli: 0,
        grossTotal: Money.zero,
        netTotal: Money.zero,
        taxTotal: Money.zero,
        discountTotal: Money.zero,
        costTotal: Money.zero,
        voidCount: 0,
        voidTotal: Money.zero,
        creditTotal: Money.zero,
      );

  /// Ticket promedio (evita división por cero).
  Money get averageTicket => transactionCount == 0
      ? Money.zero
      : Money(MoneyMath.mulDiv(grossTotal.cents, 1, transactionCount));

  /// Utilidad bruta estimada.
  Money get grossProfit => netTotal - costTotal;

  /// Margen sobre la venta neta, en basis points.
  int get marginBps => netTotal.isZero ? 0 : MoneyMath.mulDiv(grossProfit.cents, 10000, netTotal.cents);

  /// Unidades vendidas (aproximado, para mostrar).
  double get unitsSold => quantityMilli / 1000;

  bool get isEmpty => transactionCount == 0;
}

/// Punto de una serie temporal (gráficos de ventas).
@immutable
class TimeSeriesPoint {
  const TimeSeriesPoint({
    required this.bucket,
    required this.total,
    required this.count,
    this.label = '',
  });

  /// Inicio del intervalo (día, hora o mes).
  final DateTime bucket;
  final Money total;
  final int count;

  /// Etiqueta ya formateada para el eje X del gráfico.
  final String label;

  TimeSeriesPoint withLabel(String value) =>
      TimeSeriesPoint(bucket: bucket, total: total, count: count, label: value);
}

/// Fila del ranking de productos más vendidos.
@immutable
class TopProductRow {
  const TopProductRow({
    required this.productUuid,
    required this.productName,
    required this.quantityMilli,
    required this.revenue,
    required this.cost,
    required this.lines,
  });

  final String? productUuid;
  final String productName;
  final int quantityMilli;
  final Money revenue;
  final Money cost;
  final int lines;

  Money get profit => revenue - cost;

  int get marginBps => revenue.isZero ? 0 : MoneyMath.mulDiv(profit.cents, 10000, revenue.cents);

  double get unitsSold => quantityMilli / 1000;
}

/// Desglose por método de pago.
@immutable
class PaymentBreakdownRow {
  const PaymentBreakdownRow({
    required this.method,
    required this.amount,
    required this.count,
  });

  final PaymentMethod method;
  final Money amount;
  final int count;

  int shareBps(Money total) =>
      total.isZero ? 0 : MoneyMath.mulDiv(amount.cents, 10000, total.cents);
}

/// Ventas por categoría.
@immutable
class CategorySalesRow {
  const CategorySalesRow({
    required this.categoryId,
    required this.categoryName,
    required this.revenue,
    required this.quantityMilli,
  });

  final int? categoryId;
  final String categoryName;
  final Money revenue;
  final int quantityMilli;
}

/// Productividad por cajero.
@immutable
class CashierPerformanceRow {
  const CashierPerformanceRow({
    required this.userName,
    required this.transactionCount,
    required this.total,
    required this.discountTotal,
    required this.voidCount,
  });

  final String userName;
  final int transactionCount;
  final Money total;
  final Money discountTotal;
  final int voidCount;

  Money get averageTicket => transactionCount == 0
      ? Money.zero
      : Money(MoneyMath.mulDiv(total.cents, 1, transactionCount));
}

/// Ranking de clientes por consumo.
@immutable
class CustomerRankingRow {
  const CustomerRankingRow({
    required this.customerUuid,
    required this.customerName,
    required this.transactionCount,
    required this.total,
  });

  final String? customerUuid;
  final String customerName;
  final int transactionCount;
  final Money total;
}

/// Fila del reporte de inventario valorizado.
@immutable
class InventoryValuationRow {
  const InventoryValuationRow({
    required this.productUuid,
    required this.name,
    required this.sku,
    required this.stockMilli,
    required this.minStockMilli,
    required this.cost,
    required this.price,
  });

  final String productUuid;
  final String name;
  final String sku;
  final int stockMilli;
  final int minStockMilli;
  final Money cost;
  final Money price;

  bool get isLowStock => minStockMilli > 0 && stockMilli <= minStockMilli;
  bool get isNegative => stockMilli < 0;

  Money get costValue => Money(MoneyMath.mulDiv(cost.cents, stockMilli, 1000));
  Money get retailValue => Money(MoneyMath.mulDiv(price.cents, stockMilli, 1000));

  double get units => stockMilli / 1000;
}

/// Fila de la tabla "¿cuándo vendo más?" (día de la semana + franja horaria).
@immutable
class WeekdayHourSalesRow {
  const WeekdayHourSalesRow({
    required this.weekday,
    required this.hour,
    required this.total,
    required this.count,
  });

  /// 0 = domingo ... 6 = sábado (igual que `DateTime.weekday % 7`).
  final int weekday;
  final int hour;
  final Money total;
  final int count;
}
