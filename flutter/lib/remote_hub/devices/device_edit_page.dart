import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../credentials/credential_vault.dart';
import 'device_record.dart';

/// What the owner entered. The password never enters [DeviceRecord] and is
/// not written to the vault here: the host has not accepted it yet. The
/// caller uses it for the next connect, which stores it (if [savePassword])
/// only after the host accepted a login with it.
class DeviceEditResult {
  DeviceEditResult(this.record, this.password, this.savePassword,
      {this.forgetStoredPassword = false});
  final DeviceRecord record;
  final String password;
  final bool savePassword;

  /// The previously stored password must be removed from the vault: the
  /// owner unchecked saving, or the endpoint changed and the old password
  /// must not be sent to the new one.
  final bool forgetStoredPassword;
}

/// Writes the device list to local storage; throws when it was not written.
typedef CatalogWriter = Future<void> Function(DeviceCatalog next);

/// Applies an edit of [existing] (null: a new device) to [catalog] so that
/// the device list and the vault change together or not at all. Returns the
/// written catalog, or null when nothing was kept; [onError] then gets the
/// text to show the owner. A typed password is never written here (see
/// [DeviceEditResult]).
Future<DeviceCatalog?> commitDeviceEdit(
  CredentialVault vault,
  DeviceCatalog catalog,
  DeviceRecord? existing,
  DeviceEditResult result, {
  required CatalogWriter writeCatalog,
  required void Function(String message) onError,
}) {
  final record = result.record;
  final drop = existing != null &&
      existing.credentialRef != null &&
      (result.forgetStoredPassword || record.credentialRef == null);
  return _commitDroppingCredential(
    vault,
    drop ? existing : null,
    DeviceCatalog([
      for (final d in catalog.devices)
        if (d.id != record.id) d,
      record,
    ]),
    writeCatalog: writeCatalog,
    onError: onError,
    stuckMessage: _oldPasswordStuck,
  );
}

/// Removes [device] from [catalog] together with its stored password, so
/// that neither a listed device loses its password nor a password outlives
/// its device. Returns the written catalog, or null when nothing changed.
Future<DeviceCatalog?> commitDeviceRemoval(
  CredentialVault vault,
  DeviceCatalog catalog,
  DeviceRecord device, {
  required CatalogWriter writeCatalog,
  required void Function(String message) onError,
}) =>
    _commitDroppingCredential(
      vault,
      device.credentialRef != null ? device : null,
      DeviceCatalog([
        for (final x in catalog.devices)
          if (x.id != device.id) x
      ]),
      writeCatalog: writeCatalog,
      onError: onError,
      stuckMessage: 'The stored password could not be removed from the '
          'vault, so "${device.label}" was kept. Try again.',
    );

/// Writes [next] and removes the stored password of [dropFrom] (if given).
///
/// The password is read first and removed before the list is written; if
/// the list then cannot be written it is put back, so the old record keeps
/// its password. A vault that cannot read or delete leaves both unchanged.
/// Only when the list write and the restore both fail is the password gone;
/// the old record then finds no password and the owner is asked for it.
/// Nothing in this order can leave a password that no record points at.
Future<DeviceCatalog?> _commitDroppingCredential(
  CredentialVault vault,
  DeviceRecord? dropFrom,
  DeviceCatalog next, {
  required CatalogWriter writeCatalog,
  required void Function(String message) onError,
  required String stuckMessage,
}) async {
  String? previous;
  if (dropFrom != null) {
    try {
      previous = await vault.read(dropFrom);
      await vault.forget(dropFrom.id);
    } on VaultException {
      onError(stuckMessage);
      return null;
    }
  }
  try {
    await writeCatalog(next);
  } catch (_) {
    if (dropFrom != null && previous != null) {
      try {
        await vault.save(dropFrom.id, previous);
      } on VaultException {
        onError('$_listNotSaved Its stored password could not be restored; '
            'enter it again on the next connect.');
        return null;
      }
    }
    onError(_listNotSaved);
    return null;
  }
  return next;
}

const _oldPasswordStuck = 'The old password could not be removed from the '
    'vault, so the computer was left unchanged. Try again.';

const _listNotSaved = 'The computer list could not be saved to local '
    'storage. The change was not kept.';

/// Add or edit one host (plan 12.2): name, platform, approved tailnet IPv4,
/// full MagicDNS name, fixed port 21118, password and an explicit choice to
/// store it. No URLs, RustDesk IDs or free-form commands are accepted.
class DeviceEditPage extends StatefulWidget {
  const DeviceEditPage({super.key, this.existing});

  final DeviceRecord? existing;

  @override
  State<DeviceEditPage> createState() => _DeviceEditPageState();
}

