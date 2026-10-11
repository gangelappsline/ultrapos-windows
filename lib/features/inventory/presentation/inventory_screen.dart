import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/products_dao.dart';
import '../../../core/domain/enums.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/ui/app_widgets.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/money.dart';
import '../../auth/application/session_controller.dart';
import '../application/product_filter_controller.dart';
import 'widgets/category_manager_dialog.dart';
import 'widgets/product_form_dialog.dart';
import 'widgets/stock_movement_dialog.dart';

/// Módulo de inventario.
///
/// Tabla densa con búsqueda instantánea, filtros por categoría/estado y las
/// tres operaciones que realmente se hacen en un mostrador:
///   * **Editar** el producto (precio, costo, mínimo, categoría).
///   * **Mover stock** (entrada de mercancía, merma, conteo físico).
///   * **Desactivar** (nunca borrar: los históricos de venta deben seguir
///     cuadrando; un producto borrado rompería reportes de meses anteriores).
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  final TextEditingController _search = TextEditingController();
  Product? _selected;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      ref.read(productFilterProvider.notifier).setSearch(_search.text);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ProductFilter filter = ref.watch(productFilterProvider);
    final AsyncValue<List<Product>> products =
        ref.watch(_productsForFilterProvider(filter));
    final CurrencyFormat currency = ref.watch(currencyFormatProvider);
    final bool canManage = ref.watch(sessionProvider).role.canManageInventory;

    return Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        children: <Widget>[
          ModuleHeader(
            title: 'Inventario',
            subtitle: 'Catálogo, existencias y movimientos de mercancía',
            actions: <Widget>[
              SecondaryButton(
                label: 'Categorías',
                icon: Icons.category_outlined,
                onPressed: canManage ? () => _openCategories() : null,
              ),
              const SizedBox(width: AppSpacing.sm),
              SecondaryButton(
                label: 'Movimiento',
                icon: Icons.swap_vert,
                onPressed: _selected == null || !canManage
                    ? null
                    : () => _openStockDialog(_selected!),
              ),
              const SizedBox(width: AppSpacing.sm),
              PrimaryButton(
                label: 'Nuevo producto',
                icon: Icons.add,
                shortcut: 'F9',
                onPressed: canManage ? () => _openProductForm(null) : null,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _FilterBar(search: _search, filter: filter),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: products.when(
              data: (List<Product> list) => AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    _InventoryHeaderRow(canManage: canManage),
                    Expanded(
                      child: list.isEmpty
                          ? EmptyState(
                              title: filter.isEmpty
                                  ? 'El catálogo está vacío'
                                  : 'Sin resultados',
                              message: filter.isEmpty
                                  ? 'Cree su primer producto para comenzar a vender. '
                                      'Puede importar la lista completa más adelante.'
                                  : 'Ningún producto coincide con los filtros aplicados.',
                              icon: Icons.inventory_2_outlined,
                              action: filter.isEmpty && canManage
                                  ? PrimaryButton(
                                      label: 'Crear producto',
                                      icon: Icons.add,
                                      onPressed: () => _openProductForm(null),
                                    )
                                  : null,
                            )
                          : ListView.builder(
                              itemCount: list.length,
                              itemBuilder: (BuildContext context, int index) {
                                final Product product = list[index];
                                return _InventoryRow(
                                  product: product,
                                  currency: currency,
                                  selected: _selected?.id == product.id,
                                  canManage: canManage,
                                  onTap: () => setState(() => _selected = product),
                                  onEdit: () => _openProductForm(product),
                                  onStock: () => _openStockDialog(product),
                                  onToggleActive: () => _toggleActive(product),
                                );
                              },
                            ),
                    ),
                    _InventoryTotals(products: list, currency: currency),
                  ],
                ),
              ),
              error: (Object error, _) => ErrorState(message: '$error'),
              loading: () => const LoadingState(message: 'Cargando catálogo…'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openProductForm(Product? product) async {
    final bool? saved = await ProductFormDialog.show(context, product: product);
    if (saved ?? false) {
      ref.invalidate(_productsForFilterProvider);
      AppSnack.success(
        context,
        product == null ? 'Producto creado.' : 'Producto actualizado.',
      );
    }
  }

  Future<void> _openStockDialog(Product product) async {
    final bool? saved = await StockMovementDialog.show(context, product: product);
    if (saved ?? false) {
      ref.invalidate(_productsForFilterProvider);
      AppSnack.success(context, 'Movimiento registrado para "${product.name}".');
    }
  }

  Future<void> _openCategories() async {
    await CategoryManagerDialog.show(context);
    ref.invalidate(categoriesProvider);
  }

  Future<void> _toggleActive(Product product) async {
    final bool deactivate = product.isActive;
    final bool confirmed = await ConfirmDialog.show(
      context,
      title: deactivate ? 'Desactivar producto' : 'Reactivar producto',
      message: deactivate
          ? '"${product.name}" dejará de aparecer en la pantalla de venta. '
              'No se borra: las ventas históricas siguen quedando intactas.'
          : '"${product.name}" volverá a estar disponible para vender.',
      confirmLabel: deactivate ? 'Desactivar' : 'Reactivar',
      destructive: deactivate,
    );
    if (!confirmed || !mounted) return;

    try {
      final User? user = ref.read(currentUserProvider);
      await ref.read(appDatabaseProvider).productsDao.updateProduct(
            product: product,
            isActive: !deactivate,
            auditNote: deactivate
                ? 'Desactivado por ${user?.fullName ?? 'sistema'}'
                : 'Reactivado por ${user?.fullName ?? 'sistema'}',
          );
      ref.invalidate(_productsForFilterProvider);
      if (mounted) {
        AppSnack.success(context, deactivate ? 'Producto desactivado.' : 'Producto reactivado.');
      }
    } on AppFailure catch (failure) {
      if (mounted) AppSnack.error(context, failure.message);
    }
  }
}

/// Proveedor derivado del filtro actual de la tabla.
final _productsForFilterProvider = StreamProvider.family<List<Product>, ProductFilter>(
  (Ref ref, ProductFilter filter) =>
      ref.watch(appDatabaseProvider).productsDao.watchFiltered(filter),
);

/// Barra de filtros: búsqueda, categoría, estado y alertas de stock.
class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.search, required this.filter});

  final TextEditingController search;
  final ProductFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Category>> categories = ref.watch(categoriesProvider);

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 320,
            child: TextField(
              controller: search,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Buscar por nombre, SKU o código de barras…',
                prefixIcon: Icon(Icons.search, size: 17),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          categories.maybeWhen(
            data: (List<Category> list) => SizedBox(
              width: 220,
              child: DropdownButtonFormField<int?>(
                initialValue: filter.categoryId,
                isDense: true,
                decoration: const InputDecoration(labelText: 'Categoría'),
                items: <DropdownMenuItem<int?>>[
                  const DropdownMenuItem<int?>(value: null, child: Text('Todas')),
                  for (final Category category in list)
                    DropdownMenuItem<int?>(
                      value: category.id,
                      child: Text(category.name),
                    ),
                ],
                onChanged: (int? value) =>
                    ref.read(productFilterProvider.notifier).setCategory(value),
              ),
            ),
            orElse: () => const SizedBox(width: 220),
          ),
          const SizedBox(width: AppSpacing.sm),
          _FilterToggle(
            label: 'Stock bajo',
            icon: Icons.warning_amber_outlined,
            color: AppColors.orange,
            value: filter.onlyLowStock,
            onChanged: (bool value) =>
                ref.read(productFilterProvider.notifier).setLowStockOnly(value),
          ),
          _FilterToggle(
            label: 'Agotados',
            icon: Icons.remove_shopping_cart_outlined,
            color: AppColors.red,
            value: filter.onlyOutOfStock,
            onChanged: (bool value) =>
                ref.read(productFilterProvider.notifier).setOutOfStockOnly(value),
          ),
          _FilterToggle(
            label: 'Inactivos',
            icon: Icons.visibility_off_outlined,
            color: AppColors.grey500,
            value: filter.includeInactive,
            onChanged: (bool value) =>
                ref.read(productFilterProvider.notifier).setIncludeInactive(value),
          ),
          const Spacer(),
          if (!filter.isEmpty)
            SecondaryButton(
              label: 'Limpiar',
              icon: Icons.filter_alt_off_outlined,
              textOnly: true,
              onPressed: () {
                search.clear();
                ref.read(productFilterProvider.notifier).reset();
              },
            ),
        ],
      ),
    );
  }
}

