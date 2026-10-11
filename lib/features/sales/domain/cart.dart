import 'package:flutter/foundation.dart';

import '../../../core/domain/enums.dart';
import '../../../core/domain/sale_totals.dart';
import '../../../core/database/app_database.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/utils/money.dart';

/// Línea del carrito.
///
/// Guarda una **copia** de los datos del producto (nombre, precio, costo,
/// impuesto) en el momento de agregarlo: si el precio cambia mientras la venta
/// está en curso, el cliente paga el precio que se le mostró. El `productId` es
/// solo la referencia para descontar inventario.
@immutable
class CartLine {
  const CartLine({
    required this.lineId,
    required this.name,
    this.productId,
    this.productUuid,
    this.sku = '',
    this.barcode = '',
    required this.unitPrice,
    this.unitCost = Money.zero,
    required this.quantity,
    this.discountBps = 0,
    this.discountAmount = Money.zero,
    this.taxRateBps = 0,
    this.trackStock = true,
    this.isWeighted = false,
    this.note,
  });

  /// Identificador estable dentro del carrito (no es el id del producto):
  /// el mismo producto puede aparecer en dos líneas con precios distintos.
  final String lineId;

  final int? productId;
  final String? productUuid;
  final String name;
  final String sku;
  final String barcode;

  final Money unitPrice;
  final Money unitCost;
  final Quantity quantity;

  /// Descuento porcentual de la línea (basis points).
  final int discountBps;

  /// Descuento fijo de la línea (centavos).
  final Money discountAmount;

  final int taxRateBps;
  final bool trackStock;
  final bool isWeighted;
  final String? note;

  /// Importe bruto antes de descuentos (precio × cantidad).
  Money get gross => unitPrice.priceFor(quantity);

  /// Descuento aplicado a esta línea (porcentaje + monto fijo), nunca mayor
  /// que el importe bruto.
  Money get discountTotal {
    final Money percent = MoneyMath.applyBps(gross, discountBps);
    final Money total = percent + discountAmount;
    return total > gross ? gross : total;
  }

  /// Importe de la línea antes del descuento general de la venta.
  Money get netBeforeOrderDiscount => gross - discountTotal;

  CartLine copyWith({
    int? productId,
    String? productUuid,
    String? name,
    String? sku,
    String? barcode,
    Money? unitPrice,
    Money? unitCost,
    Quantity? quantity,
    int? discountBps,
    Money? discountAmount,
    int? taxRateBps,
    bool? trackStock,
    bool? isWeighted,
    Object? note = _absent,
  }) =>
      CartLine(
        lineId: lineId,
        productId: productId ?? this.productId,
        productUuid: productUuid ?? this.productUuid,
        name: name ?? this.name,
        sku: sku ?? this.sku,
        barcode: barcode ?? this.barcode,
        unitPrice: unitPrice ?? this.unitPrice,
        unitCost: unitCost ?? this.unitCost,
        quantity: quantity ?? this.quantity,
        discountBps: discountBps ?? this.discountBps,
        discountAmount: discountAmount ?? this.discountAmount,
        taxRateBps: taxRateBps ?? this.taxRateBps,
        trackStock: trackStock ?? this.trackStock,
        isWeighted: isWeighted ?? this.isWeighted,
        note: note == _absent ? this.note : note as String?,
      );

  @override
  String get description => '$quantity x $unitPrice';
}

/// Carrito de la venta en curso.
///
/// Es **inmutable** y vive en memoria: la venta no toca la base de datos hasta
/// que se cobra (o se guarda en espera). Así, cancelar una venta no deja basura
/// ni consume folios, y el cajero puede experimentar sin miedo.
@immutable
class Cart {
  const Cart({
    this.lines = const <CartLine>[],
    this.customerId,
    this.customerUuid,
    this.customerName,
    this.customerDiscountBps = 0,
    this.orderDiscountBps = 0,
    this.orderDiscountAmount = Money.zero,
    this.note,
    this.orderLabel,
    this.heldSaleUuid,
    this.startedAt,
  });

  static const Cart empty = Cart();

  final List<CartLine> lines;

  final int? customerId;
  final String? customerUuid;
  final String? customerName;

