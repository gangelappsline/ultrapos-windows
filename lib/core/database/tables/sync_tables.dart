import 'package:drift/drift.dart';

import '../converters/app_converters.dart';
import '../../domain/enums.dart';

/// Infraestructura de sincronización: cola de salida (outbox), cursores de
/// entrada y bitácora de eventos.
///
/// Se implementa el patrón **Transactional Outbox**: la operación de negocio y
/// su registro en la cola se escriben en la MISMA transacción SQLite. De este
/// modo es imposible que una venta quede guardada sin encolarse para la nube,
/// o al revés. Sin este patrón, un corte de luz entre ambas escrituras crea
/// divergencias silenciosas entre cajas.
library;

/// Cola de operaciones pendientes de enviar a la nube.
@TableIndex(name: 'idx_outbox_op_id', columns: {#opId}, unique: true)
@TableIndex(name: 'idx_outbox_status', columns: {#status, #nextAttemptAt})
@TableIndex(name: 'idx_outbox_entity', columns: {#entity, #entityUuid})
@TableIndex(name: 'idx_outbox_created', columns: {#createdAt})
@DataClassName('SyncQueueEntry')
class SyncOutbox extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// **Idempotency key** enviada al servidor. El servidor registra los `op_id`
  /// ya aplicados, de forma que un reintento tras un timeout no duplica la
  /// operación (crítico en ventas).
  TextColumn get opId => text().withLength(min: 8, max: 64)();

  TextColumn get entity => text().map(const SyncEntityConverter())();

  /// UUID de la fila afectada (identidad global, no el id local).
  TextColumn get entityUuid => text()();

  TextColumn get operation => text().map(const SyncOperationConverter())();

  /// Snapshot completo de la fila en JSON (para que el servidor no necesite
  /// aplicar deltas: aplica el estado final).
  TextColumn get payloadJson => text()();

  TextColumn get status => text().map(const SyncStatusConverter())();

  /// Número de intentos realizados.
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// Último error recibido (para diagnóstico en la UI).
  TextColumn get lastError => text().nullable()();

  /// Momento del último intento.
  DateTimeColumn get lastAttemptAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();

  /// Momento en que debe reintentarse (retroceso exponencial).
  DateTimeColumn get nextAttemptAt => integer().map(const DateTimeMillisConverter())();

  /// Marca de tiempo de la última escritura local (Last Write Wins).
  DateTimeColumn get lwwTimestamp => integer().map(const DateTimeMillisConverter())();

  /// Prioridad: menor = antes. Las ventas viajan antes que los cambios de
  /// catálogo para no retrasar la conciliación de caja.
  IntColumn get priority => integer().withDefault(const Constant(100))();

  /// HTTP status del último fallo (0 si no hubo respuesta).
  IntColumn get lastHttpStatus => integer().withDefault(const Constant(0))();

  TextColumn get deviceId => text().nullable()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();

  /// Momento en que se confirmó la sincronización.
  DateTimeColumn get syncedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{opId};
}

/// Cursor de lectura incremental por entidad.
///
/// La nube no envía "todo": envía lo que cambió desde `lastPulledAt`.
@TableIndex(name: 'idx_cursors_entity', columns: {#entity}, unique: true)
@DataClassName('SyncCursor')
class SyncCursors extends Table {
  TextColumn get entity => text().map(const SyncEntityConverter())();

  /// Fecha del último registro remoto aplicado (`updated_at` del servidor).
  DateTimeColumn get lastPulledAt => integer().map(const DateTimeMillisConverter())();

  /// Versión de esquema remota observada (diagnóstico de compatibilidad).
  IntColumn get lastServerVersion => integer().withDefault(const Constant(1))();

  /// Filas aplicadas desde el último ciclo.
  IntColumn get rowsApplied => integer().withDefault(const Constant(0))();

  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{entity};
}

/// Bitácora de sincronización (feed visible en Configuración > Sincronización).
///
/// Se conserva una ventana acotada: se purgan los eventos antiguos en cada
/// ciclo para no engordar la base de datos de una caja que lleva años operando.
@TableIndex(name: 'idx_sync_events_created', columns: {#createdAt})
@DataClassName('SyncEvent')
class SyncEvents extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  /// `info` | `warning` | `error` | `success`
  TextColumn get level => text().withDefault(const Constant('info'))();

  TextColumn get message => text()();

  TextColumn get entity => text().nullable().map(const NullableSyncEntityConverter())();

  TextColumn get entityUuid => text().nullable()();

  /// Contadores del ciclo: `{"pushed": 12, "pulled": 3, "failed": 0}`
  TextColumn get metricsJson => text().nullable()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
}
