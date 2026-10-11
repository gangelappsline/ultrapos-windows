# UltraPOS en Windows: compilación, permisos de red y puesta en marcha

Todo lo que hay que hacer en un equipo Windows nuevo (el de desarrollo y el de
la caja), en orden. El resumen de una línea:

```
pwsh -ExecutionPolicy Bypass -File tool/setup_windows.ps1
```

## 1. Requisitos del equipo de desarrollo

| Componente | Versión | Nota |
| --- | --- | --- |
| Windows | 10 21H2+ / 11 | x64. Se usan APIs de spooler y COM. |
| Flutter SDK | 3.35 o superior (stable) | `flutter doctor -v` debe dar Windows OK. |
| Visual Studio | 2022, carga **"Desarrollo para escritorio con C++"** | Incluye MSVC v143, Windows SDK 10 y CMake. |
| Git | cualquiera | Para clonar y para `flutter pub get` en dependencias git. |
| PowerShell | 5.1 o 7+ | El script funciona en ambos. |

Comprobación rápida:

```powershell
flutter --version
flutter doctor -v
flutter config --enable-windows-desktop
```

## 2. Puesta en marcha del repositorio

El repositorio **no versiona la carpeta `windows/`**: la genera Flutter según su
versión (cambia entre releases) y el script de arranque la parchea con las
plantillas de `tool/windows_templates/`.

```powershell
git clone <repo> ultrapos
cd ultrapos
pwsh -ExecutionPolicy Bypass -File tool/setup_windows.ps1
```

Qué hace el script, paso a paso:

1. Verifica `flutter` y habilita el escritorio de Windows.
2. `flutter create --platforms=windows --project-name ultrapos --org com.ultrapos .`
   (solo si `windows/runner/main.cpp` no existe: es idempotente).
3. Copia los parches del runner: `main.cpp` (título, tamaño inicial, contexto
   COM, modo kiosco) y `Runner.rc` (versión del producto, icono, DPI).
4. **Añade** `tool/windows_templates/CMakeLists.append.cmake` al final de
   `windows/CMakeLists.txt` (no lo reemplaza: la plantilla de Flutter cambia
   entre versiones). El parche aplica la versión del producto, exige
   `OPENSSL_ROOT_DIR` si se pidió cifrado y permite fijar la versión de pdfium.
5. `flutter pub get`.
6. `dart run build_runner build --delete-conflicting-outputs` (genera el código
   de Drift: `*.g.dart`. Sin este paso no compila).
7. `flutter build windows --release --dart-define=ULTRAPOS_ENV=production`.

Resultado: `build\windows\x64\runner\Release\ultrapos.exe` (acompañado de
`flutter_windows.dll` y de la carpeta `data/`; se distribuye la carpeta completa).

Para solo preparar el proyecto sin compilar: `-SkipBuild`.

## 3. Variables de compilación (`--dart-define`)

| Variable | Efecto | Valor por defecto |
| --- | --- | --- |
| `ULTRAPOS_ENV` | `development` / `staging` / `production`. En producción el log detallado se apaga. | `development` |
| `ULTRAPOS_SYNC_URL` | Endpoint REST de sincronización. Si está vacío, la app funciona **100 % local**. | vacío |
| `ULTRAPOS_SUPABASE_URL` + `ULTRAPOS_SUPABASE_ANON_KEY` | Alternativa a `ULTRAPOS_SYNC_URL` con Supabase. | vacío |
| `ULTRAPOS_DB_ENCRYPTION` | `true` cifra la base con SQLCipher (requiere OpenSSL, ver §5). | `false` |
| `ULTRAPOS_LOG_SQL` | `true` vuelca el SQL de Drift en la consola (solo desarrollo). | `false` |

Ejemplo de compilación de producción con nube:

```powershell
flutter build windows --release `
  --dart-define=ULTRAPOS_ENV=production `
  --dart-define=ULTRAPOS_SYNC_URL=https://api.minegocio.com/ultrapos
```

> Los `--dart-define` forman parte del binario: cambiar la URL exige recompilar.
> Es deliberado — un POS no debe poder apuntar a un servidor arbitrario por un
> archivo de texto editable.

## 4. Permisos de red en Windows

La caja necesita **salida** a la nube y, si la impresora es de red, a la
impresora. Nada de entrada.

- **Firewall de Windows.** Al primer arranque del `.exe` aparece el aviso
  "Permitir que esta aplicación se comunique…". Para instalarlo sin interacción
  (despliegue por GPO o script):

  ```powershell
  New-NetFirewallRule -DisplayName "UltraPOS (salida)" -Direction Outbound `
    -Program "C:\UltraPOS\ultrapos.exe" -Action Allow -Profile Domain,Private
  ```

  No hace falta ninguna regla de entrada: la aplicación no escucha puertos.

- **Impresora de red (ESC/POS en 9100).** Si la impresora está en otra subred,
  habilitar la salida al puerto:

  ```powershell
  New-NetFirewallRule -DisplayName "UltraPOS impresora 9100" -Direction Outbound `
    -Protocol TCP -RemotePort 9100 -Action Allow -Profile Domain,Private
  ```

