import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../../errors/app_failure.dart';
import '../../utils/id_generator.dart';
import '../../utils/money.dart';
import '../app_database.dart';
import '../sync_payloads.dart';
import '../tables/sales_tables.dart';

part 'customers_dao.g.dart';

/// Ficha de cliente con datos de compra agregados (pantalla de clientes).
class CustomerOverview {
  const CustomerOverview({
    required this.customer,
    required this.purchaseCount,
    required this.totalSpent,
    required this.averageTicket,
    this.lastPurchaseAt,
  });

  final Customer customer;
  final int purchaseCount;
  final Money totalSpent;
  final Money averageTicket;
  final DateTime? lastPurchaseAt;
}

/// Acceso a clientes.
@DriftAccessor(tables: <Type>[Customers, Sales])
class CustomersDao extends DatabaseAccessor<AppDatabase> with _$CustomersDaoMixin {
  CustomersDao(AppDatabase db) : super(db);

  // ---------------------------------------------------------------------------
  // Consultas
  // ---------------------------------------------------------------------------

  /// Búsqueda por nombre, NIT, teléfono o correo. `limit` alto por defecto
  /// porque en el POS el cajero filtra escribiendo, no paginando.
  Stream<List<Customer>> watchAll({String? search, int limit = 200}) {
    final SimpleSelectStatement<$CustomersTable, Customer> query = select(customers);
    query
      ..where((t) {
        Expression<bool> predicate = t.deletedAt.isNull() & t.isActive.equals(true);
        final String? term = search?.trim();
        if (term != null && term.isNotEmpty) {
          final String pattern = '%${term.toLowerCase()}%';
          predicate = predicate &
              (t.name.lower().like(pattern) |
                  t.taxId.lower().like(pattern) |
                  t.phone.like(pattern) |
                  t.email.lower().like(pattern));
        }
        return predicate;
      })
      ..orderBy(<OrderingTerm Function($CustomersTable)>[
        (t) => OrderingTerm(expression: t.name),
      ])
      ..limit(limit);
    return query.watch();
  }

