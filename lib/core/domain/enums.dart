/// Enumeraciones de dominio compartidas por todas las capas.
///
/// Se guardan en la base de datos como **texto** (no como índice de enum):
/// así un reordenamiento del enum jamás corrompe datos históricos — un fallo
/// clásico y carísimo en sistemas POS que llevan años en producción.
library;

/// Contrato de los enums persistibles.
///
/// Cada valor exporta una clave **estable en texto** que se guarda en SQLite y
/// viaja a la nube. Renombrar un valor del enum en Dart no rompe los datos ya
/// escritos en las cajas (a diferencia de persistir `index` o `name`).
abstract interface class StorageKeyed {
  String get storageKey;
}

// ---------------------------------------------------------------------------
// Usuarios y seguridad
// ---------------------------------------------------------------------------

/// Roles disponibles. La jerarquía importa: [canManage] usa [level].
enum UserRole implements StorageKeyed {
  cashier('cashier', 'Cajero', 1),
  supervisor('supervisor', 'Supervisor', 2),
  admin('admin', 'Administrador', 3);

  const UserRole(this.storageKey, this.label, this.level);

  final String storageKey;
  final String label;
  final int level;

  static UserRole fromStorage(String? value) => values.firstWhere(
        (UserRole r) => r.storageKey == value,
        orElse: () => UserRole.cashier,
      );

  /// ¿Este rol puede realizar acciones que requieren [other] (o menos)?
  bool canManage(UserRole other) => level >= other.level;

  bool get canVoidSales => level >= UserRole.supervisor.level;
  bool get canManageInventory => level >= UserRole.supervisor.level;
  bool get canManageUsers => level >= UserRole.admin.level;
  bool get canConfigureSystem => level >= UserRole.admin.level;
  bool get canCloseCashSession => true;
  bool get canViewReports => level >= UserRole.supervisor.level;
}

// ---------------------------------------------------------------------------
// Ventas
// ---------------------------------------------------------------------------

/// Estado de una venta. Una venta nunca se borra: se anula (auditoría).
enum SaleStatus implements StorageKeyed {
  /// Ticket en curso, guardado como "en espera" (no afecta stock ni caja).
  held('held', 'En espera'),
  completed('completed', 'Completada'),
  voided('voided', 'Anulada'),
  refunded('refunded', 'Devuelta');

  const SaleStatus(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static SaleStatus fromStorage(String? value) => values.firstWhere(
        (SaleStatus s) => s.storageKey == value,
        orElse: () => SaleStatus.completed,
      );

  /// ¿Afecta los totales de caja y reportes?
  bool get isEffective => this == SaleStatus.completed || this == SaleStatus.refunded;
}

/// Formas de pago soportadas. Se modela el pago mixto como una lista de
/// [Payments], por lo que no existe un método "mixto": es la ausencia de un
/// único método.
enum PaymentMethod implements StorageKeyed {
  cash('cash', 'Efectivo'),
  card('card', 'Tarjeta'),
  transfer('transfer', 'Transferencia'),
  credit('credit', 'Crédito'),
  other('other', 'Otro');

  const PaymentMethod(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static PaymentMethod fromStorage(String? value) => values.firstWhere(
        (PaymentMethod m) => m.storageKey == value,
        orElse: () => PaymentMethod.cash,
      );

  /// Solo el efectivo entra al arqueo de caja.
  bool get affectsCashDrawer => this == PaymentMethod.cash;

  /// Métodos que no se pueden cobrar si no hay cliente registrado.
  bool get requiresCustomer => this == PaymentMethod.credit;
}

// ---------------------------------------------------------------------------
// Inventario
// ---------------------------------------------------------------------------

/// Tipo de movimiento de inventario (kardex).
enum StockMovementType implements StorageKeyed {
  sale('sale', 'Venta'),
  purchase('purchase', 'Entrada por compra'),
  adjustmentIn('adjustment_in', 'Ajuste positivo'),
  adjustmentOut('adjustment_out', 'Ajuste negativo'),
  transferIn('transfer_in', 'Traslado entrante'),
  transferOut('transfer_out', 'Traslado saliente'),
  returnIn('return_in', 'Devolución de cliente'),
  initial('initial', 'Carga inicial'),
  loss('loss', 'Merma / pérdida');

  const StockMovementType(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static StockMovementType fromStorage(String? value) => values.firstWhere(
        (StockMovementType t) => t.storageKey == value,
        orElse: () => StockMovementType.adjustmentIn,
      );

  /// Signo del efecto sobre el stock.
  int get direction => switch (this) {
        StockMovementType.sale => -1,
        StockMovementType.adjustmentOut => -1,
        StockMovementType.transferOut => -1,
        StockMovementType.loss => -1,
        _ => 1,
      };

  bool get increases => direction > 0;
}

/// Unidad de venta del producto.
enum ProductUnit implements StorageKeyed {
  unit('unit', 'Unidad', 'u'),
  kilogram('kilogram', 'Kilogramo', 'kg'),
  gram('gram', 'Gramo', 'g'),
  liter('liter', 'Litro', 'L'),
  meter('meter', 'Metro', 'm'),
  package('package', 'Paquete', 'pqt'),
  service('service', 'Servicio', '');

