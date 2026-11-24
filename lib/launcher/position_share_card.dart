// Settings > Location: whether this station's position goes out with its
// beacon, how coarsely for everyone, and the code that lets friends read the
// rest (XPRS.md 6.2.1). The core decides what is aired and does the hiding
// (xprs_shared_position.dart); this card only records the owner's choices.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:xprs_core/src/platform/os.dart' as platform;
import 'package:xprs_core/src/services/xprs/xprs_passphrases.dart';
import 'package:xprs_core/src/services/xprs/xprs_shared_position.dart';

import '../services/i18n/core_i18n.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';
import '../services/preferences_service.dart';

/// The ranges offered, coarsest first (the core's list): each is one more
/// decimal everyone may read. 100 km, the default, says "this region".
const List<int> kPositionRadiiM = kXprsPosRangesM;

String positionRadiusLabel(int m) => m >= 1000 ? '${m ~/ 1000} km' : '$m m';

/// A phone shares its place by default, to 100 km: once, the first time the
/// app runs with this version, and it says so with a notice that opens the
/// switch. A desktop is not a moving thing with a GPS and stays off until its
/// owner says; whoever already chose keeps their choice.
void sharePositionByDefault() {
  final prefs = PreferencesService.instanceSync;
  if (prefs == null || prefs.positionShareChosen) return;
  if (!platform.isAndroid && !platform.isIOS) return;
  prefs.positionShare = true;
  NotificationService.instance.show(XprsNotification(
    level: NotificationLevel.info,
    title: tr('notifications.position.default'),
    body: tr('notifications.position.default.body'),
    source: PositionSharePage.target,
    scope: NotificationScope.both,
  ));
}

class PositionShareCard extends StatefulWidget {
  const PositionShareCard({super.key});

  @override
  State<PositionShareCard> createState() => _PositionShareCardState();
}

class _PositionShareCardState extends State<PositionShareCard> {
  PreferencesService? get _prefs => PreferencesService.instanceSync;
  late final TextEditingController _fixed = TextEditingController(
    text: _prefs?.positionFixed ?? '',
  );
  late final TextEditingController _code = TextEditingController(
    text: _prefs?.positionCode ?? '',
  );
  final TextEditingController _friend = TextEditingController();
  final TextEditingController _friendCode = TextEditingController();
  String? _fixedError;
  Timer? _fixedDue;
  Timer? _codeDue;

  @override
  void initState() {
    super.initState();
    // The owner opened the switch: the one place the system may be asked
    // for the location permission, and a first fix taken while they look.
    if (_prefs?.positionShare ?? false) _askFix();
  }

  /// A fix, asking for the permission if it was never given. Only ever from
  /// this card, on the owner's own tap or visit.
  Future<void> _askFix() async {
    await LocationService.instance.currentPosition();
    await XprsSharedPosition.instance.refresh();
    if (mounted) setState(() {});
  }

  /// The code as it is typed, once the typing pauses; emptied, a new one.
  void _codeChanged(String _) {
    _codeDue?.cancel();
    _codeDue = Timer(const Duration(milliseconds: 800), _saveCode);
  }

  void _saveCode() {
    _codeDue?.cancel();
    final v = _code.text.trim();
    if (v.isEmpty || v == (_prefs?.positionCode ?? '')) return;
    _prefs?.positionCode = v;
    _rehide();
  }

  void _newCode() {
    final c = xprsNewPosCode();
    _prefs?.positionCode = c;
    _code.text = c;
    _rehide();
  }