  Future<List<Customer>> search(String term, {int limit = 30}) async {
    final String query = term.trim();
    if (query.isEmpty) return <Customer>[];
    final String pattern = '%${query.toLowerCase()}%';
    return (select(customers)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.isActive.equals(true) &
              (t.name.lower().like(pattern) |
                  t.taxId.lower().like(pattern) |
                  t.phone.like(pattern)))
          ..orderBy(<OrderingTerm Function($CustomersTable)>[
            (t) => OrderingTerm(expression: t.name),
          ])
          ..limit(limit))
        .get();
  }

  /// Clientes atendidos recientemente (para el selector de la venta).
  Future<List<Customer>> recentlyServed({int limit = 12}) => (select(customers)
        ..where((t) => t.deletedAt.isNull() & t.lastPurchaseAt.isNotNull())
        ..orderBy(<OrderingTerm Function($CustomersTable)>[
          (t) => OrderingTerm(expression: t.lastPurchaseAt, mode: OrderingMode.desc),
        ])
        ..limit(limit))
      .get();

  Future<Customer?> findById(int id) =>
      (select(customers)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Customer?> findByUuid(String uuid) =>
      (select(customers)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

  Future<Customer?> findByTaxId(String taxId) {
    final String clean = taxId.trim();
    if (clean.isEmpty) return Future<Customer?>.value();
    return (select(customers)
          ..where((t) => t.taxId.equals(clean) & t.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
  }

  Future<Customer?> findByPhone(String phone) {
    if (phone.trim().isEmpty) return Future<Customer?>.value();
    return (select(customers)
          ..where((t) => t.phone.equals(phone.trim()) & t.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
  }

  /// Clientes con saldo pendiente (ventas a crédito por cobrar).
  Future<List<Customer>> withBalance() => (select(customers)
        ..where((t) =>
            t.deletedAt.isNull() & t.isActive.equals(true) & t.balance.isBiggerThanValue(Money.zero))
        ..orderBy(<OrderingTerm Function($CustomersTable)>[
          (t) => OrderingTerm(expression: t.balance, mode: OrderingMode.desc),
        ]))
      .get();

  Future<int> countActive() async {
    final Expression<int> count = customers.id.count();
    final TypedResult row = await (selectOnly(customers)
          ..addColumns(<Expression<Object>>[count])
          ..where(customers.deletedAt.isNull() & customers.isActive.equals(true)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  /// Ficha con métricas de compra (se calculan en SQL, no en memoria).
  Future<CustomerOverview?> overview(String customerUuid) async {
    final Customer? customer = await findByUuid(customerUuid);
    if (customer == null) return null;

    final QueryRow row = await customSelect(
      '''
      SELECT COUNT(*)                    AS purchase_count,
             COALESCE(SUM(total), 0)     AS total_spent,
             MAX(created_at)             AS last_purchase
        FROM sales
       WHERE customer_uuid = ?
         AND status = 'completed'
         AND deleted_at IS NULL;
      ''',
      variables: <Variable<Object>>[Variable.withString(customerUuid)],
    ).getSingle();

    final int count = row.read<int>('purchase_count');
    final Money total = Money(row.read<int>('total_spent'));
    final int? lastMillis = row.readNullable<int>('last_purchase');

    return CustomerOverview(
      customer: customer,
      purchaseCount: count,
      totalSpent: total,
      averageTicket: count == 0 ? Money.zero : Money(MoneyMath.mulDiv(total.cents, 1, count)),
      lastPurchaseAt: lastMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastMillis, isUtc: true).toLocal(),
    );
  }

  /// Historial de compras del cliente.
  Future<List<Sale>> purchaseHistory(String customerUuid, {int limit = 200}) =>
      (select(sales)
            ..where((t) =>
                t.customerUuid.equals(customerUuid) &
                t.deletedAt.isNull() &
                t.status.equalsValue(SaleStatus.completed))
            ..orderBy(<OrderingTerm Function($SalesTable)>[
              (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .get();

  // ---------------------------------------------------------------------------
  // Escrituras
  // ---------------------------------------------------------------------------

  Future<Customer> createCustomer({
    required String name,
    String taxId = '',
    String phone = '',
    String email = '',
    String address = '',
    Money creditLimit = Money.zero,
    int discountBps = 0,
    String? notes,
  }) async {
    final DateTime now = attachedDatabase.now;
    final String uuid = IdGenerator.uuid();

    return attachedDatabase.writeWithOutbox<Customer>(
      action: () async {
        final int id = await into(customers).insert(
          CustomersCompanion.insert(
            uuid: uuid,
            name: name.trim(),
            taxId: Value<String>(taxId.trim()),
            phone: Value<String>(phone.trim()),
            email: Value<String>(email.trim()),
            address: Value<String>(address.trim()),
            creditLimit: Value<Money>(creditLimit),
            discountBps: Value<int>(discountBps),
            notes: Value<String?>(notes),
            createdAt: now,
            updatedAt: now,
            deviceId: Value<String?>(attachedDatabase.deviceUuid),
          ),
        );
        final Customer created =
            await (select(customers)..where((t) => t.id.equals(id))).getSingle();
        await attachedDatabase.recordAudit(
          entity: 'customer',
          entityUuid: uuid,
          action: 'create',
          note: 'Alta de cliente: ${created.name}',
        );
        return created;
      },
      entity: SyncEntity.customer,
      entityUuid: uuid,
      operation: SyncOperation.insert,
      payload: SyncPayloads.customer(created),
      priority: 25,
    );
  }

  Future<void> updateCustomer({
    required Customer customer,
    String? name,
    String? taxId,
    String? phone,
    String? email,
    String? address,
    Money? creditLimit,
    int? discountBps,
    bool? isActive,
    String? notes,
  }) async {
    final DateTime now = attachedDatabase.now;
    final Customer updated = customer.copyWith(
      name: name?.trim() ?? customer.name,
      taxId: taxId?.trim() ?? customer.taxId,
      phone: phone?.trim() ?? customer.phone,
      email: email?.trim() ?? customer.email,
      address: address?.trim() ?? customer.address,
      creditLimit: creditLimit ?? customer.creditLimit,
      discountBps: discountBps ?? customer.discountBps,
      isActive: isActive ?? customer.isActive,
      notes: notes ?? customer.notes,
      updatedAt: now,
      syncVersion: customer.syncVersion + 1,
    );

    await attachedDatabase.writeWithOutbox(
      action: () => update(customers).replace(updated),
      entity: SyncEntity.customer,
      entityUuid: customer.uuid,
      operation: SyncOperation.update,
      payload: SyncPayloads.customer(updated),
      lwwTimestamp: now,
      priority: 25,
    );
  }

  /// Baja lógica del cliente.
  Future<void> softDelete(Customer customer) async {
    final DateTime now = attachedDatabase.now;
    await attachedDatabase.writeWithOutbox(
      action: () async {
        await (update(customers)..where((t) => t.id.equals(customer.id))).write(
          CustomersCompanion(
            deletedAt: Value<DateTime>(now),
            isActive: const Value<bool>(false),
            updatedAt: Value<DateTime>(now),
          ),
        );
        await attachedDatabase.recordAudit(
          entity: 'customer',
          entityUuid: customer.uuid,
          action: 'delete',
          note: 'Cliente dado de baja: ${customer.name}',
        );
      },
      entity: SyncEntity.customer,
      entityUuid: customer.uuid,
      operation: SyncOperation.delete,
      payload: <String, Object?>{
        'uuid': customer.uuid,
        'deleted_at': now.toUtc().toIso8601String(),
        'is_active': false,
      },
      lwwTimestamp: now,
      priority: 25,
    );
  }

  /// Actualiza la fecha de última compra (se invoca al cobrar).
  Future<void> touchLastPurchase(String customerUuid, DateTime when) async {
    await (update(customers)..where((t) => t.uuid.equals(customerUuid)))
        .write(CustomersCompanion(lastPurchaseAt: Value<DateTime>(when.toUtc())));
  }

  /// Suma puntos de fidelidad (1 punto por unidad monetaria por defecto).
  Future<void> addLoyaltyPoints(String customerUuid, int points) async {
    await customStatement(
      'UPDATE customers SET loyalty_points = loyalty_points + ? WHERE uuid = ?;',
      <Object?>[points, customerUuid],
    );
  }

  /// Aplica el saldo de una venta a crédito.
  ///
  /// Se valida el límite **antes** de fiar: es la única protección real contra
  /// el sobreendeudamiento de un cliente en un POS sin conexión.
  Future<void> applyCreditBalance({
    required Customer customer,
    required Money amount,
  }) async {
    final Money newBalance = customer.balance + amount;
    if (customer.creditLimit.isPositive && newBalance > customer.creditLimit) {
      throw BusinessRuleFailure(
        message: 'El cliente "${customer.name}" excede su límite de crédito '
            '(disponible: ${customer.creditLimit - customer.balance}).',
        rule: 'credit_limit_exceeded',
      );
    }

    // Una sola transacción: saldo + encolado. Si se corta la luz entre ambos,
    // la caja quedaría con un saldo que la nube nunca conocería.
    await attachedDatabase.transaction<void>(() async {
      final DateTime now = attachedDatabase.now;
      await customStatement(
        'UPDATE customers SET balance = ?, updated_at = ? WHERE uuid = ?;',
        <Object?>[newBalance.cents, now.toUtc().millisecondsSinceEpoch, customer.uuid],
      );
      final Customer updated = (await findByUuid(customer.uuid))!;
      await attachedDatabase.enqueueOutbox(
        entity: SyncEntity.customer,
        entityUuid: updated.uuid,
        operation: SyncOperation.update,
        // Snapshot completo (no solo el saldo): la nube no debe quedarse con
        // una fila parcial si aplica el payload sin hacer merge.
        payload: SyncPayloads.customer(updated),
        lwwTimestamp: now,
        priority: 25,
      );
    });
  }

  /// Saldo pendiente total de la cartera de crédito.
  Future<Money> totalReceivable() async {
    final QueryRow row = await customSelect(
      'SELECT COALESCE(SUM(balance), 0) AS total FROM customers WHERE deleted_at IS NULL;',
    ).getSingle();
    return Money(row.read<int>('total'));
  }
}