- **Proxy corporativo.** Flutter usa el proxy del sistema (`WinHTTP`). Si el
  equipo sale por un proxy con autenticación, hay que configurarlo en Windows
  (Configuración > Red > Proxy) o usar un proxy transparente: la app no pide
  credenciales de proxy.

- **Modo local.** Si el comercio no quiere nube, no se define `ULTRAPOS_SYNC_URL`
  y no hay tráfico de salida alguno; todo queda en `%LOCALAPPDATA%` con
  respaldos manuales a USB desde Configuración > Datos.

## 5. Cifrado de la base de datos (opcional, SQLCipher)

Por defecto la base **no** está cifrada: entre velocidad de arranque, robustez
ante antivirus y cifrado, un POS de barrio prioriza los dos primeros. Para
equipos expuestos (retail grande, kiosco en calle):

```powershell
# 1) OpenSSL 3.x (vcpkg)
vcpkg install openssl:x64-windows

# 2) Dependencia de cifrado
flutter pub add sqlcipher_flutter_libs

# 3) Compilar
flutter build windows --release `
  --dart-define=ULTRAPOS_ENV=production `
  --dart-define=ULTRAPOS_DB_ENCRYPTION=true `
  --cmake-args="-DOPENSSL_ROOT_DIR=C:/vcpkg/installed/x64-windows"
```

Errores típicos y qué significan:

| Error | Causa | Solución |
| --- | --- | --- |
| `Could NOT find OpenSSL` | Falta `OPENSSL_ROOT_DIR` | Pasar la ruta del paso 3 (el parche de CMake avisa antes con un mensaje claro). |
| `LINK : fatal error LNK2019 … OPENSSL` | OpenSSL de 32 bits o de otra versión | Usar el build `x64-windows` y borrar `build/` antes de recompilar. |
| La app arranca y la BD está vacía | Cambió la clave y el archivo ya existía | Restaurar el respaldo o borrar `%LOCALAPPDATA%\UltraPOS\ultrapos.sqlite`. |

La clave se genera en el primer arranque y se guarda en el almacén seguro de
Windows (DPAPI, ligada al usuario de Windows): copiar el `.sqlite` a otro equipo
no sirve para leerlo.

## 6. Hardware

**Impresora térmica.**

- **USB instalada en Windows** (la más común): instalar el driver del fabricante
  y elegir en Configuración > Impresora > "Impresora de Windows" el nombre exacto
  de la cola. Se envía RAW por el spooler (`winspool.drv`), sin pasar por el
  driver: los caracteres ESC/POS no se interpretan como texto.
- **Red (LAN)**: elegir "Impresora de red" e indicar IP y puerto (9100 por
  defecto). Probar con `Imprimir prueba` antes de dar la caja por lista.
- **Serie (COM)**: 9600/19200/38400/115200 baudios.
- **Sin impresora**: "Solo PDF". El ticket se abre en el visor y se puede
  imprimir en cualquier láser.

**Cajón de dinero.** Se abre, por orden de fiabilidad: (1) con el pulso ESC/POS
enviado a la impresora (puerto RJ11 de la impresora), (2) por puerto serie
propio. Se configura en Configuración > Impresora > Cajón.

**Lector de código de barras.** Cualquiera en modo "teclado" (HID). El sistema
distingue al lector del tecleo humano por la ráfaga de caracteres (50 ms) y
busca primero por coincidencia exacta de código de barras/SKU.

## 7. Instalación en la caja

1. Copiar la carpeta completa `build\windows\x64\runner\Release\` a
   `C:\UltraPOS\` en el equipo de la caja.
2. Crear un acceso directo en el escritorio (y en la carpeta de inicio, si es
   una terminal dedicada).
3. Primer arranque:
   - Configuración > Empresa: razón social, NIT y moneda (salen en el ticket).
   - Configuración > Impresora: tipo, destino y **Imprimir prueba**.
   - Configuración > Usuarios: crear un administrador con PIN y un cajero.
   - Inventario: cargar categorías y productos (o importar por CSV).
   - Caja: abrir turno antes de vender en efectivo.
4. Modo kiosco (opcional): crear la variable de entorno de usuario
   `ULTRAPOS_KIOSK=1`. La ventana arranca fija y sin maximizar/minimizar.

## 8. Diagnóstico rápido

| Síntoma | Dónde mirar |
| --- | --- |
| No imprime | Configuración > Impresora > Imprimir prueba; cola de impresión de Windows; nombre exacto de la impresora. |
| El cajón no abre | Tipo de cajón (impresora o COM) y que el efectivo esté habilitado como método en la venta. |
| "Sin conexión · N pendientes" | Configuración > Sincronización: cola local, último error y antigüedad. La caja **sigue vendiendo**: el pendiente es solo la subida. |
| La app no abre | `%LOCALAPPDATA%\UltraPOS\logs\` (log rotativo diario). |
| Pantalla borrosa | El manifiesto del runner ya declara DPI por monitor; si persiste, revisar el escalado en Windows (>150 % en pantallas de 1366x768 no es recomendable). |
