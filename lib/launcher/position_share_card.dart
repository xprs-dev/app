// Settings > Privacy: whether this station's position goes out with its
// beacon, and how coarsely. The core decides what is aired
// (xprs_shared_position.dart); this card only records the owner's choice.

import 'package:flutter/material.dart';
import 'package:xprs_core/src/services/xprs/xprs_shared_position.dart';

import '../services/i18n/core_i18n.dart';
import '../services/preferences_service.dart';

/// The radii offered, in metres. 10 m is a normal fix; the larger ones say
/// "this building", "this park", "this part of town", "this town".
const List<int> kPositionRadiiM = [10, 50, 100, 500, 1000, 5000, 10000];

String positionRadiusLabel(int m) => m >= 1000 ? '${m ~/ 1000} km' : '$m m';

class PositionShareCard extends StatefulWidget {
  const PositionShareCard({super.key});

  @override
  State<PositionShareCard> createState() => _PositionShareCardState();
}

class _PositionShareCardState extends State<PositionShareCard> {
  PreferencesService? get _prefs => PreferencesService.instanceSync;
  late final TextEditingController _fixed =
      TextEditingController(text: _prefs?.positionFixed ?? '');
  String? _fixedError;

  @override
  void dispose() {
    _fixed.dispose();
    super.dispose();
  }

  void _saveFixed() {
    final v = _fixed.text.trim();
    if (v.isNotEmpty && xprsParseLatLon(v) == null) {
      setState(() => _fixedError = tr('settings.position.fixed_bad'));
      return;
    }
    _prefs?.positionFixed = v;
    setState(() => _fixedError = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('settings.position.fixed_saved')),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = _prefs?.positionShare ?? false;
    final radius = _prefs?.positionRadiusM ?? 10;
    var idx = kPositionRadiiM.indexOf(radius);
    if (idx < 0) idx = 0;
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
            subtitle: Text(tr('settings.position.share_help'),
                style: TextStyle(color: cs.onSurfaceVariant)),
            value: on,
            onChanged: (v) {
              _prefs?.positionShare = v;
              if (v) XprsSharedPosition.instance.refresh();
              setState(() {});
            },
          ),
          if (on) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                tr('settings.position.radius',
                    {'radius': positionRadiusLabel(kPositionRadiiM[idx])}),
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
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(tr('settings.position.radius_help'),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _fixed,
                      keyboardType: const TextInputType.numberWithOptions(
                          signed: true, decimal: true),
                      decoration: InputDecoration(
                        labelText: tr('settings.position.fixed'),
                        hintText: '38.7077,-9.1365',
                        helperText: tr('settings.position.fixed_help'),
                        helperMaxLines: 3,
                        errorText: _fixedError,
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _saveFixed(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: tr('common.save'),
                    icon: const Icon(Icons.check),
                    onPressed: _saveFixed,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text(
                shared == null
                    ? tr('settings.position.none')
                    : tr('settings.position.aired', {
                        'pos': shared.pos,
                        'radius': positionRadiusLabel(shared.acc),
                      }),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.primary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
