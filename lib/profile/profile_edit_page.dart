/*
 * ProfileEditPage — customise an identity.
 *
 * Lets the user change the editable parts of a profile (nickname, description,
 * avatar colour and avatar image) and shows the read-only identity (callsign +
 * npub, with copy) plus a reveal/copy of the secret key for backup. Also
 * deletes the profile. Ported in spirit from xprs/lib/pages/profile_page.dart
 * but adapted to XPRS's [IwiProfile] + [ProfileService].
 */

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'iwi_profile.dart';
import 'identity_backup.dart';
import 'profile_avatar.dart';
import 'profile_crypto.dart';
import 'profile_encryption.dart';
import 'profile_service.dart';
import '../services/android_permissions_service.dart';
import '../services/preferences_service.dart';
import '../services/xprs/xprs_callsign.dart';

class ProfileEditPage extends StatefulWidget {
  final IwiProfile profile;
  const ProfileEditPage({super.key, required this.profile});

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  late IwiProfile _p;
  late final TextEditingController _nickname;
  late final TextEditingController _description;

  /// The callsign a radio authority issued this operator (XPRS.md 6.4.1).
  /// Empty for everyone who has not been issued one, which is most people.
  late final TextEditingController _licence;

  /// Why the typed callsign cannot be saved, or null. From
  /// [xprsIssuedCallsignRefusal], the one grammar.
  String? _licenceError;
  bool _revealKey = false;
  bool _saving = false;

  // Survives-uninstall identity backup status.
  String? _backupPath;
  bool _backupExists = false;
  bool _backupEncrypted = false;
  bool _backupBusy = false;

  @override
  void initState() {
    super.initState();
    _p = widget.profile;
    _nickname = TextEditingController(text: _p.nickname);
    _description = TextEditingController(text: _p.description);
    _licence = TextEditingController(text: _p.licenceCallsign);
    _refreshBackupStatus();
    _refreshEncStatus();
  }

  Future<void> _refreshBackupStatus() async {
    final path = await IdentityBackup.instance.backupPath();
    final exists = await IdentityBackup.instance.backupExists();
    final enc = exists ? await IdentityBackup.instance.isEncrypted() : false;
    if (!mounted) return;
    setState(() {
      _backupPath = path;
      _backupExists = exists;
      _backupEncrypted = enc;
    });
  }

