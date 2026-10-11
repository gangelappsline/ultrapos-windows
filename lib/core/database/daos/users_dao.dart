import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../../security/pin_hasher.dart';
import '../../utils/id_generator.dart';
import '../../utils/money.dart';
import '../app_database.dart';
import '../sync_payloads.dart';
import '../tables/system_tables.dart';

part 'users_dao.g.dart';

/// Acceso a usuarios, roles y autenticación por PIN.
///
/// Reglas de seguridad que este DAO garantiza:
///  * El PIN **nunca** se guarda en claro: se almacena `pbkdf2-sha256` con sal.
///  * Si un usuario queda sin hash (todos los usuarios sin PIN), el POS exige
///    configurarlo antes de permitir ventas.
///  * La comparación del hash es en tiempo constante (ver [PinHasher]).
@DriftAccessor(tables: <Type>[Users])
class UsersDao extends DatabaseAccessor<AppDatabase> with _$UsersDaoMixin {
  UsersDao(AppDatabase db) : super(db);

  // ---------------------------------------------------------------------------
  // Consultas
  // ---------------------------------------------------------------------------

  Stream<List<User>> watchAll({bool includeInactive = false}) {
    final SimpleSelectStatement<Users, User> query = select(users)
      ..where((t) => includeInactive ? const Constant(true) : t.isActive.equals(true))
      ..orderBy(<OrderingTerm Function(Users)>[
        (t) => OrderingTerm(expression: t.role),
        (t) => OrderingTerm(expression: t.fullName),
      ]);
    return query.watch();
  }

  Future<List<User>> all({bool includeInactive = false}) {
    final SimpleSelectStatement<Users, User> query = select(users)
      ..where((t) => includeInactive ? const Constant(true) : t.isActive.equals(true))
      ..orderBy(<OrderingTerm Function(Users)>[(t) => OrderingTerm(expression: t.fullName)]);
    return query.get();
  }

