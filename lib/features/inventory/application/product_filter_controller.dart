import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/daos/products_dao.dart';

/// Filtro activo de la tabla de inventario.
///
/// Vive en Riverpod (y no en el `State` del widget) porque la pantalla de
/// inventario se reconstruye al cambiar de módulo y el cajero espera encontrar
/// la lista tal como la dejó: filtro, categoría y búsqueda incluidos.
class ProductFilterController extends Notifier<ProductFilter> {
  @override
  ProductFilter build() => const ProductFilter();

  void setSearch(String value) {
    final String clean = value.trim();
    state = clean.isEmpty
        ? state.copyWith(clearSearch: true)
        : state.copyWith(search: clean);
  }

  void setCategory(int? categoryId) {
    state = categoryId == null
        ? state.copyWith(clearCategory: true)
        : state.copyWith(categoryId: categoryId);
  }

  void setLowStockOnly(bool value) => state = state.copyWith(onlyLowStock: value);

  void setOutOfStockOnly(bool value) => state = state.copyWith(onlyOutOfStock: value);

  void setIncludeInactive(bool value) => state = state.copyWith(includeInactive: value);

  void setOnlyFavorites(bool value) => state = state.copyWith(onlyFavorites: value);

  void setSort(ProductSort sort) => state = state.copyWith(sort: sort);

  void setLimit(int limit) => state = state.copyWith(limit: limit);

  void reset() => state = const ProductFilter();
}

final productFilterProvider = NotifierProvider<ProductFilterController, ProductFilter>(
  ProductFilterController.new,
);
