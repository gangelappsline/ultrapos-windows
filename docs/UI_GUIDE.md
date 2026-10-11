# Guía de interfaz y boceto de la pantalla principal

Objetivo: que UltraPOS **se sienta como software nativo de Windows**, no como
una app móvil estirada. Eso se consigue con densidad, atajos visibles y cero
ceremonias: el cajero no debe tocar el mouse en ningún momento del día.

## 1. Paleta (valores exactos del logo)

| Color | Hex | Uso |
| --- | --- | --- |
| Azul profundo | `#0A2A4A` | Navegación lateral, barras, títulos, texto principal. |
| Cyan de acción | `#00AEEF` | Botones de acción, iconos activos, series de gráficos, foco. |
| Naranja de cobro | `#FF6B00` | **Botón COBRAR**, total a pagar, alertas de stock bajo. |
| Fondo claro | `#F5F7FA` | Fondo de pantalla, tarjetas y modales. |
| Rojo de error | `#E53935` | Errores, anulaciones, faltantes de caja. |

Derivados en `app_colors.dart` (`deepBlue600`, `cyanSurface`, `orangeSurface`,
`redSurface`, `success`, `warning`, grises). Reglas de uso:

- El naranja es **escaso por diseño**: solo aparece en cobrar, totales y
  alertas. Si todo es naranja, nada llama la atención.
- El rojo nunca se usa para decorar: solo error, anulación y diferencia de caja.
- Nada de texto sobre cyan puro: el contraste no alcanza AA. Sobre cyan, texto
  azul profundo o blanco con peso ≥ 600.

## 2. Tipografía, espacio y forma

- Familia: **Inter** si está empaquetada; si no, `Segoe UI Variable Text` /
  `Segoe UI` (la nativa de Windows). Siempre hay una disponible: la app compila
  y se ve bien sin assets.
- Escala (escritorio, 1366x768 mínimo): `display` 22, `headline` 17-19,
  `title` 15, `body` 13, `caption` 11.5, `table` 12.5.
- **Cifras tabulares** (`AppTypography.tabularFigures`) en toda columna de
  dinero, cantidades y contadores: los importes no "bailan" al recorrer la lista.
- Radios: 8 (controles), 10 (tarjetas pequeñas), 12 (tarjetas y modales).
- Sombra de tarjeta: una sola, sutil (`AppColors.cardShadow`); más de dos
  niveles de elevación ensucian la pantalla.
- Alturas fijas: barra de título 40, encabezado de módulo 44, controles 38
  (48 en el primario del cobro), barra de estado 30. Nada cambia de alto entre
  módulos: el ojo no debe recolocarse al cambiar de sección.
- Espaciado: 4/8/12/16/20/24 (`AppSpacing`). Rejilla de 12 px entre campos.

## 3. Marco de la aplicación

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ULTRAPOS  ·  CAJA-1                     _  □  ✕      (barra de título propia) │
├────────────┬─────────────────────────────────────────────────────────────────┤
│ ▣ Ventas   │  Ventas                            [Buscar F2] [Cliente F3]…   │ 44
│ ▤ Inventar.│ ─────────────────────────────────────────────────────────────── │
│ ☺ Clientes │  ┌───────────────────────────────┐ ┌──────────────────────────┐ │
│ ▦ Caja     │  │ BUSCAR PRODUCTO (F2)          │ │ CARRITO                  │ │
│ ▥ Reportes │  │ ┌───────────────────────────┐ │ │ ┌──────────────────────┐ │ │
│ ⚙ Config.  │  │ │ escanear o escribir…      │ │ │ │ 3 x Café 250g   C$120│ │ │
│            │  │ └───────────────────────────┘ │ │ │ 1 x Pan molde    C$55│ │ │
│  216 px    │  │ ▸ 100021  Café 250g   3 disp. │ │ │ 2 x Leche 1L    C$80 │ │ │
│            │  │ ▸ 100022  Café 500g   1 disp. │ │ └──────────────────────┘ │ │
│  (colapsa  │  │ ▸ SKU-77  Azúcar 1kg  12 disp.│ │ Subtotal          C$255 │ │
│   a 76 px) │  │                                │ │ Descuento (F6)   -C$10  │ │
│            │  │                                │ │ IVA 15% incl.    C$33.2 │ │
│            │  │                                │ ├──────────────────────────┤ │
│            │  │                                │ │ TOTAL    C$245.00        │ │
│            │  │                                │ │ ┌──────────────────────┐ │ │
│            │  │                                │ │ │   COBRAR   (F12)     │ │ │
│            │  │                                │ │ └──────────────────────┘ │ │
│            │  │                                │ │ [F9 Mixto] [F4 Espera]  │ │
│            │  └───────────────────────────────┘ └──────────────────────────┘ │
├────────────┴─────────────────────────────────────────────────────────────────┤
│ ● Turno abierto 14:20 · María   │  ☁ 2 pendientes │ F2 Buscar · F12 Cobrar…  │ 30
└──────────────────────────────────────────────────────────────────────────────┘
```

### Descripción textual del boceto (para diseño)

**Barra de título propia (40 px, azul profundo).** Nombre del negocio, equipo
(`CAJA-1`) y los tres botones de ventana a la derecha, dibujados por la app
(`window_manager`) para que el marco se vea oscuro y coherente con la paleta, en
lugar del gris del sistema. Arrastrable; doble clic maximiza.

**Navegación lateral (216 px, azul profundo; 76 px compacta si el ancho baja de
1440).** Seis módulos con icono + etiqueta y su atajo (F2…F7). El módulo activo
se marca con una barra cyan de 3 px al borde izquierdo y fondo `deepBlue800`: se
lee de reojo, sin animaciones.

**Encabezado del módulo (44 px, fondo claro).** Título a la izquierda
(`headline`), acciones a la derecha. En Ventas: **Buscar (F2)** con foco
permanente en la caja de búsqueda, **Cliente (F3)**, **Descuento (F6)**,
**En espera (F4)**.

**Columna izquierda: búsqueda de producto (flex 3).**
- Caja de búsqueda grande (48 px) con etiqueta "escanear o escribir…". El foco
  vive aquí siempre: el cajero teclea o dispara el lector y nunca más toca el
  mouse.
- Lista de resultados en filas de 40 px (`DataRowTile`): SKU (monoespaciado),
  nombre, precio alineado a la derecha con cifras tabulares y **disponibilidad**
  a la derecha: `12` en gris, `3` en naranja si queda poco, `agotado` en rojo.
- Coincidencia exacta de código de barras/SKU = arriba del todo y auto-añadida
  al carrito (la ráfaga del lector no debe dejarse "confirmar" a mano).
- Enter sobre una fila la agrega; `F7` permite teclear cantidad y Enter.

**Columna derecha: carrito y cobro (420 px mínimo, flex 2).**
- Filas de línea a 44 px: `cantidad × producto`, importe a la derecha, y el
  descuento de línea como chip cyan cuando existe. `F8` retira la línea.
- Subtotal, descuento e impuesto (`IVA 15% incl.`) en `body`; la base fiscal se
  describe en texto, no se esconde.
- **Total a pagar** en `display` (22) sobre una franja de fondo claro con el
  importe en azul profundo: es el dato que el cajero lee en voz alta.
- **Botón COBRAR**: naranja `#FF6B00`, 48 px, ancho completo, con la etiqueta
  `COBRAR  (F12)`. Es el único elemento naranja de la pantalla y debe ser el
  más grande: F12 y Enter son equivalentes.
