part of 'launcher.dart';

// ── Iwi Settings ─────────────────────────────────────────────────────

/// The pages Settings opens, one per topic.
enum SettingsTopic { device, language, privacy, network, updates, storage, developer }

/// Settings: a short menu of topics ([topic] null), or one topic's page.
class IwiSettingsPage extends StatefulWidget {
  final SettingsTopic? topic;
  const IwiSettingsPage({super.key, this.topic});

  @override
  State<IwiSettingsPage> createState() => _IwiSettingsPageState();
}

class _IwiSettingsPageState extends State<IwiSettingsPage> {
  PreferencesService? _prefs;
  String? _dataDir;
  List<_WappDataEntry> _wappDataEntries = [];
  final UpdateService _upd = UpdateService.instance;

  @override
  void initState() {
    super.initState();
    // A grant made while the app stayed in the foreground (adb, a system
    // shortcut) brings no resume to notice it; opening Settings is when the
    // Permissions line has to be right.
    unawaited(PermissionState.instance.refresh());
    _load();
  }

  Future<void> _load() async {
    final prefs = await PreferencesService.instance();
    final defaultPath = wappsDataStorage(prefs).basePath;
    await _upd.load(); // populate the stable/beta update-folder addresses
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _dataDir = prefs.wappDataDir ?? defaultPath;
    });
    // The directory walk and the hosted-media count are for their own
    // pages, not for every page Settings opens.
    if (widget.topic == SettingsTopic.storage) await _refreshWappData();
  }

  /// Prompt for a single text value (used for the Reticulum sharing-folder
  /// addresses). Returns the trimmed input, or null if cancelled.
  Future<String?> _editTextPref({
    required String title,
    required String help,
    required String hint,
    required String initial,
  }) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              help,
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: hint,
                filled: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('common.save')),
          ),
        ],
      ),
    );
  }

  String _folderSubtitle(String v) =>
      v.trim().isEmpty ? tr('settings.folders.unset') : v.trim();

  Future<void> _editUpdateFolder({required bool beta}) async {
    final r = await _editTextPref(
      title: tr(beta ? 'settings.folders.beta' : 'settings.folders.stable'),
      help: tr('settings.folders.edit_help', {
        'channel': tr(beta
            ? 'settings.folders.channel.beta'
            : 'settings.folders.channel.stable')
      }),
      hint: 'npub1…',
      initial: beta ? _upd.betaFolder : _upd.stableFolder,
    );
    if (r == null) return;
    if (beta) {
      await _upd.setBetaFolder(r);
    } else {
      await _upd.setStableFolder(r);
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshWappData() async {
    final dataDir = _dataDir;
    if (dataDir == null) return;
    final storage = makeFilesystemStorage(dataDir);
    if (!await storage.directoryExists('')) {
      if (mounted) setState(() => _wappDataEntries = []);
      return;
    }
    final subdirs = await storage.listDirectory('');
    final entries = <_WappDataEntry>[];
    for (final sub in subdirs) {
      if (!sub.isDirectory) continue;
      var size = 0;
      try {
        final children =
            await storage.listDirectory(sub.path, recursive: true);
        for (final c in children) {
          if (!c.isDirectory) size += c.size ?? 0;
        }
      } catch (_) {}
      entries.add(_WappDataEntry(
        sub.name,
        storage.getAbsolutePath(sub.path),
        size,
      ));
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    if (mounted) setState(() => _wappDataEntries = entries);
  }

  /// Human-readable description of the current locale pref for the
  /// Settings subtitle. Shows "Auto — pt_PT" when no explicit choice
  /// has been made (so the user can see what "Auto" resolved to),
  /// and just the explicit locale otherwise.
  String _localeSubtitle() {
    final p = _prefs;
    if (p == null) return '';
    final explicit = p.localePreference;
    if (explicit == null || explicit.isEmpty) {
      return tr('common.language.auto',
          {'locale': _languageName(CoreI18n.instance.resolved)});
    }
    return _languageName(explicit);
  }

  /// The dropdown's value must be one of its items: a stored tag with no
  /// folder in this build (an old `pt_PT`, a removed language) reads as Auto
  /// rather than crashing the dropdown.
  String _localeValue() {
    final v = _prefs?.localePreference ?? '';
    return CoreI18n.instance.languages.contains(v) ? v : '';
  }

  /// A language names itself (the one string a person must be able to read
  /// whatever is selected), so these are not in any lang file.
  static String _languageName(String code) => switch (code) {
        'en' => 'English',
        'pt' || 'pt_PT' => 'Português',
        'pt_BR' => 'Português (Brasil)',
        'es' => 'Español',
        'de' => 'Deutsch',
        'fr' => 'Français',
        'it' => 'Italiano',
        _ => code,
      };

  /// Persist the new locale preference and fire [LocaleChangedEvent]
  /// so every open [WappPage] reloads its translations. The empty
  /// string value ("") resets to "Auto" (follows the OS).
  void _onLocaleChanged(String? value) {
    final p = _prefs;
    if (p == null) return;
    p.localePreference = (value == null || value.isEmpty) ? null : value;
    setState(() {});
    EventBus().fire(LocaleChangedEvent(locale: p.activeLocale()));
  }

  void _onBleDebugChanged(bool enabled) {
    final p = _prefs;
    if (p == null) return;
    p.bleDebug = enabled;
    if (mounted) setState(() {});
  }

  Future<void> _onRemoteApiChanged(bool enabled) async {
    final p = _prefs;
    if (p == null) return;
    p.remoteApiEnabled = enabled;
    if (enabled) {
      await RemoteApiService.instance
          .start(port: p.remoteApiPort, navigatorKey: rootNavigatorKey);
    } else {
      await RemoteApiService.instance.stop();
    }
    if (mounted) setState(() {});
  }

  Future<void> _editRnsServers() async {
    if (_prefs == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RnsServersPage()),
    );
    if (mounted) setState(() {}); // refresh the subtitle count on return
  }

  Future<void> _pickDirectory() async {
    final defaultPath =
        _prefs == null ? '' : wappsDataStorage(_prefs!).basePath;
    final controller = TextEditingController(text: _dataDir);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('settings.storage.dir')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('settings.storage.dir.help'),
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: tr('settings.storage.dir.path'),
                filled: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: tr('settings.storage.dir.reset'),
                  onPressed: () => controller.text = defaultPath,
                ),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('common.save')),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && _prefs != null) {
      // Create the directory through the abstraction so the same code path
      // will work later with encrypted/IndexedDB backends.
      await makeFilesystemStorage(result).createDirectory('');
      _prefs!.wappDataDir = result;
      if (mounted) setState(() => _dataDir = result);
      await _refreshWappData();
    }
  }

  Future<void> _openDataDir() async {
    final dataDir = _dataDir;
    if (dataDir == null) return;
    // Make sure it exists (via the abstraction), then hand the absolute
    // path to the platform's external file manager. Both calls flow
    // through `platform.*` so the web build has a clean no-op instead
    // of a dart:io Process spawn.
    await makeFilesystemStorage(dataDir).createDirectory('');
    await platform.openInFileManager(dataDir);
  }

  String _humanSize(int bytes) => trBytes(bytes);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final topic = widget.topic;
    return Scaffold(
      appBar: AppBar(
          title: Text(topic == null ? tr('common.settings') : _topicTitle(topic))),
      body: _prefs == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: topic == null ? _menu(cs) : _topicBody(topic, cs),
            ),
    );
  }

  static String _topicTitle(SettingsTopic t) => switch (t) {
        SettingsTopic.device => tr('settings.device.title'),
        SettingsTopic.language => tr('common.language'),
        SettingsTopic.privacy => tr('settings.topic.privacy'),
        SettingsTopic.network => tr('settings.topic.network'),
        SettingsTopic.updates => tr('launcher.drawer.updates'),
        SettingsTopic.storage => tr('settings.storage.title'),
        SettingsTopic.developer => tr('settings.topic.developer'),
      };

  /// One topic's page: the sections that belong to it, nothing else.
  List<Widget> _topicBody(SettingsTopic t, ColorScheme cs) => switch (t) {
        SettingsTopic.device => _secDevice(cs),
        SettingsTopic.language => _secLang(cs),
        SettingsTopic.privacy => [
            ..._secPrivacy(cs),
            // Coverage says where this station serves: beside location
            // sharing, where the location without GPS is set too.
            const CoverageCard(),
            const SizedBox(height: 24),
            ..._secMuted(cs),
          ],
        SettingsTopic.network => _secRns(cs),
        SettingsTopic.updates => _secFolders(cs),
        SettingsTopic.storage => [..._secDatadir(cs), ..._secWappdata(cs)],
        SettingsTopic.developer => _secRemote(cs),
      };

  /// Open a page, and restate the menu's lines when coming back from it.
  void _push(Widget page) => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => page))
          .then((_) {
        if (mounted) setState(() {});
      });

  Widget _entry(IconData icon, String title, String subtitle, Widget page) =>
      ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _push(page),
      );

  Widget _group(ColorScheme cs, List<Widget> rows) => Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 56),
            rows[i],
          ],
        ]),
      );

  /// Settings itself: one line per topic, the ones reached for most on top,
  /// each opening a page of its own.
  List<Widget> _menu(ColorScheme cs) {
    final call = ProfileService.instance.activeProfile?.callsign ?? '';
    final api = RemoteApiService.instance.running;
    return [
      _group(cs, [
        // Every permission is optional; this is where one refused at the
        // intro is granted later, and which features are off is said here.
        if (platform.platformName() == 'android')
          ValueListenableBuilder<Set<String>>(
            valueListenable: PermissionState.instance.missing.listenable,
            builder: (context, missing, _) => _entry(
              Icons.verified_user_outlined,
              tr('permissions.title'),
              missing.isEmpty
                  ? tr('permissions.all_granted')
                  : tr('permissions.settings.missing', {
                      'list': missing
                          .map((k) => tr('permissions.$k.title'))
                          .toSet()
                          .join(', '),
                    }),
              const PermissionsPage(),
            ),
          ),
        _entry(Icons.badge_outlined, tr('settings.device.title'),
            call.isEmpty ? tr('settings.topic.device.desc') : call,
            const IwiSettingsPage(topic: SettingsTopic.device)),
        _entry(Icons.language, tr('common.language'), _localeSubtitle(),
            const IwiSettingsPage(topic: SettingsTopic.language)),
        _entry(Icons.place_outlined, tr('settings.topic.privacy'),
            tr('settings.topic.privacy.desc'),
            const IwiSettingsPage(topic: SettingsTopic.privacy)),
      ]),
      const SizedBox(height: 16),
      _group(cs, [
        _entry(Icons.groups, tr('launcher.drawer.groups'),
            tr('settings.topic.groups.desc'), const GroupsPage()),
        _entry(Icons.memory, tr('hardware.title'),
            tr('settings.topic.hardware.desc'), const HardwarePage()),
        _entry(Icons.dns_outlined, tr('settings.topic.network'),
            tr('settings.topic.network.desc'),
            const IwiSettingsPage(topic: SettingsTopic.network)),
      ]),
      const SizedBox(height: 16),
      _group(cs, [
        _entry(Icons.system_update_alt, tr('launcher.drawer.updates'),
            tr('settings.topic.updates.desc'),
            const IwiSettingsPage(topic: SettingsTopic.updates)),
        _entry(Icons.folder_outlined, tr('settings.storage.title'),
            tr('settings.topic.storage.desc'),
            const IwiSettingsPage(topic: SettingsTopic.storage)),
        _entry(Icons.code, tr('settings.topic.developer'),
            api
                ? tr('settings.remote.listening',
                    {'port': _prefs?.remoteApiPort ?? 3456})
                : tr('settings.topic.developer.desc'),
            const IwiSettingsPage(topic: SettingsTopic.developer)),
      ]),
    ];
  }

  List<Widget> _secMuted(ColorScheme cs) => [
      // ── Muted accounts ──
      //
      // Where a mute is taken back. Muting itself happens where the
      // spam is — the ⋯ menu on the post — because that is where the
      // user is when they decide.
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        child: ListTile(
          leading: const Icon(Icons.volume_off),
          title: Text(tr('settings.muted.title')),
          subtitle: Text(
            () {
              final n = RnsService.instance.mutedCallsigns.length;
              return n == 0
                  ? tr('settings.muted.none')
                  : trn('settings.muted.count', n);
            }(),
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(
                  builder: (_) => const MutedPage()))
              .then((_) {
            if (mounted) setState(() {});
          }),
        ),
      ),
      const SizedBox(height: 24),
      ];

  List<Widget> _secLang(ColorScheme cs) => [
      // ── Language ──
      Text(
        tr('common.language.desc'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
      ),
      const SizedBox(height: 12),
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        child: ListTile(
          leading: const Icon(Icons.language),
          title: Text(tr('common.language')),
          subtitle: Text(
            _localeSubtitle(),
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          // The choices are the folders this build ships under
          // assets/lang/, so adding a language never touches this
          // screen. Each is named in itself, never translated.
          trailing: DropdownButton<String>(
            value: _localeValue(),
            underline: const SizedBox.shrink(),
            items: [
              DropdownMenuItem(
                  value: '', child: Text(tr('common.auto'))),
              for (final code in CoreI18n.instance.languages)
                DropdownMenuItem(
                    value: code, child: Text(_languageName(code))),
            ],
            onChanged: _onLocaleChanged,
          ),
        ),
      ),
      const SizedBox(height: 24),
      ];

  List<Widget> _secRemote(ColorScheme cs) => [
      // ── Remote control API ──
      Text(tr('settings.remote.title'),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              )),
      const SizedBox(height: 4),
      Text(
        tr('settings.remote.help',
            {'port': _prefs?.remoteApiPort ?? 3456}),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
      ),
      const SizedBox(height: 12),
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        child: SwitchListTile(
          secondary: const Icon(Icons.cable),
          title: Text(tr('settings.remote.api')),
          subtitle: Text(
            RemoteApiService.instance.running
                ? tr('settings.remote.listening',
                    {'port': _prefs?.remoteApiPort ?? 3456})
                : tr('common.off'),
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          value: _prefs?.remoteApiEnabled ?? false,
          onChanged: _onRemoteApiChanged,
        ),
      ),
      const SizedBox(height: 12),
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        child: SwitchListTile(
          secondary: const Icon(Icons.bug_report),
          title: Text(tr('settings.ble_debug.title')),
          subtitle: Text(
            tr('settings.ble_debug.help'),
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          value: _prefs?.bleDebug ?? false,
          onChanged: _onBleDebugChanged,
        ),
      ),
      const SizedBox(height: 24),
      ];

  List<Widget> _secDevice(ColorScheme cs) => [
      // ── This device ──
      const DeviceIdentityCard(),
      const SizedBox(height: 24),
      ];

  List<Widget> _secPrivacy(ColorScheme cs) => [
      // ── Privacy ──
      const PositionShareCard(),
      const SizedBox(height: 24),
      ];

  List<Widget> _secRns(ColorScheme cs) => [
      // ── Reticulum ──
      Text(tr('settings.reticulum.title'),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              )),
      const SizedBox(height: 4),
      Text(
        tr('settings.reticulum.help'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
      ),
      const SizedBox(height: 12),
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        child: ListTile(
          leading: const Icon(Icons.dns),
          title: Text(tr('settings.reticulum.servers')),
          subtitle: Text(
            () {
              final list = _prefs?.rnsBootstrapServers ?? const [];
              if (list.isEmpty) return tr('settings.reticulum.servers.none');
              final n = list.length;
              return trn('settings.reticulum.servers.count', n,
                  {'first': list.first, 'more': n > 1 ? ' …' : ''});
            }(),
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          trailing: const Icon(Icons.edit),
          onTap: _editRnsServers,
        ),
      ),
      const SizedBox(height: 24),
      ];

  List<Widget> _secFolders(ColorScheme cs) => [
      // ── Sharing folders (Reticulum) ──
      Text(tr('settings.folders.title'),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              )),
      const SizedBox(height: 4),
      Text(
        tr('settings.folders.help'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
      ),
      const SizedBox(height: 12),
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: Text(tr('settings.folders.stable')),
              subtitle: Text(
                _folderSubtitle(_upd.stableFolder),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              trailing: const Icon(Icons.edit),
              onTap: () => _editUpdateFolder(beta: false),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.science_outlined),
              title: Text(tr('settings.folders.beta')),
              subtitle: Text(
                _folderSubtitle(_upd.betaFolder),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              trailing: const Icon(Icons.edit),
              onTap: () => _editUpdateFolder(beta: true),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      ];

  List<Widget> _secDatadir(ColorScheme cs) => [
      // ── Data Directory ──
      Text(tr('settings.storage.title'),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              )),
      const SizedBox(height: 4),
      Text(
        tr('settings.storage.help'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
      ),
      const SizedBox(height: 12),
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        child: ListTile(
          leading: const Icon(Icons.folder),
          title: Text(tr('settings.storage.dir')),
          subtitle: Text(
            _dataDir ?? tr('settings.storage.dir.unset'),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: cs.onSurfaceVariant,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.open_in_new),
                tooltip: tr('settings.storage.dir.open'),
                onPressed: _openDataDir,
              ),
              const Icon(Icons.edit),
            ],
          ),
          onTap: _pickDirectory,
        ),
      ),
      const SizedBox(height: 24),
      ];

  List<Widget> _secWappdata(ColorScheme cs) => [
      // ── Per-wapp data ──
      Text(tr('settings.wappdata.title'),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              )),
      const SizedBox(height: 4),
      Text(
        tr('settings.wappdata.help'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
      ),
      const SizedBox(height: 12),
      ..._buildWappDataList(cs),
      ];

  List<Widget> _buildWappDataList(ColorScheme cs) {
    final entries = _wappDataEntries;
    if (entries.isEmpty) {
      return [
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
          ),
          color: cs.surfaceContainerLow,
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(tr('settings.wappdata.none')),
            subtitle: Text(tr('settings.wappdata.none.help')),
          ),
        ),
      ];
    }

    return [
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              ListTile(
                leading: const Icon(Icons.extension),
                title: Text(entries[i].name),
                subtitle: Text(
                  _humanSize(entries[i].size),
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
                trailing: IconButton(
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  tooltip: tr('settings.wappdata.delete'),
                  onPressed: () => _confirmDelete(entries[i]),
                ),
              ),
              if (i < entries.length - 1)
                Divider(
                    height: 1,
                    thickness: 1,
                    color: cs.outlineVariant.withAlpha(50)),
            ],
          ],
        ),
      ),
    ];
  }

  Future<void> _confirmDelete(_WappDataEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('settings.wappdata.delete.title', {'name': entry.name})),
        content: Text(tr('settings.wappdata.delete.body',
            {'name': entry.name, 'size': _humanSize(entry.size)})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        // Split the absolute path into parent + leaf and delete via the
        // abstraction so the same code path works with non-filesystem
        // backends in the future.
        final sep = platform.pathSeparator;
        final slashIdx = entry.path.lastIndexOf(sep);
        if (slashIdx > 0) {
          final parent = entry.path.substring(0, slashIdx);
          final leaf = entry.path.substring(slashIdx + 1);
          await makeFilesystemStorage(parent)
              .deleteDirectory(leaf, recursive: true);
        }
        await _refreshWappData();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('settings.wappdata.delete.failed', {'error': e}))),
          );
        }
      }
    }
  }
}

