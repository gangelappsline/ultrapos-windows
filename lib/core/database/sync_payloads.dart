import '../domain/enums.dart';
import 'app_database.dart';

/// Construcción de los **payloads de sincronización**.
///
/// Este archivo es el contrato entre la caja y la nube. Reglas:
///
///  1. Los payloads se construyen **desde la fila ya persistida**, dentro de la
///     misma transacción que la escritura de negocio. Nunca desde el objeto que
///     se "iba a guardar": si la base de datos normaliza algo (un default, un
///     redondeo), la nube debe recibir exactamente lo que quedó guardado.
///  2. Los campos **locales** (`id` autoincremental) nunca viajan. La identidad
///     global es `uuid`.
///  3. El dinero viaja como **centavos enteros** (`*_cents`) y las cantidades
///     como **milésimas** (`quantity_milli`). Un float jamás cruza la red.
///  4. Los enums viajan por `storageKey` (texto estable), no por ordinal.
///  5. El payload es un *snapshot completo*: el servidor aplica el estado final
///     sin necesidad de entender deltas.
///
/// Cualquier cambio aquí es un cambio de contrato: debe acompañarse de la
/// versión del API y de la prueba correspondiente.
abstract final class SyncPayloads {
  /// Payload de una venta: cabecera + líneas + pagos en un solo agregado.
  ///
  /// Se envía como un bloque porque el servidor debe insertar el ticket
  /// completo de forma atómica; un ticket sin líneas no sirve para nada.
  static Map<String, Object?> sale({
    required Sale sale,
    required List<SaleItem> items,
    required List<SalePayment> payments,
  }) =>
      <String, Object?>{
        'uuid': sale.uuid,
        'folio': sale.folio,
        'folio_prefix': sale.folioPrefix,
        'folio_number': sale.folioNumber,
        'status': sale.status.storageKey,
        'customer_uuid': sale.customerUuid,
        'customer_name': sale.customerName,
        'user_uuid': sale.userUuid,
        'user_name': sale.userName,
        'cash_session_uuid': sale.cashSessionUuid,
        'subtotal_cents': sale.subtotal.cents,
        'discount_total_cents': sale.discountTotal.cents,
        'taxable_base_cents': sale.taxableBase.cents,
        'tax_total_cents': sale.taxTotal.cents,
        'total_cents': sale.total.cents,
        'paid_total_cents': sale.paidTotal.cents,
        'change_total_cents': sale.changeTotal.cents,
        'cost_total_cents': sale.costTotal.cents,
        'is_mixed_payment': sale.isMixedPayment,
        'is_credit_sale': sale.isCreditSale,
        'item_count': sale.itemCount,
        'note': sale.note,
        'order_label': sale.orderLabel,
        'printed': sale.printed,
        'created_at': sale.createdAt.toUtc().toIso8601String(),
        'updated_at': sale.updatedAt.toUtc().toIso8601String(),
        'device_id': sale.deviceId,
        'items': items.map(_saleItem).toList(growable: false),
        'payments': payments.map(_salePayment).toList(growable: false),
      };

  static Map<String, Object?> _saleItem(SaleItem item) => <String, Object?>{
        'uuid': item.uuid,
        'line_number': item.lineNumber,
        'product_uuid': item.productUuid,
        'product_name': item.productName,
        'sku': item.sku,
        'barcode': item.barcode,
        'quantity_milli': item.quantity.milli,
        'unit_price_cents': item.unitPrice.cents,
        'unit_cost_cents': item.unitCost.cents,
        'discount_bps': item.discountBps,
        'discount_amount_cents': item.discountAmount.cents,
        'tax_rate_bps': item.taxRateBps,
        'net_total_cents': item.netTotal.cents,
        'tax_amount_cents': item.taxAmount.cents,
        'line_total_cents': item.lineTotal.cents,
        'is_exempt': item.isExempt,
      };

