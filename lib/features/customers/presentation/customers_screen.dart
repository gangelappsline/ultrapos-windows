import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/customers_dao.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/ui/app_widgets.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/money.dart';
import '../../auth/application/session_controller.dart';

/// Búsqueda de clientes (texto reactivo).
class CustomerSearchController extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value.trim();
}

final customerSearchProvider =
    NotifierProvider<CustomerSearchController, String>(CustomerSearchController.new);

/// Clientes visibles según el término de búsqueda.
final filteredCustomersProvider = StreamProvider<List<Customer>>((Ref ref) {
  final String search = ref.watch(customerSearchProvider);
  return ref
      .watch(appDatabaseProvider)
      .customersDao
      .watchAll(search: search.isEmpty ? null : search);
});

/// Módulo de clientes: ficha, historial de compras y cuentas por cobrar.
///
/// El objetivo real de este módulo en una tienda es doble: fidelizar (a quién
/// le vendemos) y **cobrar el fiado** (quién nos debe). Por eso la tabla se
/// ordena por deuda y muestra el saldo en la primera columna tras el nombre.
class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  final TextEditingController _search = TextEditingController();
  Customer? _selected;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Customer>> customers = ref.watch(filteredCustomersProvider);
    final CurrencyFormat currency = ref.watch(currencyFormatProvider);
    final AsyncValue<Money> receivable = ref.watch(totalReceivableProvider);

    return Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        children: <Widget>[
          ModuleHeader(
            title: 'Clientes',
            subtitle: 'Fichas, historial de compras y saldos pendientes',
            actions: <Widget>[
              KpiCard(
                label: 'Por cobrar',
                value: currency.money(receivable.value ?? Money.zero),
                icon: Icons.account_balance_wallet_outlined,
                color: AppColors.orange,
                hint: 'Total fiado pendiente de cobro',
              ),
              const SizedBox(width: AppSpacing.sm),
              PrimaryButton(
                label: 'Nuevo cliente',
                icon: Icons.person_add_alt,
                onPressed: () => _openForm(null),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 320,
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Buscar por nombre, NIT, teléfono o correo…',
                      prefixIcon: Icon(Icons.search, size: 17),
                    ),
                    onChanged: (String value) =>
                        ref.read(customerSearchProvider.notifier).set(value),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                SecondaryButton(
                  label: 'Solo con saldo',
                  icon: Icons.receipt_long_outlined,
                  onPressed: () => _showWithBalance(),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: AppCard(
                    padding: EdgeInsets.zero,
                    child: customers.when(
                      data: (List<Customer> list) => list.isEmpty
                          ? const EmptyState(
                              title: 'Sin clientes',
                              message: 'Registre a sus clientes frecuentes para llevar su '
                                  'historial y controlar el crédito.',
                              icon: Icons.people_outline,
                            )
                          : ListView.builder(
                              itemCount: list.length,
                              itemBuilder: (BuildContext context, int index) {
                                final Customer customer = list[index];
                                return _CustomerRow(
                                  customer: customer,
                                  currency: currency,
                                  selected: _selected?.id == customer.id,
                                  onTap: () => setState(() => _selected = customer),
                                  onEdit: () => _openForm(customer),
                                );
                              },
                            ),
                      error: (Object error, _) => ErrorState(message: '$error'),
                      loading: () => const LoadingState(message: 'Cargando clientes…'),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                SizedBox(
                  width: 380,
                  child: _selected == null
                      ? const AppCard(
                          child: EmptyState(
                            title: 'Seleccione un cliente',
                            message: 'Verá su ficha, su historial de compras y su saldo.',
                            icon: Icons.person_search,
                          ),
                        )
                      : _CustomerDetail(customer: _selected!, currency: currency),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showWithBalance() async {
    final List<Customer> debtors =
        await ref.read(appDatabaseProvider).customersDao.withBalance();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        icon: const Icon(Icons.receipt_long_outlined, color: AppColors.orange),
        title: const Text('Clientes con saldo pendiente'),
        content: SizedBox(
          width: 520,
          height: 380,
          child: debtors.isEmpty
              ? const EmptyState(
                  title: 'Nadie debe nada',
                  message: 'Todas las cuentas están al día.',
                  icon: Icons.celebration_outlined,
                )
              : ListView.separated(
                  itemCount: debtors.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) {
                    final Customer customer = debtors[index];
                    return ListTile(
                      dense: true,
                      title: Text(customer.name),
                      subtitle: Text(
                        customer.phone.isEmpty ? 'Sin teléfono' : customer.phone,
                        style: AppTypography.caption,
                      ),
                      trailing: Text(
                        ref
                            .read(currencyFormatProvider)
                            .money(customer.balance),
                        style: AppTypography.tableStrong.copyWith(color: AppColors.orange),
                      ),
                    );
                  },
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  Future<void> _openForm(Customer? customer) async {
    final bool? saved = await CustomerFormDialog.show(context, customer: customer);
    if (saved ?? false) {
      AppSnack.success(context, customer == null ? 'Cliente creado.' : 'Cliente actualizado.');
      if (customer != null) setState(() => _selected = null);
    }
  }
}

/// Total pendiente de cobro de toda la tienda.
final totalReceivableProvider = FutureProvider<Money>(
  (Ref ref) => ref.watch(appDatabaseProvider).customersDao.totalReceivable(),
);

/// Fila de la tabla de clientes.
class _CustomerRow extends StatelessWidget {
  const _CustomerRow({
    required this.customer,
    required this.currency,
    required this.selected,
    required this.onTap,
    required this.onEdit,
  });

  final Customer customer;
  final CurrencyFormat currency;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => DataRowTile(
        selected: selected,
        onTap: onTap,
        cells: <Widget>[
          Row(
            children: <Widget>[
              CircleAvatar(
                radius: 13,
                backgroundColor: AppColors.cyanSurface,
                child: Text(
                  customer.name.substring(0, 1).toUpperCase(),
                  style: AppTypography.caption.copyWith(
                    color: AppColors.deepBlue,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      customer.name,
                      style: AppTypography.body.copyWith(fontSize: 12.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      <String>[
                        if (customer.taxId.isNotEmpty) 'NIT ${customer.taxId}',
                        if (customer.phone.isNotEmpty) customer.phone,
                        if (customer.email.isNotEmpty) customer.email,
                      ].join(' · '),
                      style: AppTypography.caption.copyWith(
                        fontSize: 10,
                        color: AppColors.textHint,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(
            width: 110,
            child: Text(
              customer.lastPurchaseAt == null
                  ? 'Nunca'
                  : AppFormat.shortDate(customer.lastPurchaseAt!),
              style: AppTypography.caption,
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              customer.creditLimit.isPositive
                  ? currency.formatCents(customer.creditLimit.cents, withSymbol: false)
                  : 'Sin crédito',
              textAlign: TextAlign.right,
              style: AppTypography.caption,
            ),
          ),
          SizedBox(
            width: 120,
            child: Text(
              currency.money(customer.balance),
              textAlign: TextAlign.right,
              style: AppTypography.tableStrong.copyWith(
                fontSize: 12.5,
                color: customer.balance.isPositive ? AppColors.orange : AppColors.textPrimary,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: IconButton(
              tooltip: 'Editar',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, color: AppColors.deepBlue),
            ),
          ),
        ],
      );
}

/// Ficha del cliente con historial de compras.
class _CustomerDetail extends ConsumerWidget {
  const _CustomerDetail({required this.customer, required this.currency});

  final Customer customer;
  final CurrencyFormat currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Sale>> history = ref.watch(customerHistoryProvider(customer.uuid));

    return AppCard(
      title: customer.name,
      subtitle: customer.taxId.isEmpty ? 'Consumidor final identificado' : 'NIT ${customer.taxId}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _InfoRow(label: 'Teléfono', value: customer.phone.isEmpty ? '—' : customer.phone),
          _InfoRow(label: 'Correo', value: customer.email.isEmpty ? '—' : customer.email),
          _InfoRow(label: 'Dirección', value: customer.address.isEmpty ? '—' : customer.address),
          _InfoRow(
            label: 'Límite de crédito',
            value: customer.creditLimit.isZero ? 'Sin crédito' : currency.money(customer.creditLimit),
          ),
          _InfoRow(
            label: 'Saldo pendiente',
            value: currency.money(customer.balance),
            color: customer.balance.isPositive ? AppColors.orange : AppColors.success,
          ),
          _InfoRow(
            label: 'Descuento',
            value: customer.discountBps == 0
                ? 'Sin descuento'
                : AppFormat.percent(customer.discountBps),
          ),
          _InfoRow(label: 'Puntos', value: '${customer.loyaltyPoints}'),
          const Divider(height: AppSpacing.md),
          const SectionLabel('Historial de compras'),
          Expanded(
            child: history.when(
              data: (List<Sale> sales) => sales.isEmpty
                  ? Center(
                      child: Text(
                        'Sin compras registradas',
                        style: AppTypography.caption,
                      ),
                    )
                  : ListView.separated(
                      itemCount: sales.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final Sale sale = sales[index];
                        return ListTile(
                          dense: true,
                          title: Text(sale.folio, style: AppTypography.body.copyWith(fontSize: 12)),
                          subtitle: Text(
                            '${AppFormat.dateTime(sale.createdAt)} · ${sale.userName}',
                            style: AppTypography.caption,
                          ),
                          trailing: Text(
                            currency.money(sale.total),
                            style: AppTypography.table.copyWith(fontSize: 12),
                          ),
                        );
                      },
                    ),
              error: (Object error, _) => ErrorState(message: '$error'),
              loading: () => const LoadingState(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Historial de compras de un cliente.
final customerHistoryProvider = FutureProvider.family<List<Sale>, String>(
  (Ref ref, String customerUuid) =>
      ref.watch(appDatabaseProvider).customersDao.purchaseHistory(customerUuid),
);

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 130,
              child: Text(
                label,
                style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: AppTypography.body.copyWith(fontSize: 12.5, color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}

/// Alta y edición de clientes.
class CustomerFormDialog extends ConsumerStatefulWidget {
  const CustomerFormDialog({super.key, this.customer});

  final Customer? customer;

  static Future<bool?> show(BuildContext context, {Customer? customer}) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => CustomerFormDialog(customer: customer),
      );

  @override
  ConsumerState<CustomerFormDialog> createState() => _CustomerFormDialogState();
}

class _CustomerFormDialogState extends ConsumerState<CustomerFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _taxId;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _address;
  late final TextEditingController _creditLimit;
  late final TextEditingController _discount;
  late final TextEditingController _notes;
  String? _error;

  bool get _isEditing => widget.customer != null;

  @override
  void initState() {
    super.initState();
    final Customer? c = widget.customer;
    _name = TextEditingController(text: c?.name ?? '');
    _taxId = TextEditingController(text: c?.taxId ?? '');
    _phone = TextEditingController(text: c?.phone ?? '');
    _email = TextEditingController(text: c?.email ?? '');
    _address = TextEditingController(text: c?.address ?? '');
    _creditLimit = TextEditingController(
      text: c == null ? '' : c.creditLimit.units.toStringAsFixed(2),
    );
    _discount = TextEditingController(
      text: c == null || c.discountBps == 0 ? '' : (c.discountBps / 100).toStringAsFixed(2),
    );
    _notes = TextEditingController(text: c?.notes ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _taxId.dispose();
    _phone.dispose();
    _email.dispose();
    _address.dispose();
    _creditLimit.dispose();
    _discount.dispose();
    _notes.dispose();
    super.dispose();
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
          Icon(
            _isEditing ? Icons.edit_outlined : Icons.person_add_alt,
            color: AppColors.deepBlue,
            size: 22,
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(_isEditing ? 'Editar cliente' : 'Nuevo cliente'),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nombre o razón social *'),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _taxId,
                      decoration: const InputDecoration(labelText: 'NIT / RUC / RFC'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Teléfono'),
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
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Correo'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _address,
                      decoration: const InputDecoration(labelText: 'Dirección'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              const SectionLabel('Crédito y descuentos'),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _creditLimit,
                      textAlign: TextAlign.right,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Límite de crédito',
                        prefixText: '${currency.symbol} ',
                        helperText: '0 = no se le fía',
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _discount,
                      textAlign: TextAlign.right,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Descuento habitual',
                        suffixText: '%',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Notas internas'),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                InlineBanner(
                  message: _error!,
                  icon: Icons.error_outline,
                  color: AppColors.red,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        PrimaryButton(
          label: _isEditing ? 'Guardar' : 'Crear cliente',
          icon: Icons.save_outlined,
          onPressed: _save,
        ),
      ],
    );
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'El nombre es obligatorio.');
      return;
    }

    final Money creditLimit = Money.tryParse(_creditLimit.text) ?? Money.zero;
    final double? percent = double.tryParse(_discount.text.replaceAll(',', '.'));
    final int discountBps = percent == null ? 0 : (percent * 100).round();
    final CustomersDao dao = ref.read(appDatabaseProvider).customersDao;

    try {
      if (_isEditing) {
        final Customer customer = widget.customer!;
        await dao.updateCustomer(
          customer: customer,
          name: name,
          taxId: _taxId.text,
          phone: _phone.text,
          email: _email.text,
          address: _address.text,
          creditLimit: creditLimit,
          discountBps: discountBps,
          notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        );
      } else {
        await dao.createCustomer(
          name: name,
          taxId: _taxId.text,
          phone: _phone.text,
          email: _email.text,
          address: _address.text,
          creditLimit: creditLimit,
          discountBps: discountBps,
          notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on AppFailure catch (failure) {
      setState(() => _error = failure.message);
    } on Object catch (error) {
      setState(() => _error = 'No se pudo guardar el cliente: $error');
    }
  }
}
