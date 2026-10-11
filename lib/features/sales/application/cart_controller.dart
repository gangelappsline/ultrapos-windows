import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/providers.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/utils/money.dart';
import '../domain/cart.dart';

/// Carrito de la venta en curso (estado global de la aplicación).
final cartProvider = NotifierProvider<CartController, Cart>(CartController.new);

/// Totales calculados del carrito, derivados una sola vez por cambio.
///
/// La interfaz **nunca** calcula importes: los lee de aquí. Así el panel de
/// totales, el ticket y la venta guardada son siempre el mismo número.
final cartComputationProvider = Provider<CartComputation>((Ref ref) {
  final Cart cart = ref.watch(cartProvider);
  final OperationSettings rules =
      ref.watch(operationSettingsProvider).value ?? OperationSettings.defaults;
  return CartCalculator.computeDetailed(
    cart,
    taxIncludedInPrice: rules.includedInPrice,
  );
});

/// Solo los totales (atajo muy usado por los widgets).
final cartTotalsProvider = Provider(
  (Ref ref) => ref.watch(cartComputationProvider).totals,
);

/// Operaciones sobre el carrito.
class CartController extends Notifier<Cart> {
  @override
  Cart build() => Cart.empty;

  AppDatabase get _database => ref.read(appDatabaseProvider);

  // ---------------------------------------------------------------------------
  // Contenido
  // ---------------------------------------------------------------------------

  /// Agrega un producto al carrito (o suma cantidad si ya está y es "simple").
  CartLine addProduct(Product product, {Quantity? quantity, String? note}) {
    if (!product.isActive) {
      throw BusinessRuleFailure(
        message: 'El producto "${product.name}" está desactivado.',
        rule: 'inactive_product',
      );
    }

    final Quantity amount = quantity ??
        Quantity(product.sellByWeight ? 0 : Quantity.unitsPerWhole);
    if (amount.milli < 0) {
      throw const ValidationFailure(message: 'La cantidad no puede ser negativa.');
    }

    // Los productos a granel o con descuento/nota nunca se fusionan: cada
    // pesada y cada ajuste es una línea propia, igual que en un ticket real.
    final int existingIndex = product.sellByWeight || note != null
        ? -1
        : _indexOfSimpleLine(product.id);
    if (existingIndex >= 0) {
      final CartLine existing = state.lines[existingIndex];
      _updateLine(
        existing.lineId,
        (CartLine line) => line.copyWith(quantity: line.quantity + amount),
      );
      return state.lines[existingIndex];
    }

    final CartLine line = CartLine(
      lineId: IdGenerator.lineId(),
      productId: product.id,
      productUuid: product.uuid,
      name: product.name,
      sku: product.sku,
      barcode: product.barcode,
      unitPrice: product.price,
      unitCost: product.cost,
      quantity: amount,
      taxRateBps: product.taxRateBps,
      trackStock: product.trackStock,
      isWeighted: product.sellByWeight,
      note: note,
    );

    state = state.copyWith(
      lines: <CartLine>[...state.lines, line],
      startedAt: state.startedAt ?? DateTime.now(),
    );
    return line;
  }

  /// Agrega por código de barras o SKU (lector, o búsqueda manual).
  Future<Product?> addByCode(String code, {Quantity? quantity}) async {
    final String clean = code.trim();
    if (clean.isEmpty) return null;

    Product? product = await _database.productsDao.findByBarcode(clean);
    product ??= await _database.productsDao.findBySku(clean);
    if (product == null) return null;

    addProduct(product, quantity: quantity);
    return product;
  }

  void setQuantity(String lineId, Quantity quantity) {
    if (quantity.isNegative) {
      throw const ValidationFailure(message: 'La cantidad no puede ser negativa.');
    }
    if (quantity.isZero) {
      removeLine(lineId);
      return;
    }
    _updateLine(lineId, (CartLine line) => line.copyWith(quantity: quantity));
  }

  void increment(String lineId, {Quantity step = const Quantity(Quantity.unitsPerWhole)}) {
    _updateLine(
      lineId,
      (CartLine line) => line.copyWith(quantity: line.quantity + step),
    );
  }

  void decrement(String lineId, {Quantity step = const Quantity(Quantity.unitsPerWhole)}) {
    final CartLine? line = _line(lineId);
    if (line == null) return;
    final Quantity next = line.quantity - step;
    if (!next.isPositive) {
      removeLine(lineId);
      return;
    }
    _updateLine(lineId, (CartLine current) => current.copyWith(quantity: next));
  }

  void removeLine(String lineId) {
    state = state.copyWith(
      lines: state.lines.where((CartLine line) => line.lineId != lineId).toList(growable: false),
    );
  }

  // ---------------------------------------------------------------------------
  // Precios, descuentos y notas
  // ---------------------------------------------------------------------------

