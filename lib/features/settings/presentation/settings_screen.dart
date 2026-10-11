import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/daos/settings_dao.dart';
import '../../../core/database/daos/sync_dao.dart';
import '../../../core/domain/enums.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/hardware/hardware_manager.dart';
import '../../../core/hardware/printer_config.dart';
import '../../../core/hardware/printer_transport.dart';
import '../../../core/providers.dart';
import '../../../core/sync/sync_models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/ui/app_widgets.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/id_generator.dart';
import '../../auth/application/session_controller.dart';

/// Módulo de configuración, organizado por pestañas.
///
/// Cada pestaña responde a una pregunta concreta del dueño o del encargado:
///   * **Empresa** — ¿qué sale impreso en el ticket?
///   * **Operación** — ¿cómo se comporta la caja al vender?
///   * **Impresora** — ¿por dónde sale el papel y cómo se abre el cajón?
///   * **Sincronización** — ¿está subiendo todo a la nube?
///   * **Usuarios** — ¿quién puede hacer qué?
///   * **Datos** — respaldos, diagnóstico y mantenimiento.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 6, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isAdmin = ref.watch(sessionProvider).role.canConfigureSystem;

    return Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        children: <Widget>[
          const ModuleHeader(
            title: 'Configuración',
            subtitle: 'Datos del negocio, operación, hardware, usuarios y respaldos',
            icon: Icons.settings_outlined,
          ),
          const SizedBox(height: AppSpacing.md),
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: const <Widget>[
              Tab(text: 'Empresa'),
              Tab(text: 'Operación'),
              Tab(text: 'Impresora'),
              Tab(text: 'Sincronización'),
              Tab(text: 'Usuarios'),
              Tab(text: 'Datos'),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                const _CompanyTab(),
                const _OperationTab(),
                const _PrinterTab(),
                const _SyncTab(),
                isAdmin
                    ? const _UsersTab()
                    : const EmptyState(
                        title: 'Sección restringida',
                        message: 'Solo un administrador puede gestionar usuarios.',
                        icon: Icons.lock_outline,
                      ),
                const _DataTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Empresa
// -----------------------------------------------------------------------------

/// Tasas de impuesto habituales en la región (basis points).
const List<int> _commonTaxRatesBps = <int>[0, 500, 1000, 1500, 1600, 1800, 1900];

class _CompanyTab extends ConsumerStatefulWidget {
  const _CompanyTab();

  @override
  ConsumerState<_CompanyTab> createState() => _CompanyTabState();
}

class _CompanyTabState extends ConsumerState<_CompanyTab> {
  final Map<String, TextEditingController> _fields = <String, TextEditingController>{
    'legalName': TextEditingController(),
    'taxId': TextEditingController(),
    'address': TextEditingController(),
    'phone': TextEditingController(),
    'email': TextEditingController(),
    'receiptHeader': TextEditingController(),
    'receiptFooter': TextEditingController(),
    'currencySymbol': TextEditingController(),
    'currencyCode': TextEditingController(),
    'taxLabel': TextEditingController(),
  };
  bool _loaded = false;
  int _taxRateBps = AppConfig.defaultTaxRateBps;

  @override
  void dispose() {
    for (final TextEditingController controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<CompanyProfile> profile = ref.watch(companyProfileProvider);
    final OperationSettings rules =
        ref.watch(operationSettingsProvider).value ?? OperationSettings.defaults;

    return profile.when(
      data: (CompanyProfile data) {
        // Los controladores se llenan una sola vez: reescribirlos en cada
        // reconstrucción borraría lo que el usuario está escribiendo.
        if (!_loaded) {
          _fields['legalName']!.text = data.legalName;
          _fields['taxId']!.text = data.taxId;
          _fields['address']!.text = data.address;
          _fields['phone']!.text = data.phone;
          _fields['email']!.text = data.email;
          _fields['receiptHeader']!.text = data.receiptHeader;
          _fields['receiptFooter']!.text = data.receiptFooter;
          _fields['currencySymbol']!.text = data.currencySymbol;
          _fields['currencyCode']!.text = data.currencyCode;
          _fields['taxLabel']!.text = data.taxLabel;
          _taxRateBps = rules.rateBps;
          _loaded = true;
        }

        // La tasa guardada puede no estar en la lista corta: se agrega para que
        // el desplegable nunca quede en un valor que no puede mostrar.
        final List<int> rates = <int>{..._commonTaxRatesBps, _taxRateBps}.toList()..sort();

        return SingleChildScrollView(
          child: AppCard(
            title: 'Datos del negocio',
            subtitle: 'Aparecen impresos en cada ticket',
            actions: <Widget>[
              PrimaryButton(
                label: 'Guardar',
                icon: Icons.save_outlined,
                onPressed: _save,
              ),
            ],
            child: Column(
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _fields['legalName'],
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(labelText: 'Nombre o razón social'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                        controller: _fields['taxId'],
                        decoration: const InputDecoration(labelText: 'NIT / RUC / RFC'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: <Widget>[
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _fields['address'],
                        decoration: const InputDecoration(labelText: 'Dirección'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                        controller: _fields['phone'],
                        decoration: const InputDecoration(labelText: 'Teléfono'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                        controller: _fields['email'],
                        decoration: const InputDecoration(labelText: 'Correo'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                const SectionLabel('Moneda e impuesto'),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _fields['currencySymbol'],
                        decoration: const InputDecoration(
                          labelText: 'Símbolo de moneda',
                          hintText: r'C$',
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                        controller: _fields['currencyCode'],
                        decoration: const InputDecoration(
                          labelText: 'Código ISO',
                          hintText: 'NIO',
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                        controller: _fields['taxLabel'],
                        decoration: const InputDecoration(
                          labelText: 'Nombre del impuesto',
                          hintText: 'IVA',
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<int>(
                        initialValue: _taxRateBps,
                        decoration: const InputDecoration(labelText: 'Tasa por defecto'),
                        items: <DropdownMenuItem<int>>[
                          for (final int bps in rates)
                            DropdownMenuItem<int>(
                              value: bps,
                              child: Text(
                                bps == 0 ? 'Exento' : '${(bps / 100).toStringAsFixed(2)} %',
                              ),
                            ),
                        ],
                        onChanged: (int? value) =>
                            setState(() => _taxRateBps = value ?? _taxRateBps),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                const SectionLabel('Mensajes del ticket'),
                TextField(
                  controller: _fields['receiptHeader'],
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Encabezado',
                    hintText: 'RUC/NIT · Dirección · Teléfono',
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _fields['receiptFooter'],
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Pie del ticket',
                    hintText: '¡Gracias por su compra!',
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                const HintText(
                  'El logo del ticket se toma de assets/branding. Para cambiarlo, '
                  'reemplace ultrapos_logo.png en esa carpeta y vuelva a compilar.',
                ),
              ],
            ),
          ),
        );
      },
      error: (Object error, _) => ErrorState(message: '$error'),
      loading: () => const LoadingState(message: 'Cargando datos del negocio…'),
    );
  }

  Future<void> _save() async {
    final String legalName = _fields['legalName']!.text.trim();
    if (legalName.isEmpty) {
      AppSnack.warning(context, 'El nombre del negocio no puede quedar vacío.');
      return;
    }

    try {
      await ref.read(appDatabaseProvider).settingsDao.saveCompanyProfile(
            CompanyProfilesCompanion(
              legalName: Value<String>(legalName),
              taxId: Value<String>(_fields['taxId']!.text.trim()),
              address: Value<String>(_fields['address']!.text.trim()),
              phone: Value<String>(_fields['phone']!.text.trim()),
              email: Value<String>(_fields['email']!.text.trim()),
              receiptHeader: Value<String>(_fields['receiptHeader']!.text.trim()),
              receiptFooter: Value<String>(_fields['receiptFooter']!.text.trim()),
              currencyCode: Value<String>(_fields['currencyCode']!.text.trim()),
              currencySymbol: Value<String>(_fields['currencySymbol']!.text.trim()),
              taxLabel: Value<String>(_fields['taxLabel']!.text.trim()),
              defaultTaxRateBps: Value<int>(_taxRateBps),
            ),
          );

      // La tasa también vive en `app_settings` porque de ahí la lee la regla de
      // operación en caliente (carrito, cobro y arqueo sin reiniciar la app).
      await ref.read(appDatabaseProvider).settingsDao.setValue(
            SettingsKeys.taxRateBps,
            _taxRateBps,
          );

      ref.invalidate(operationSettingsProvider);
      if (mounted) AppSnack.success(context, 'Datos del negocio guardados.');
    } on AppFailure catch (failure) {
      if (mounted) AppSnack.error(context, failure.message);
    }
  }
}

// -----------------------------------------------------------------------------
// Operación
// -----------------------------------------------------------------------------

class _OperationTab extends ConsumerWidget {
  const _OperationTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final OperationSettings rules =
        ref.watch(operationSettingsProvider).value ?? OperationSettings.defaults;

    return SingleChildScrollView(
      child: AppCard(
        title: 'Reglas de operación',
        subtitle: 'Definen cómo se comporta la caja al vender',
        child: Column(
          children: <Widget>[
            _SettingSwitch(
              label: 'Los precios incluyen impuesto',
              description: 'Si está activo, el precio de la etiqueta es lo que paga el '
                  'cliente y el impuesto se desglosa por dentro. Si no, el impuesto se '
                  'suma al final.',
              value: rules.includedInPrice,
              onChanged: (bool value) => _set(ref, context, SettingsKeys.taxIncluded, value),
            ),
            _SettingSwitch(
              label: 'Exigir turno de caja abierto para cobrar',
              description: 'Recomendado: sin turno abierto, los cobros en efectivo no se '
                  'pueden arquear al cerrar el día.',
              value: rules.requireOpenSession,
              onChanged: (bool value) =>
                  _set(ref, context, SettingsKeys.requireOpenSession, value),
            ),
            _SettingSwitch(
              label: 'Permitir ventas a crédito (fiado)',
              description: 'Requiere un cliente registrado con límite de crédito.',
              value: rules.allowCreditSales,
              onChanged: (bool value) => _set(ref, context, SettingsKeys.allowCreditSales, value),
            ),
            _SettingSwitch(
              label: 'Permitir vender sin stock',
              description: 'Úselo solo si su inventario suele ir por detrás de la realidad '
                  '(por ejemplo, cuando las entradas se registran al final del día).',
              value: rules.allowNegativeStock,
              onChanged: (bool value) =>
                  _set(ref, context, SettingsKeys.allowNegativeStock, value),
            ),
            _SettingSwitch(
              label: 'Abrir el cajón al cobrar en efectivo',
              description: 'Se envía la orden a la impresora o al puerto serie configurado '
                  'en la pestaña Impresora.',
              value: _boolSetting(ref, SettingsKeys.openDrawerOnCash, fallback: true),
              onChanged: (bool value) => _set(ref, context, SettingsKeys.openDrawerOnCash, value),
            ),
            _SettingSwitch(
              label: 'Imprimir el ticket al cobrar',
              description: 'Si está apagado, el cajero reimprime con Ctrl+P cuando lo pida '
                  'el cliente.',
              value: _boolSetting(ref, SettingsKeys.printAutomatically, fallback: true),
              onChanged: (bool value) =>
                  _set(ref, context, SettingsKeys.printAutomatically, value),
            ),
          ],
        ),
      ),
    );
  }

  /// Lee un interruptor desde `app_settings` mientras carga o si no existe.
  static bool _boolSetting(WidgetRef ref, String key, {required bool fallback}) {
    final String? raw = ref.watch(settingsValueProvider(key)).value;
    if (raw == null) return fallback;
    return raw == 'true' || raw == '1';
  }

  Future<void> _set(
    WidgetRef ref,
    BuildContext context,
    String key,
    Object value,
  ) async {
    await ref.read(appDatabaseProvider).settingsDao.setValue(key, value);
    ref
      ..invalidate(operationSettingsProvider)
      ..invalidate(settingsValueProvider(key))
      ..invalidate(printerConfigProvider);
    if (context.mounted) AppSnack.success(context, 'Configuración actualizada.');
  }
}

// -----------------------------------------------------------------------------
// Impresora y cajón
// -----------------------------------------------------------------------------

class _PrinterTab extends ConsumerStatefulWidget {
  const _PrinterTab();

  @override
  ConsumerState<_PrinterTab> createState() => _PrinterTabState();
}

/// Velocidades estándar de una impresora térmica serie.
const List<int> _baudRates = <int>[9600, 19200, 38400, 57600, 115200];

class _PrinterTabState extends ConsumerState<_PrinterTab> {
  final TextEditingController _networkHost = TextEditingController();
  final TextEditingController _networkPort = TextEditingController();
  final TextEditingController _comPort = TextEditingController();
  final TextEditingController _drawerComPort = TextEditingController();

  PrinterConfig? _draft;
  List<String> _printers = const <String>[];
  String _comPorts = '';
  bool _busy = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    // La enumeración de impresoras y puertos usa la API nativa: se hace una vez.
    _printers = availableWindowsPrinters();
    final List<String> ports = availableComPorts();
    _comPorts = ports.isEmpty ? 'ninguno' : ports.join(', ');
  }

  @override
  void dispose() {
    _networkHost.dispose();
    _networkPort.dispose();
    _comPort.dispose();
    _drawerComPort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<PrinterConfig> config = ref.watch(printerConfigProvider);

    return config.when(
      data: (PrinterConfig loaded) {
        final PrinterConfig draft = _draft ?? loaded;
        if (!_loaded) {
          _networkHost.text = draft.networkHost ?? '';
          _networkPort.text = '${draft.networkPort}';
          _comPort.text = draft.comPort ?? 'COM1';
          _drawerComPort.text = draft.drawerComPort ?? 'COM2';
          _loaded = true;
        }

        // Si la impresora guardada ya no existe en Windows, se ofrece igual para
        // que el usuario vea qué había configurado antes de elegir otra.
        final List<String> printers = <String>{
          ..._printers,
          if ((draft.windowsPrinterName ?? '').isNotEmpty) draft.windowsPrinterName!,
        }.toList();

        return SingleChildScrollView(
          child: AppCard(
            title: 'Impresora de tickets',
            subtitle: 'Térmica ESC/POS o la impresora predeterminada de Windows',
            actions: <Widget>[
              SecondaryButton(
                label: 'Imprimir prueba',
                icon: Icons.print_outlined,
                onPressed: _busy ? null : () => _testPrint(draft),
              ),
              const SizedBox(width: AppSpacing.sm),
              PrimaryButton(
                label: 'Guardar',
                icon: Icons.save_outlined,
                onPressed: _busy ? null : () => _save(draft),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SectionLabel('Conexión'),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: <Widget>[
                    for (final PrinterType type in PrinterType.values)
                      ChoiceChip(
                        label: Text(type.label),
                        selected: draft.type == type,
                        selectedColor: AppColors.deepBlue,
                        showCheckmark: false,
                        labelStyle: AppTypography.caption.copyWith(
                          color: draft.type == type ? AppColors.white : AppColors.textPrimary,
                        ),
                        onSelected: (_) => setState(() {
                          _draft = draft.copyWith(type: type);
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (draft.type == PrinterType.windowsSpool)
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String>(
                          initialValue: printers.contains(draft.windowsPrinterName)
                              ? draft.windowsPrinterName
                              : null,
                          decoration: const InputDecoration(
                            labelText: 'Impresora instalada en Windows',
                            hintText: 'Seleccione la térmica',
                          ),
                          items: <DropdownMenuItem<String>>[
                            for (final String name in printers)
                              DropdownMenuItem<String>(value: name, child: Text(name)),
                          ],
                          onChanged: (String? value) => setState(() {
                            _draft = draft.copyWith(windowsPrinterName: value);
                          }),
                        ),
                      ),
                    if (draft.type == PrinterType.network) ...<Widget>[
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _networkHost,
                          decoration: const InputDecoration(
                            labelText: 'Dirección IP de la impresora',
                            hintText: '192.168.1.50',
                          ),
                          onChanged: (String value) =>
                              _draft = _draft!.copyWith(networkHost: value.trim()),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: TextField(
                          controller: _networkPort,
                          keyboardType: TextInputType.number,
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Puerto',
                            hintText: '9100',
                          ),
                          onChanged: (String value) => _draft = _draft!.copyWith(
                            networkPort: int.tryParse(value) ?? 9100,
                          ),
                        ),
                      ),
                    ],
                    if (draft.type == PrinterType.serial) ...<Widget>[
                      Expanded(
                        child: TextField(
                          controller: _comPort,
                          decoration: const InputDecoration(
                            labelText: 'Puerto serie',
                            hintText: 'COM1',
                          ),
                          onChanged: (String value) =>
                              _draft = _draft!.copyWith(comPort: value.trim()),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: <int>{..._baudRates, draft.comBaudRate}.contains(
                            draft.comBaudRate,
                          )
                              ? draft.comBaudRate
                              : 9600,
                          decoration: const InputDecoration(labelText: 'Velocidad'),
                          items: <DropdownMenuItem<int>>[
                            for (final int baud in <int>{..._baudRates, draft.comBaudRate}.toList()
                              ..sort())
                              DropdownMenuItem<int>(value: baud, child: Text('$baud')),
                          ],
                          onChanged: (int? value) => setState(() {
                            _draft = draft.copyWith(comBaudRate: value ?? 9600);
                          }),
                        ),
                      ),
                    ],
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: DropdownButtonFormField<PaperWidth>(
                        initialValue: draft.paperWidth,
                        decoration: const InputDecoration(labelText: 'Ancho del papel'),
                        items: <DropdownMenuItem<PaperWidth>>[
                          for (final PaperWidth width in PaperWidth.values)
                            DropdownMenuItem<PaperWidth>(
                              value: width,
                              child: Text('${width.millimeters} mm'),
                            ),
                        ],
                        onChanged: (PaperWidth? value) => setState(() {
                          _draft = draft.copyWith(paperWidth: value ?? PaperWidth.mm80);
                        }),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                const SectionLabel('Cajón de dinero'),
                Row(
                  children: <Widget>[
                    for (final DrawerType type in DrawerType.values)
                      Padding(
                        padding: const EdgeInsets.only(right: AppSpacing.xs),
                        child: ChoiceChip(
                          label: Text(type.label),
                          selected: draft.drawer == type,
                          selectedColor: AppColors.deepBlue,
                          showCheckmark: false,
                          labelStyle: AppTypography.caption.copyWith(
                            color: draft.drawer == type
                                ? AppColors.white
                                : AppColors.textPrimary,
                          ),
                          onSelected: (_) =>
                              setState(() => _draft = draft.copyWith(drawer: type)),
                        ),
                      ),
                    if (draft.drawer == DrawerType.serial) ...<Widget>[
                      const SizedBox(width: AppSpacing.sm),
                      SizedBox(
                        width: 160,
                        child: TextField(
                          controller: _drawerComPort,
                          decoration: const InputDecoration(
                            labelText: 'Puerto del cajón',
                            isDense: true,
                          ),
                          onChanged: (String value) =>
                              _draft = _draft!.copyWith(drawerComPort: value.trim()),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: draft.printCopies.clamp(1, 3),
                        decoration: const InputDecoration(labelText: 'Copias por ticket'),
                        items: const <DropdownMenuItem<int>>[
                          DropdownMenuItem<int>(value: 1, child: Text('1 copia')),
                          DropdownMenuItem<int>(value: 2, child: Text('2 copias')),
                          DropdownMenuItem<int>(value: 3, child: Text('3 copias')),
                        ],
                        onChanged: (int? value) => setState(() {
                          _draft = draft.copyWith(printCopies: value ?? 1);
                        }),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _SettingSwitch(
                        label: 'Cortar papel automáticamente',
                        description: null,
                        value: draft.autoCut,
                        onChanged: (bool value) =>
                            setState(() => _draft = draft.copyWith(autoCut: value)),
                      ),
                    ),
                    Expanded(
                      child: _SettingSwitch(
                        label: 'Imprimir ticket al cobrar',
                        description: null,
                        value: draft.printAutomatically,
                        onChanged: (bool value) => setState(
                          () => _draft = draft.copyWith(printAutomatically: value),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                InlineBanner(
                  message: 'Impresoras detectadas: '
                      '${_printers.isEmpty ? 'ninguna' : _printers.join(', ')}. '
                      'Puertos serie: $_comPorts.',
                  icon: Icons.print_outlined,
                  color: AppColors.deepBlue600,
                ),
                const SizedBox(height: AppSpacing.sm),
                const HintText(
                  'El cajón se abre con el comando ESC/POS enviado a la impresora o al '
                  'puerto serie indicado. Si no tiene cajón, elija "Sin cajón": la venta '
                  'en efectivo funciona igual.',
                ),
              ],
            ),
          ),
        );
      },
      error: (Object error, _) => ErrorState(message: '$error'),
      loading: () => const LoadingState(message: 'Leyendo la configuración de hardware…'),
    );
  }

  Future<void> _save(PrinterConfig config) async {
    setState(() => _busy = true);
    try {
      await ref.read(hardwareManagerProvider).saveConfig(config);
      ref.invalidate(printerConfigProvider);
      if (mounted) AppSnack.success(context, 'Configuración de impresora guardada.');
    } on AppFailure catch (failure) {
      if (mounted) AppSnack.error(context, failure.message);
    } on Object catch (error) {
      if (mounted) AppSnack.error(context, 'No se pudo guardar: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testPrint(PrinterConfig config) async {
    setState(() => _busy = true);
    try {
      final CompanyProfile? company = ref.read(companyProfileProvider).value;
      if (company == null) {
        if (mounted) AppSnack.warning(context, 'Aún no se cargan los datos del negocio.');
        return;
      }
      // Se guarda primero: la prueba debe usar exactamente lo que quedará activo.
      await ref.read(hardwareManagerProvider).saveConfig(config);
      ref.invalidate(printerConfigProvider);

      final HardwareReport report =
          await ref.read(hardwareManagerProvider).testPrint(company: company);
      if (!mounted) return;
      if (report.success) {
        AppSnack.success(context, report.message);
      } else {
        AppSnack.error(context, report.message);
      }
    } on Object catch (error) {
      if (mounted) AppSnack.error(context, 'Error al imprimir la prueba: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// -----------------------------------------------------------------------------
// Sincronización
// -----------------------------------------------------------------------------

class _SyncTab extends ConsumerWidget {
  const _SyncTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SyncStatusSnapshot status =
        ref.watch(syncStatusProvider).value ?? SyncStatusSnapshot.idle;
    final SyncQueueStats stats =
        ref.watch(syncQueueStatsProvider).value ?? SyncQueueStats.empty;
    final List<SyncQueueEntry> queue =
        ref.watch(syncQueueProvider).value ?? const <SyncQueueEntry>[];

    return SingleChildScrollView(
      child: Column(
        children: <Widget>[
          AppCard(
            title: 'Estado de la nube',
            subtitle: AppConfig.hasCloudBackend
                ? 'Servidor configurado'
                : 'Sin servidor configurado: la caja opera 100 % local',
            actions: <Widget>[
              SecondaryButton(
                label: 'Sincronizar ahora',
                icon: Icons.sync,
                onPressed: status.isSyncing
                    ? null
                    : () => unawaited(
                          ref.read(syncServiceProvider).syncNow(manual: true),
                        ),
              ),
              const SizedBox(width: AppSpacing.sm),
              SecondaryButton(
                label: 'Reintentar fallidos',
                icon: Icons.refresh,
                onPressed: status.failedCount == 0
                    ? null
                    : () => unawaited(ref.read(syncServiceProvider).retryFailed()),
              ),
            ],
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    KpiCard(
                      label: 'Estado',
                      value: status.label,
                      icon: status.isOnline
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_off_outlined,
                      color: status.isOnline ? AppColors.success : AppColors.orange,
                      hint: status.lastSyncAt == null
                          ? 'Nunca se sincronizó'
                          : 'Última: ${AppFormat.dateTime(status.lastSyncAt!)}',
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    KpiCard(
                      label: 'Pendientes',
                      value: '${status.pendingCount}',
                      icon: Icons.cloud_upload_outlined,
                      color: AppColors.cyan,
                      hint: 'Operaciones por subir',
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    KpiCard(
                      label: 'Con error',
                      value: '${status.failedCount}',
                      icon: Icons.error_outline,
                      color: status.failedCount > 0 ? AppColors.red : AppColors.grey400,
                      hint: 'Reintento automático con espera creciente',
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    KpiCard(
                      label: 'Más antigua',
                      value: stats.oldestPendingAt == null
                          ? '—'
                          : AppFormat.shortDuration(stats.oldestAge),
                      icon: Icons.schedule,
                      color: AppColors.deepBlue,
                      hint: 'Antigüedad de la operación más vieja',
                    ),
                  ],
                ),
                if (status.lastError != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  InlineBanner(
                    message: 'Último error: ${status.lastError}',
                    icon: Icons.warning_amber_outlined,
                    color: AppColors.red,
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                const HintText(
                  'El motor reintenta solo, con espera creciente (3 s, 6 s, 12 s… hasta 15 '
                  'minutos). Una venta nunca se pierde por falta de internet: se guarda '
                  'local y se sube cuando vuelva la conexión.',
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            title: 'Cola de sincronización',
            subtitle: '${queue.length} operación(es) en la cola local',
            height: 380,
            child: queue.isEmpty
                ? const EmptyState(
                    title: 'Cola vacía',
                    message: 'Todo lo registrado en esta caja ya llegó a la nube.',
                    icon: Icons.cloud_done_outlined,
                  )
                : ListView.separated(
                    itemCount: queue.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final SyncQueueEntry entry = queue[index];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          _statusIcon(entry.status),
                          size: 16,
                          color: _statusColor(entry.status),
                        ),
                        title: Text(
                          '${_entityLabel(entry.entity)} · ${entry.operation.storageKey}',
                          style: AppTypography.body.copyWith(fontSize: 12.5),
                        ),
                        subtitle: Text(
                          <String>[
                            entry.status.label,
                            'Intento ${entry.attempts}',
                            if (entry.lastError != null) entry.lastError!,
                            AppFormat.dateTime(entry.createdAt),
                          ].join(' · '),
                          style: AppTypography.caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static String _entityLabel(SyncEntity entity) => switch (entity) {
        SyncEntity.company => 'Negocio',
        SyncEntity.user => 'Usuario',
        SyncEntity.category => 'Categoría',
        SyncEntity.product => 'Producto',
        SyncEntity.customer => 'Cliente',
        SyncEntity.stockMovement => 'Movimiento de stock',
        SyncEntity.cashSession => 'Turno de caja',
        SyncEntity.cashMovement => 'Movimiento de caja',
        SyncEntity.sale => 'Venta',
        SyncEntity.saleItem => 'Línea de venta',
        SyncEntity.salePayment => 'Pago',
        SyncEntity.setting => 'Configuración',
      };

  static IconData _statusIcon(SyncStatus status) => switch (status) {
        SyncStatus.pending => Icons.schedule,
        SyncStatus.inFlight => Icons.cloud_upload_outlined,
        SyncStatus.synced => Icons.cloud_done_outlined,
        SyncStatus.retry => Icons.refresh,
        SyncStatus.failed => Icons.error_outline,
        SyncStatus.conflict => Icons.warning_amber_outlined,
      };

  static Color _statusColor(SyncStatus status) => switch (status) {
        SyncStatus.pending => AppColors.orange,
        SyncStatus.inFlight => AppColors.cyan,
        SyncStatus.synced => AppColors.success,
        SyncStatus.retry => AppColors.orange,
        SyncStatus.failed => AppColors.red,
        SyncStatus.conflict => AppColors.warning,
      };
}

// -----------------------------------------------------------------------------
// Usuarios
// -----------------------------------------------------------------------------

class _UsersTab extends ConsumerWidget {
  const _UsersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<User>> users = ref.watch(usersProvider);

    return AppCard(
      title: 'Usuarios y roles',
      subtitle: 'Cajero · Supervisor · Administrador',
      actions: <Widget>[
        PrimaryButton(
          label: 'Nuevo usuario',
          icon: Icons.person_add_alt,
          onPressed: () => _openUserForm(context, ref, null),
        ),
      ],
      child: users.when(
        data: (List<User> list) => list.isEmpty
            ? const EmptyState(
                title: 'Sin usuarios',
                message: 'Cree al menos un administrador para poder operar.',
                icon: Icons.badge_outlined,
              )
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (BuildContext context, int index) {
                  final User user = list[index];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      user.role == UserRole.admin
                          ? Icons.admin_panel_settings_outlined
                          : (user.role == UserRole.supervisor
                              ? Icons.supervisor_account_outlined
                              : Icons.badge_outlined),
                      size: 18,
                      color: user.isActive ? AppColors.deepBlue : AppColors.grey400,
                    ),
                    title: Text(user.fullName),
                    subtitle: Text(
                      <String>[
                        user.role.label,
                        '@${user.username}',
                        if ((user.employeeCode ?? '').isNotEmpty) '#${user.employeeCode}',
                        if (user.lastLoginAt != null)
                          'último acceso ${AppFormat.dateTime(user.lastLoginAt!)}',
                      ].join(' · '),
                      style: AppTypography.caption,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        StatusChip(
                          label: user.isActive ? 'Activo' : 'Inactivo',
                          color: user.isActive ? AppColors.success : AppColors.grey400,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        IconButton(
                          tooltip: 'Editar y cambiar PIN',
                          iconSize: 16,
                          onPressed: () => _openUserForm(context, ref, user),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                      ],
                    ),
                  );
                },
              ),
        error: (Object error, _) => ErrorState(message: '$error'),
        loading: () => const LoadingState(),
      ),
    );
  }

  Future<void> _openUserForm(BuildContext context, WidgetRef ref, User? user) async {
    final bool? saved = await UserFormDialog.show(context, user: user);
    if (saved ?? false) {
      ref.invalidate(usersProvider);
      if (context.mounted) {
        AppSnack.success(context, user == null ? 'Usuario creado.' : 'Usuario actualizado.');
      }
    }
  }
}

/// Alta y edición de usuarios (incluye el cambio de PIN).
class UserFormDialog extends ConsumerStatefulWidget {
  const UserFormDialog({super.key, this.user});

  final User? user;

  static Future<bool?> show(BuildContext context, {User? user}) => showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => UserFormDialog(user: user),
      );

  @override
  ConsumerState<UserFormDialog> createState() => _UserFormDialogState();
}

class _UserFormDialogState extends ConsumerState<UserFormDialog> {
  late final TextEditingController _fullName;
  late final TextEditingController _username;
  late final TextEditingController _employeeCode;
  late final TextEditingController _pin;
  late final TextEditingController _maxDiscount;
  late UserRole _role;
  late bool _isActive;
  String? _error;
  bool _busy = false;

  bool get _isEditing => widget.user != null;

  @override
  void initState() {
    super.initState();
    final User? user = widget.user;
    _fullName = TextEditingController(text: user?.fullName ?? '');
    _username = TextEditingController(text: user?.username ?? '');
    _employeeCode = TextEditingController(text: user?.employeeCode ?? '');
    _pin = TextEditingController();
    _maxDiscount = TextEditingController(
      text: user == null || user.maxDiscountBps == 0
          ? ''
          : (user.maxDiscountBps / 100).toStringAsFixed(2),
    );
    _role = user?.role ?? UserRole.cashier;
    _isActive = user?.isActive ?? true;
  }

  @override
  void dispose() {
    _fullName.dispose();
    _username.dispose();
    _employeeCode.dispose();
    _pin.dispose();
    _maxDiscount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        title: Row(
          children: <Widget>[
            const Icon(Icons.badge_outlined, color: AppColors.deepBlue, size: 22),
            const SizedBox(width: AppSpacing.sm),
            Text(_isEditing ? 'Editar usuario' : 'Nuevo usuario'),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: _fullName,
                autofocus: !_isEditing,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nombre completo *'),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _username,
                      enabled: !_isEditing,
                      decoration: const InputDecoration(
                        labelText: 'Usuario *',
                        helperText: 'No se puede cambiar después',
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _employeeCode,
                      decoration: const InputDecoration(labelText: 'Código de empleado'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<UserRole>(
                      initialValue: _role,
                      decoration: const InputDecoration(labelText: 'Rol'),
                      items: <DropdownMenuItem<UserRole>>[
                        for (final UserRole role in UserRole.values)
                          DropdownMenuItem<UserRole>(
                            value: role,
                            child: Text(
                              '${role.label} · ${_roleHint(role)}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (UserRole? value) =>
                          setState(() => _role = value ?? UserRole.cashier),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _maxDiscount,
                      textAlign: TextAlign.right,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Descuento máximo',
                        suffixText: '%',
                        helperText: '0 = sin límite especial',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  labelText: _isEditing ? 'Nuevo PIN (vacío = conservar)' : 'PIN *',
                  counterText: '',
                  helperText: '4 a 8 dígitos',
                ),
              ),
              if (_isEditing) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                SwitchListTile(
                  value: _isActive,
                  onChanged: (bool value) => setState(() => _isActive = value),
                  title: const Text('Usuario activo'),
                  subtitle: const Text(
                    'Un usuario inactivo no puede ingresar, pero conserva su historial.',
                    style: AppTypography.caption,
                  ),
                  dense: true,
                ),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                InlineBanner(
                  message: _error!,
                  icon: Icons.error_outline,
                  color: AppColors.red,
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              const HintText(
                'El PIN se guarda cifrado con PBKDF2-SHA256 y sal aleatoria por usuario: '
                'nunca se sincroniza a la nube ni se puede leer desde la base de datos.',
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          PrimaryButton(
            label: _isEditing ? 'Guardar' : 'Crear usuario',
            icon: Icons.save_outlined,
            onPressed: _busy ? null : _save,
          ),
        ],
      );

  static String _roleHint(UserRole role) => switch (role) {
        UserRole.cashier => 'vende y cobra',
        UserRole.supervisor => 'anula, descuenta y ve reportes',
        UserRole.admin => 'control total',
      };

  Future<void> _save() async {
    final String fullName = _fullName.text.trim();
    final String username = _username.text.trim().toLowerCase();
    final String pin = _pin.text.trim();
    final String employeeCode = _employeeCode.text.trim();
    final double? percent = double.tryParse(_maxDiscount.text.replaceAll(',', '.'));
    final int maxDiscountBps = percent == null || percent <= 0 ? 0 : (percent * 100).round();

    if (fullName.isEmpty) {
      setState(() => _error = 'Escriba el nombre completo.');
      return;
    }
    if (!_isEditing && username.length < 2) {
      setState(() => _error = 'El nombre de usuario debe tener al menos 2 caracteres.');
      return;
    }
    if (!_isEditing && pin.length < 4) {
      setState(() => _error = 'El PIN debe tener al menos 4 dígitos.');
      return;
    }
    if (_isEditing && pin.isNotEmpty && pin.length < 4) {
      setState(() => _error = 'El PIN debe tener al menos 4 dígitos.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final User? current = widget.user;
      if (current == null) {
        await ref.read(appDatabaseProvider).usersDao.createUser(
              username: username,
              fullName: fullName,
              role: _role,
              pin: pin,
              employeeCode: employeeCode.isEmpty ? null : employeeCode,
              maxDiscountBps: maxDiscountBps,
            );
      } else {
        await ref.read(appDatabaseProvider).usersDao.updateUser(
              uuid: current.uuid,
              fullName: fullName,
              role: _role,
              employeeCode: employeeCode.isEmpty ? null : employeeCode,
              maxDiscountBps: maxDiscountBps,
              isActive: _isActive,
            );
        if (pin.isNotEmpty) {
          await ref.read(appDatabaseProvider).usersDao.setPin(
                uuid: current.uuid,
                pin: pin,
                actingUserName: ref.read(sessionProvider).displayName,
              );
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _error = failure.message;
          _busy = false;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString().replaceFirst('Invalid argument(s): ', '');
          _busy = false;
        });
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Datos y diagnóstico
// -----------------------------------------------------------------------------

class _DataTab extends ConsumerStatefulWidget {
  const _DataTab();

  @override
  ConsumerState<_DataTab> createState() => _DataTabState();
}

class _DataTabState extends ConsumerState<_DataTab> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<Device> device = ref.watch(deviceProvider);

    return SingleChildScrollView(
      child: Column(
        children: <Widget>[
          AppCard(
            title: 'Respaldo de la base de datos',
            subtitle: 'Copia completa del negocio en un archivo',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const HintText(
                  'El respaldo se puede guardar en una memoria USB o en una carpeta de '
                  'red. Recomendación: hacerlo al cerrar el día, con el turno ya cuadrado.',
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: SecondaryButton(
                        label: 'Crear respaldo ahora',
                        icon: Icons.backup_outlined,
                        expand: true,
                        onPressed: _busy ? null : _backup,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: SecondaryButton(
                        label: 'Optimizar base de datos',
                        icon: Icons.cleaning_services_outlined,
                        expand: true,
                        onPressed: _busy ? null : _compact,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            title: 'Este equipo',
            subtitle: 'Identificación usada en folios y sincronización',
            child: device.when(
              data: (Device data) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _InfoLine(label: 'Nombre del equipo', value: data.name),
                  _InfoLine(label: 'Prefijo de folios', value: data.folioPrefix),
                  _InfoLine(label: 'UUID', value: data.uuid),
                  _InfoLine(label: 'Host', value: data.hostname ?? '—'),
                  _InfoLine(label: 'Versión', value: AppConfig.appVersion),
                  _InfoLine(label: 'Base de datos', value: '${AppConfig.databaseName}.sqlite'),
                  const SizedBox(height: AppSpacing.sm),
                  SecondaryButton(
                    label: 'Renombrar equipo',
                    icon: Icons.edit_outlined,
                    onPressed: () => _renameDevice(data),
                  ),
                ],
              ),
              error: (Object error, _) => ErrorState(message: '$error'),
              loading: () => const LoadingState(),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _backup() async {
    final FileSaveLocation? location = await getSaveLocation(
      suggestedName: IdGenerator.backupFileName(DateTime.now()),
      acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(label: 'Base de datos SQLite', extensions: <String>['sqlite']),
      ],
    );
    if (location == null) return;

    setState(() => _busy = true);
    try {
      final File target = File(location.path);
      // `VACUUM INTO` exige que el archivo destino no exista.
      if (await target.exists()) await target.delete();
      await ref.read(appDatabaseProvider).backupTo(target.path);
      if (mounted) AppSnack.success(context, 'Respaldo creado en ${target.path}');
    } on AppFailure catch (failure) {
      if (mounted) AppSnack.error(context, failure.message);
    } on Object catch (error) {
      if (mounted) AppSnack.error(context, 'No se pudo respaldar: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _compact() async {
    setState(() => _busy = true);
    try {
      await ref.read(appDatabaseProvider).compact();
      if (mounted) AppSnack.success(context, 'Base de datos optimizada.');
    } on AppFailure catch (failure) {
      if (mounted) AppSnack.error(context, failure.message);
    } on Object catch (error) {
      if (mounted) AppSnack.error(context, 'No se pudo optimizar: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameDevice(Device device) async {
    final TextEditingController controller = TextEditingController(text: device.name);
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Nombre del equipo'),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Nombre',
              hintText: 'CAJA-1',
              helperText: 'Se imprime en el ticket y aparece en la nube',
            ),
            onSubmitted: (String value) => Navigator.of(dialogContext).pop(value),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          PrimaryButton(
            label: 'Guardar',
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          ),
        ],
      ),
    );
    controller.dispose();

    final String trimmed = (name ?? '').trim();
    if (trimmed.isEmpty) return;

    await ref.read(appDatabaseProvider).settingsDao.updateDeviceName(trimmed);
    ref.invalidate(deviceProvider);
    if (mounted) AppSnack.success(context, 'Equipo renombrado.');
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 170,
              child: Text(
                label,
                style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: AppTypography.body.copyWith(fontSize: 12.5),
              ),
            ),
          ],
        ),
      );
}

/// Interruptor de configuración con explicación.
class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Switch(value: value, onChanged: onChanged),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: AppTypography.body.copyWith(fontSize: 12.5)),
                  if (description != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      description!,
                      style: AppTypography.caption.copyWith(
                        color: AppColors.textHint,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}
