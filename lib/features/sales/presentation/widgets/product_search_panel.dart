import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/ui/app_widgets.dart';
import '../../../../core/utils/formatters.dart';
import '../../../auth/application/session_controller.dart';
import '../../application/cart_controller.dart';

/// Búsqueda de productos y catálogo rápido.
///
/// Comportamiento esperado por un cajero con lector de códigos:
///  1. Escanea → el producto entra al carrito (sin buscar nada).
///  2. Si no tiene lector, escribe → resultados en vivo (con "debounce").
///  3. Clic en una tarjeta → entra al carrito.
///
/// El campo de búsqueda **nunca** recibe el texto del lector: el detector de
/// hardware consume los códigos y los envía por el flujo [HardwareManager.scans].
class ProductSearchPanel extends ConsumerStatefulWidget {
  const ProductSearchPanel({super.key});

  @override
  ConsumerState<ProductSearchPanel> createState() => _ProductSearchPanelState();
}

class _ProductSearchPanelState extends ConsumerState<ProductSearchPanel> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'product-search');

  Timer? _debounce;
  StreamSubscription<String>? _scanSubscription;
  ProductResults _results = ProductResults.empty;
  String _query = '';
  int? _categoryId;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    // Escucha al lector de códigos en modo "teclado": el hardware entrega el
    // texto cuando detecta la ráfaga de teclas y el terminador (Enter/Tab).
    _scanSubscription =
        ref.read(hardwareManagerProvider).scanner.scans.listen(_onScan);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scanSubscription?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Datos
  // ---------------------------------------------------------------------------

  Future<void> _loadRecent() async {
    final List<Product> products =
        await ref.read(appDatabaseProvider).productsDao.search('', limit: 24);
    if (mounted) setState(() => _results = ProductResults(products));
  }

  Future<void> _runSearch(String term, {int? categoryId}) async {
    final List<Product> products = term.trim().isEmpty
        ? await ref.read(appDatabaseProvider).productsDao.search('', limit: 60)
        : await ref.read(appDatabaseProvider).productsDao.search(term, limit: 60);

    final List<Product> filtered = categoryId == null
        ? products
        : products.where((Product p) => p.categoryId == categoryId).toList(growable: false);

    if (mounted) setState(() => _results = ProductResults(filtered));
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    _debounce = Timer(AppDurations.searchDebounce, () {
      _runSearch(value, categoryId: _categoryId);
    });
  }

  /// Un código escaneado va directo al carrito: cero fricción.
  Future<void> _onScan(String code) async {
    if (!mounted) return;
    try {
      final Product? product =
          await ref.read(cartProvider.notifier).addByCode(code);
      if (product == null) {
        AppSnack.warning(context, 'Código "$code" no encontrado en el catálogo.');
        return;
      }
      _announceAdded(product);
    } on AppFailure catch (failure) {
      AppSnack.warning(context, failure.message);
    }
  }

  Future<void> _addProduct(Product product) async {
    try {
      ref.read(cartProvider.notifier).addProduct(product);
      _announceAdded(product);
    } on AppFailure catch (failure) {
      AppSnack.error(context, failure.message);
    }
  }

  void _announceAdded(Product product) {
    final CurrencyFormat currency = ref.read(currencyFormatProvider);
    AppSnack.success(
      context,
      '${product.name} · ${currency.money(product.price)}'
      '${product.trackStock ? ' · stock ${AppFormat.quantity(product.stock)}' : ''}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Category>> categories = ref.watch(categoriesProvider);
    final CurrencyFormat currency = ref.watch(currencyFormatProvider);

    return AppCard(
      padding: EdgeInsets.zero,
      title: 'Productos',
      subtitle: 'Escanee un código o busque por nombre, SKU o código de barras',
      actions: <Widget>[
        if (_query.isNotEmpty)
          IconButton(
            tooltip: 'Limpiar búsqueda',
            icon: const Icon(Icons.close, size: 17),
            onPressed: () {
              _searchController.clear();
              _onQueryChanged('');
            },
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.xs,
            ),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              autofocus: true,
              onChanged: _onQueryChanged,
              onSubmitted: (String value) async {
                // Enter con un solo resultado: lo agrega sin usar el ratón.
                if (_results.products.length == 1) {
                  await _addProduct(_results.products.first);
                  _searchController.clear();
                  _onQueryChanged('');
                }
              },
              style: AppTypography.body.copyWith(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Nombre, código de barras o SKU…',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: const Padding(
                  padding: EdgeInsets.only(right: AppSpacing.sm),
                  child: Center(
                    widthFactor: 1,
                    child: Text('F2', style: AppTypography.shortcut),
                  ),
                ),
              ),
            ),
          ),
          // Filtro por categoría (chips compactos, desplazables).
          categories.maybeWhen(
            data: (List<Category> list) => list.isEmpty
                ? const SizedBox.shrink()
                : SizedBox(
                    height: 34,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                      children: <Widget>[
                        _CategoryChip(
                          label: 'Todo',
                          color: AppColors.deepBlue,
                          selected: _categoryId == null,
                          onTap: () {
                            setState(() => _categoryId = null);
                            _runSearch(_query);
                          },
                        ),
                        for (final Category category in list)
                          _CategoryChip(
                            label: category.name,
                            color: _colorFromHex(category.colorHex) ?? AppColors.cyan,
                            selected: _categoryId == category.id,
                            onTap: () {
                              setState(() => _categoryId = category.id);
                              _runSearch(_query, categoryId: category.id);
                            },
                          ),
                      ],
                    ),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
          const SizedBox(height: AppSpacing.xs),
          const Divider(height: 1, color: AppColors.divider),
          Expanded(
            child: _results.products.isEmpty
                ? EmptyState(
                    title: _query.isEmpty ? 'Sin productos' : 'Sin resultados',
                    message: _query.isEmpty
                        ? 'Cargue productos desde Inventario para empezar a vender.'
                        : 'No se encontró "$_query". Pruebe con otro nombre o escanee '
                            'el código de barras.',
                    icon: Icons.search_off,
                    action: _query.isEmpty
                        ? null
                        : SecondaryButton(
                            label: 'Limpiar',
                            icon: Icons.close,
                            onPressed: () {
                              _searchController.clear();
                              _onQueryChanged('');
                            },
                          ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 190,
                      mainAxisExtent: 96,
                      crossAxisSpacing: AppSpacing.sm,
                      mainAxisSpacing: AppSpacing.sm,
                    ),
                    itemCount: _results.products.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Product product = _results.products[index];
                      return _ProductTile(
                        product: product,
                        currency: currency,
                        onTap: () => _addProduct(product),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static Color? _colorFromHex(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final String clean = hex.replaceAll('#', '');
    if (clean.length != 6 && clean.length != 8) return null;
    final int? value = int.tryParse(clean, radix: 16);
    if (value == null) return null;
    return Color(clean.length == 6 ? 0xFF000000 | value : value);
  }
}

/// Contenedor inmutable de resultados (evita comparar listas mutables).
@immutable
class ProductResults {
  const ProductResults(this.products);

  final List<Product> products;

  static const ProductResults empty = ProductResults(<Product>[]);
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
        child: Material(
          color: selected ? color : AppColors.grey100,
          borderRadius: AppRadius.pillAll,
          child: InkWell(
            onTap: onTap,
            borderRadius: AppRadius.pillAll,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: 3,
              ),
              child: Text(
                label,
                style: AppTypography.caption.copyWith(
                  color: selected ? AppColors.white : AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
}

/// Tarjeta de producto en la grilla.
class _ProductTile extends StatefulWidget {
  const _ProductTile({
    required this.product,
    required this.currency,
    required this.onTap,
  });

  final Product product;
  final CurrencyFormat currency;
  final VoidCallback onTap;

  @override
  State<_ProductTile> createState() => _ProductTileState();
}

class _ProductTileState extends State<_ProductTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Product product = widget.product;
    final bool lowStock = product.trackStock && product.minStock.isPositive &&
        product.stock <= product.minStock;
    final bool outOfStock = product.trackStock && !product.stock.isPositive;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDurations.instant,
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: _hovered ? AppColors.cyanSurface : AppColors.card,
            borderRadius: AppRadius.mdAll,
            border: Border.all(
              color: outOfStock
                  ? AppColors.red
                  : (lowStock ? AppColors.orange : AppColors.border),
              width: _hovered ? 1.4 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    product.name,
                    style: AppTypography.body.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (product.sku.isNotEmpty)
                    Text(
                      product.sku,
                      style: AppTypography.caption.copyWith(
                        fontSize: 10,
                        color: AppColors.textHint,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.currency.money(product.price),
                      style: AppTypography.tableStrong.copyWith(fontSize: 13),
                    ),
                  ),
                  if (product.trackStock)
                    Text(
                      outOfStock ? 'agotado' : AppFormat.quantity(product.stock),
                      style: AppTypography.caption.copyWith(
                        fontSize: 10,
                        color: outOfStock
                            ? AppColors.red
                            : (lowStock ? AppColors.orange : AppColors.textSecondary),
                        fontWeight: lowStock || outOfStock ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