  /// Descuento permanente del cliente seleccionado (no se suma al general:
  /// se aplica el mayor de los dos para evitar promociones acumuladas).
  final int customerDiscountBps;

  final int orderDiscountBps;
  final Money orderDiscountAmount;

  final String? note;
  final String? orderLabel;

  /// Si la venta se recuperó de un pedido en espera, conserva su uuid para
  /// actualizarlo en lugar de crear una venta nueva.
  final String? heldSaleUuid;

  final DateTime? startedAt;

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
  bool get hasCustomer => customerId != null;

  int get itemCount => lines.length;

  /// Total de artículos en milésimas de unidad (soporta peso y unidades).
  int get totalQuantityMilli => lines.fold(
        0,
        (int sum, CartLine line) => sum + line.quantity.milli,
      );

  bool get hasDiscount => orderDiscountBps > 0 ||
      !orderDiscountAmount.isZero ||
      lines.any((CartLine line) =>
          line.discountBps > 0 || !line.discountAmount.isZero);

  List<String> get unknownCodes =>
      lines.where((CartLine line) => line.productId == null).map((CartLine l) => l.name).toList();

  Cart copyWith({
    List<CartLine>? lines,
    int? customerId,
    String? customerUuid,
    String? customerName,
    int? customerDiscountBps,
    int? orderDiscountBps,
    Money? orderDiscountAmount,
    Object? note = _absent,
    Object? orderLabel = _absent,
    Object? heldSaleUuid = _absent,
    DateTime? startedAt,
    bool clearCustomer = false,
    bool clearOrderDiscount = false,
  }) =>
      Cart(
        lines: lines ?? this.lines,
        customerId: clearCustomer ? null : (customerId ?? this.customerId),
        customerUuid: clearCustomer ? null : (customerUuid ?? this.customerUuid),
        customerName: clearCustomer ? null : (customerName ?? this.customerName),
        customerDiscountBps:
            clearCustomer ? 0 : (customerDiscountBps ?? this.customerDiscountBps),
        orderDiscountBps: clearOrderDiscount ? 0 : (orderDiscountBps ?? this.orderDiscountBps),
        orderDiscountAmount:
            clearOrderDiscount ? Money.zero : (orderDiscountAmount ?? this.orderDiscountAmount),
        note: note == _absent ? this.note : note as String?,
        orderLabel: orderLabel == _absent ? this.orderLabel : orderLabel as String?,
        heldSaleUuid: heldSaleUuid == _absent ? this.heldSaleUuid : heldSaleUuid as String?,
        startedAt: startedAt ?? this.startedAt,
      );
}

/// Cálculo monetario del carrito.
///
/// Es la **única** fuente de verdad de los importes: la pantalla, el ticket y
/// la venta persistida usan el mismo resultado. Un POS que calcula totales en
/// dos sitios distintos acaba mostrando un importe al cliente y guardando otro.
///
/// Reglas aplicadas (y por qué):
///   * Se redondea **una vez por línea** y luego se suman las líneas. Así el
///     total no cambia si se parte una cantidad en dos líneas iguales.
///   * Descuento de cliente y descuento general **no se acumulan**: se aplica el
///     mayor. Acumularlos permite que dos descuentos pequeños sumen un precio
///     regalado por error.
///   * El descuento general se reparte proporcionalmente al importe de cada
///     línea, y el residuo del redondeo va a la línea mayor: la suma de las
///     líneas siempre coincide exactamente con el total cobrado.
abstract final class CartCalculator {
  /// Calcula los totales del carrito.
  ///
  /// [taxIncludedInPrice] `true` cuando el precio de lista ya lleva el impuesto
  /// (práctica habitual en comercio minorista de LatAm).
  static SaleTotals compute(
    Cart cart, {
    required bool taxIncludedInPrice,
  }) =>
      computeDetailed(cart, taxIncludedInPrice: taxIncludedInPrice).totals;

