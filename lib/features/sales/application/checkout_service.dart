import 'package:flutter/foundation.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/sales_dao.dart';
import '../../../core/domain/enums.dart';
import '../../../core/domain/sale_totals.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/hardware/hardware_manager.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/utils/money.dart';
import '../domain/cart.dart';

/// Resultado del cobro: lo que la interfaz necesita para informar al cajero.
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
  final Money paidTotal;

  /// Vuelto entregado al cliente.
  final Money change;

  /// `true` si el ticket salió por la impresora.
  final bool printed;

  /// Motivo por el que no se imprimió (la venta **ya está** guardada).
  final String? printError;

  bool get hasChange => change.isPositive;

  String get headline => 'Venta $folio registrada';
}

/// Cobro de una venta.
///
/// Este servicio concentra la operación más delicada del sistema. Todo lo que
/// debe ser consistente ocurre en **una sola transacción** de SQLite:
///
///   1. Comprobación de stock de cada línea (con las reglas del negocio).
///   2. Cabecera de la venta con folio reservado de forma atómica.
///   3. Líneas con precio, costo e impuesto **congelados**.
///   4. Pagos con su vuelto.
///   5. Descuento de inventario y kardex.
///   6. Cliente (última compra, saldo a crédito).
///   7. Encolado de la venta completa en el outbox de sincronización.
///   8. Auditoría.
///
/// Fuera de la transacción, y por tanto sin poder tumbarla, quedan la impresión
/// del ticket y la apertura del cajón: el hardware es un accesorio del cobro, no
/// un requisito para que el cobro exista.
class CheckoutService {
  CheckoutService({required this.database, required this.hardware});

  final AppDatabase database;
  final HardwareManager hardware;

  static const String _scope = 'checkout';