  Future<void> _backupNow() async {
    setState(() => _backupBusy = true);
    if (!await AndroidPermissionsService.instance.hasAllFilesAccess()) {
      final ok =
          await AndroidPermissionsService.instance.requestAllFilesAccess();
      if (!ok) {
        if (mounted) {
          setState(() => _backupBusy = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Storage access is needed to save the backup.')));
        }
        return;
      }
    }
    final pass =
        PreferencesService.instanceSync?.identityBackupPassphrase ?? '';
    await IdentityBackup.instance
        .backupAll(ProfileService.instance.profiles, passphrase: pass);
    await _refreshBackupStatus();
    if (!mounted) return;
    setState(() => _backupBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Identity backed up')));
  }

  /// Set/clear the backup passphrase, then re-write the backup. An empty
  /// passphrase removes encryption (plaintext backup).
  Future<void> _changePassphrase() async {
    final prefs = PreferencesService.instanceSync;
    final controller =
        TextEditingController(text: prefs?.identityBackupPassphrase ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup passphrase'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Encrypt the backup with a passphrase. Leave blank for a '
              'plaintext backup. If you forget it, the backup cannot be '
              'restored — there is no recovery.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'Passphrase (blank = none)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return; // cancelled
    prefs?.identityBackupPassphrase = result;
    await _backupNow();
  }

  @override
  void dispose() {
    _nickname.dispose();
    _description.dispose();
    _licence.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    const group = XTypeGroup(
      label: 'images',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;
    // Store inside the profile's own folder so it travels with the identity.
    await ProfileService.instance
        .storageForProfile(_p.id)
        .writeBytes('avatar.png', bytes);
    setState(() => _p = _p.copyWith(avatar: 'avatar.png'));
  }

  void _removeAvatar() => setState(() => _p = _p.copyWith(avatar: ''));

  /// Re-check the typed callsign on every keystroke, so the reason shows up
  /// where it was typed rather than when Save is pressed.
  void _checkLicence(String v) {
    final t = v.trim();
    setState(() => _licenceError = t.isEmpty ? null : xprsIssuedCallsignRefusal(t));
  }

  /// Go back to the callsign this profile's key derives.
  Future<void> _useDerived() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use your derived callsign?'),
        content: Text(
          'You will transmit as ${_p.callsign} again. Peers reach you under '
          'both names, but mail a neighbour was already carrying for '
          '${_p.licenceCallsign} may not arrive, and apps you have open keep '
          'the old name until you reopen them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Use derived'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _licence.clear();
    setState(() => _licenceError = null);
  }

  Future<void> _save() async {
    // A refused callsign is never written: the Save button is disabled while
    // one is showing, and this is the second door in case it is not.
    if (_licenceError != null) return;
    setState(() => _saving = true);
    final edited = _p.copyWith(
      nickname: _nickname.text.trim(),
      description: _description.text.trim(),
      licenceCallsign: xprsNormaliseCallsign(_licence.text),
    );
    await ProfileService.instance.update(edited);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Profile saved')));
    Navigator.of(context).pop(true);
  }


  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copied')));
  }

  // ── profile encryption ────────────────────────────────────────────────

  bool _encBusy = false;
  bool _usesDeviceKey = false;
  bool _hasCachedKeys = false;

  Future<void> _refreshEncStatus() async {
    final device = await ProfileEncryption.usesDeviceKey(_p.id);
    final cached = await ProfileEncryption.hasCachedKeys(_p.id);
    if (!mounted) return;
    setState(() {
      _usesDeviceKey = device;
      _hasCachedKeys = cached;
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Turn encryption on for a profile that predates the encrypt-by-default
  /// behaviour (or one where it was removed). Device-key mode: no password
  /// to invent, unlock is fingerprint/face.
  Future<void> _enableEncryption() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Encrypt this profile'),
        content: const Text(
          'All existing data of this profile on this device will be DELETED '
          '(messages, chat history, media). The profile starts fresh, fully '
          'encrypted.\n\n'
          'It unlocks with your fingerprint (or the phone\'s screen lock). '
          'You can add a password afterwards.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete data & encrypt')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _encBusy = true);
    try {
      await ProfileEncryption.enableWithDeviceKey(_p.id);
      _snack('Profile encrypted. Restart XPRS to complete.');
    } catch (e) {
      _snack('Enable failed: $e');
    }
    if (mounted) setState(() => _encBusy = false);
    await _refreshEncStatus();
  }

  /// Add a password to a device-key profile: from then on nobody can open
  /// the data without it, not even with the unlocked phone in their hand.
  Future<void> _addPassword() async {
    final pw = await showDialog<String?>(
      context: context,
      builder: (ctx) => const _PasswordSetupDialog(
        title: 'Add a password',
        warning: 'Your data stays intact. From now on the profile needs this '
            'password (emoji welcome) — the device key is dropped, and there '
            'is NO recovery if you forget it.',
        confirmLabel: 'Set password',
      ),
    );
    if (pw == null) return;
    setState(() => _encBusy = true);
    try {
      await ProfileEncryption.addPassword(_p.id, pw);
      _snack('Password set');
    } catch (e) {
      _snack('Could not set password: $e');
    }
    if (mounted) setState(() => _encBusy = false);
    await _refreshEncStatus();
  }

  /// Drop the password and go back to fingerprint-only unlocking.
  Future<void> _removePassword() async {
    final pw = await _askPassword('Remove password',
        'Enter the current password. The profile stays encrypted, but it '
        'will unlock with your fingerprint alone.',
        confirmLabel: 'Remove password');
    if (pw == null) return;
    setState(() => _encBusy = true);
    try {
      await ProfileEncryption.removePassword(_p.id, pw);
      _snack('Password removed — fingerprint unlock');
    } on WrongProfilePassword {
      _snack('Wrong password');
    } catch (e) {
      _snack('Could not remove password: $e');
    }
    if (mounted) setState(() => _encBusy = false);
    await _refreshEncStatus();
  }

  Future<void> _disableEncryption() async {
    String? pw;
    if (_usesDeviceKey) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove encryption'),
          content: const Text(
            'The encrypted data on this device will be DELETED and the '
            'profile returns to unencrypted storage, fresh. Anything written '
            'from then on sits on the disk in the clear.',
            style: TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete data & decrypt')),
          ],
        ),
      );
      if (ok != true) return;
    } else {
      pw = await _askPassword(
        'Remove encryption',
        'Enter the profile password. The encrypted data on this device will '
        'be DELETED; the profile returns to unencrypted storage, fresh.',
        confirmLabel: 'Delete data & decrypt',
      );
      if (pw == null) return;
    }
    setState(() => _encBusy = true);
    try {
      await ProfileEncryption.disable(_p.id, password: pw);
      _snack('Encryption removed. Restart XPRS to complete.');
    } on WrongProfilePassword {
      _snack('Wrong password');
    } catch (e) {
      _snack('Disable failed: $e');
    }
    if (mounted) setState(() => _encBusy = false);
    await _refreshEncStatus();
  }

  Future<void> _changeEncryptionPassword() async {
    final old = await _askPassword('Change password', 'Current password');
    if (old == null) return;
    if (!mounted) return;
    final fresh = await showDialog<String?>(
      context: context,
      builder: (ctx) => const _PasswordSetupDialog(
        title: 'New password',
        warning: 'Your data stays intact — only the password changes. '
            'No recovery if you forget it.',
        confirmLabel: 'Change password',
      ),
    );
    if (fresh == null) return;
    setState(() => _encBusy = true);
    try {
      await ProfileEncryption.changePassword(_p.id, old, fresh);
      _snack('Password changed');
    } on WrongProfilePassword {
      _snack('Wrong current password');
    } catch (e) {
      _snack('Change failed: $e');
    }
    if (mounted) setState(() => _encBusy = false);
  }

  Future<void> _lockNow() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lock profile'),
        content: const Text(
            'XPRS will close to lock the profile. Background message '
            'reception stops until you unlock it again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Lock & close')),
        ],
      ),
    );
    if (ok != true) return;
    await ProfileEncryption.lockNow(_p.id);
    exit(0);
  }

  Future<String?> _askPassword(String title, String message,
      {String confirmLabel = 'OK'}) {
    final controller = TextEditingController();
    return showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(confirmLabel)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            // Off while a typed callsign is refused: the reason is already
            // next to the field, and a disabled Save is how the screen says
            // "not that one" without a second dialog.
            onPressed: (_saving || _licenceError != null) ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Avatar + change/remove.
          Center(
            child: Column(
              children: [
                ProfileAvatar(profile: _p, size: 96),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      label: const Text('Change photo'),
                      onPressed: _pickAvatar,
                    ),
                    if (_p.avatar.isNotEmpty)
                      TextButton.icon(
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Remove'),
                        onPressed: _removeAvatar,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nickname,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Nickname',
              hintText: _p.callsign,
              helperText: 'Shown instead of your callsign. Leave blank to use '
                  'the callsign.',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _description,
            maxLines: 3,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'About',
              hintText: 'A short bio or status (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text('Avatar colour', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final name in kProfileColors)
                _ColorDot(
                  color: profileColor(_p.copyWith(color: name)),
                  selected: _p.color == name,
                  onTap: () => setState(() => _p = _p.copyWith(color: name)),
                ),
              _ColorDot(
                color: profileColor(_p.copyWith(color: '')),
                selected: _p.color.isEmpty,
                label: 'auto',
                onTap: () => setState(() => _p = _p.copyWith(color: '')),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // The name this key derives. Read-only forever: it is an arithmetic
          // function of the key (XPRS.md 3), and it is also this profile's
          // folder on disk, so it cannot move.
          _IdentityRow(
            label: 'Callsign (from your key)',
            value: _p.callsign,
            mono: true,
            onCopy: () => _copy('Callsign', _p.callsign),
          ),
          if (_licence.text.trim().isNotEmpty)
            _IdentityRow(
              label: 'Transmitting as',
              value: xprsNormaliseCallsign(_licence.text),
              mono: true,
              onCopy: () =>
                  _copy('Callsign', xprsNormaliseCallsign(_licence.text)),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _licence,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [_CallsignInputFormatter()],
            maxLength: kXprsMaxCallsignChars,
            onChanged: _checkLicence,
            decoration: InputDecoration(
              labelText: 'Licensed callsign (optional)',
              hintText: 'CT1ABC',
              errorText: _licenceError,
              helperText: _licenceError == null &&
                      _licence.text.trim().isNotEmpty &&
                      !xprsLooksIssued(_licence.text)
                  ? 'That is an unusual shape for an issued callsign. Saved '
                      'as typed.'
                  : 'Leave blank unless a radio authority issued you one.',
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_p.licenceCallsign.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _useDerived,
                child: Text('Use ${_p.callsign} instead'),
              ),
            ),
          _LicenceNote(derived: _p.callsign, typed: _licence.text.trim()),
          _IdentityRow(
            label: 'Public key (npub)',
            value: _p.npub,
            mono: true,
            onCopy: () => _copy('npub', _p.npub),
          ),
          const SizedBox(height: 8),
          // Secret key — hidden behind a reveal, for backup/export only.
          Card(
            color: cs.errorContainer.withValues(alpha: 0.3),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.key, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Secret key (nsec)',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => _revealKey = !_revealKey),
                        child: Text(_revealKey ? 'Hide' : 'Reveal'),
                      ),
                    ],
                  ),
                  if (_revealKey) ...[
                    SelectableText(
                      _p.nsec,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy secret key'),
                          onPressed: () => _copy('Secret key', _p.nsec),
                        ),
                      ],
                    ),
                  ],
                  const Text(
                    'Anyone with this key controls this identity. Back it up '
                    'somewhere safe and never share it.',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Profile encryption: everything this profile stores on this
          // device (messages, media, databases) encrypted at rest, unlocked
          // by password + secret key. See docs/plan-encrypted-storage.md.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        ProfileEncryption.isEncrypted(_p.id)
                            ? Icons.lock
                            : Icons.lock_open,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Profile encryption',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Text(
                        !ProfileEncryption.isEncrypted(_p.id)
                            ? 'Off'
                            : _usesDeviceKey
                                ? 'Device key'
                                : 'Password',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    !ProfileEncryption.isEncrypted(_p.id)
                        ? 'Encrypt everything this profile stores on this '
                            'device. Enabling deletes the profile\'s current '
                            'data and starts fresh.'
                        : _usesDeviceKey
                            ? 'Everything this profile stores on this device '
                                'is encrypted, and unlocks automatically on '
                                'this device. Add a password to protect it '
                                'even from someone holding the unlocked phone.'
                            : 'Everything this profile stores on this device '
                                'is encrypted. Unlocked by your password '
                                'mixed with the secret key.',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: _encBusy
                        ? const [
                            SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          ]
                        : [
                            if (!ProfileEncryption.isEncrypted(_p.id))
                              FilledButton.icon(
                                onPressed: _enableEncryption,
                                icon: const Icon(Icons.enhanced_encryption,
                                    size: 16),
                                label: const Text('Encrypt profile'),
                              )
                            else ...[
                              // "Lock now" on a device-key profile is a lie:
                              // the next launch silently unlocks it again.
                              // Only a password profile genuinely locks.
                              if (!_usesDeviceKey)
                                OutlinedButton.icon(
                                  onPressed: _lockNow,
                                  icon: const Icon(Icons.lock, size: 16),
                                  label: const Text('Lock now'),
                                ),
                              if (_usesDeviceKey)
                                OutlinedButton.icon(
                                  onPressed: _addPassword,
                                  icon: const Icon(Icons.password, size: 16),
                                  label: const Text('Add password'),
                                )
                              else ...[
                                OutlinedButton.icon(
                                  onPressed: _changeEncryptionPassword,
                                  icon: const Icon(Icons.password, size: 16),
                                  label: const Text('Change password'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _removePassword,
                                  icon: const Icon(Icons.key, size: 16),
                                  label: const Text('Use device key'),
                                ),
                              ],
                              if (_hasCachedKeys && !_usesDeviceKey)
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    await ProfileEncryption
                                        .clearCachedKeys(_p.id);
                                    await _refreshEncStatus();
                                    _snack('Device key cache cleared');
                                  },
                                  icon: const Icon(Icons.key_off, size: 16),
                                  label: const Text('Forget device key'),
                                ),
                              TextButton.icon(
                                onPressed: _disableEncryption,
                                icon: const Icon(Icons.no_encryption, size: 16),
                                label: const Text('Remove encryption'),
                              ),
                            ],
                          ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Survives-uninstall backup: keeps the nsec on phone storage so a
          // reinstall / data wipe can restore the identity.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.backup_outlined, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Identity backup',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Text(
                        _backupExists
                            ? (_backupEncrypted ? 'Encrypted' : 'Plaintext')
                            : 'Not yet saved',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _backupPath == null
                        ? 'Grant storage access to keep a copy that survives '
                            'uninstalling the app.'
                        : 'Saved to:\n$_backupPath',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _backupBusy ? null : _backupNow,
                        icon: _backupBusy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.save_alt, size: 16),
                        label: const Text('Back up now'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _backupBusy ? null : _changePassphrase,
                        icon: const Icon(Icons.lock_outline, size: 16),
                        label: Text(_backupEncrypted
                            ? 'Change passphrase'
                            : 'Add passphrase'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'A plaintext backup holds your secret key in the clear — '
                    'anyone with access to this phone\'s storage can read it. '
                    'Add a passphrase to encrypt it.',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Password setup: two matching fields + a hard warning. Returns the
/// password via Navigator.pop, or null on cancel.
class _PasswordSetupDialog extends StatefulWidget {
  final String title;
  final String warning;
  final String confirmLabel;
  const _PasswordSetupDialog({
    required this.title,
    required this.warning,
    required this.confirmLabel,
  });

  @override
  State<_PasswordSetupDialog> createState() => _PasswordSetupDialogState();
}

class _PasswordSetupDialogState extends State<_PasswordSetupDialog> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  bool get _valid => _a.text.isNotEmpty && _a.text == _b.text;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.warning, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: _a,
            autofocus: true,
            obscureText: _obscure,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Password',
              helperText: 'Emoji welcome 🔑',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon:
                    Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _b,
            obscureText: _obscure,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Repeat password',
              errorText: _b.text.isNotEmpty && _a.text != _b.text
                  ? 'Passwords differ'
                  : null,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, _a.text) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final String? label;
  final VoidCallback onTap;
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? cs.onSurface : Colors.transparent,
            width: 3,
          ),
        ),
        child: label != null
            ? Text(label!,
                style: const TextStyle(color: Colors.white, fontSize: 10))
            : (selected
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : null),
      ),
    );
  }
}