- Debajo: `F9 Pago mixto`, `F4 En espera`, `Ctrl+P Reimprimir` como botones
  secundarios (texto + icono), nunca como botones grandes.

**Barra de estado (30 px, azul profundo).** Turno abierto con hora y cajero,
estado de sincronización (`☁ 2 pendientes`), y la leyenda de atajos en
`caption`. Es la memoria del sistema: el cajero deja de preguntar "¿quedó
guardado?".

## 4. Ventanas modales (cobro, cliente, arqueo)

- Ancho 520-640 px, radio 12, fondo `#F5F7FA`, sombra de tarjeta.
- El campo que importa arranca con foco y texto seleccionado: en Cobro, el
  importe recibido; en Cierre de caja, la primera denominación.
- Acciones a la derecha, primaria siempre a la derecha del todo (`Cobrar`,
  `Guardar`), `Esc` cancela.
- Feedback de error **dentro** del modal (`InlineBanner` rojo), nunca en un
  diálogo encima del diálogo.
- Diálogos sin animación de escala: un `fade` de 80 ms como máximo. Un POS no
  hace esperar al cajero para "verse moderno".

## 5. Atajos (deben funcionar siempre, en cualquier módulo)

| Tecla | Acción | Tecla | Acción |
| --- | --- | --- | --- |
| `F1` | Ayuda | `F8` | Retirar línea |
| `F2` | Buscar producto | `F9` | Pago mixto |
| `F3` | Cliente | `F10` | Abrir cajón |
| `F4` | Ventas en espera | `F12` | **COBRAR** |
| `F5` | Sincronizar | `Ctrl+P` | Reimprimir último ticket |
| `F6` | Descuento | `Ctrl+L` | Cerrar sesión |
| `F7` | Cantidad | `Esc` | Cancelar |

Los atajos son también botones visibles: el cajero los aprende viéndolos, no
leyendo un manual.

## 6. Reglas de color por estado

| Estado | Color | Dónde |
| --- | --- | --- |
| Stock bajo (≤ mínimo) | Naranja | Inventario, alertas del panel |
| Agotado / stock negativo | Rojo | Inventario, buscador de ventas |
| Turno de caja abierto | Verde | Barra de estado |
| Caja cerrada | Gris | Barra de estado |
| Diferencia de arqueo | Rojo (faltante) / verde (sobrante) | Cierre de caja |
| Operación sincronizada | Verde | Configuración > Sincronización |
| Pendiente de subir | Naranja | Barra de estado |
| Venta anulada | Rojo y tachada | Reportes, historial |

## 7. Lo que **no** se hace (y por qué)

- **No animaciones largas ni transiciones de pantalla**: cada milisegundo extra
  es una venta menos en hora punta.
- **No gestos táctiles** (swipe, long-press): el objetivo es un teclado, un
  lector y un mouse de tres botones.
- **No "hero cards" ni tarjetas gigantes**: la prioridad es ver 8-10 líneas de
  carrito en un 1366x768, no una imagen bonita.
- **No confirmaciones para todo**: solo se confirma lo irreversible (anular
  venta, cerrar turno, borrar cliente).
- **No tocar el ratón para cobrar**: F12 → importe → Enter → listo.