class _WappDataEntry {
  final String name;
  final String path;
  final int size;
  _WappDataEntry(this.name, this.path, this.size);
}

// ── Reticulum bootstrap servers ──────────────────────────────────────────
//
// A full-screen editor for the ordered list of bootstrap hubs. The node tries
// each in order until one answers with real Reticulum traffic, so order is the
// priority. Add / edit (separate host + port fields) / remove / reorder, all
// persisted immediately.

class RnsServersPage extends StatefulWidget {
  const RnsServersPage({super.key});

  @override
  State<RnsServersPage> createState() => _RnsServersPageState();
}

class _RnsServersPageState extends State<RnsServersPage> {
  PreferencesService? _prefs;
  List<String> _servers = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await PreferencesService.instance();
    if (!mounted) return;
    setState(() {
      _prefs = p;
      _servers = List<String>.from(p.rnsBootstrapServers);
    });
  }

  void _save() {
    _prefs?.rnsBootstrapServers = _servers;
  }

  /// Split "host:port" into (host, port-string). Port defaults to "4242".
  (String, String) _split(String entry) {
    final s = entry.trim();
    final i = s.lastIndexOf(':');
    if (i <= 0 || i == s.length - 1) return (s, '4242');
    return (s.substring(0, i), s.substring(i + 1));
  }

  Future<void> _addOrEdit({int? index}) async {
    final initial = index == null ? ('', '4242') : _split(_servers[index]);
    final hostCtl = TextEditingController(text: initial.$1);
    final portCtl = TextEditingController(text: initial.$2);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(tr(index == null ? 'settings.servers.add' : 'settings.servers.edit')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: hostCtl,
                autofocus: true,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: tr('settings.servers.host'),
                  hintText: 'rns.example.net',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: portCtl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr('settings.servers.port'),
                  hintText: '4242',
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
              onPressed: () {
                final host = hostCtl.text.trim();
                if (host.isEmpty) {
                  Navigator.pop(ctx);
                  return;
                }
                final port = int.tryParse(portCtl.text.trim()) ?? 4242;
                Navigator.pop(ctx, '$host:$port');
              },
              child: Text(tr('common.save')),
            ),
          ],
        );
      },
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _servers.add(result);
      } else {
        _servers[index] = result;
      }
    });
    _save();
  }

  void _remove(int index) {
    setState(() => _servers.removeAt(index));
    _save();
  }

  void _resetDefaults() {
    setState(() {
      _prefs?.rnsBootstrapServers = <String>[]; // clears → getter returns defaults
      _servers = List<String>.from(_prefs?.rnsBootstrapServers ?? const []);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('settings.servers.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: tr('settings.servers.reset'),
            onPressed: _resetDefaults,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add),
        label: Text(tr('settings.servers.add')),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              tr('settings.servers.help'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: _servers.isEmpty
                ? Center(
                    child: Text(tr('settings.servers.empty'),
                        style: TextStyle(color: cs.onSurfaceVariant)),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
                    itemCount: _servers.length,
                    onReorder: (oldI, newI) {
                      setState(() {
                        if (newI > oldI) newI -= 1;
                        final item = _servers.removeAt(oldI);
                        _servers.insert(newI, item);
                      });
                      _save();
                    },
                    itemBuilder: (context, i) {
                      final entry = _servers[i];
                      final hp = _split(entry);
                      return Card(
                        key: ValueKey('rns-srv-$i-$entry'),
                        elevation: 0,
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side:
                              BorderSide(color: cs.outlineVariant.withAlpha(80)),
                        ),
                        color: cs.surfaceContainerLow,
                        child: ListTile(
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: cs.primaryContainer,
                            child: Text('${i + 1}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onPrimaryContainer)),
                          ),
                          title: Text(hp.$1,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(tr('settings.servers.port_n', {'port': hp.$2}),
                              style: TextStyle(color: cs.onSurfaceVariant)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit),
                                tooltip: tr('common.edit'),
                                onPressed: () => _addOrEdit(index: i),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: tr('common.remove'),
                                onPressed: () => _remove(i),
                              ),
                              ReorderableDragStartListener(
                                index: i,
                                child: const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: Icon(Icons.drag_handle),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

