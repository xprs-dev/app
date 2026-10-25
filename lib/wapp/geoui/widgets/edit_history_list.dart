import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../services/i18n/core_i18n.dart';

/// The versions of one message or post, oldest first, back to the original
/// (XPRS.md 7.8.1). Rebuilds when [versions] changes, so a withdrawal that
/// arrives while it is open (7.8.2) replaces the words on screen at once
/// instead of leaving them there until the dialog is closed.
///
/// Each version is `{text, date, time, by, role}`; one with a `note` is a line
/// of its own (for example "This message was deleted.").
class EditHistoryList extends StatelessWidget {
  final ValueListenable<List<Map<String, dynamic>>> versions;

  const EditHistoryList({super.key, required this.versions});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.maxFinite,
      child: ValueListenableBuilder<List<Map<String, dynamic>>>(
        valueListenable: versions,
        builder: (context, list, _) => ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < list.length; i++)
              if ((list[i]['note'] ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('${list[i]['note']}',
                      style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: cs.onSurfaceVariant)),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i == 0 && list[i]['role'] == 'author' ? tr('geoui.history.original') : (i == list.length - 1 ? tr('geoui.history.current') : tr('geoui.history.edit'))}'
                        ' \u00b7 ${list[i]['date'] ?? ''} ${list[i]['time'] ?? ''}'
                        ' \u00b7 ${list[i]['by'] ?? ''}'
                        '${list[i]['role'] == 'author' || list[i]['role'] == null ? '' : ' (${list[i]['role']})'}',
                        style:
                            TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 2),
                      Text('${list[i]['text'] ?? ''}'),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
