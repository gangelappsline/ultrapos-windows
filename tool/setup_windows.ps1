<#
.SYNOPSIS
    Bootstrap del proyecto UltraPOS en Windows (PowerShell 7+ / 5.1).

.DESCRIPTION
    Automatiza los pasos que NO pueden venir versionados en el repositorio:
      1. Verifica el SDK de Flutter.
      2. Genera la carpeta `windows/` (runner nativo C++).
      3. Aplica los parches de UltraPOS al runner (título, tamaño, DPI, icono).
      4. Resuelve dependencias y genera el código de Drift.
      5. Compila el instalador de release.

.PARAMETER SkipBuild
    Solo prepara el proyecto, sin compilar el .exe de release.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File tool/setup_windows.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Write-Step([string]$text) {
    Write-Host ""
    Write-Host "=== $text ===" -ForegroundColor Cyan
}

function Assert-Command([string]$name, [string]$hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "No se encontró '$name'. $hint"
    }
}

Write-Step 'Verificando toolchain'
Assert-Command 'flutter' 'Instala Flutter 3.35+ y agrégalo al PATH: https://docs.flutter.dev/get-started/install/windows'
flutter --version
flutter config --enable-windows-desktop | Out-Null

Write-Step 'Generando runner nativo de Windows'
if (-not (Test-Path 'windows/runner/main.cpp')) {
    flutter create --platforms=windows --project-name ultrapos --org com.ultrapos .
} else {
    Write-Host 'windows/ ya existe: se omite flutter create.'
}

Write-Step 'Aplicando parches de UltraPOS al runner'
$templates = Join-Path $root 'tool/windows_templates'
if (Test-Path $templates) {
    # main.cpp y Runner.rc son reemplazos completos de archivos del runner;
    # CMakeLists.append.cmake se AÑADE al CMakeLists generado (no lo reemplaza,
    # porque la plantilla cambia entre versiones de Flutter).
    Copy-Item -Path (Join-Path $templates 'runner/*') -Destination (Join-Path $root 'windows/runner') -Recurse -Force
    Write-Host 'Runner parcheado (main.cpp, Runner.rc).' -ForegroundColor Green

    $cmakeTarget = Join-Path $root 'windows/CMakeLists.txt'
    $snippet = Join-Path $templates 'CMakeLists.append.cmake'
    $marker = '# --- UltraPOS (parche aplicado por tool/setup_windows.ps1) ---'
    if (-not (Select-String -Path $cmakeTarget -SimpleMatch $marker -Quiet)) {
        Add-Content -Path $cmakeTarget -Value ''
        Add-Content -Path $cmakeTarget -Value $marker
        Get-Content -Path $snippet | Add-Content -Path $cmakeTarget
        Write-Host 'Parche de CMake añadido a windows/CMakeLists.txt.' -ForegroundColor Green
    } else {
        Write-Host 'El parche de CMake ya estaba aplicado.'
    }
} else {
    Write-Warning "No se encontraron plantillas en $templates"
}

# Icono de la aplicación: solo si existe el archivo de marca (es opcional).
$brandIcon = Join-Path $root 'assets/branding/ultrapos.ico'
$runnerIcon = Join-Path $root 'windows/runner/resources/app_icon.ico'
if ((Test-Path $brandIcon) -and (Test-Path (Split-Path $runnerIcon -Parent))) {
    Copy-Item -Path $brandIcon -Destination $runnerIcon -Force
    Write-Host 'Icono de la aplicación aplicado.' -ForegroundColor Green
} else {
    Write-Host 'Sin assets/branding/ultrapos.ico: se usa el icono por defecto.' -ForegroundColor Yellow
}

Write-Step 'Resolviendo dependencias'
flutter pub get

Write-Step 'Generando código de Drift'
dart run build_runner build --delete-conflicting-outputs

if (-not $SkipBuild) {
    Write-Step 'Compilando release Windows (x64)'
    flutter build windows --release --dart-define=ULTRAPOS_ENV=production
    Write-Host ""
    Write-Host "Listo -> build\windows\x64\runner\Release\ultrapos.exe" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host 'Preparación completa (sin compilar).' -ForegroundColor Green
}
