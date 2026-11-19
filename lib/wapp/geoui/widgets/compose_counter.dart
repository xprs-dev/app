// The countdown under a composer that has a size limit, as on Twitter: how
// much room is left, amber near the end, red and negative past it.
//
// The room is counted in UTF-8 BYTES, because that is what a packet holds: a
// plain letter takes one, an accented letter two, most emoji four. The limit
// comes from the wapp's screen (`"max"` on its field); the host only counts.
import 'dart:convert';

import 'package:flutter/material.dart';

import 'chat_palette.dart';

/// The room left in a composer limited to [max] bytes, holding [text] and the
/// [extra] text that will be sent with it (attachment tokens).
int composeRoomLeft(int max, String text, [String extra = '']) {
  var all = text.trim();
  final e = extra.trim();
  if (e.isNotEmpty) all = all.isEmpty ? e : '$all $e';
  return max - utf8.encode(all).length;
}

/// The number itself. Grey while there is room, amber in the last [warnAt],
/// red once past the limit (the caller disables sending then).
class ComposeCounter extends StatelessWidget {
  final int left;
  final int warnAt;
  const ComposeCounter(this.left, {super.key, this.warnAt = 20});

  @override
  Widget build(BuildContext context) {
    final color = left < 0
        ? const Color(0xFFF15C6D)
        : left <= warnAt
            ? Colors.amber
            : ChatPalette.secondary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        '$left',
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: left <= warnAt ? FontWeight.w600 : FontWeight.normal,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