  Future<CheckoutResult> checkout({
    required Cart cart,
    required CartComputation computation,
    required List<PaymentRequest> payments,
    required User user,
    required CompanyProfile company,
    CashSession? cashSession,
    bool allowCredit = true,
    bool requireOpenSession = true,
    bool printTicket = true,
    bool openDrawer = true,
  }) async {
    if (cart.isEmpty) {
      throw const BusinessRuleFailure(
        message: 'No hay productos en la venta.',
        rule: 'empty_cart',
      );
    }

    final SaleTotals totals = computation.totals;
    final PaymentValidation validation = PaymentValidator.validate(
      totals: totals,
      payments: payments,
      hasCustomer: cart.hasCustomer,
      allowCredit: allowCredit,
    );
    if (!validation.isValid) {
      throw ValidationFailure(
        message: validation.message ?? 'Los pagos no cuadran con el total.',
      );
    }

    final bool paysCash =
        payments.any((PaymentRequest p) => p.method.affectsCashDrawer);
    if (requireOpenSession && paysCash && cashSession == null) {
      throw const BusinessRuleFailure(
        message: 'Debe abrir un turno de caja antes de cobrar en efectivo.',
        rule: 'cash_session_required',
      );
    }

    final Money creditAmount = payments
        .where((PaymentRequest p) => p.method == PaymentMethod.credit)
        .fold(Money.zero, (Money sum, PaymentRequest p) => sum + p.amount);

    // El folio se numera por equipo (prefijo configurado), no por usuario: dos
    // cajeros en la misma caja deben compartir una única serie consecutiva.
    final String folioPrefix =
        (await database.settingsDao.device())?.folioPrefix ?? 'A';

    final SaleInsertRequest request = buildSaleRequest(
      cart: cart,
      computation: computation,
      user: user,
      cashSession: cashSession,
      payments: payments,
      folioPrefix: folioPrefix,
    );

    // Los totales que se guardan en la cabecera incluyen lo cobrado y el
    // vuelto: el reporte de caja debe poder reconstruirse sin recalcular.
    final SaleTotals stored = totals.copyWith(
      paidTotal: validation.paidTotal,
      changeTotal: validation.change,
    );

    late Sale sale;
    late List<SaleItem> items;
    late List<SalePayment> paymentRows;

    await database.transaction<void>(() async {
      // 0) Un pedido en espera recuperado se convierte en esta venta: se
      //    elimina el borrador para no dejar dos documentos del mismo pedido.
      if (cart.heldSaleUuid != null) {
        final SaleDetails? held = await database.salesDao.detailsFor(cart.heldSaleUuid!);
        if (held != null) {
          await database.salesDao.deleteHeldOrder(held.sale);
        }
      }

      // 1) Stock: se comprueba TODO antes de escribir nada. Un fallo a mitad de
      //    la venta obligaría a explicarle al cliente por qué faltaba lo último.
      final Map<int, Product> products = <int, Product>{};
      for (final CartLine line in computation.lines) {
        final int? productId = line.productId;
        if (productId == null) continue;
        final Product? product = await database.productsDao.findById(productId);
        if (product == null) continue;
        final AppFailure? stockFailure = CartValidator.checkStock(
          line: cart.lines.firstWhere((CartLine l) => l.lineId == line.lineId),
          product: product,
        );
        if (stockFailure != null) throw stockFailure;
        products[productId] = product;
      }

      // 2) Cabecera.
      sale = await database.salesDao.insertSale(request: request, totals: stored);

      // 3) Líneas + inventario.
      items = <SaleItem>[];
      for (final LineTotals line in computation.lines) {
        final SaleItem inserted = await database.salesDao.insertItem(
          saleId: sale.id,
          saleUuid: sale.uuid,
          item: SaleItemRequest(
            lineNumber: items.length + 1,
            productId: line.productId,
            productUuid: line.productUuid,
            productName: line.productName,
            sku: line.sku,
            barcode: line.barcode,
            quantity: line.quantity,
            unitPrice: line.unitPrice,
            unitCost: line.unitCost,
            discountBps: _lineOf(cart, line.lineId).discountBps,
            discountAmount: line.discount,
            taxRateBps: line.taxRateBps,
            netTotal: line.net,
            taxAmount: line.tax,
            lineTotal: line.total,
            isExempt: line.isExempt,
          ),
        );
        items.add(inserted);

        final Product? product =
            line.productId == null ? null : products[line.productId];
        if (product != null && product.trackStock) {
          await database.inventoryDao.applySaleMovement(
            product: product,
            quantity: line.quantity,
            saleUuid: sale.uuid,
            userName: user.fullName,
          );
        }
      }

      // 4) Pagos.
      paymentRows = <SalePayment>[];
      for (final PaymentRequest payment in payments) {
        // El vuelto se imputa al efectivo (es el único que lo genera).
        final Money changeForThisPayment = payment.method.affectsCashDrawer
            ? validation.change
            : Money.zero;
        paymentRows.add(
          await database.salesDao.insertPayment(
            saleId: sale.id,
            saleUuid: sale.uuid,
            payment: SalePaymentRequest(
              method: payment.method,
              amount: payment.amount,
              changeGiven: changeForThisPayment,
              reference: payment.reference,
              cardLast4: payment.last4,
            ),
          ),
        );
      }

      // 5) Cliente.
      if (cart.customerUuid != null) {
        await database.customersDao.touchLastPurchase(
          cart.customerUuid!,
          sale.createdAt,
        );
        if (creditAmount.isPositive) {
          final Customer? customer =
              await database.customersDao.findByUuid(cart.customerUuid!);
          if (customer != null) {
            await database.customersDao.applyCreditBalance(
              customer: customer,
              amount: creditAmount,
            );
          }
        }
      }

      // 6) Sincronización (agregado completo, idempotente por uuid).
      await database.salesDao.enqueueSaleAggregate(
        sale: sale,
        items: items,
        payments: paymentRows,
      );

      // 7) Auditoría.
      await database.recordAudit(
        entity: 'sale',
        entityUuid: sale.uuid,
        action: 'checkout',
        userId: user.uuid,
        userName: user.fullName,
        after: <String, Object?>{
          'folio': sale.folio,
          'total_cents': stored.total.cents,
          'paid_cents': stored.paidTotal.cents,
          'change_cents': stored.changeTotal.cents,
          'items': items.length,
          'methods': payments.map((PaymentRequest p) => p.method.storageKey).toList(),
          if (cashSession != null) 'cash_session': cashSession.uuid,
        },
        note: 'Cobro en ${payments.length} pago(s)',
      );
    });

    Log.info(_scope, 'Venta ${sale.folio} cobrada', data: <String, Object?>{
      'total': stored.total.cents,
      'pagos': payments.length,
      'cliente': cart.customerName ?? 'Consumidor Final',
    });

    // --- Post-venta: hardware y notificación -------------------------------
    bool printed = false;
    String? printError;

    if (printTicket) {
      final HardwareReport report = await hardware.printSaleTicket(
        details: (sale: sale, items: items, payments: paymentRows),
        company: company,
        openDrawer: openDrawer,
      );
      printed = report.success;
      printError = report.success ? null : report.message;
      if (report.success) {
        await database.salesDao.markPrinted(sale.uuid);
      } else {
        Log.warning(_scope, 'Venta ${sale.folio} sin imprimir: ${report.message}');
      }
    } else if (openDrawer) {
      // Sin ticket igualmente se abre el cajón: el efectivo entra al cajón.
      await hardware.openCashDrawer();
    }

    return CheckoutResult(
      saleUuid: sale.uuid,
      folio: sale.folio,
      totals: stored,
      paidTotal: stored.paidTotal,
      change: stored.changeTotal,
      printed: printed,
      printError: printError,
    );
  }