  /// Calcula totales **y** el desglose por línea.
  static CartComputation computeDetailed(
    Cart cart, {
    required bool taxIncludedInPrice,
  }) {
    if (cart.isEmpty) {
      return const CartComputation(totals: SaleTotals.zero, lines: <LineTotals>[]);
    }

    // 1) Importes por línea antes del descuento general.
    final List<_WorkingLine> working = <_WorkingLine>[];
    for (final CartLine line in cart.lines) {
      final Money gross = line.gross;
      final Money discount = line.discountTotal;
      working.add(
        _WorkingLine(
          line: line,
          gross: gross,
          discount: discount,
          base: gross - discount,
        ),
      );
    }

    // 2) Descuento general sobre la base ya descontada por línea.
    final int effectiveOrderBps = cart.customerDiscountBps > cart.orderDiscountBps
        ? cart.customerDiscountBps
        : cart.orderDiscountBps;
    final Money baseTotal = working.fold(
      Money.zero,
      (Money sum, _WorkingLine item) => sum + item.base,
    );
    final Money orderDiscount = _resolveOrderDiscount(
      cart: cart,
      baseTotal: baseTotal,
      effectiveBps: effectiveOrderBps,
    );
    final List<Money> shares = _distributeProportionally(
      total: orderDiscount,
      weights: working.map((_WorkingLine item) => item.base.cents).toList(growable: false),
    );

    // 3) Impuestos y totales.
    final Map<int, Money> taxByRate = <int, Money>{};
    final List<LineTotals> lineTotals = <LineTotals>[];
    Money subtotal = Money.zero;
    Money discountTotal = Money.zero;
    Money taxableBase = Money.zero;
    Money taxTotal = Money.zero;
    Money total = Money.zero;

    for (int i = 0; i < working.length; i++) {
      final _WorkingLine item = working[i];
      final Money afterOrder = item.base - shares[i];
      // La tasa de la línea es la del producto en el momento de agregarlo:
      // 0 = exento (nunca se "adivina" el impuesto al cobrar).
      final int rateBps = item.line.taxRateBps;

      final Money lineTax;
      final Money lineTotal;
      if (taxIncludedInPrice) {
        lineTax = MoneyMath.extractBps(afterOrder, rateBps);
        lineTotal = afterOrder;
      } else {
        lineTax = MoneyMath.applyBps(afterOrder, rateBps);
        lineTotal = afterOrder + lineTax;
      }
      final Money lineNet = taxIncludedInPrice ? afterOrder - lineTax : afterOrder;

      subtotal += item.gross;
      discountTotal += item.discount + shares[i];
      taxableBase += lineNet;
      taxTotal += lineTax;
      total += lineTotal;

      if (rateBps > 0 && !lineTax.isZero) {
        taxByRate[rateBps] = (taxByRate[rateBps] ?? Money.zero) + lineTax;
      }

      lineTotals.add(
        LineTotals(
          lineId: item.line.lineId,
          productId: item.line.productId,
          productUuid: item.line.productUuid,
          productName: item.line.name,
          sku: item.line.sku,
          barcode: item.line.barcode,
          quantity: item.line.quantity,
          unitPrice: item.line.unitPrice,
          unitCost: item.line.unitCost,
          gross: item.gross,
          discount: item.discount + shares[i],
          net: lineNet,
          tax: lineTax,
          total: lineTotal,
          taxRateBps: rateBps,
          isExempt: rateBps == 0,
        ),
      );
    }

    final SaleTotals totals = SaleTotals(
      subtotal: subtotal,
      discountTotal: discountTotal,
      taxableBase: taxableBase,
      taxTotal: taxTotal,
      total: total,
      itemCount: cart.itemCount,
      quantityMilli: cart.totalQuantityMilli,
      taxByRate: taxByRate,
    );

    return CartComputation(totals: totals, lines: lineTotals);
  }

  /// Descuento general efectivo: el mayor entre el del cliente y el general,
  /// limitado al importe de la venta.
  static Money _resolveOrderDiscount({
    required Cart cart,
    required Money baseTotal,
    required int effectiveBps,
  }) {
    final Money percent = MoneyMath.applyBps(baseTotal, effectiveBps);
    final Money fixed = cart.orderDiscountAmount;
    final Money result = fixed > percent ? fixed : percent;
    return result > baseTotal ? baseTotal : result;
  }