  const ProductUnit(this.storageKey, this.label, this.abbreviation);

  final String storageKey;
  final String label;
  final String abbreviation;

  static ProductUnit fromStorage(String? value) => values.firstWhere(
        (ProductUnit u) => u.storageKey == value,
        orElse: () => ProductUnit.unit,
      );

  /// ¿Se vende por peso/medida (permite decimales en el carrito)?
  bool get allowsDecimals => switch (this) {
        ProductUnit.kilogram || ProductUnit.gram || ProductUnit.liter || ProductUnit.meter => true,
        _ => false,
      };

  /// ¿Descuenta inventario? Un servicio, no.
  bool get tracksStock => this != ProductUnit.service;
}

// ---------------------------------------------------------------------------
// Caja
// ---------------------------------------------------------------------------

/// Movimiento manual de caja durante el turno.
enum CashMovementType implements StorageKeyed {
  opening('opening', 'Apertura'),
  sale('sale', 'Venta en efectivo'),
  refund('refund', 'Devolución'),
  deposit('deposit', 'Ingreso de efectivo'),
  withdrawal('withdrawal', 'Retiro de efectivo'),
  expense('expense', 'Pago de gasto'),
  closing('closing', 'Cierre');

  const CashMovementType(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static CashMovementType fromStorage(String? value) => values.firstWhere(
        (CashMovementType t) => t.storageKey == value,
        orElse: () => CashMovementType.deposit,
      );

  /// Efecto sobre el efectivo esperado en el cajón.
  int get direction => switch (this) {
        CashMovementType.withdrawal => -1,
        CashMovementType.expense => -1,
        CashMovementType.refund => -1,
        _ => 1,
      };

  /// Los movimientos automáticos no se capturan a mano.
  bool get isManual =>
      this == CashMovementType.deposit ||
      this == CashMovementType.withdrawal ||
      this == CashMovementType.expense;
}

/// Estado del turno de caja.
enum CashSessionStatus implements StorageKeyed {
  open('open', 'Abierto'),
  closed('closed', 'Cerrado');

  const CashSessionStatus(this.storageKey, this.label);

  final String storageKey;
  final String label;

  static CashSessionStatus fromStorage(String? value) => values.firstWhere(
        (CashSessionStatus s) => s.storageKey == value,
        orElse: () => CashSessionStatus.open,
      );
}

// ---------------------------------------------------------------------------
// Sincronización
// ---------------------------------------------------------------------------

/// Entidades sincronizables. El orden de la lista es el orden de empuje
/// (los catálogos viajan antes que las ventas para que las referencias existan
/// en el servidor cuando llegue la venta).
enum SyncEntity implements StorageKeyed {
  company('company'),
  user('user'),
  category('category'),
  product('product'),
  customer('customer'),
  stockMovement('stock_movement'),
  cashSession('cash_session'),
  cashMovement('cash_movement'),
  sale('sale'),
  saleItem('sale_item'),
  salePayment('sale_payment'),
  setting('setting');

  const SyncEntity(this.storageKey);

  final String storageKey;

  static SyncEntity? tryFromStorage(String? value) {
    for (final SyncEntity e in values) {
      if (e.storageKey == value) return e;
    }
    return null;
  }
}

/// Operación dentro de la cola de sincronización.
enum SyncOperation implements StorageKeyed {
  insert('insert'),
  update('update'),
  delete('delete');

  const SyncOperation(this.storageKey);

  final String storageKey;

  static SyncOperation fromStorage(String? value) => values.firstWhere(
        (SyncOperation o) => o.storageKey == value,
        orElse: () => SyncOperation.update,
      );
}

/// Estado de una fila de la cola de sincronización.
enum SyncStatus implements StorageKeyed {
  /// Recién creada, lista para enviarse.
  pending('pending', 'Pendiente'),

  /// Enviándose en este momento (evita doble envío si se reinicia la app).
  inFlight('in_flight', 'Enviando'),

  synced('synced', 'Sincronizado'),

  /// Falló pero se reintentará con retroceso exponencial.
  retry('retry', 'Reintentando'),

  /// Falló tras agotar los reintentos: requiere atención del administrador.
  failed('failed', 'Con error'),

  /// El servidor reportó una versión más nueva (se resolvió por LWW).
  conflict('conflict', 'Conflicto resuelto');

  const SyncStatus(this.storageKey, this.label);

  final String storageKey;
  final String label;

  bool get isTerminal => this == SyncStatus.synced || this == SyncStatus.conflict;
  bool get needsAttention => this == SyncStatus.failed;

  static SyncStatus fromStorage(String? value) => values.firstWhere(
        (SyncStatus s) => s.storageKey == value,
        orElse: () => SyncStatus.pending,
      );
}

/// Estrategia de resolución de conflictos aplicada.
enum ConflictResolution implements StorageKeyed {
  /// El local ganó: se reenvía la operación.
  localWins('local_wins'),

  /// El remoto ganó: se sobrescribió la fila local.
  remoteWins('remote_wins'),

  /// Ambas versiones se conservaron (reenvío + recarga).
  merged('merged');

  const ConflictResolution(this.storageKey);

  final String storageKey;
}
