# Arquitectura de UltraPOS

Punto de venta de escritorio para Windows, **offline-first**. La regla que
gobierna todas las decisiones de abajo:

> Ninguna operación de caja puede depender de la red, y ninguna venta puede
> perderse por culpa de la red.

## 1. Estructura de carpetas (por funcionalidad, no por tipo)

```
lib/
├── app/                         # Arranque y marco de la aplicación
│   ├── bootstrap.dart           #   inicialización: ventana, BD, sync, sesión
│   ├── app.dart                 #   MaterialApp + tema + atajos globales
│   └── shell/                   #   barra de título, navegación, barra de estado
│       ├── app_shell.dart       #     AppSection{sales..settings} + F2..F7
│       ├── title_bar.dart       #     minimizar/maximizar/cerrar (window_manager)
│       └── status_bar.dart      #     caja abierta, sync, atajos, reloj
│
├── core/                        # Infraestructura transversal (sin UI de negocio)
│   ├── config/app_config.dart   #   constantes, --dart-define, denominaciones
│   ├── theme/                   #   colores, tipografía, espacios, tema Material 3
│   ├── domain/                  #   enums + DTOs (sale_totals, report_models)
│   ├── database/
│   │   ├── app_database.dart    #   @DriftDatabase + Transactional Outbox
│   │   ├── tables/              #   18 tablas (sistema, catálogo, ventas, caja, sync)
│   │   ├── daos/                #   9 DAOs: la única puerta de entrada a los datos
│   │   ├── converters/          #   Money/Quantity/enums <-> columnas SQL
│   │   └── sync_payloads.dart   #   contrato con la nube (snapshots completos)
│   ├── sync/                    #   motor de sincronización (7 archivos)
│   ├── hardware/                #   impresora ESC/POS, cajón, lector, PDF
│   ├── security/                #   PIN (PBKDF2), almacén seguro (DPAPI)
│   ├── ui/                      #   kit de widgets de escritorio + gráficos
│   ├── utils/                   #   Money, Quantity, formatos, ids
│   ├── errors/app_failure.dart  #   jerarquía de fallos tipados
│   ├── logging/app_logger.dart  #   log a archivo + consola de depuración
│   └── providers.dart           #   grafo de proveedores de Riverpod
│
└── features/                    # Un módulo = una carpeta = una responsabilidad
    ├── auth/                    #   login con PIN, bloqueo por intentos
    ├── sales/                   #   carrito, cobro, tickets, pedidos en espera
    ├── inventory/               #   catálogo, stock, movimientos, categorías
    ├── customers/               #   fichas, historial, saldo (fiado)
    ├── cash/                    #   turnos, arqueo por denominación, movimientos
    ├── reports/                 #   panel, series, rankings, exportación
    │   └── application/report_exporter.dart
    └── settings/                #   negocio, operación, impresora, sync, usuarios
```

**Por qué por funcionalidad y no por capas.** El código que cambia junto vive
junto. Cuando hay que ajustar la regla de descuentos, todo lo relevante está en
`features/sales/`; no hay que recorrer siete carpetas.

## 2. Decisiones técnicas y su justificación

| Área | Decisión | Por qué (y qué se descartó) |
| --- | --- | --- |
| Plataforma | **Flutter 3.x, solo Windows desktop** | Un único binario nativo con DPI correcto, sin runtime aparte. Se descarta web/móvil: los requisitos (impresora térmica, cajón, COM/USB) son de escritorio. |
| Estado | **Riverpod 3** | (Descartado Bloc.) Los proveedores se componen y se invalidan solos: cuando cambia la tasa de impuesto, `operationSettingsProvider` se invalida y carrito, cobro y reportes recalculan sin reiniciar. Con Bloc eso serían eventos encadenados entre cuatro blocs, y el POS necesita que el precio cambie **ya**. |
| Base de datos | **SQLite + Drift** | (Descartado Isar.) El POS vive de consultas agregadas (ventas por día, por cajero, por método de pago, arqueo) y de transacciones: eso es SQL. Drift da consultas tipadas, migraciones versionadas, streams reactivos y `VACUUM INTO` para respaldos consistentes en caliente. Isar no tiene agregaciones ni respaldo caliente serio. |
| Escritura offline | **Transactional Outbox** | Cada escritura de negocio inserta, en la *misma transacción*, su fila de `sync_outbox`. No existe la ventana en la que "se guardó la venta pero no la intención de sincronizarla". |
| Idempotencia | **`op_id` único por operación** | El servidor registra los `op_id` aplicados: un reintento tras un timeout no duplica la venta. Es el requisito más crítico de todo el sistema. |
| Conflictos | **Last Write Wins por `lww_timestamp`** | Precios, stock y fichas: gana la escritura más reciente, y los **totales de venta nunca se reescriben** (una venta es un hecho, no un dato editable). |
| Reintentos | **Retroceso exponencial acotado** | 3 s → 6 s → 12 s … hasta 15 min, máximo 12 intentos, y luego estado `failed` visible en Configuración > Sincronización. Un cajero no debe ver el log; el administrador sí. |
| Cifrado | **SQLCipher opcional** (`ULTRAPOS_DB_ENCRYPTION=true`) | La clave vive en DPAPI (almacén seguro de Windows). Va apagado por defecto porque en Windows exige OpenSSL y complica el build: ver `docs/WINDOWS_SETUP.md`. |
| Impresión | **Generador ESC/POS propio + `pdf`/`printing`** | `esc_pos_printer` está sin mantenimiento desde 2021; se generan los bytes y se envían por spooler RAW (`winspool`), socket 9100 o COM. Si no hay impresora, el ticket sale en PDF. |

