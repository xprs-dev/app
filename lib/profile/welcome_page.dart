/*
 * WelcomePage — first-run profile creation for iwi.
 *
 * Ported and slimmed down from xprs/lib/pages/welcome_page.dart.
 * The parent page ships a lot of extras (vanity generator, i18n,
 * station mode, permissions onboarding) that iwi doesn't need yet.
 * What's preserved: the callsign preview card, regenerate, import
 * nsec, and the "Continue" finalization handoff.
 *
 * The page does NOT write anything to disk until the user hits
 * Continue — [ProfileService.generatePreview] / [buildFromNsec] just
 * build an in-memory [IwiProfile], and [saveAndActivate] is only
 * called from [_finalize].
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reticulum/reticulum.dart' as reticulum;

import 'iwi_profile.dart';
import 'identity_backup.dart';
import 'vanity_callsign_page.dart';
import 'profile_service.dart';
import '../services/android_permissions_service.dart';
import '../services/i18n/core_i18n.dart';
import '../services/preferences_service.dart';

class WelcomePage extends StatefulWidget {
  /// Fired once the profile has been persisted and activated. The
  /// caller (IwiApp) flips the root route from WelcomePage to the
  /// launcher in response.
  final VoidCallback onComplete;

  /// When true, show a Cancel button and allow the user to dismiss
  /// the page without creating a profile. Set this when pushing the
  /// welcome page as a modal on top of an existing profile (e.g. the
  /// "Add profile…" flow from the AppBar switcher). Leave it false
  /// for the first-run boot path where there is no going back.
  final bool canCancel;

  const WelcomePage({
    super.key,
    required this.onComplete,
    this.canCancel = false,
  });

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final _nicknameController = TextEditingController();

  /// In-memory preview profile. Never persisted until [_finalize].
  IwiProfile _preview = ProfileService.instance.generatePreview();

  /// Previous preview — kept so "go back" can undo a regenerate.
  IwiProfile? _previous;

  bool _isFinalizing = false;
  String? _error;

  // ── Restore-from-backup (survives-uninstall identity) ──────────────────
  /// Identities found in the survives-uninstall backup, auto-loaded on init
  /// when the file is plaintext and reachable. Drives the restore card.
  List<RestorableIdentity> _restorable = const [];

  @override
  void initState() {
    super.initState();
    _loadRestorable();
  }

  /// Auto-detect a reachable, plaintext backup so we can offer one-tap restore.
  /// Encrypted or permission-gated backups are reached via [_restoreFromBackup].
  Future<void> _loadRestorable() async {
    try {
      if (!await IdentityBackup.instance.backupExists()) return;
      if (await IdentityBackup.instance.isEncrypted()) return;
      final list = await IdentityBackup.instance.readBackup();
      if (mounted && list.isNotEmpty) setState(() => _restorable = list);
    } catch (_) {
      // Best-effort — the manual "Restore from a backup" button still works.
    }
  }

  /// Save a restored identity and hand off to the launcher. Reuses
  /// [ProfileService.buildFromNsec] so the callsign/npub are re-derived.
  Future<void> _restore(RestorableIdentity id) async {
    setState(() {
      _isFinalizing = true;
      _error = null;
    });
    try {
      // buildFromNsec re-derives the callsign from the key; a licensed one
      // cannot be re-derived (XPRS.md 6.4.2), so it is restored here or not
      // at all.
      final profile = ProfileService.instance
          .buildFromNsec(id.nsec, nickname: id.nickname)
          .copyWith(
              licenceCallsign: id.licenceCallsign,
              licenceCallsigns: id.licenceCallsigns);
      await ProfileService.instance.saveAndActivate(profile);
      await _ensureBackupAccess();
      if (!mounted) return;
      widget.onComplete();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFinalizing = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Manual restore: grant storage access if needed, unlock an encrypted backup
  /// with a passphrase, then restore (or pick when several identities exist).
  Future<void> _restoreFromBackup() async {
    // Android: the backup lives on public storage behind all-files-access.
    if (!await AndroidPermissionsService.instance.hasAllFilesAccess()) {
      final ok = await AndroidPermissionsService.instance
          .requestAllFilesAccess();
      if (!ok) {
        if (mounted) {
          setState(
            () => _error = tr('onboarding.restore.need_storage'),
          );
        }
        return;
      }
    }
    if (!await IdentityBackup.instance.backupExists()) {
      if (mounted) setState(() => _error = tr('onboarding.restore.none'));
      return;
    }
    var passphrase = '';
    if (await IdentityBackup.instance.isEncrypted()) {
      final entered = await _promptPassphrase();
      if (entered == null || entered.isEmpty) return;
      passphrase = entered;
    }
    List<RestorableIdentity> list;
    try {
      list = await IdentityBackup.instance.readBackup(passphrase: passphrase);
    } on BadPassphrase catch (e) {
      if (mounted) setState(() => _error = e.message);
      return;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return;
    }
    if (list.isEmpty) {
      if (mounted) setState(() => _error = tr('onboarding.restore.empty'));
      return;
    }
    // Keep encrypting future auto-backups with the same passphrase.
    if (passphrase.isNotEmpty) {
      PreferencesService.instanceSync?.identityBackupPassphrase = passphrase;
    }
    if (list.length == 1) {
      await _restore(list.first);
      return;
    }
    if (!mounted) return;
    final chosen = await showDialog<RestorableIdentity>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('onboarding.restore.which')),
        children: [
          for (final id in list)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, id),
              child: Text(
                '${id.callsign}${id.nickname.isNotEmpty ? '  (${id.nickname})' : ''}',
              ),
            ),
        ],
      ),
    );
    if (chosen != null) await _restore(chosen);
  }

  Future<String?> _promptPassphrase() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('onboarding.restore.unlock_title')),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: InputDecoration(
            hintText: tr('onboarding.restore.passphrase_hint'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(tr('onboarding.unlock.button')),
          ),
        ],
      ),
    );
  }

  Widget _restoreCard(ThemeData theme, ColorScheme cs) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.restore, color: cs.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('onboarding.restore.title'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: cs.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            tr('onboarding.restore.found'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 12),
          for (final id in _restorable)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton.icon(
                onPressed: _isFinalizing ? null : () => _restore(id),
                icon: const Icon(Icons.badge),
                label: Text(
                  tr('onboarding.restore.button', {'callsign': id.callsign}) +
                      (id.nickname.isNotEmpty ? '  (${id.nickname})' : ''),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  /// Open the full-screen generator and adopt whatever the user picked. The
  /// search runs on its own isolate inside that page, so it never competes with
  /// this screen for frames.
  Future<void> _openVanityPage() async {
    final picked = await Navigator.of(context).push<IwiProfile>(
      MaterialPageRoute(
        builder: (_) => VanityCallsignPage(currentCallsign: _preview.callsign),
      ),
    );
    if (picked != null && mounted) _selectVanity(picked);
  }

  /// Use a found vanity match as the active preview (so Continue keeps it).
  void _selectVanity(IwiProfile match) {
    setState(() {
      _previous = _preview;
      _preview = match;
      _error = null;
    });
  }

  void _regenerate() {
    setState(() {
      _previous = _preview;
      _preview = ProfileService.instance.generatePreview(
        nickname: _nicknameController.text.trim(),
      );
      _error = null;
    });
  }

  void _goBack() {
    final prev = _previous;
    if (prev == null) return;
    setState(() {
      _preview = prev;
      _previous = null;
      _error = null;
    });
  }

  Future<void> _importNsec() async {
    final controller = TextEditingController();
    // Both halves of a callsign are the holder's own choice (spec section 3):
    // the prefix says what kind of holder this is -- X1 a person, X2 a movable
    // station, X3 a fixed one -- and the length is "the holder's own choice,
    // and four is the default". Fixed once, at import, because the callsign is
    // how everyone who hears this device addresses and stores it.
    var kind = CallsignKind.person;
    var length = reticulum.NostrCrypto.kDefaultCallsignLength;
    final result = await showDialog<(String, CallsignKind, int)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('onboarding.import.title')),
          // Scrollable: with the keyboard up there is barely a third of the
          // screen left, and an AlertDialog clips its content rather than
          // shrinking -- the prefix and length rows ended up underneath the
          // action buttons.
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('onboarding.import.intro')),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'nsec1…',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(tr('onboarding.import.kind')),
                    const SizedBox(width: 10),
                    DropdownButton<CallsignKind>(
                      value: kind,
                      onChanged: (v) =>
                          setLocal(() => kind = v ?? CallsignKind.person),
                      items: [
                        DropdownMenuItem(
                          value: CallsignKind.person,
                          child: Text(tr('onboarding.import.kind_person')),
                        ),
                        DropdownMenuItem(
                          value: CallsignKind.mobile,
                          child: Text(tr('onboarding.import.kind_mobile')),
                        ),
                        DropdownMenuItem(
                          value: CallsignKind.station,
                          child: Text(tr('onboarding.import.kind_station')),
                        ),
                      ],
                    ),
                  ],
                ),
                Row(
                  children: [
                    Text(tr('onboarding.vanity.length')),
                    const SizedBox(width: 10),
                    DropdownButton<int>(
                      value: length,
                      onChanged: (v) => setLocal(
                        () => length =
                            v ?? reticulum.NostrCrypto.kDefaultCallsignLength,
                      ),
                      items: [
                        for (
                          var n = reticulum.NostrCrypto.kMinCallsignLength;
                          n <= reticulum.NostrCrypto.kMaxCallsignLength;
                          n++
                        )
                          DropdownMenuItem(value: n, child: Text('$n')),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.cancel')),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, (controller.text.trim(), kind, length)),
              child: Text(tr('onboarding.import.button')),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final (nsec, chosenKind, callsignLength) = result;
    if (nsec.isEmpty) return;
    try {
      final profile = ProfileService.instance.buildFromNsec(
        nsec,
        nickname: _nicknameController.text.trim(),
        kind: chosenKind,
        callsignLength: callsignLength,
      );
      setState(() {
        _previous = _preview;
        _preview = profile;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _finalize() async {
    setState(() {
      _isFinalizing = true;
      _error = null;
    });
    try {
      final profile = _preview.copyWith(
        nickname: _nicknameController.text.trim(),
      );
      await ProfileService.instance.saveAndActivate(profile);
      await _ensureBackupAccess();
      if (!mounted) return;
      widget.onComplete();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFinalizing = false;
          _error = e.toString();
        });
      }
    }
  }

  /// One-time nudge so the automatic identity backup can write to the
  /// survives-uninstall location. Android-only; no-op once access is granted
  /// (and on desktop). Skipping is fine — the profile editor can enable it
  /// later, and the auto-backup just stays idle until then.
  Future<void> _ensureBackupAccess() async {
    final prefs = PreferencesService.instanceSync;
    var pass = prefs?.identityBackupPassphrase ?? '';
    // On Android the backup lives in shared storage and is written only
    // encrypted, so the nudge also asks for the passphrase.
    final needPass = IdentityBackup.instance.requiresPassphrase && pass.isEmpty;
    final hasAccess =
        await AndroidPermissionsService.instance.hasAllFilesAccess();
    if (hasAccess && !needPass) {
      // Already granted (or desktop) — make sure the first backup is written.
      await IdentityBackup.instance.backupAll(
        ProfileService.instance.profiles,
        passphrase: pass,
      );
      return;
    }
    if (!mounted) return;
    final controller = TextEditingController();
    final allow = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('onboarding.backup.title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('onboarding.backup.intro')),
            if (needPass) ...[
              const SizedBox(height: 12),
              Text(
                tr('onboarding.backup.passphrase_warning'),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: tr('onboarding.backup.passphrase_hint'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('onboarding.backup.not_now')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('onboarding.backup.allow')),
          ),
        ],
      ),
    );
    final entered = controller.text;
    controller.dispose();
    if (allow != true) return;
    if (needPass) {
      if (entered.isEmpty) return;
      prefs?.identityBackupPassphrase = entered;
      pass = entered;
    }
    if (!hasAccess &&
        !await AndroidPermissionsService.instance.requestAllFilesAccess()) {
      return;
    }
    await IdentityBackup.instance.backupAll(
      ProfileService.instance.profiles,
      passphrase: pass,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return PopScope(
      canPop: widget.canCancel,
      child: Scaffold(
        appBar: widget.canCancel
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: tr('common.cancel'),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                title: Text(tr('onboarding.welcome.add_profile')),
              )
            : null,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 48,
                    maxWidth: 560,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: cs.primaryContainer,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.waving_hand,
                              size: 36,
                              color: cs.primary,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tr('onboarding.welcome.title'),
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  tr('onboarding.welcome.intro'),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),

                      // Restore-from-backup card (only when a backup was found).
                      if (_restorable.isNotEmpty) _restoreCard(theme, cs),

                      // Callsign card
                      Text(
                        tr('onboarding.welcome.your_callsign'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          children: [
                            Icon(Icons.badge, size: 48, color: cs.primary),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_previous != null)
                                  IconButton(
                                    onPressed: _isFinalizing ? null : _goBack,
                                    icon: const Icon(Icons.undo),
                                    tooltip: tr('onboarding.welcome.revert'),
                                    color: cs.primary,
                                  )
                                else
                                  const SizedBox(width: 48),
                                const SizedBox(width: 8),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  child: Text(
                                    _preview.callsign,
                                    key: ValueKey(_preview.callsign),
                                    style: theme.textTheme.headlineMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: cs.primary,
                                          letterSpacing: 2,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const SizedBox(width: 48),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SelectableText(
                              _preview.npub,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onPrimaryContainer,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _isFinalizing ? null : _regenerate,
                                  icon: const Icon(Icons.refresh, size: 18),
                                  label: Text(tr('onboarding.welcome.generate')),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _isFinalizing ? null : _importNsec,
                                  icon: const Icon(Icons.key, size: 18),
                                  label: Text(tr('onboarding.welcome.import_nsec')),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _isFinalizing
                                      ? null
                                      : _restoreFromBackup,
                                  icon: const Icon(Icons.restore, size: 18),
                                  label: Text(tr('onboarding.welcome.restore')),
                                ),
                                FilledButton.icon(
                                  onPressed: _isFinalizing ? null : _finalize,
                                  icon: _isFinalizing
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.check, size: 18),
                                  label: Text(tr('common.continue')),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),
                      // Choosing a callsign you like is a whole task of its own
                      // (type a pattern, watch a brute-force search, pick from
                      // matches), and it does not belong squeezed in beside the
                      // preview card and the Continue button. One button; the
                      // work happens on its own full screen.
                      Text(
                        tr('onboarding.welcome.custom_title'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tr('onboarding.welcome.custom_desc'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _isFinalizing ? null : _openVanityPage,
                        icon: const Icon(Icons.search, size: 18),
                        label: Text(tr('onboarding.welcome.custom_button')),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),

                      const SizedBox(height: 20),
                      Text(
                        tr('onboarding.welcome.nickname'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _nicknameController,
                        decoration: InputDecoration(
                          hintText: tr('onboarding.welcome.nickname_hint'),
                          border: const OutlineInputBorder(),
                        ),
                      ),

                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: cs.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 20,
                                color: cs.error,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: TextStyle(color: cs.onErrorContainer),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.secondaryContainer.withAlpha(128),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 20,
                              color: cs.secondary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                tr('onboarding.welcome.storage_note'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