class _DeviceEditPageState extends State<DeviceEditPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _label;
  late final TextEditingController _ip;
  late final TextEditingController _name;
  final _password = TextEditingController();
  late HostPlatform _platform;
  late QualityPreset _quality;
  late InputMode _inputMode;
  bool _savePassword = false;
  late bool _confirmed;
  String? _error;

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    _label = TextEditingController(text: d?.label ?? '');
    _ip = TextEditingController(text: d?.endpoint.tailnetIpv4 ?? '');
    _name = TextEditingController(text: d?.endpoint.tlsServerName ?? '');
    _platform = d?.platform ?? HostPlatform.macos;
    final prefs = d?.preferences ?? const DevicePreferences();
    _quality = prefs.quality;
    _inputMode = prefs.inputMode;
    _confirmed = d?.ownerConfirmed ?? false;
    _savePassword = d?.credentialRef != null;
  }

  @override
  void dispose() {
    _label.dispose();
    _ip.dispose();
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  String? _check(void Function() validate) {
    try {
      validate();
      return null;
    } on DeviceConfigException catch (e) {
      return e.message;
    }
  }

  /// A changed address or name needs a fresh confirmation (plan 7.4) and a
  /// fresh credential decision: the stored password is not carried over.
  void _endpointEdited(String _) {
    if (_confirmed || _savePassword) {
      setState(() {
        _confirmed = false;
        _savePassword = false;
      });
    }
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    try {
      final endpoint = RemoteEndpoint.validated(
          tailnetIpv4: _ip.text, tlsServerName: _name.text);
      final old = widget.existing;
      final hadStored = old?.credentialRef != null;
      final endpointChanged = old != null && old.endpoint != endpoint;
      // A newly typed password replaces the stored one only once the host
      // accepts it; until then the stored one stays.
      final keepStored = hadStored && !endpointChanged && _savePassword;
      final record = DeviceRecord.create(
        id: old?.id ?? const Uuid().v4(),
        label: _label.text,
        platform: _platform,
        endpoint: endpoint,
        ownerConfirmed: _confirmed,
        hasStoredCredential: keepStored,
        preferences: DevicePreferences(
          quality: _quality,
          inputMode: _inputMode,
          // Chosen by the name the host reports; kept as it was.
          displayId: old?.preferences.displayId,
          clipboardMode: old?.preferences.clipboardMode ??
              ClipboardMode.disabled,
        ),
        lastSuccessfulConnectionAt: old?.lastSuccessfulConnectionAt,
      );
      Navigator.of(context).pop(DeviceEditResult(
          record, _password.text, _savePassword,
          forgetStoredPassword: hadStored && !keepStored));
    } on DeviceConfigException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit computer' : 'Add computer')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Name'),
              maxLength: kMaxLabelLength,
              validator: (v) =>
                  _check(() => DeviceRecord.validateLabel(v ?? '')),
            ),
            DropdownButtonFormField<HostPlatform>(
              value: _platform,
              decoration: const InputDecoration(labelText: 'Platform'),
              items: const [
                DropdownMenuItem(
                    value: HostPlatform.macos, child: Text('macOS')),
                DropdownMenuItem(
                    value: HostPlatform.windows, child: Text('Windows')),
              ],
              onChanged: (v) => setState(() => _platform = v ?? _platform),
            ),
            TextFormField(
              controller: _ip,
              decoration: const InputDecoration(
                  labelText: 'Approved Tailscale IPv4', hintText: '100.x.y.z'),
              keyboardType: TextInputType.number,
              onChanged: _endpointEdited,
              validator: (v) => _check(() => RemoteEndpoint.validated(
                  tailnetIpv4: v ?? '',
                  tlsServerName: 'placeholder.example.ts.net')),
            ),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: 'Full MagicDNS name',
                  hintText: 'computer.tailnet-name.ts.net'),
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: _endpointEdited,
              validator: (v) => _check(() => RemoteEndpoint.validated(
                  tailnetIpv4: '100.64.0.1', tlsServerName: v ?? '')),
            ),
            DropdownButtonFormField<QualityPreset>(
              value: _quality,
              decoration: const InputDecoration(labelText: 'Picture quality'),
              items: const [
                DropdownMenuItem(
                    value: QualityPreset.economy,
                    child: Text('Economy (low bandwidth)')),
                DropdownMenuItem(
                    value: QualityPreset.balanced, child: Text('Balanced')),
                DropdownMenuItem(
                    value: QualityPreset.quality, child: Text('Best quality')),
              ],
              onChanged: (v) => setState(() => _quality = v ?? _quality),
            ),
            DropdownButtonFormField<InputMode>(
              value: _inputMode,
              decoration: const InputDecoration(
                  labelText: 'Pointer on touch screens'),
              items: const [
                DropdownMenuItem(
                    value: InputMode.trackpad,
                    child: Text('Trackpad (move the pointer)')),
                DropdownMenuItem(
                    value: InputMode.touch,
                    child: Text('Touch (tap where you click)')),
              ],
              onChanged: (v) => setState(() => _inputMode = v ?? _inputMode),
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Port'),
              trailing: Text('$kServeTlsPort (Tailscale Serve, TLS)'),
            ),
            TextFormField(
              controller: _password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                  labelText: 'Host password',
                  helperText: editing
                      ? 'Leave empty to keep the saved password. A new '
                          'address or name needs the password again. A new '
                          'password is saved after the computer accepts it'
                      : 'Saved after the computer accepts it on the first '
                          'connection'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _savePassword,
              onChanged: (v) => setState(() => _savePassword = v ?? false),
              title: const Text('Save the password on this device'),
              subtitle: const Text(
                  'Stored in the system keychain/keystore. Not saved otherwise.'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _confirmed,
              onChanged: (v) => setState(() => _confirmed = v ?? false),
              title: const Text('This address and name belong to my computer'),
              subtitle: const Text(
                  'Remote Hub only connects to confirmed computers.'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _submit, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}