  /// Convierte el carrito en la solicitud que entiende `SalesDao`.
  /// Construye la cabecera de venta a partir del carrito calculado.
  ///
  /// Es el **único** punto donde un carrito se convierte en una fila de venta:
  /// lo usan el cobro y el "pedido en espera" (F4), de modo que un pedido
  /// guardado y luego cobrado se registra exactamente igual.
  static SaleInsertRequest buildSaleRequest({
    required Cart cart,
    required CartComputation computation,
    required User user,
    required String folioPrefix,
    List<PaymentRequest> payments = const <PaymentRequest>[],
    CashSession? cashSession,
    SaleStatus status = SaleStatus.completed,
    String? orderLabel,
  }) {
    final List<SaleItemRequest> items = <SaleItemRequest>[];
    for (int i = 0; i < computation.lines.length; i++) {
      final LineTotals line = computation.lines[i];
      final CartLine source = _lineOf(cart, line.lineId);
      items.add(
        SaleItemRequest(
          lineNumber: i + 1,
          productId: line.productId,
          productUuid: line.productUuid,
          productName: line.productName,
          sku: line.sku,
          barcode: line.barcode,
          quantity: line.quantity,
          unitPrice: line.unitPrice,
          unitCost: line.unitCost,
          discountBps: source.discountBps,
          discountAmount: line.discount,
          taxRateBps: line.taxRateBps,
          netTotal: line.net,
          taxAmount: line.tax,
          lineTotal: line.total,
          isExempt: line.isExempt,
        ),
      );
    }

    final Money costTotal = computation.lines.fold(
      Money.zero,
      (Money sum, LineTotals line) => sum + line.quantity.priceFor(line.unitCost),
    );

    return SaleInsertRequest(
      folioPrefix: folioPrefix,
      status: status,
      userId: user.id,
      userUuid: user.uuid,
      userName: user.fullName,
      items: items,
      payments: payments
          .map(
            (PaymentRequest p) => SalePaymentRequest(
              method: p.method,
              amount: p.amount,
              changeGiven: Money.zero,
              reference: p.reference,
              cardLast4: p.last4,
            ),
          )
          .toList(growable: false),
      customerId: cart.customerId,
      customerUuid: cart.customerUuid,
      customerName: cart.customerName,
      cashSessionId: cashSession?.id,
      cashSessionUuid: cashSession?.uuid,
      note: cart.note,
      orderLabel: orderLabel ?? cart.orderLabel,
      costTotal: costTotal,
    );
  }

  static CartLine _lineOf(Cart cart, String lineId) => cart.lines.firstWhere(
        (CartLine line) => line.lineId == lineId,
        orElse: () => cart.lines.first,
      );
}