  /// Aplica un descuento a una línea (porcentaje y/o monto fijo).
  void applyLineDiscount(String lineId, {int bps = 0, Money amount = Money.zero}) {
    if (bps < 0 || amount.isNegative) {
      throw const ValidationFailure(message: 'El descuento no puede ser negativo.');
    }
    if (bps > 10000) {
      throw const ValidationFailure(message: 'El descuento no puede superar el 100 %.');
    }
    _updateLine(
      lineId,
      (CartLine line) => line.copyWith(discountBps: bps, discountAmount: amount),
    );
  }

  /// Cambia el precio de una línea (venta a granel, precio negociado).
  void overrideLinePrice(String lineId, Money price) {
    if (price.isNegative) {
      throw const ValidationFailure(message: 'El precio no puede ser negativo.');
    }
    _updateLine(lineId, (CartLine line) => line.copyWith(unitPrice: price));
  }

  void setLineNote(String lineId, String? note) {
    _updateLine(
      lineId,
      (CartLine line) => line.copyWith(note: (note ?? '').trim().isEmpty ? null : note!.trim()),
    );
  }

  /// Descuento general de la venta (porcentaje y/o monto fijo).
  void applyOrderDiscount({int bps = 0, Money amount = Money.zero}) {
    if (bps < 0 || amount.isNegative) {
      throw const ValidationFailure(message: 'El descuento no puede ser negativo.');
    }
    if (bps > 10000) {
      throw const ValidationFailure(message: 'El descuento no puede superar el 100 %.');
    }
    state = state.copyWith(orderDiscountBps: bps, orderDiscountAmount: amount);
  }

  void clearOrderDiscount() => state = state.copyWith(clearOrderDiscount: true);

  void setCustomer(Customer? customer) {
    if (customer == null) {
      state = state.copyWith(clearCustomer: true);
      return;
    }
    state = state.copyWith(
      customerId: customer.id,
      customerUuid: customer.uuid,
      customerName: customer.name,
      customerDiscountBps: customer.discountBps,
    );
  }

  void setNote(String? note) {
    final String? clean = (note ?? '').trim().isEmpty ? null : note!.trim();
    state = state.copyWith(note: clean);
  }

  void setOrderLabel(String? label) {
    final String? clean = (label ?? '').trim().isEmpty ? null : label!.trim();
    state = state.copyWith(orderLabel: clean);
  }

  // ---------------------------------------------------------------------------
  // Ciclo de vida
  // ---------------------------------------------------------------------------

  void clear() => state = Cart.empty;

  void restore(Cart cart) => state = cart;

  /// Recupera un pedido en espera conservando su uuid (se actualizará, no se
  /// duplicará, si el cajero vuelve a guardarlo).
  Future<void> loadHeldOrder(SaleDetails details) async {
    final List<CartLine> lines = <CartLine>[];
    for (final SaleItem item in details.items) {
      final Product? product = item.productUuid == null
          ? null
          : await _database.productsDao.findByUuid(item.productUuid!);
      lines.add(
        CartLine(
          lineId: IdGenerator.lineId(),
          productId: product?.id ?? item.productId,
          productUuid: item.productUuid,
          name: item.productName,
          sku: item.sku,
          barcode: item.barcode,
          unitPrice: item.unitPrice,
          unitCost: item.unitCost,
          quantity: item.quantity,
          taxRateBps: item.taxRateBps,
          trackStock: product?.trackStock ?? true,
          isWeighted: product?.sellByWeight ?? false,
          note: item.note,
        ),
      );
    }

    state = Cart(
      lines: lines,
      customerId: details.sale.customerId,
      customerUuid: details.sale.customerUuid,
      customerName: details.sale.customerName,
      note: details.sale.note,
      orderLabel: details.sale.orderLabel,
      heldSaleUuid: details.sale.uuid,
      startedAt: details.sale.createdAt,
    );
  }

  // ---------------------------------------------------------------------------
  // Internos
  // ---------------------------------------------------------------------------

  CartLine? _line(String lineId) {
    for (final CartLine line in state.lines) {
      if (line.lineId == lineId) return line;
    }
    return null;
  }

  int _indexOfSimpleLine(int? productId) {
    if (productId == null) return -1;
    for (int i = 0; i < state.lines.length; i++) {
      final CartLine line = state.lines[i];
      if (line.productId == productId &&
          !line.isWeighted &&
          line.discountBps == 0 &&
          line.discountAmount.isZero &&
          line.note == null) {
        return i;
      }
    }
    return -1;
  }

  void _updateLine(String lineId, CartLine Function(CartLine line) transform) {
    bool changed = false;
    final List<CartLine> lines = state.lines.map((CartLine line) {
      if (line.lineId != lineId) return line;
      changed = true;
      return transform(line);
    }).toList(growable: false);

    if (changed) state = state.copyWith(lines: lines);
  }
}