## 3. Flujo de una venta (el camino que hay que entender)

```
Cajero escanea ──▶ productByBarcodeProvider
                     │  (productsDao.findByBarcode: exacto primero)
                     ▼
              CartController.addByCode  ──▶  CartComputation  ──▶  UI (inmediata)
                     │                          ▲
                     │                          └── un solo cálculo (CartCalculator):
                     │                              precio, descuento, impuesto, redondeo
                     ▼
   F12 / "Cobrar" ──▶ PaymentDialog  ──▶ PaymentValidator (pagos, vuelto, fiado)
                     │
                     ▼
        CheckoutService.checkout ── UNA transacción SQLite ─────────────┐
        │  1. borra el borrador si era pedido en espera                │
        │  2. verifica stock (salvo allowNegativeStock)                │
        │  3. insertSale + folio por equipo (A-000123)                 │
        │  4. por línea: insertItem + applySaleMovement (stock+costo)  │
        │  5. insertPayment                                            │
        │  6. touchLastPurchase / applyCreditBalance (fiado)           │
        │  7. enqueueSaleAggregate → sync_outbox (op_id idempotente)   │
        │  8. recordAudit('sale','checkout')                           │
        └──────────────────────────────────────────────────────────────┘
                     │
                     ▼ (después del commit: el hardware nunca bloquea el cobro)
        HardwareManager.printSaleTicket  +  openCashDrawer
```

Si falla la impresión (impresora apagada, sin papel), la venta ya está cobrada y
guardada: se avisa al cajero y se ofrece reimprimir con Ctrl+P.

## 4. Reglas de diseño que hay que respetar al tocar el código

1. **Un solo cálculo.** Los importes por línea salen de `CartCalculator`. Nunca
   se recalcula un total "a mano" en una pantalla; si hace falta otro dato, se
   añade al cálculo.
2. **Un solo conversor carrito→venta.** `CheckoutService.buildSaleRequest` es el
   único punto donde el carrito se convierte en filas de venta (lo usan el cobro
   y "pedido en espera").
3. **Los DAOs son la única puerta a los datos.** Un widget nunca escribe SQL.
4. **Fuera de la transacción no hay hardware.** La impresora y el cajón se
   accionan después del commit.
5. **Nada de borrados físicos.** `deleted_at` (borrado lógico): un POS no borra
   historia.
6. **El PIN nunca se toca.** Solo `users_dao` conoce `pin_hash`/`pin_salt`, y
   jamás se sincronizan a la nube.
7. **La interfaz de escritorio se respeta.** Alturas de 34-38 px, atajos a la
   vista, sin animaciones largas: ver `docs/UI_GUIDE.md`.

## 5. Módulos y qué hace cada uno

| Módulo | Pregunta que responde | Pantalla principal |
| --- | --- | --- |
| Ventas | ¿Cómo cobro rápido y sin errores? | `sales_screen.dart` (F2 buscar, F12 cobrar) |
| Inventario | ¿Qué tengo, qué me falta, qué se movió? | `inventory_screen.dart` |
| Clientes | ¿Quién me debe y qué compró? | `customers_screen.dart` |
| Caja | ¿Cuadra el efectivo al cerrar el turno? | `cash_screen.dart` (arqueo por denominación) |
| Reportes | ¿Cómo va el negocio? | `reports_screen.dart` (+ PDF/CSV) |
| Configuración | ¿Quién puede hacer qué y por dónde imprime? | `settings_screen.dart` (6 pestañas) |