/// Uppercase as it is typed, and refuse any character the `call` value type
/// does not have (XPRS.md 670: uppercase letters, digits, `-` and `/`).
///
/// Filtering here rather than only validating means a lowercase callsign is
/// never WRONG, it is just typed, which is what an operator entering their own
/// callsign in a hurry expects.
class _CallsignInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue old, TextEditingValue next) {
    final cleaned = next.text.toUpperCase().replaceAll(RegExp('[^A-Z0-9/-]'), '');
    if (cleaned == next.text) return next;
    final at = next.selection.baseOffset - (next.text.length - cleaned.length);
    return TextEditingValue(
      text: cleaned,
      selection:
          TextSelection.collapsed(offset: at.clamp(0, cleaned.length)),
    );
  }
}

/// What setting a licensed callsign does, and, at greater length, what it does
/// NOT do.
///
/// The wording is drawn from XPRS.md 6.4.2 rather than invented, because that
/// section is unusually blunt about the temptation here: "the temptation to
/// read more into it is strong". It proves the sender holds a key. It proves
/// nothing about entitlement to the callsign. A receiver may keep its own
/// record of an out-of-band check and "must never transmit that verdict as
/// though it were a fact about the callsign", which rules out a badge on this
/// screen too, since the screen is fed by the same records.
class _LicenceNote extends StatelessWidget {
  final String derived;
  final String typed;
  const _LicenceNote({required this.derived, required this.typed});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = typed.isEmpty ? 'CT1ABC' : xprsNormaliseCallsign(typed);
    final small = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    Widget para(String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(body, style: small),
            ],
          ),
        );

    return Card(
      margin: const EdgeInsets.only(top: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            para('What this does',
                'Everything this device sends will go out as $name instead of '
                '$derived, and a signed identity announcement will bind $name '
                'to the key you already have. Your key does not change, and '
                'neither does $derived.'),
            para('What it proves, and what it does not',
                'The announcement proves that whoever holds this key wrote '
                'these packets. It proves nothing about your entitlement to '
                'the callsign: an $derived name is checked against its key by '
                'arithmetic, an issued callsign has no arithmetic '
                'relationship to any key, and XPRS has no register and issues '
                'no credentials. Another station can announce the same '
                'callsign with a different key and both announcements will '
                'verify. Anyone who wants certainty checks your '
                "administration's own licence register, out of band, once. "
                'This app never transmits an opinion about whether a callsign '
                'is licensed.'),
            para('Others will see you as a station',
                'A callsign is read as a person only when it begins X1. A '
                'licensed callsign says nothing about whether its holder is a '
                'person or a mast, and guessing would be worse than saying '
                'station, so you will appear in the Stations list rather than '
                'in People.'),
            para('Mail already on its way',
                'Peers keep reaching you under both names. But mail a '
                'neighbour was already carrying for your old callsign may not '
                'be handed over; ask the sender to resend. Apps you already '
                'have open keep the old name until you reopen them.'),
            Text(
              'On amateur bands a licensed callsign is the only one that may '
              'be transmitted at all, and encryption is not permitted there.',
              style: small,
            ),
          ],
        ),
      ),
    );
  }
}

class _IdentityRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final VoidCallback onCopy;
  const _IdentityRow({
    required this.label,
    required this.value,
    required this.onCopy,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurfaceVariant)),
                SelectableText(
                  value,
                  style: TextStyle(
                      fontSize: 12,
                      fontFamily: mono ? 'monospace' : null),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            tooltip: 'Copy',
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}