  /// Reparte [total] proporcionalmente a [weights] repartiendo el residuo.
  ///
  /// La suma del resultado es **exactamente** [total] (propiedad verificada en
  /// `test/unit/cart_calculator_test.dart`).
  static List<Money> _distributeProportionally({
    required Money total,
    required List<int> weights,
  }) {
    if (total.isZero || weights.isEmpty) {
      return List<Money>.filled(weights.length, Money.zero);
    }
    final int weightSum = weights.fold(0, (int sum, int w) => sum + w);
    if (weightSum <= 0) {
      // Sin base que repartir: todo el descuento va a la primera línea.
      return List<Money>.generate(
        weights.length,
        (int index) => index == 0 ? total : Money.zero,
      );
    }

    final List<Money> shares = weights
        .map((int weight) => Money(MoneyMath.mulDiv(total.cents, weight, weightSum)))
        .toList(growable: true);
    int assigned = shares.fold(0, (int sum, Money value) => sum + value.cents);
    int remainder = total.cents - assigned;

    // El residuo del redondeo se asigna a las líneas de mayor peso para que
    // ninguna quede negativa ni con un descuento desproporcionado.
    if (remainder != 0) {
      final List<int> order = List<int>.generate(weights.length, (int i) => i)
        ..sort((int a, int b) => weights[b].compareTo(weights[a]));
      int cursor = 0;
      while (remainder != 0 && cursor < order.length * weights.length) {
        final int index = order[cursor % order.length];
        final int step = remainder > 0 ? 1 : -1;
        if (step < 0 && shares[index].cents == 0) {
          cursor++;
          continue;
        }
        shares[index] = Money(shares[index].cents + step);
        remainder -= step;
        cursor++;
      }
    }
    return shares;
  }
}

/// Línea en proceso de cálculo.
class _WorkingLine {
  _WorkingLine({
    required this.line,
    required this.gross,
    required this.discount,
    required this.base,
  });

  final CartLine line;
  final Money gross;
  final Money discount;
  final Money base;
}

/// Desglose calculado de una línea (lo que se persiste en la venta).
@immutable
class LineTotals {
  const LineTotals({
    required this.lineId,
    required this.productId,
    required this.productUuid,
    required this.productName,
    required this.sku,
    required this.barcode,
    required this.quantity,
    required this.unitPrice,
    required this.unitCost,
    required this.gross,
    required this.discount,
    required this.net,
    required this.tax,
    required this.total,
    required this.taxRateBps,
    required this.isExempt,
  });

  final String lineId;
  final int? productId;
  final String? productUuid;
  final String productName;
  final String sku;
  final String barcode;
  final Quantity quantity;
  final Money unitPrice;
  final Money unitCost;
  final Money gross;
  final Money discount;
  final Money net;
  final Money tax;
  final Money total;
  final int taxRateBps;
  final bool isExempt;
}

/// Resultado completo del cálculo del carrito.
@immutable
class CartComputation {
  const CartComputation({required this.totals, required this.lines});

  final SaleTotals totals;
  final List<LineTotals> lines;

  /// Desglose de una línea concreta (por su identificador de carrito).
  LineTotals? forLine(String lineId) {
    for (final LineTotals line in lines) {
      if (line.lineId == lineId) return line;
    }
    return null;
  }
}

/// Pago recibido (una entrada por forma de pago en pagos mixtos).
@immutable
class PaymentRequest {
  const PaymentRequest({
    required this.method,
    required this.amount,
    this.reference,
    this.last4,
  });

  final PaymentMethod method;
  final Money amount;

  /// Referencia de la transacción (voucher, número de transferencia).
  final String? reference;

  /// Últimos 4 dígitos de la tarjeta (recibo del cliente).
  final String? last4;

  Map<String, Object?> toJson() => <String, Object?>{
        'method': method.storageKey,
        'amount_cents': amount.cents,
        if (reference != null) 'reference': reference,
        if (last4 != null) 'last4': last4,
      };
}

/// Validación de los pagos contra el total de la venta.
@immutable
class PaymentValidation {
  const PaymentValidation({
    required this.isValid,
    required this.paidTotal,
    required this.change,
    required this.message,
    this.requiresCustomer = false,
  });

  final bool isValid;
  final Money paidTotal;
  final Money change;
  final String? message;

  /// El cobro exige un cliente registrado (venta a crédito).
  final bool requiresCustomer;