  /// What is aired follows the choice just made: the hidden form is worked
  /// out again (off this thread, in the core) and the line below redrawn.
  Future<void> _rehide() async {
    await XprsSharedPosition.instance.refresh();
    if (mounted) setState(() {});
  }

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: _code.text.trim()));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(tr('settings.position.code_copied'))),
    );
  }

  /// A friend's code, kept against their callsign in the profile's encrypted
  /// store: what they air is opened with it from then on.
  void _addFriend() {
    final call = _friend.text.trim().toUpperCase();
    final code = _friendCode.text.trim();
    if (call.isEmpty || code.isEmpty) return;
    XprsPassphrases.instance.hint(call, code);
    _friend.clear();
    _friendCode.clear();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(tr('settings.position.friend_saved', {'call': call}))),
    );
  }

  @override
  void dispose() {
    // Left before the typing paused: the value still counts.
    if (_fixedDue?.isActive ?? false) _saveFixed();
    if (_codeDue?.isActive ?? false) _saveCode();
    _fixedDue?.cancel();
    _codeDue?.cancel();
    _fixed.dispose();
    _code.dispose();
    _friend.dispose();
    _friendCode.dispose();
    super.dispose();
  }

  /// Saved as it is typed, once the typing pauses: a valid position (or an
  /// empty field) is stored at once, and only a malformed one is pointed out.
  void _fixedChanged(String _) {
    _fixedDue?.cancel();
    _fixedDue = Timer(const Duration(milliseconds: 800), _saveFixed);
  }

  void _saveFixed() {
    _fixedDue?.cancel();
    final v = _fixed.text.trim();
    final bad = v.isNotEmpty && xprsParseLatLon(v) == null;
    if (!bad && v != (_prefs?.positionFixed ?? '')) {
      _prefs?.positionFixed = v;
      if (_prefs?.positionShare ?? false) _rehide();
    }
    if (!mounted) return;
    setState(
      () => _fixedError = bad ? tr('settings.position.fixed_bad') : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = _prefs?.positionShare ?? false;
    // A range kept from an older version sits on the step that covers it.
    final radius = _prefs?.positionRadiusM ?? kPositionRadiiM.first;
    final idx = kPositionRadiiM.indexOf(
        kPositionRadiiM[xprsPosDecimals(radius)]);
    final hides = idx < kPositionRadiiM.length - 1;
    final shared = XprsSharedPosition.instance.current();
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
      ),
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.place_outlined),
            title: Text(tr('settings.position.share')),
            subtitle: Text(
              tr('settings.position.share_help'),
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            value: on,
            onChanged: (v) {
              _prefs?.positionShare = v;
              if (v) _askFix();
              setState(() {});
            },
          ),
          if (on) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                tr('settings.position.radius', {
                  'radius': positionRadiusLabel(kPositionRadiiM[idx]),
                }),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Slider(
              value: idx.toDouble(),
              min: 0,
              max: (kPositionRadiiM.length - 1).toDouble(),
              divisions: kPositionRadiiM.length - 1,
              label: positionRadiusLabel(kPositionRadiiM[idx]),
              onChanged: (v) {
                _prefs?.positionRadiusM = kPositionRadiiM[v.round()];
                setState(() {});
              },
              onChangeEnd: (_) => _rehide(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                tr('settings.position.radius_help'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: TextField(
                controller: _fixed,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: tr('settings.position.fixed'),
                  hintText: '38.7077,-9.1365',
                  helperText: tr('settings.position.fixed_help'),
                  helperMaxLines: 3,
                  errorText: _fixedError,
                  border: const OutlineInputBorder(),
                ),
                onChanged: _fixedChanged,
                onSubmitted: (_) => _saveFixed(),
              ),
            ),
            if (hides) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: TextField(
                  controller: _code,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: tr('settings.position.code'),
                    helperText: tr('settings.position.code_help'),
                    helperMaxLines: 3,
                    border: const OutlineInputBorder(),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: tr('settings.position.code_copy'),
                          onPressed: _copyCode,
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: tr('settings.position.code_new'),
                          onPressed: _newCode,
                        ),
                      ],
                    ),
                  ),
                  onChanged: _codeChanged,
                  onSubmitted: (_) => _saveCode(),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text(
                shared == null
                    ? tr('settings.position.none')
                    : shared.xr == null
                        ? tr('settings.position.aired', {
                            'pos': shared.pos,
                            'radius': positionRadiusLabel(shared.acc),
                          })
                        : tr('settings.position.aired_hidden', {
                            'pos': shared.pos,
                            'radius': positionRadiusLabel(shared.acc),
                          }),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.primary),
              ),
            ),
          ],
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              tr('settings.position.friend'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _friend,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: tr('settings.position.friend_call'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _friendCode,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: tr('settings.position.friend_code'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _addFriend(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: tr('settings.position.friend_add'),
                  onPressed: _addFriend,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The card on a page of its own: what a wapp's "Share my location" button
/// opens (`"open": "host:position"`), so the person lands on the switch itself
/// rather than being told where in Settings to find it.
class PositionSharePage extends StatelessWidget {
  const PositionSharePage({super.key});

  /// The name a wapp links to.
  static const String target = 'host:position';

  @override
  Widget build(BuildContext context) =>
      NotificationTargetView(source: target, child: _page(context));

  Widget _page(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('settings.privacy.title'))),
    body: const SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: PositionShareCard(),
    ),
  );
}