  static Map<String, Object?> _salePayment(SalePayment payment) => <String, Object?>{
        'uuid': payment.uuid,
        'method': payment.method.storageKey,
        'amount_cents': payment.amount.cents,
        'change_given_cents': payment.changeGiven.cents,
        'reference': payment.reference,
        'card_last4': payment.cardLast4,
      };

  /// Payload de un producto (catálogo: el servidor lo recibe y también lo
  /// difunde al resto de cajas).
  static Map<String, Object?> product(Product product, {String? categoryUuid}) =>
      <String, Object?>{
        'uuid': product.uuid,
        'sku': product.sku,
        'barcode': product.barcode,
        'name': product.name,
        'description': product.description,
        'category_uuid': categoryUuid,
        'unit': product.unit.storageKey,
        'price_cents': product.price.cents,
        'cost_cents': product.cost.cents,
        'tax_rate_bps': product.taxRateBps,
        'stock_milli': product.stock.milli,
        'min_stock_milli': product.minStock.milli,
        'track_stock': product.trackStock,
        'sell_by_weight': product.sellByWeight,
        'is_favorite': product.isFavorite,
        'is_active': product.isActive,
        'image_path': product.imagePath,
        'created_at': product.createdAt.toUtc().toIso8601String(),
        'updated_at': product.updatedAt.toUtc().toIso8601String(),
        'deleted_at': product.deletedAt?.toUtc().toIso8601String(),
        'sync_version': product.syncVersion,
        'device_id': product.deviceId,
      };

  static Map<String, Object?> category(Category category) => <String, Object?>{
        'uuid': category.uuid,
        'name': category.name,
        'color_hex': category.colorHex,
        'icon_name': category.iconName,
        'sort_order': category.sortOrder,
        'is_active': category.isActive,
        'created_at': category.createdAt.toUtc().toIso8601String(),
        'updated_at': category.updatedAt.toUtc().toIso8601String(),
        'deleted_at': category.deletedAt?.toUtc().toIso8601String(),
        'sync_version': category.syncVersion,
        'device_id': category.deviceId,
      };

  static Map<String, Object?> customer(Customer customer) => <String, Object?>{
        'uuid': customer.uuid,
        'name': customer.name,
        'tax_id': customer.taxId,
        'phone': customer.phone,
        'email': customer.email,
        'address': customer.address,
        'credit_limit_cents': customer.creditLimit.cents,
        'balance_cents': customer.balance.cents,
        'loyalty_points': customer.loyaltyPoints,
        'discount_bps': customer.discountBps,
        'notes': customer.notes,
        'is_active': customer.isActive,
        'last_purchase_at': customer.lastPurchaseAt?.toUtc().toIso8601String(),
        'created_at': customer.createdAt.toUtc().toIso8601String(),
        'updated_at': customer.updatedAt.toUtc().toIso8601String(),
        'deleted_at': customer.deletedAt?.toUtc().toIso8601String(),
        'sync_version': customer.syncVersion,
        'device_id': customer.deviceId,
      };

  /// El PIN **nunca** se sincroniza: la credencial vive solo en el equipo.
  /// La nube recibe identidad, rol y estado.
  static Map<String, Object?> user(User user) => <String, Object?>{
        'uuid': user.uuid,
        'username': user.username,
        'full_name': user.fullName,
        'role': user.role.storageKey,
        'employee_code': user.employeeCode,
        'is_active': user.isActive,
        'max_discount_bps': user.maxDiscountBps,
        'last_login_at': user.lastLoginAt?.toUtc().toIso8601String(),
        'created_at': user.createdAt.toUtc().toIso8601String(),
        'updated_at': user.updatedAt.toUtc().toIso8601String(),
        'deleted_at': user.deletedAt?.toUtc().toIso8601String(),
        'sync_version': user.syncVersion,
        'device_id': user.deviceId,
      };