  Future<User?> findById(int id) =>
      (select(users)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<User?> findByUuid(String uuid) =>
      (select(users)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

  Future<User?> findByUsername(String username) => (select(users)
        ..where((t) => t.username.lower().equals(username.trim().toLowerCase())))
      .getSingleOrNull();

  Future<List<User>> pinCandidates() => (select(users)
        ..where((t) => t.isActive.equals(true) & t.pinHash.isNotNull()))
      .get();

  Future<int> countActive() async {
    final Expression<int> count = users.id.count();
    final TypedResult row =
        await (selectOnly(users)..addColumns(<Expression<Object>>[count])).getSingle();
    return row.read(count) ?? 0;
  }

  Future<bool> hasAnyActive() async => await countActive() > 0;

  // ---------------------------------------------------------------------------
  // Escritura
  // ---------------------------------------------------------------------------

  /// Crea un usuario y lo encola para la nube.
  ///
  /// Devuelve el id local. La fila y su operación de sincronización se escriben
  /// en la **misma transacción** (patrón outbox): o el usuario existe en ambos
  /// lados, o en ninguno.
  Future<int> createUser({
    required String username,
    required String fullName,
    required UserRole role,
    required String pin,
    String? employeeCode,
    int maxDiscountBps = 0,
    bool isActive = true,
  }) async {
    final String? pinError = PinHasher.validate(pin);
    if (pinError != null) {
      throw ArgumentError('PIN inválido: $pinError');
    }
    final String cleanUsername = username.trim().toLowerCase();
    if (cleanUsername.length < 2) {
      throw ArgumentError('El nombre de usuario debe tener al menos 2 caracteres.');
    }
    final User? existing = await findByUsername(cleanUsername);
    if (existing != null) {
      throw ArgumentError('Ya existe un usuario con el nombre "$cleanUsername".');
    }

    final PinHashResult hashed = PinHasher.hash(pin);
    final String uuid = IdGenerator.uuid();

    // La fila y su operación de sincronización se escriben en la **misma
    // transacción** (patrón outbox): o el usuario existe en ambos lados, o en
    // ninguno. El payload se construye a partir de la fila ya guardada, para
    // que la nube reciba exactamente lo que quedó en la base de datos.
    return attachedDatabase.transaction<int>(() async {
      final DateTime now = attachedDatabase.now;
      final int id = await into(users).insert(
        UsersCompanion.insert(
          uuid: uuid,
          username: cleanUsername,
          fullName: fullName.trim(),
          role: role,
          pinHash: Value<String?>(hashed.encoded),
          pinSalt: Value<String?>(hashed.saltBase64),
          employeeCode: Value<String?>(employeeCode?.trim()),
          isActive: Value<bool>(isActive),
          maxDiscountBps: Value<int>(maxDiscountBps),
          createdAt: now,
          updatedAt: now,
          deviceId: Value<String?>(attachedDatabase.deviceUuid),
        ),
      );
      final User created = (await findById(id))!;
      await attachedDatabase.enqueueOutbox(
        entity: SyncEntity.user,
        entityUuid: created.uuid,
        operation: SyncOperation.insert,
        payload: SyncPayloads.user(created),
        lwwTimestamp: created.updatedAt,
        priority: 70,
      );
      return id;
    });
  }

  /// Actualiza los datos editables de un usuario (sin tocar el PIN).
  Future<void> updateUser({
    required String uuid,
    String? fullName,
    UserRole? role,
    String? employeeCode,
    int? maxDiscountBps,
    bool? isActive,
  }) async {
    final User? current = await findByUuid(uuid);
    if (current == null) {
      throw StateError('No existe el usuario $uuid');
    }
    if (current.role == UserRole.admin && isActive == false) {
      final int admins = await _activeAdminCount();
      if (admins <= 1) {
        throw StateError('No se puede desactivar al último administrador.');
      }
    }

    final DateTime now = attachedDatabase.now;
    await attachedDatabase.transaction<void>(() async {
      await (update(users)..where((t) => t.uuid.equals(uuid))).write(
        UsersCompanion(
          fullName: fullName == null ? const Value.absent() : Value<String>(fullName.trim()),
          role: role == null ? const Value.absent() : Value<UserRole>(role),
          employeeCode:
              employeeCode == null ? const Value.absent() : Value<String?>(employeeCode.trim()),
          maxDiscountBps:
              maxDiscountBps == null ? const Value.absent() : Value<int>(maxDiscountBps),
          isActive: isActive == null ? const Value.absent() : Value<bool>(isActive),
          updatedAt: Value<DateTime>(now),
          syncVersion: Value<int>(current.syncVersion + 1),
        ),
      );
      final User updated = (await findByUuid(uuid))!;
      await attachedDatabase.enqueueOutbox(
        entity: SyncEntity.user,
        entityUuid: uuid,
        operation: SyncOperation.update,
        payload: SyncPayloads.user(updated),
        lwwTimestamp: now,
        priority: 70,
      );
    });
  }

  /// Cambia el PIN de un usuario (operación sensible: se audita).
  ///
  /// El PIN **no viaja** al servidor: se sincronizan usuario y rol, pero la
  /// credencial queda en el equipo. Un PIN filtrado en la nube sería un
  /// incidente de seguridad, no un problema de sincronización.
  Future<void> setPin({
    required String uuid,
    required String pin,
    String? actingUserName,
  }) async {
    final String? pinError = PinHasher.validate(pin);
    if (pinError != null) {
      throw ArgumentError('PIN inválido: $pinError');
    }
    final User? current = await findByUuid(uuid);
    if (current == null) {
      throw StateError('No existe el usuario $uuid');
    }

    final PinHashResult hashed = PinHasher.hash(pin);
    final DateTime now = attachedDatabase.now;
    await (update(users)..where((t) => t.uuid.equals(uuid))).write(
      UsersCompanion(
        pinHash: Value<String?>(hashed.encoded),
        pinSalt: Value<String?>(hashed.saltBase64),
        updatedAt: Value<DateTime>(now),
        syncVersion: Value<int>(current.syncVersion + 1),
      ),
    );
    await attachedDatabase.recordAudit(
      entity: 'user',
      entityUuid: uuid,
      action: 'set_pin',
      userName: actingUserName,
      note: 'Cambio de PIN de ${current.username}',
    );
  }

  Future<void> deactivate(String uuid) =>
      updateUser(uuid: uuid, isActive: false);

  /// Registra el último acceso (para el reporte de actividad de usuarios).
  Future<void> recordLogin(int userId) async {
    await (update(users)..where((t) => t.id.equals(userId)))
        .write(UsersCompanion(lastLoginAt: Value<DateTime?>(attachedDatabase.now)));
  }

  // ---------------------------------------------------------------------------
  // Autenticación
  // ---------------------------------------------------------------------------

  /// Busca un usuario activo cuyo PIN coincida.
  ///
  /// Se recorren los candidatos (con hash) y se verifica en tiempo constante.
  /// Con pocos usuarios por caja (habitualmente < 20) el coste es despreciable,
  /// y evita exponer qué usuario existe.
  Future<User?> authenticateWithPin(String pin) async {
    if (pin.isEmpty) return null;
    final List<User> candidates = await pinCandidates();
    for (final User user in candidates) {
      if (PinHasher.verify(pin, user.pinHash, legacySaltBase64: user.pinSalt)) {
        // Rehash transparente: si subimos las iteraciones, el PIN se actualiza
        // solo la próxima vez que el usuario entra (sin pedirle nada).
        if (PinHasher.needsRehash(user.pinHash)) {
          final PinHashResult fresh = PinHasher.hash(pin);
          await (update(users)..where((t) => t.id.equals(user.id))).write(
            UsersCompanion(
              pinHash: Value<String?>(fresh.encoded),
              pinSalt: Value<String?>(fresh.saltBase64),
            ),
          );
        }
        return user;
      }
    }
    return null;
  }

  /// Verifica el PIN de un usuario concreto (autorización de supervisor).
  Future<bool> verifyPinOf(String userUuid, String pin) async {
    final User? user = await findByUuid(userUuid);
    if (user == null || !user.isActive) return false;
    return PinHasher.verify(pin, user.pinHash, legacySaltBase64: user.pinSalt);
  }

  /// Usuarios que pueden autorizar anulaciones (supervisor o superior).
  /// Verifica un PIN y devuelve el usuario solo si su rol alcanza [minimumRole].
  ///
  /// Se usa para autorizaciones puntuales (anular una venta, aplicar un
  /// descuento alto) sin cambiar de usuario: la operación sigue quedando
  /// registrada a nombre del cajero y del supervisor que autorizó.
  Future<User?> authorizeWithPin(String pin, {required UserRole minimumRole}) async {
    final User? user = await authenticateWithPin(pin);
    if (user == null) return null;
    if (user.role.level < minimumRole.level) return null;
    return user;
  }

  Future<List<User>> authorizers() {
    final List<UserRole> roles = UserRole.values
        .where((UserRole role) => role.canVoidSales)
        .toList(growable: false);
    return (select(users)
          ..where((t) => t.isActive.equals(true) & t.role.isInValues(roles)))
        .get();
  }

  Future<int> _activeAdminCount() async {
    final Expression<int> count = users.id.count();
    final TypedResult row = await (selectOnly(users)
          ..addColumns(<Expression<Object>>[count])
          ..where(users.role.equalsValue(UserRole.admin) & users.isActive.equals(true)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  /// Crea el administrador inicial en el primer arranque.
  ///
  /// Se llama una única vez, desde el asistente de bienvenida. Si ya existe
  /// algún usuario, no hace nada (idempotente).
  Future<User?> ensureInitialAdmin({
    required String pin,
    String fullName = 'Administrador',
    String username = 'admin',
  }) async {
    if (await hasAnyActive()) return null;
    final int id = await createUser(
      username: username,
      fullName: fullName,
      role: UserRole.admin,
      pin: pin,
      employeeCode: '01',
      maxDiscountBps: 10000,
    );
    return findById(id);
  }
}