class _FilterToggle extends StatelessWidget {
  const _FilterToggle({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: AppSpacing.sm),
        child: FilterChip(
          selected: value,
          onSelected: onChanged,
          avatar: Icon(icon, size: 15, color: value ? AppColors.white : color),
          label: Text(label),
          labelStyle: AppTypography.caption.copyWith(
            color: value ? AppColors.white : AppColors.textPrimary,
            fontWeight: value ? FontWeight.w600 : FontWeight.w400,
          ),
          selectedColor: color,
          backgroundColor: AppColors.grey50,
          side: BorderSide(color: value ? color : AppColors.border),
          showCheckmark: false,
        ),
      );
}

/// Encabezado de la tabla de productos.
class _InventoryHeaderRow extends StatelessWidget {
  const _InventoryHeaderRow({required this.canManage});

  final bool canManage;

  @override
  Widget build(BuildContext context) => Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: const BoxDecoration(
          color: AppColors.grey50,
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: <Widget>[
            const Expanded(flex: 4, child: Text('Producto', style: AppTypography.label)),
            const SizedBox(width: 110, child: Text('SKU', style: AppTypography.label)),
            const SizedBox(width: 110, child: Text('Categoría', style: AppTypography.label)),
            const SizedBox(
              width: 90,
              child: Text('Costo', style: AppTypography.label, textAlign: TextAlign.right),
            ),
            const SizedBox(
              width: 90,
              child: Text('Precio', style: AppTypography.label, textAlign: TextAlign.right),
            ),
            const SizedBox(
              width: 100,
              child: Text('Stock', style: AppTypography.label, textAlign: TextAlign.right),
            ),
            const SizedBox(
              width: 110,
              child: Text('Margen', style: AppTypography.label, textAlign: TextAlign.right),
            ),
            const SizedBox(width: 96),
          ],
        ),
      );
}

