import 'package:flutter/foundation.dart';

import '../domain/enums.dart';

/// Quién gana un conflicto de versiones.
enum ConflictWinner {
  /// La versión local es la vigente: se vuelve a empujar.
  local,

  /// La versión remota es la vigente: se sobrescribe la fila local.
  remote,

  /// No hay conflicto real (la fila no existe localmente o es idéntica).
  none,
}

/// Decisión de resolución con su justificación (auditable).
@immutable
class ConflictDecision {
  const ConflictDecision({
    required this.winner,
    required this.reason,
    this.shouldReenqueueLocal = false,
    this.shouldReloadRemote = false,
  });

  final ConflictWinner winner;
  final String reason;
  final bool shouldReenqueueLocal;
  final bool shouldReloadRemote;

  bool get isConflict => winner != ConflictWinner.none;
}

/// Resolución de conflictos **Last Write Wins (LWW)** con clave compuesta.
///
/// Reglas implementadas:
///
/// 1. **Datos transaccionales** (ventas, pagos, movimientos de stock y caja)
///    son *append-only*: no se resuelven por tiempo, sino por **idempotencia**.
///    Una venta con el mismo `uuid`/`op_id` simplemente no se reaplica. Esta
///    es la única forma correcta: comparar "quién llegó último" entre dos cajas
///    que vendieron offline produciría pérdida de ventas.
///
/// 2. **Datos maestros** (productos, precios, clientes, usuarios) usan LWW por
///    `updated_at`. Empate exacto (milisegundo idéntico, muy posible entre dos
///    equipos) se rompe comparando el `device_id` de forma lexicográfica: todos
///    los nodos deben elegir el mismo ganador o las cajas divergen para siempre.
///
/// 3. **Nunca se pierde una venta**: si el LWW favorece al remoto en un
///    producto, la venta ya registrada conserva precio y costo congelados en
///    sus líneas.
abstract final class ConflictResolver {
  /// Entidades *append-only* donde el tiempo no decide nada.
  static bool isAppendOnly(SyncEntity entity) => switch (entity) {
        SyncEntity.sale ||
        SyncEntity.saleItem ||
        SyncEntity.salePayment ||
        SyncEntity.stockMovement ||
        SyncEntity.cashSession ||
        SyncEntity.cashMovement =>
          true,
        _ => false,
      };

  /// Compara dos versiones. Devuelve `true` si **el remoto** es más nuevo.
  ///
  /// Clave de versión = (`updatedAt`, `deviceId`). El desempate por
  /// `deviceId` es lo que garantiza convergencia entre todas las cajas.
  static bool remoteWins({
    required DateTime localUpdatedAt,
    required String? localDeviceId,
    required DateTime remoteUpdatedAt,
    required String? remoteDeviceId,
  }) {
    final int timeComparison = remoteUpdatedAt.compareTo(localUpdatedAt);
    if (timeComparison != 0) return timeComparison > 0;
    if (localDeviceId == null || remoteDeviceId == null) return false;
    // Mismo instante: gana el device_id lexicográficamente menor.
    return remoteDeviceId.compareTo(localDeviceId) < 0;
  }

  /// Decide qué hacer con un cambio remoto que llega.
  static ConflictDecision decide({
    required SyncEntity entity,
    required DateTime? localUpdatedAt,
    required String? localDeviceId,
    required DateTime remoteUpdatedAt,
    required String? remoteDeviceId,
    required bool hasPendingLocalChanges,
  }) {
    // Regla 1: transaccionales -> idempotencia, nunca LWW.
    if (isAppendOnly(entity)) {
      return const ConflictDecision(
        winner: ConflictWinner.none,
        reason: 'Entidad append-only: se aplica por idempotencia (op_id/uuid).',
      );
    }

    // La fila no existe localmente: se crea sin discusión.
    if (localUpdatedAt == null) {
      return ConflictDecision(
        winner: ConflictWinner.remote,
        reason: 'La entidad ${entity.storageKey} no existe localmente: se crea.',
        shouldReloadRemote: true,
      );
    }

    final bool remoteIsNewer = remoteWins(
      localUpdatedAt: localUpdatedAt,
      localDeviceId: localDeviceId,
      remoteUpdatedAt: remoteUpdatedAt,
      remoteDeviceId: remoteDeviceId,
    );

    if (!remoteIsNewer) {
      return ConflictDecision(
        winner: ConflictWinner.local,
        reason: 'La versión local es más reciente (o gana el desempate por dispositivo).',
        shouldReenqueueLocal: hasPendingLocalChanges,
      );
    }

    return ConflictDecision(
      winner: ConflictWinner.remote,
      reason: 'La versión remota es más reciente: se sobrescribe la local.',
      shouldReloadRemote: true,
    );
  }
}
