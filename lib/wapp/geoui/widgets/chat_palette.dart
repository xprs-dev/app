// ChatPalette: the shared colour palette and type scale for the GeoUI
// messaging widgets (ChatViewField bubbles/background, ConversationsField and
// RoomsField lists, and the wapp page chrome). The layout and surfaces follow
// WhatsApp's dark theme, the messenger most people already know, so a chat
// here reads as familiar on first sight; the accent and the outgoing bubble
// are Telegram's blue rather than WhatsApp's green. This is generic styling: no app (APRS, Circles and
// so on) knowledge lives here, and every chat-based wapp shares it.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

abstract final class ChatPalette {
  /// Window chrome: app bar, tab bar, conversation list, room header. Pure
  /// black, the same as the chat, as in WhatsApp's current dark theme.
  static const Color windowBg = Color(0xFF000000);

  /// Chat history background, behind the message bubbles. Pure black.
  static const Color chatBg = Color(0xFF000000);

  /// Incoming (received) message bubble.
  static const Color inBubble = Color(0xFF202C33);

  /// Outgoing (sent) message bubble. Telegram's night-theme blue.
  static const Color outBubble = Color(0xFF2B5278);

  /// A raised surface: the composer's input pill, search boxes, the day
  /// separator and the selected row of a conversation list.
  static const Color raised = Color(0xFF1F2C34);

  /// Hairlines between list rows and panes.
  static const Color divider = Color(0xFF222D34);

  /// Primary text on bubbles and rows.
  static const Color text = Color(0xFFE9EDEF);

  /// Secondary text: timestamps, subtitles, unselected tabs.
  static const Color secondary = Color(0xFF8696A0);

  /// Accent: sender actions, tab indicator, unread badges, the send button.
  /// Telegram's blue.
  static const Color accent = Color(0xFF2AABEE);

  /// Text drawn ON the accent (an unread count, the send icon).
  static const Color onAccent = Color(0xFFFFFFFF);

  /// Links and the read double-tick.
  static const Color link = Color(0xFF53BDEB);

  /// Group sender names: each person keeps one colour, picked from a set that
  /// stays readable on the incoming bubble (WhatsApp does the same, which is
  /// how a busy group stays legible without reading every name).
  static const List<Color> _senderColors = [
    Color(0xFF53BDEB), Color(0xFFFC9775), Color(0xFFA5B337),
    Color(0xFFDFA62A), Color(0xFF25D366), Color(0xFFFF72A1),
    Color(0xFF7F66FF), Color(0xFF02A698), Color(0xFFE26AB6),
    Color(0xFF8B9CFF), Color(0xFFFFBC38), Color(0xFF42C7B8),
  ];

  /// The stable colour for [who]'s name in a group.
  static Color senderColor(String who) {
    var h = 0;
    for (final c in who.toUpperCase().codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _senderColors[h % _senderColors.length];
  }

  // Type scale. WhatsApp sets message text at 16sp on a phone and about 14px
  // on its desktop and web clients; the rest of the scale follows from it.
  static bool get _touch =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Message body, and what is typed in the composer.
  static double get bodySize => _touch ? 16 : 14.5;

  /// A sender's name above their message in a group.
  static double get senderSize => _touch ? 14 : 13;

  /// Time and ticks inside a bubble, and the small actions beside them.
  static const double metaSize = 11;

  /// A conversation list row: the name, and the last line said there.
  static double get rowTitleSize => _touch ? 17 : 16;
  static double get rowSubtitleSize => _touch ? 14.5 : 14;

  /// The age at the right of a list row, and the unread count under it.
  static const double rowMetaSize = 12;

  /// Bubble corners. The corner nearest the sender is squared off on the first
  /// bubble of a run, where the tail sits.
  static const double bubbleRadius = 8;
}
