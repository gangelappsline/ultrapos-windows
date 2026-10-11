import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/ui/app_widgets.dart';
import '../../../../core/utils/formatters.dart';

/// Selector de cliente (F3).
///
/// En una tienda de barrio el 80 % de las ventas son "Consumidor Final"; por eso
/// el diálogo se abre con el buscador vacío y solo muestra resultados cuando el
/// cajero escribe algo. Busca por nombre, NIT, teléfono o correo, y permite
/// crear un cliente nuevo sin salir de la venta (nadie quiere interrumpir un
/// cobro para ir a otro módulo).
class CustomerPickerDialog extends ConsumerStatefulWidget {
  const CustomerPickerDialog({super.key});

  static Future<Customer?> show(BuildContext context) => showDialog<Customer>(
        context: context,
        builder: (BuildContext context) => const CustomerPickerDialog(),
      );

  @override
  ConsumerState<CustomerPickerDialog> createState() => _CustomerPickerDialogState();
}

class _CustomerPickerDialogState extends ConsumerState<CustomerPickerDialog> {
  final TextEditingController _search = TextEditingController();
  List<Customer> _results = const <Customer>[];
  Customer? _selected;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(_run);
  }

  @override
  void dispose() {
    _search.removeListener(_run);
    _search.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final String term = _search.text.trim();
    setState(() => _loading = true);
    final List<Customer> found = term.isEmpty
        // Sin búsqueda se muestran los últimos clientes atendidos: en una caja
        // el 90 % de las ventas con cliente son para los mismos de siempre.
        ? await ref
            .read(appDatabaseProvider)
            .customersDao
            .recentlyServed(limit: 12)
        : await ref.read(appDatabaseProvider).customersDao.search(term, limit: 25);
    if (!mounted) return;
    setState(() {
      _results = found;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final CurrencyFormat currency = ref.watch(currencyFormatProvider);

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      title: Row(
        children: <Widget>[
          const Icon(Icons.person_search, color: AppColors.cyan, size: 22),
          const SizedBox(width: AppSpacing.sm),
          const Text('Cliente de la venta'),
          const Spacer(),
          SizedBox(
            width: 300,
            child: TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Nombre, NIT, teléfono…',
                prefixIcon: Icon(Icons.search, size: 16),
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: 360,
        child: Column(
          children: <Widget>[
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const LoadingState(message: 'Buscando clientes…')
                  : _results.isEmpty
                      ? EmptyState(
                          title: _search.text.trim().isEmpty
                              ? 'Sin clientes recientes'
                              : 'Sin resultados',
                          message: 'Puede vender como Consumidor Final o crear un '
                              'cliente nuevo con el botón de abajo.',
                          icon: Icons.person_off_outlined,
                        )
                      : ListView.separated(
                          itemCount: _results.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (BuildContext context, int index) {
                            final Customer customer = _results[index];
                            final bool selected = _selected?.id == customer.id;
                            return ListTile(
                              dense: true,
                              selected: selected,
                              leading: CircleAvatar(
                                radius: 14,
                                backgroundColor: AppColors.cyanSurface,
                                child: Text(
                                  customer.name.substring(0, 1).toUpperCase(),
                                  style: AppTypography.caption.copyWith(
                                    color: AppColors.deepBlue,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              title: Text(customer.name),
                              subtitle: Text(
                                <String>[
                                  if (customer.taxId.isNotEmpty) 'NIT ${customer.taxId}',
                                  if (customer.phone.isNotEmpty) customer.phone,
                                  if (customer.email.isNotEmpty) customer.email,
                                ].join(' · '),
                                style: AppTypography.caption,
                              ),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: <Widget>[
                                  if (!customer.balance.isZero)
                                    Text(
                                      'Saldo ${currency.money(customer.balance)}',
                                      style: AppTypography.caption.copyWith(
                                        color: customer.balance.isPositive
                                            ? AppColors.orange
                                            : AppColors.success,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  if (customer.discountBps > 0)
                                    Text(
                                      'Desc. ${AppFormat.percent(customer.discountBps)}',
                                      style: AppTypography.caption.copyWith(
                                        fontSize: 10,
                                        color: AppColors.deepBlue,
                                      ),
                                    ),
                                  if (customer.lastPurchaseAt != null)
                                    Text(
                                      'Última: '
                                      '${AppFormat.shortDate(customer.lastPurchaseAt!)}',
                                      style: AppTypography.caption.copyWith(
                                        fontSize: 10,
                                        color: AppColors.textHint,
                                      ),
                                    ),
                                ],
                              ),
                              onTap: () => setState(() => _selected = customer),
                              onLongPress: () => Navigator.of(context).pop(customer),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Consumidor Final'),
        ),
        SecondaryButton(
          label: 'Nuevo cliente',
          icon: Icons.person_add_alt,
          onPressed: _createCustomer,
        ),
        PrimaryButton(
          label: 'Asignar',
          icon: Icons.check,
          shortcut: 'Enter',
          onPressed: _selected == null
              ? null
              : () => Navigator.of(context).pop(_selected),
        ),
      ],
    );
  }

  Future<void> _createCustomer() async {
    final CustomerDraft? draft = await showDialog<CustomerDraft>(
      context: context,
      builder: (BuildContext context) => const _QuickCustomerDialog(),
    );
    if (draft == null || !mounted) return;

    final Customer created = await ref
        .read(appDatabaseProvider)
        .customersDao
        .createCustomer(
          name: draft.name,
          taxId: draft.taxId,
          phone: draft.phone,
          email: draft.email,
          discountBps: draft.discountBps,
        );
    if (!mounted) return;
    Navigator.of(context).pop(created);
  }
}

/// Borrador de cliente (lo que el cajero puede capturar sin interrumpir la venta).
@immutable
class CustomerDraft {
  const CustomerDraft({
    required this.name,
    this.taxId = '',
    this.phone = '',
    this.email = '',
    this.discountBps = 0,
  });

  final String name;
  final String taxId;
  final String phone;
  final String email;
  final int discountBps;
}

/// Alta rápida de cliente desde la pantalla de venta.
class _QuickCustomerDialog extends StatefulWidget {
  const _QuickCustomerDialog();

  @override
  State<_QuickCustomerDialog> createState() => _QuickCustomerDialogState();
}

class _QuickCustomerDialogState extends State<_QuickCustomerDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _taxId = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _email = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _taxId.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.person_add_alt, color: AppColors.cyan),
        title: const Text('Nuevo cliente'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nombre o razón social'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _taxId,
                decoration: const InputDecoration(labelText: 'NIT / RUC / RFC'),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _phone,
                      decoration: const InputDecoration(labelText: 'Teléfono'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _email,
                      decoration: const InputDecoration(labelText: 'Correo'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const HintText(
                'Solo el nombre es obligatorio: se puede completar la ficha después '
                'desde el módulo Clientes.',
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              final String name = _name.text.trim();
              if (name.isEmpty) return;
              Navigator.of(context).pop(
                CustomerDraft(
                  name: name,
                  taxId: _taxId.text.trim(),
                  phone: _phone.text.trim(),
                  email: _email.text.trim(),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.orange,
              foregroundColor: AppColors.white,
            ),
            child: const Text('Crear y asignar'),
          ),
        ],
      );
}