  static const PaymentValidation pending = PaymentValidation(
    isValid: false,
    paidTotal: Money.zero,
    change: Money.zero,
    message: 'Falta cubrir el total de la venta.',
  );
}

/// Reglas de pago de una venta.
///
/// Se validan **antes** de tocar la base de datos: es mejor decirle al cajero
/// "faltan 25.00" que dejar una venta a medio cobrar.
abstract final class PaymentValidator {
  static PaymentValidation validate({
    required SaleTotals totals,
    required List<PaymentRequest> payments,
    required bool hasCustomer,
    bool allowCredit = true,
  }) {
    final Money paid = payments.fold(
      Money.zero,
      (Money sum, PaymentRequest payment) => sum + payment.amount,
    );

    if (payments.isEmpty) {
      return PaymentValidation(
        isValid: false,
        paidTotal: Money.zero,
        change: Money.zero,
        message: 'Registre al menos una forma de pago.',
      );
    }
    if (payments.any((PaymentRequest p) => !p.amount.isPositive)) {
      return PaymentValidation(
        isValid: false,
        paidTotal: paid,
        change: Money.zero,
        message: 'Hay un pago con importe cero o negativo.',
      );
    }

    final bool hasCredit = payments.any((PaymentRequest p) => p.method == PaymentMethod.credit);
    if (hasCredit && !allowCredit) {
      return PaymentValidation(
        isValid: false,
        paidTotal: paid,
        change: Money.zero,
        message: 'Las ventas a crédito están desactivadas en Configuración.',
      );
    }
    if (hasCredit && !hasCustomer) {
      return PaymentValidation(
        isValid: false,
        paidTotal: paid,
        change: Money.zero,
        message: 'Para fiar la venta debe seleccionar un cliente registrado.',
        requiresCustomer: true,
      );
    }

    final Money cash = payments
        .where((PaymentRequest p) => p.method.affectsCashDrawer)
        .fold(Money.zero, (Money sum, PaymentRequest p) => sum + p.amount);
    final Money nonCash = paid - cash;

    // Los pagos que no son efectivo nunca pueden exceder el total: no existe
    // "vuelto" en una tarjeta.
    if (nonCash > totals.total) {
      return PaymentValidation(
        isValid: false,
        paidTotal: paid,
        change: Money.zero,
        message: 'Los pagos que no son en efectivo superan el total de la venta.',
      );
    }

    final Money change = paid > totals.total ? paid - totals.total : Money.zero;
    if (change > cash) {
      return PaymentValidation(
        isValid: false,
        paidTotal: paid,
        change: Money.zero,
        message: 'El vuelto no puede superar el efectivo recibido.',
      );
    }

    if (paid < totals.total) {
      final Money missing = totals.total - paid;
      return PaymentValidation(
        isValid: false,
        paidTotal: paid,
        change: Money.zero,
        message: 'Faltan ${missing.cents / 100} por cubrir.',
      );
    }

    return PaymentValidation(
      isValid: true,
      paidTotal: paid,
      change: change,
      message: null,
    );
  }
}

/// Marca de "parámetro no informado" (distingue `null` de "sin cambios").
const Object _absent = Object();

/// Validaciones de negocio del carrito que requieren el catálogo.
abstract final class CartValidator {
  /// Comprueba el stock disponible de la línea.
  ///
  /// Se ejecuta al cobrar (no al agregar): en un POS de mostrador es normal
  /// escanear más unidades que el stock registrado y decidir al final. Avisar
  /// demasiado pronto obliga al cajero a lidiar con diálogos que no vienen al
  /// caso. Devuelve `null` si la línea puede venderse.
  static AppFailure? checkStock({required CartLine line, required Product? product}) {
    if (product == null || !product.trackStock || !line.trackStock) return null;
    if (product.stock >= line.quantity) return null;
    return BusinessRuleFailure(
      message: 'Stock insuficiente de "${product.name}": hay '
          '${product.stock}, se intentan vender ${line.quantity}.',
      rule: 'insufficient_stock',
      technicalDetail: 'available_milli=${product.stock.milli} '
          'requested_milli=${line.quantity.milli}',
    );
  }
}
