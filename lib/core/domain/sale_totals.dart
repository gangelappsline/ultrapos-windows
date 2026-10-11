import 'package:flutter/foundation.dart';

import '../utils/money.dart';

/// Totales calculados de una venta.
///
/// Es un DTO compartido por:
///  * el calculador del carrito (`features/sales/domain/cart_calculator.dart`),
///  * la capa de persistencia (cabecera de la venta),
///  * el generador de tickets, PDF y reportes.
///
/// Al ser un único objeto inmutable, lo que ve el cajero en pantalla, lo que se
/// imprime y lo que se guarda en la base de datos son **exactamente** los
/// mismos números. No hay dos cálculos que puedan divergir por un centavo.
@immutable
class SaleTotals {
  const SaleTotals({
    required this.subtotal,
    required this.discountTotal,
    required this.taxableBase,
    required this.taxTotal,
    required this.total,
    this.paidTotal = Money.zero,
    this.changeTotal = Money.zero,
    this.taxByRate = const <int, Money>{},
    this.itemCount = 0,
    this.quantityMilli = 0,
    this.roundingAdjustment = Money.zero,
  });

  /// Suma de líneas a precio de lista, antes de cualquier descuento.
  final Money subtotal;

  /// Descuento total (líneas + descuento general).
  final Money discountTotal;

  /// Base imponible neta.
  final Money taxableBase;

  /// Impuesto total.
  final Money taxTotal;

  /// Importe final a cobrar.
  final Money total;

  /// Entregado por el cliente.
  final Money paidTotal;

  /// Vuelto.
  final Money changeTotal;

  /// Desglose del impuesto por tasa (bps -> importe), para reportes fiscales
  /// y para imprimir el detalle de impuestos en el ticket.
  final Map<int, Money> taxByRate;

  final int itemCount;

  /// Cantidad total en milésimas (útil para tickets por peso).
  final int quantityMilli;

  /// Ajuste por redondeo final (algunos comercios redondean a la moneda
  /// mínima). Siempre se expone para que sea visible y auditable.
  final Money roundingAdjustment;

  static const SaleTotals zero = SaleTotals(
    subtotal: Money.zero,
    discountTotal: Money.zero,
    taxableBase: Money.zero,
    taxTotal: Money.zero,
    total: Money.zero,
  );

  /// Porcentaje de descuento efectivo sobre el subtotal (basis points).
  int get effectiveDiscountBps {
    if (subtotal.isZero) return 0;
    return MoneyMath.mulDiv(discountTotal.cents, 10000, subtotal.cents);
  }

  bool get isEmpty => itemCount == 0;

  SaleTotals copyWith({
    Money? subtotal,
    Money? discountTotal,
    Money? taxableBase,
    Money? taxTotal,
    Money? total,
    Money? paidTotal,
    Money? changeTotal,
    Map<int, Money>? taxByRate,
    int? itemCount,
    int? quantityMilli,
    Money? roundingAdjustment,
  }) =>
      SaleTotals(
        subtotal: subtotal ?? this.subtotal,
        discountTotal: discountTotal ?? this.discountTotal,
        taxableBase: taxableBase ?? this.taxableBase,
        taxTotal: taxTotal ?? this.taxTotal,
        total: total ?? this.total,
        paidTotal: paidTotal ?? this.paidTotal,
        changeTotal: changeTotal ?? this.changeTotal,
        taxByRate: taxByRate ?? this.taxByRate,
        itemCount: itemCount ?? this.itemCount,
        quantityMilli: quantityMilli ?? this.quantityMilli,
        roundingAdjustment: roundingAdjustment ?? this.roundingAdjustment,
      );

  @override
  String toString() =>
      'SaleTotals(subtotal=$subtotal, descuento=$discountTotal, '
      'base=$taxableBase, impuesto=$taxTotal, total=$total)';
}

/// Resultado de un cobro (lo que devuelve el servicio de venta al POS).
///
/// Incluye el estado de impresión de forma deliberada: la venta **siempre**
/// queda registrada aunque la impresora falle, y el cajero necesita saberlo
/// para reimprimir o entregar el ticket en PDF. La venta y el papel son dos
/// responsabilidades distintas; mezclarlas termina en tickets duplicados.
@immutable
class CheckoutResult {
  const CheckoutResult({
    required this.saleUuid,
    required this.folio,
    required this.totals,
    required this.paidTotal,
    required this.change,
    this.printed = false,
    this.printError,
  });

  final String saleUuid;
  final String folio;
  final SaleTotals totals;

  /// Entregado por el cliente.
  final Money paidTotal;

  /// Vuelto devuelto.
  final Money change;

  /// `true` si el ticket salió correctamente por la impresora.
  final bool printed;

  /// Motivo por el que no se imprimió (la venta ya está registrada).
  final String? printError;

  bool get hasChange => change.isPositive;
}
