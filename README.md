# UltraPOS — Punto de venta para Windows

Aplicación de escritorio **offline-first** para comercios: ventas rápidas,
inventario, clientes, caja con arqueo, reportes y sincronización opcional con la
nube. Escrita en Flutter (solo Windows), con SQLite/Drift local y Riverpod como
gestión de estado.

> Toda operación se guarda **primero** en el equipo y la interfaz se actualiza al
> instante. La nube es una consecuencia, nunca un requisito: si se cae el
> internet, la caja sigue cobrando.

## Módulos

| Módulo | Qué resuelve |
| --- | --- |
| **Ventas** | Búsqueda por nombre/código de barras/SKU, carrito con impuesto y descuentos automáticos, cliente opcional (consumidor final por defecto), pago en efectivo/tarjeta/transferencia/mixto/crédito, ticket a impresora térmica. |
| **Inventario** | Productos con categorías, precio y costo, stock y stock mínimo con alertas, entradas/salidas/pérdidas/conteo físico, historial de movimientos. |
| **Clientes** | NIT/RUC, teléfono, correo, límite y saldo de crédito, historial de compras. |
| **Caja** | Apertura y cierre de turno, arqueo por denominación, movimientos de efectivo, cuadre con diferencia y nota. |
| **Reportes** | Ventas por día, ticket promedio, impuestos, utilidad, rankings de productos y cajeros, exportación a PDF y CSV. |
| **Configuración** | Datos del negocio, impuestos, impresora y cajón, sincronización, usuarios y roles (Administrador/Supervisor/Cajero), respaldos. |

## Empezar

```powershell
git clone <repo> ultrapos
cd ultrapos
pwsh -ExecutionPolicy Bypass -File tool/setup_windows.ps1
```

El script genera el runner de Windows, aplica los parches de UltraPOS, resuelve
dependencias, genera el código de Drift y compila el release. Instrucciones
completas (permisos de red, cifrado opcional, hardware, instalación en caja):
**[docs/WINDOWS_SETUP.md](docs/WINDOWS_SETUP.md)**.

## Documentación

| Documento | Contenido |
| --- | --- |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Estructura de carpetas, decisiones técnicas (Riverpod, Drift, outbox), flujo de una venta. |
| [docs/SYNC_ENGINE.md](docs/SYNC_ENGINE.md) | Motor de sincronización: contrato de datos, idempotencia de ventas, LWW, backend REST/Supabase. |
| [docs/UI_GUIDE.md](docs/UI_GUIDE.md) | Paleta del logo, tipografía, espaciado, boceto de la pantalla principal y reglas de escritorio. |
| [docs/WINDOWS_SETUP.md](docs/WINDOWS_SETUP.md) | Compilación, permisos de red, impresoras, cajón, kiosco, diagnóstico. |

## Atajos

`F2` Buscar · `F3` Cliente · `F4` Ventas en espera · `F5` Sincronizar ·
`F6` Descuento · `F7` Cantidad · `F8` Retirar línea · `F9` Pago mixto ·
`F10` Abrir cajón · **`F12` Cobrar** · `Ctrl+P` Reimprimir · `Ctrl+L` Cerrar
sesión · `Esc` Cancelar · `F1` Ayuda.

## Paleta

Azul profundo `#0A2A4A` · Cyan `#00AEEF` · Naranja de cobro `#FF6B00` ·
Fondo claro `#F5F7FA` · Rojo de error `#E53935`.

## Estado del proyecto

Código base completo por módulos sobre la arquitectura descrita. Antes del
primer build hay que ejecutar `setup_windows.ps1` (genera `windows/` y el código
de Drift). El cifrado de base de datos (SQLCipher) y el backend en la nube son
opcionales y están apagados por defecto: `flutter build windows --release` sin
variables produce un POS 100 % local.
