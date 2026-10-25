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

import 'callsign_input.dart';
import 'iwi_profile.dart';
import 'identity_backup.dart';
import 'profile_avatar.dart';
import 'profile_crypto.dart';
import 'profile_encryption.dart';
import 'profile_service.dart';
import '../services/android_permissions_service.dart';
import '../services/preferences_service.dart';
import '../services/xprs/xprs_self.dart';
import '../services/xprs/xprs_callsign.dart';
import '../services/xprs/xprs_profiles.dart';
import '../services/i18n/core_i18n.dart';

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

  /// The field a new issued callsign is typed into (XPRS.md 6.4.1). It is
  /// not the list: a callsign joins [_licences] when Add accepts it.
  late final TextEditingController _licence;

  /// Why the typed callsign cannot be added, or null. From
  /// [xprsIssuedCallsignRefusal], the one grammar. Only shown once something
  /// is typed.
  String? _licenceError;

  /// Every issued callsign this operator holds, one per jurisdiction, in the
  /// order added. The derived X1 is never in it: it is the base.
  late List<String> _licences;

  /// Which one is on the air by default; '' = the derived X1.
  late String _active;
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
    _licence = TextEditingController();
    _licences = List<String>.of(_p.heldLicences);
    _active = _p.licenceCallsign.trim().toUpperCase();
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
    // Shared storage only ever holds an encrypted backup: ask for the
    // passphrase first.
    if (IdentityBackup.instance.requiresPassphrase &&
        (PreferencesService.instanceSync?.identityBackupPassphrase ?? '')
            .isEmpty) {
      return _changePassphrase();
    }
    await _writeBackup();
  }

  Future<void> _writeBackup() async {
    setState(() => _backupBusy = true);
    if (!await AndroidPermissionsService.instance.hasAllFilesAccess()) {
      final ok =
          await AndroidPermissionsService.instance.requestAllFilesAccess();
      if (!ok) {
        if (mounted) {
          setState(() => _backupBusy = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(tr('profile.backup.need_storage'))));
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
        SnackBar(content: Text(tr('profile.backup.done'))));
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
        title: Text(tr('profile.backup.passphrase.title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(IdentityBackup.instance.requiresPassphrase
                  ? 'profile.backup.passphrase.shared'
                  : 'profile.backup.passphrase.optional'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                hintText: tr('profile.backup.passphrase.hint'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(tr('common.save')),
          ),
        ],
      ),
    );
    if (result == null) return; // cancelled
    prefs?.identityBackupPassphrase = result;
    await _writeBackup();
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
    // The core makes the picture: a small square thumbnail, off the UI
    // isolate, kept as a file other stations can fetch (XPRS.md 6.3.2). The
    // profile names it; Save puts it on the air.
    final token = await XprsProfiles.instance.pictureTokenFor(bytes);
    if (!mounted) return;
    if (token == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('profile.avatar.unreadable'))));
      return;
    }
    setState(() => _p = _p.copyWith(avatar: token));
  }

  void _removeAvatar() => setState(() => _p = _p.copyWith(avatar: ''));

  /// Re-check the typed callsign on every keystroke, so the reason shows up
  /// where it was typed rather than when Save is pressed.
  void _checkLicence(String v) {
    final t = v.trim();
    setState(() => _licenceError = t.isEmpty ? null : _refusal(t));
  }

  /// The grammar's refusal, plus the two this list adds.
  String? _refusal(String typed) {
    final c = xprsNormaliseCallsign(typed);
    final r = xprsIssuedCallsignRefusal(c);
    if (r != null) return r;
    if (_licences.contains(c)) return tr('profile.callsigns.already', {'callsign': c});
    if (_licences.length >= IwiProfile.maxLicences) {
      return tr('profile.callsigns.full', {'max': IwiProfile.maxLicences});
    }
    return null;
  }

  void _addLicence() {
    final c = xprsNormaliseCallsign(_licence.text);
    final why = c.isEmpty ? null : _refusal(c);
    if (c.isEmpty || why != null) {
      setState(() => _licenceError = why);
      return;
    }
    setState(() {
      _licences.add(c);
      // The first callsign a person adds is the one they mean to use.
      if (_active.isEmpty && _licences.length == 1) _active = c;
      _licence.clear();
      _licenceError = null;
    });
  }

  /// Conversations that keep a callsign other than the one chosen here.
  int _pinnedCount() {
    if (ProfileService.instance.activeProfile?.id != _p.id) return 0;
    final act = _active.isEmpty ? _p.callsign.toUpperCase() : _active;
    return XprsSelf.instance
        .pinned()
        .values
        .where((c) => c != act && _licences.contains(c))
        .length;
  }

  void _removeLicence(String c) {
    setState(() {
      _licences.remove(c);
      if (_active == c) _active = _licences.isEmpty ? '' : _licences.first;
    });
  }

  Future<void> _save() async {
    // A refused callsign is never written: the Save button is disabled while
    // one is showing, and this is the second door in case it is not.
    // A callsign typed but not yet added is added now: pressing Save with it
    // in the field means "keep this", and losing it silently is worse.
    if (_licence.text.trim().isNotEmpty) {
      _addLicence();
      if (_licenceError != null) return;
    }
    setState(() => _saving = true);
    final edited = _p.copyWith(
      nickname: _nickname.text.trim(),
      description: _description.text.trim(),
      licenceCallsigns: List<String>.of(_licences),
      licenceCallsign: _licences.contains(_active) ? _active : '',
    );
    await ProfileService.instance.update(edited);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('profile.saved'))));
    Navigator.of(context).pop(true);
  }


  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('profile.copied', {'what': label}))));
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
        title: Text(tr('profile.encryption.enable.title')),
        content: Text(
          tr('profile.encryption.enable.body'),
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('profile.encryption.enable.button'))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _encBusy = true);
    try {
      await ProfileEncryption.enableWithDeviceKey(_p.id);
      _snack(tr('profile.encryption.enabled'));
    } catch (e) {
      _snack(tr('profile.encryption.enable.failed', {'error': e}));
    }
    if (mounted) setState(() => _encBusy = false);
    await _refreshEncStatus();
  }

  /// Add a password to a device-key profile: from then on nobody can open
  /// the data without it, not even with the unlocked phone in their hand.
  Future<void> _addPassword() async {
    final pw = await showDialog<String?>(
      context: context,
      builder: (ctx) => _PasswordSetupDialog(
        title: tr('profile.password.add.title'),
        warning: tr('profile.password.add.warning'),
        confirmLabel: tr('profile.password.add.button'),
      ),
    );
    if (pw == null) return;
    setState(() => _encBusy = true);
    try {
      await ProfileEncryption.addPassword(_p.id, pw);
      _snack(tr('profile.password.set'));
    } catch (e) {
      _snack(tr('profile.password.set.failed', {'error': e}));
    }
    if (mounted) setState(() => _encBusy = false);
    await _refreshEncStatus();
  }

  /// Drop the password and go back to fingerprint-only unlocking.
  Future<void> _removePassword() async {
    final pw = await _askPassword(tr('profile.password.remove.title'),
        tr('profile.password.remove.body'),
        confirmLabel: tr('profile.password.remove.title'));
    if (pw == null) return;
    setState(() => _encBusy = true);
    try {
      await ProfileEncryption.removePassword(_p.id, pw);
      _snack(tr('profile.password.removed'));
    } on WrongProfilePassword {
      _snack(tr('profile.password.wrong'));
    } catch (e) {
      _snack(tr('profile.password.remove.failed', {'error': e}));
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
          title: Text(tr('profile.encryption.remove.title')),
          content: Text(
            tr('profile.encryption.remove.body_device'),
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('common.cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('profile.encryption.remove.button'))),
          ],
        ),
      );
      if (ok != true) return;
    } else {
      pw = await _askPassword(
        tr('profile.encryption.remove.title'),
        tr('profile.encryption.remove.body_password'),
        confirmLabel: tr('profile.encryption.remove.button'),
      );
      if (pw == null) return;
    }
    setState(() => _encBusy = true);
    try {
      await ProfileEncryption.disable(_p.id, password: pw);
      _snack(tr('profile.encryption.removed'));
    } on WrongProfilePassword {
      _snack(tr('profile.password.wrong'));
    } catch (e) {
      _snack(tr('profile.encryption.remove.failed', {'error': e}));
    }
    if (mounted) setState(() => _encBusy = false);
    await _refreshEncStatus();
  }

  Future<void> _changeEncryptionPassword() async {
    final old = await _askPassword(
        tr('profile.password.change.title'), tr('profile.password.current'));
    if (old == null) return;
    if (!mounted) return;
    final fresh = await showDialog<String?>(
      context: context,
      builder: (ctx) => _PasswordSetupDialog(
        title: tr('profile.password.new.title'),
        warning: tr('profile.password.new.warning'),
        confirmLabel: tr('profile.password.change.title'),
      ),
    );
    if (fresh == null) return;
    setState(() => _encBusy = true);
    try {
      await ProfileEncryption.changePassword(_p.id, old, fresh);
      _snack(tr('profile.password.changed'));
    } on WrongProfilePassword {
      _snack(tr('profile.password.wrong_current'));
    } catch (e) {
      _snack(tr('profile.password.change.failed', {'error': e}));
    }
    if (mounted) setState(() => _encBusy = false);
  }

  Future<void> _lockNow() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('profile.lock.title')),
        content: Text(tr('profile.lock.body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('profile.lock.button'))),
        ],
      ),
    );
    if (ok != true) return;
    await ProfileEncryption.lockNow(_p.id);
    exit(0);
  }

  Future<String?> _askPassword(String title, String message,
      {String? confirmLabel}) {
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
              decoration: InputDecoration(
                labelText: tr('profile.password.label'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(confirmLabel ?? tr('common.ok'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('profile.edit.title')),
        actions: [
          IconButton(
            tooltip: tr('common.save'),
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
                      label: Text(tr('profile.avatar.change')),
                      onPressed: _pickAvatar,
                    ),
                    if (_p.avatar.isNotEmpty)
                      TextButton.icon(
                        icon: const Icon(Icons.close, size: 18),
                        label: Text(tr('common.remove')),
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
              labelText: tr('profile.nickname'),
              hintText: _p.callsign,
              helperText: tr('profile.nickname.help'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _description,
            maxLines: 3,
            maxLength: 200,
            decoration: InputDecoration(
              labelText: tr('profile.about'),
              hintText: tr('profile.about.hint'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(tr('profile.avatar.colour'),
              style: Theme.of(context).textTheme.labelLarge),
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
                label: tr('profile.avatar.colour.auto'),
                onTap: () => setState(() => _p = _p.copyWith(color: '')),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // The name this key derives. Read-only forever: it is an arithmetic
          // function of the key (XPRS.md 3), and it is also this profile's
          // folder on disk, so it cannot move.
          _IdentityRow(
            label: tr('profile.callsign.derived'),
            value: _p.callsign,
            mono: true,
            onCopy: () => _copy(tr('profile.callsign'), _p.callsign),
          ),
          const SizedBox(height: 12),
          // Which name goes on the air by default. The X1 is always a choice:
          // it is the base, and the one an unlicensed operator uses.
          Text(tr('profile.callsigns.title'),
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(tr('profile.callsigns.help'),
              style: Theme.of(context).textTheme.bodySmall),
          RadioListTile<String>(
            value: '',
            groupValue: _active,
            onChanged: (v) => setState(() => _active = v ?? ''),
            contentPadding: EdgeInsets.zero,
            title: Text(_p.callsign,
                style: const TextStyle(fontFamily: 'monospace')),
            subtitle: Text(tr('profile.callsigns.base')),
          ),
          for (final c in _licences)
            RadioListTile<String>(
              value: c,
              groupValue: _active,
              onChanged: (v) => setState(() => _active = v ?? ''),
              contentPadding: EdgeInsets.zero,
              title: Text(c, style: const TextStyle(fontFamily: 'monospace')),
              subtitle: _active == c
                  ? Text(tr('profile.callsign.transmitting_as'))
                  : null,
              secondary: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: tr('profile.callsigns.remove', {'callsign': c}),
                onPressed: () => _removeLicence(c),
              ),
            ),
          if (_pinnedCount() > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                  trn('profile.callsigns.pinned', _pinnedCount()),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 8),
          if (_licences.length < IwiProfile.maxLicences)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _licence,
                    // What makes this field typeable on an Android phone. The
                    // keyboard composes each word (it holds the letters it may
                    // still change), and the formatter this field had rewrote
                    // the text on every keystroke -- uppercasing it under the
                    // keyboard -- so the keyboard re-sent its own copy and the
                    // field doubled, lost or reordered letters. Now: a
                    // keyboard type that does not compose, no suggestions, no
                    // autocorrect, capitals requested rather than imposed,
                    // and a formatter that never touches composing text. The
                    // callsign is uppercased when it is added.
                    keyboardType: TextInputType.visiblePassword,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    inputFormatters: [CallsignInputFormatter()],
                    maxLength: kXprsMaxCallsignChars,
                    onChanged: _checkLicence,
                    onSubmitted: (_) => _addLicence(),
                    decoration: InputDecoration(
                      labelText: tr('profile.callsign.licensed'),
                      hintText: 'CT1ABC',
                      errorText: _licenceError,
                      helperText: tr(_licenceError == null &&
                              _licence.text.trim().isNotEmpty &&
                              !xprsLooksIssued(_licence.text)
                          ? 'profile.callsign.licensed.unusual'
                          : 'profile.callsign.licensed.help'),
                      helperMaxLines: 3,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.tonal(
                    onPressed: _addLicence,
                    child: Text(tr('common.add')),
                  ),
                ),
              ],
            ),
          _LicenceNote(
              derived: _p.callsign,
              typed: _active.isNotEmpty ? _active : _licence.text.trim()),
          _IdentityRow(
            label: tr('profile.npub'),
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
                      Expanded(
                        child: Text(tr('profile.nsec'),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => _revealKey = !_revealKey),
                        child: Text(tr(_revealKey
                            ? 'profile.nsec.hide'
                            : 'profile.nsec.reveal')),
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
                          label: Text(tr('profile.nsec.copy')),
                          onPressed: () =>
                              _copy(tr('profile.nsec.short'), _p.nsec),
                        ),
                      ],
                    ),
                  ],
                  Text(
                    tr('profile.nsec.warning'),
                    style: const TextStyle(fontSize: 11),
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
                      Expanded(
                        child: Text(tr('profile.encryption'),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Text(
                        tr(!ProfileEncryption.isEncrypted(_p.id)
                            ? 'common.off'
                            : _usesDeviceKey
                                ? 'profile.encryption.mode.device'
                                : 'profile.encryption.mode.password'),
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr(!ProfileEncryption.isEncrypted(_p.id)
                        ? 'profile.encryption.desc.off'
                        : _usesDeviceKey
                            ? 'profile.encryption.desc.device'
                            : 'profile.encryption.desc.password'),
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
                                label: Text(tr('profile.encryption.enable.button_short')),
                              )
                            else ...[
                              // "Lock now" on a device-key profile is a lie:
                              // the next launch silently unlocks it again.
                              // Only a password profile genuinely locks.
                              if (!_usesDeviceKey)
                                OutlinedButton.icon(
                                  onPressed: _lockNow,
                                  icon: const Icon(Icons.lock, size: 16),
                                  label: Text(tr('profile.lock.now')),
                                ),
                              if (_usesDeviceKey)
                                OutlinedButton.icon(
                                  onPressed: _addPassword,
                                  icon: const Icon(Icons.password, size: 16),
                                  label: Text(tr('profile.password.add.short')),
                                )
                              else ...[
                                OutlinedButton.icon(
                                  onPressed: _changeEncryptionPassword,
                                  icon: const Icon(Icons.password, size: 16),
                                  label: Text(tr('profile.password.change.title')),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _removePassword,
                                  icon: const Icon(Icons.key, size: 16),
                                  label: Text(tr('profile.password.use_device_key')),
                                ),
                              ],
                              if (_hasCachedKeys && !_usesDeviceKey)
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    await ProfileEncryption
                                        .clearCachedKeys(_p.id);
                                    await _refreshEncStatus();
                                    _snack(tr('profile.encryption.cache_cleared'));
                                  },
                                  icon: const Icon(Icons.key_off, size: 16),
                                  label: Text(tr('profile.encryption.forget_device_key')),
                                ),
                              TextButton.icon(
                                onPressed: _disableEncryption,
                                icon: const Icon(Icons.no_encryption, size: 16),
                                label: Text(tr('profile.encryption.remove.title')),
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
                      Expanded(
                        child: Text(tr('profile.backup'),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Text(
                        tr(_backupExists
                            ? (_backupEncrypted
                                ? 'profile.backup.state.encrypted'
                                : 'profile.backup.state.plaintext')
                            : 'profile.backup.state.none'),
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
                        ? tr('profile.backup.grant_storage')
                        : tr('profile.backup.saved_to', {'path': _backupPath}),
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
                        label: Text(tr('profile.backup.now')),
                      ),
                      OutlinedButton.icon(
                        onPressed: _backupBusy ? null : _changePassphrase,
                        icon: const Icon(Icons.lock_outline, size: 16),
                        label: Text(tr(_backupEncrypted
                            ? 'profile.backup.passphrase.change'
                            : 'profile.backup.passphrase.add')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr(IdentityBackup.instance.requiresPassphrase
                        ? 'profile.backup.note.shared'
                        : 'profile.backup.note.plaintext'),
                    style: const TextStyle(fontSize: 11),
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
              labelText: tr('profile.password.label'),
              helperText: tr('profile.password.emoji'),
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
              labelText: tr('profile.password.repeat'),
              errorText: _b.text.isNotEmpty && _a.text != _b.text
                  ? tr('profile.password.differ')
                  : null,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('common.cancel'))),
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
            para(tr('profile.licence.does.title'),
                tr('profile.licence.does.body',
                    {'name': name, 'derived': derived})),
            para(tr('profile.licence.proves.title'),
                tr('profile.licence.proves.body', {'derived': derived})),
            para(tr('profile.licence.station.title'),
                tr('profile.licence.station.body')),
            para(tr('profile.licence.mail.title'),
                tr('profile.licence.mail.body')),
            Text(
              tr('profile.licence.amateur'),
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
            tooltip: tr('common.copy'),
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}
