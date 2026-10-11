# Motor de sincronización de UltraPOS

UltraPOS vende sin internet. La sincronización es una **consecuencia** de la
venta, nunca un requisito previo. Este documento explica el contrato, cómo se
garantiza que una venta no se duplique y cómo conectar un backend.

## 1. Piezas

```
lib/core/sync/
├── sync_models.dart       # Envelopes, resultados, estado, configuración remota
├── sync_backoff.dart      # Retroceso exponencial acotado (3 s → 15 min)
├── sync_engine.dart       # Un ciclo: tomar lote → enviar → aplicar respuesta
├── sync_service.dart      # Fachada: arranque, latido, conectividad, estado
├── remote_api.dart        # Transporte HTTP (REST genérico o Supabase)
├── remote_apply.dart      # Aplicar cambios que llegan desde la nube
└── conflict_resolver.dart # Last Write Wins + reglas por entidad
```

Tablas implicadas:

| Tabla | Papel |
| --- | --- |
| `sync_outbox` | Cola de operaciones locales pendientes (`op_id` único = clave de idempotencia). |
| `sync_cursors` | Puntero de lectura por entidad (qué se trajo ya del servidor). |

## 2. Contrato de datos

`lib/core/database/sync_payloads.dart` define un único formato:

- **Snapshot completo de la fila** (no deltas): el servidor aplica el estado
  final, sin tener que reproducir la historia.
- Dinero → `*_cents` (entero), cantidades → `*_milli` (entero, 1000 = 1 unidad),
  enums → `storageKey`, fechas → ISO-8601 en **UTC**.
- El `id` local (autoincremental) **nunca viaja**: la identidad global es el
  `uuid`.
- La venta viaja como **agregado**: `sale` + `items[]` + `payments[]` en una sola
  operación. Un ticket a medias en la nube es un ticket corrupto.
- `SyncPayloads.sale(...)` garantiza ese agregado; `customer`, `product`,
  `category`, `user`, `stockMovement`, `cashSession`, `cashMovement`, `setting`
  y el centinela `company` cubren el resto.

Prioridades de la cola (menor = antes): catálogo y clientes primero (para que las
referencias existan), ventas después, configuración al final. El orden evita que
una venta llegue antes que el producto al que apunta.

## 3. Ciclo de sincronización

```
                    ┌───────────────────────────────┐
  cambio de         │  despierta por:               │
  conectividad ────▶│  · latido (cada 60 s)         │
  o nueva venta     │  · cambio de red              │
                    │  · "Sincronizar ahora"        │
                    └───────────────┬───────────────┘
                                    ▼
                   tomar lote (≤40 ops, prioridad y next_attempt_at)
                                    ▼
              marcar in_flight ──▶ enviar (POST /sync/push, timeout 25 s)
                                    ▼
             ┌──────────── éxito ───────────┐   ┌──────── fallo ─────────┐
             │ synced + synced_at           │   │ retry con backoff      │
             │ aplicar pull (si hay)        │   │ 3s, 6s, 12s… 15 min    │
             │ actualizar cursores          │   │ tras 12 intentos:      │
             └──────────────────────────────┘   │ failed (visible en UI) │
                                                └────────────────────────┘
```

- **Idempotencia:** cada operación lleva `op_id` (UUID). Antes de enviar, si el
  proceso murió a mitad, la fila queda `in_flight` con `last_attempt_at`; al
  reanudar se considera reintentable y **el servidor responde "ya aplicado"**
  para el mismo `op_id`. Resultado: la venta se registra exactamente una vez.
- **Un ciclo a la vez:** `SyncService` mantiene una única ejecución en curso
  (`_runningCycle`); un segundo disparo se ignora en lugar de encolarse.
- **Latido:** no hay sondeo agresivo. Si no hay nada pendiente, el ciclo es una
  consulta local y termina.

## 4. Conflictos

| Entidad | Regla | Motivo |
| --- | --- | --- |
| Precio, costo, stock, ficha de producto | **LWW** por `lww_timestamp` | El dato más reciente es el que el dueño acaba de escribir. |
| Cliente (nombre, teléfono, límite) | **LWW** | Igual que arriba, pero el saldo se **suma**, nunca se sobrescribe. |
| Venta, pago, movimiento de caja | **Nunca se reescriben** | Un ticket es un hecho histórico. Si llega un cambio remoto para una venta ya aplicada, se registra `conflict` y se conserva el local. |
| Borrado | LWW sobre `deleted_at` | Borrado lógico: la historia sobrevive. |

El estado `conflict` en `sync_outbox` significa "el servidor tenía una versión
más nueva y la resolución quedó registrada", no un error: se muestra en
Sincronización y no bloquea nada.

## 5. Conectar un backend

### Opción A — REST propio (por defecto)

```powershell
flutter build windows --release `
  --dart-define=ULTRAPOS_ENV=production `
  --dart-define=ULTRAPOS_SYNC_URL=https://api.minegocio.com/ultrapos
```

Endpoints que espera `remote_api.dart`:

| Método | Ruta | Cuerpo / respuesta |
| --- | --- | --- |
| `POST` | `/sync/push` | `{device_id, ops:[{op_id, entity, entity_uuid, operation, payload, lww}]}` → `{results:[{op_id, status:"applied"|"conflict"|"rejected", server_lww}]}` |
| `POST` | `/sync/pull` | `{device_id, cursors:{entity: iso}}` → `{changes:[{entity, entity_uuid, operation, payload, lww}]}` |
| `GET` | `/sync/config` | `{mode, interval_seconds, batch_size}` (opcional) |
| `GET` | `/health` | Prueba de conexión de la pantalla de configuración (cualquier 2xx). |

Los encabezados de cada petición son `X-UltraPOS-Device: <device_id>` y, si hay
clave publicable configurada, `Authorization: Bearer <anon_key>`.

Regla de oro del servidor: **`op_id` como clave única de la tabla de operaciones
aplicadas**. Un `op_id` repetido se responde `applied` sin volver a escribir.

### Opción B — Supabase

```powershell
flutter build windows --release `
  --dart-define=ULTRAPOS_SUPABASE_URL=https://xxxx.supabase.co `
  --dart-define=ULTRAPOS_SUPABASE_ANON_KEY=eyJhbGciOi...
```

Tablas sugeridas (una por entidad sincronizable, con `uuid` único,
`updated_at`/`lww`, `device_id`, `deleted_at`) y una tabla
`sync_operations(op_id primary key, applied_at)`. La `anon key` es pública por
diseño: la protección real son las políticas RLS (una caja solo ve su comercio).

### Opción C — Sin nube

No se define ninguna variable: la app funciona 100 % local, la cola queda en
`sent`/`pending` sin salir del equipo y los respaldos se hacen a USB desde
Configuración > Datos. Es el modo recomendado para una sola caja.

## 6. Qué ve el usuario

Nada técnico. En Configuración > Sincronización:

- **Estado**: sincronizado / sin conexión / N pendientes / N con error.
- **Cola**: entidad, operación, intento, último error y fecha de cada operación.
- **Reintentar fallidos** y **Sincronizar ahora** como acciones explícitas.

En la barra de estado inferior hay un icono permanente (nube con las pendientes).
Si la caja se queda sin internet, se sigue vendiendo y ese contador es el único
recordatorio visible.