  static Map<String, Object?> stockMovement(StockMovement movement) => <String, Object?>{
        'uuid': movement.uuid,
        'product_uuid': movement.productUuid,
        'product_name': movement.productName,
        'type': movement.type.storageKey,
        'quantity_milli': movement.quantity.milli,
        'previous_stock_milli': movement.previousStock.milli,
        'new_stock_milli': movement.newStock.milli,
        'unit_cost_cents': movement.unitCost?.cents,
        'reason': movement.reason,
        'reference_uuid': movement.referenceUuid,
        'reference_type': movement.referenceType,
        'user_uuid': movement.userId,
        'user_name': movement.userName,
        'created_at': movement.createdAt.toUtc().toIso8601String(),
        'device_id': movement.deviceId,
      };

  static Map<String, Object?> cashSession(CashSession session) => <String, Object?>{
        'uuid': session.uuid,
        'status': session.status.storageKey,
        'opened_by_uuid': session.openedByUuid,
        'opened_by_name': session.openedByName,
        'closed_by_uuid': session.closedByUuid,
        'closed_by_name': session.closedByName,
        'opening_amount_cents': session.openingAmount.cents,
        'counted_cash_cents': session.countedCash?.cents,
        'expected_cash_cents': session.expectedCash?.cents,
        'difference_cents': session.difference?.cents,
        'sales_count': session.salesCount,
        'total_sales_cents': session.totalSales.cents,
        'total_cash_cents': session.totalCash.cents,
        'total_card_cents': session.totalCard.cents,
        'total_transfer_cents': session.totalTransfer.cents,
        'total_credit_cents': session.totalCredit.cents,
        'total_other_cents': session.totalOther.cents,
        'total_tax_cents': session.totalTax.cents,
        'total_discount_cents': session.totalDiscount.cents,
        'total_voids_cents': session.totalVoids.cents,
        'void_count': session.voidCount,
        'total_deposits_cents': session.totalDeposits.cents,
        'total_withdrawals_cents': session.totalWithdrawals.cents,
        'ticket_average_cents': session.ticketAverage?.cents,
        'open_note': session.openNote,
        'close_note': session.closeNote,
        'cash_count_json': session.cashCountJson,
        'opened_at': session.openedAt.toUtc().toIso8601String(),
        'closed_at': session.closedAt?.toUtc().toIso8601String(),
        'device_id': session.deviceId,
        'created_at': session.createdAt.toUtc().toIso8601String(),
        'updated_at': session.updatedAt.toUtc().toIso8601String(),
      };

  static Map<String, Object?> cashMovement(CashMovement movement) => <String, Object?>{
        'uuid': movement.uuid,
        'session_uuid': movement.sessionUuid,
        'type': movement.type.storageKey,
        'amount_cents': movement.amount.cents,
        'reason': movement.reason,
        'category': movement.category,
        'reference': movement.reference,
        'user_uuid': movement.userId,
        'user_name': movement.userName,
        'created_at': movement.createdAt.toUtc().toIso8601String(),
        'device_id': movement.deviceId,
      };

  static Map<String, Object?> setting(AppSetting setting) => <String, Object?>{
        'key': setting.key,
        'value': setting.value,
        'updated_at': setting.updatedAt.toUtc().toIso8601String(),
        'sync_to_cloud': setting.syncToCloud,
      };

  static Map<String, Object?> company(CompanyProfile profile) => <String, Object?>{
        'legal_name': profile.legalName,
        'tax_id': profile.taxId,
        'address': profile.address,
        'phone': profile.phone,
        'email': profile.email,
        'currency_code': profile.currencyCode,
        'currency_symbol': profile.currencySymbol,
        'default_tax_rate_bps': profile.defaultTaxRateBps,
        'tax_included_in_price': profile.taxIncludedInPrice,
        'tax_label': profile.taxLabel,
        'receipt_header': profile.receiptHeader,
        'receipt_footer': profile.receiptFooter,
        'timezone': profile.timezone,
        'updated_at': profile.updatedAt.toUtc().toIso8601String(),
      };
}