/// Fila de producto.
class _InventoryRow extends ConsumerWidget {
  const _InventoryRow({
    required this.product,
    required this.currency,
    required this.selected,
    required this.canManage,
    required this.onTap,
    required this.onEdit,
    required this.onStock,
    required this.onToggleActive,
  });

  final Product product;
  final CurrencyFormat currency;
  final bool selected;
  final bool canManage;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onStock;
  final VoidCallback onToggleActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool lowStock = product.trackStock &&
        !product.minStock.isZero &&
        product.stock <= product.minStock;
    final bool outOfStock = product.trackStock && !product.stock.isPositive;

    return FutureBuilder<String>(
      future: product.categoryId == null
          ? Future<String>.value('—')
          : ref
              .read(appDatabaseProvider)
              .productsDao
              .categoryById(product.categoryId!)
              .then((Category? category) => category?.name ?? '—'),
      builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
        final String categoryName = snapshot.data ?? '…';
        return DataRowTile(
          onTap: onTap,
          selected: selected,
          cells: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 6,
                  height: 22,
                  margin: const EdgeInsets.only(right: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: !product.isActive
                        ? AppColors.grey300
                        : (outOfStock
                            ? AppColors.red
                            : (lowStock ? AppColors.orange : AppColors.cyan)),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        product.name,
                        style: AppTypography.body.copyWith(fontSize: 12.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (product.barcode.isNotEmpty)
                        Text(
                          product.barcode,
                          style: AppTypography.caption.copyWith(
                            fontSize: 10,
                            color: AppColors.textHint,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(
              width: 110,
              child: Text(product.sku.isEmpty ? '—' : product.sku,
                  style: AppTypography.caption),
            ),
            SizedBox(
              width: 110,
              child: Text(
                categoryName,
                style: AppTypography.caption,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: 90,
              child: Text(
                currency.formatCents(product.cost.cents, withSymbol: false),
                textAlign: TextAlign.right,
                style: AppTypography.table.copyWith(fontSize: 12),
              ),
            ),
            SizedBox(
              width: 90,
              child: Text(
                currency.formatCents(product.price.cents, withSymbol: false),
                textAlign: TextAlign.right,
                style: AppTypography.tableStrong.copyWith(fontSize: 12.5),
              ),
            ),
            SizedBox(
              width: 100,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    product.trackStock ? AppFormat.quantity(product.stock) : '∞',
                    style: AppTypography.tableStrong.copyWith(
                      fontSize: 12.5,
                      color: outOfStock
                          ? AppColors.red
                          : (lowStock ? AppColors.orange : AppColors.textPrimary),
                    ),
                  ),
                  if (product.trackStock && !product.minStock.isZero)
                    Text(
                      'mín ${AppFormat.quantity(product.minStock)}',
                      style: AppTypography.caption.copyWith(
                        fontSize: 9.5,
                        color: AppColors.textHint,
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: 110,
              child: Text(
                _margin(product, currency),
                textAlign: TextAlign.right,
                style: AppTypography.caption.copyWith(fontSize: 11.5),
              ),
            ),
            SizedBox(
              width: 96,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (canManage) ...<Widget>[
                    IconButton(
                      tooltip: 'Mover stock',
                      iconSize: 15,
                      visualDensity: VisualDensity.compact,
                      onPressed: onStock,
                      icon: const Icon(Icons.swap_vert, color: AppColors.cyanDark),
                    ),
                    IconButton(
                      tooltip: 'Editar',
                      iconSize: 15,
                      visualDensity: VisualDensity.compact,
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, color: AppColors.deepBlue),
                    ),
                    IconButton(
                      tooltip: product.isActive ? 'Desactivar' : 'Reactivar',
                      iconSize: 15,
                      visualDensity: VisualDensity.compact,
                      onPressed: onToggleActive,
                      icon: Icon(
                        product.isActive
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: AppColors.grey400,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Margen sobre precio de venta (lo que realmente gana el negocio).
  String _margin(Product product, CurrencyFormat currency) {
    if (!product.price.isPositive) return '—';
    final Money margin = product.price - product.cost;
    final int bps = MoneyMath.mulDiv(margin.cents, 10000, product.price.cents);
    return '${currency.money(margin)} · ${AppFormat.percent(bps)}';
  }
}

/// Resumen del inventario filtrado (valor a costo y a precio de venta).
class _InventoryTotals extends StatelessWidget {
  const _InventoryTotals({required this.products, required this.currency});

  final List<Product> products;
  final CurrencyFormat currency;

  @override
  Widget build(BuildContext context) {
    Money cost = Money.zero;
    Money retail = Money.zero;
    for (final Product product in products) {
      if (!product.trackStock) continue;
      cost = cost + Money(MoneyMath.mulDiv(product.cost.cents, product.stock.milli, 1000));
      retail =
          retail + Money(MoneyMath.mulDiv(product.price.cents, product.stock.milli, 1000));
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: const BoxDecoration(
        color: AppColors.grey50,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            '${products.length} producto(s)',
            style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Text('Valor a costo: ', style: AppTypography.caption),
          Text(currency.money(cost), style: AppTypography.tableStrong.copyWith(fontSize: 12)),
          const SizedBox(width: AppSpacing.md),
          Text('Valor a venta: ', style: AppTypography.caption),
          Text(
            currency.money(retail),
            style: AppTypography.tableStrong.copyWith(fontSize: 12, color: AppColors.deepBlue),
          ),
          const SizedBox(width: AppSpacing.md),
          Text('Margen potencial: ', style: AppTypography.caption),
          Text(
            currency.money(retail - cost),
            style: AppTypography.tableStrong.copyWith(fontSize: 12, color: AppColors.success),
          ),
        ],
      ),
    );
  }
}

/// Copia del texto al portapapeles (usado por los diálogos de inventario).
Future<void> copyToClipboard(BuildContext context, String text, String label) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) AppSnack.info(context, '$label copiado al portapapeles.');
}
