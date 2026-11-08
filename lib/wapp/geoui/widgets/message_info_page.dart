import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/i18n/core_i18n.dart';
import '../../../services/i18n/format.dart';
import 'edit_history_list.dart';

/// The details a wapp sends for ONE message's Info page (`ui.convo.info`).
///
/// The page opens at once from what the bubble already carries and fills in
/// when the wapp answers: the words as they were first written and every
/// version since, and what the core's archive holds of the packet itself (the
/// wire as it travelled, the bearer, the signal, the relays in `via:`). The
/// host sets [value]; the page shows it only when it names the page's message.
class MessageInfoBus {
  MessageInfoBus._();
  static final ValueNotifier<Map<String, dynamic>?> value =
      ValueNotifier<Map<String, dynamic>?>(null);

  static void publish(Map<String, dynamic> data) => value.value = data;
}

/// A message's Info, as a page of its own rather than a dialog: what was
/// said, by whom, to whom, how private it is, who carried it and how it
/// arrived. Every fact comes from the bubble or from the wapp's answer; the
/// page judges nothing itself.
class MessageInfoPage extends StatelessWidget {
  /// The bubble's own map, as the chat view holds it.
  final Map<String, dynamic> message;

  /// Called with the message to send it now unsealed, when it is still
  /// waiting for the recipient's key. Null hides the action.
  final void Function(Map<String, dynamic> m)? onSendPlain;

  /// The wapp's own list of versions, for a wapp that sends no details: the
  /// page then offers it as a button on an edited message.
  final void Function(Map<String, dynamic> m)? onHistory;

  /// A wapp was asked for this message's details, so the page says it is
  /// waiting for them until they arrive.
  final bool asked;

  const MessageInfoPage(
      {super.key,
      required this.message,
      this.onSendPlain,
      this.onHistory,
      this.asked = false});

  /// Push the page for [m].
  static Future<void> open(BuildContext context, Map<String, dynamic> m,
          {void Function(Map<String, dynamic> m)? onSendPlain,
          void Function(Map<String, dynamic> m)? onHistory,
          bool asked = false}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => MessageInfoPage(
            message: m,
            onSendPlain: onSendPlain,
            onHistory: onHistory,
            asked: asked),
      ));

  @override
  Widget build(BuildContext context) {
    final mid = (message['mid'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(title: Text(tr('geoui.info.title'))),
      body: ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: MessageInfoBus.value,
        builder: (context, d, _) {
          final details =
              (d != null && (d['mid'] ?? '').toString() == mid) ? d : null;
          return _InfoBody(
            message: message,
            details: details,
            onSendPlain: onSendPlain,
            onHistory: onHistory,
            asked: asked,
          );
        },
      ),
    );
  }
}

class _InfoBody extends StatelessWidget {
  final Map<String, dynamic> message;
  final Map<String, dynamic>? details;
  final void Function(Map<String, dynamic> m)? onSendPlain;
  final void Function(Map<String, dynamic> m)? onHistory;
  final bool asked;

  const _InfoBody(
      {required this.message,
      this.details,
      this.onSendPlain,
      this.onHistory,
      this.asked = false});

  Map<String, dynamic> _map(Object? o) => o is Map
      ? o.map((k, v) => MapEntry(k.toString(), v))
      : const <String, dynamic>{};

  @override
  Widget build(BuildContext context) {
    final m = message;
    final stored = _map(details?['stored']);
    final row = _map(stored['row']);
    final versions = [
      for (final v in (stored['versions'] as List? ?? const []))
        if (v is Map) v.map((k, x) => MapEntry(k.toString(), x)),
    ];
    final packet = _map(details?['packet']);
    String pick(String k) {
      final a = (row[k] ?? '').toString();
      return a.isNotEmpty ? a : (m[k] ?? '').toString();
    }

    final outgoing = (row['dir'] ?? m['dir'] ?? '').toString() == 'out';
    final from = (row['sender'] ?? m['from'] ?? '').toString();
    final convo = (details?['id'] ?? '').toString();
    final status = pick('status');
    final enc = m['enc'] == true || row['enc'] == 1;
    final auth = (packet['sig'] ?? pick('auth')).toString();
    final tsSent = _num(row['ts']) ?? _num(m['ts']);
    final tsHeard = _num(packet['heardTs']);
    final relays = (details?['relays'] ?? m['path'] ?? '')
        .toString()
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final bearer = (packet['bearer'] ?? m['via'] ?? '').toString();
    final net = (details?['net'] ?? m['net'] ?? '').toString();
    final original = versions.isNotEmpty
        ? (versions.first['text'] ?? '').toString()
        : (row['body'] ?? m['text'] ?? '').toString();
    final shown = (m['text'] ?? '').toString();
    final wire = (packet['wire'] ?? '').toString();

    final cs = Theme.of(context).colorScheme;
    final priv = _privacy(m, enc, status);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // ── what kind of message this is ───────────────────────────────
        Card(
          color: priv.color.withAlpha(36),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(priv.icon, color: priv.color, size: 32),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(priv.title,
                          style: TextStyle(
                              color: priv.color,
                              fontSize: 17,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(priv.detail,
                          style: TextStyle(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // A still hint, not a spinner: a wapp that never answers must not
        // leave something animating for as long as the page is open.
        if (details == null && asked)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(children: [
              Icon(Icons.hourglass_empty, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 10),
              Text(tr('geoui.info.loading'),
                  style: TextStyle(color: cs.onSurfaceVariant)),
            ]),
          ),

        // ── the words ──────────────────────────────────────────────────
        _Section(title: tr('geoui.info.section.message'), children: [
          _Label(versions.length > 1
              ? tr('geoui.info.original')
              : tr('geoui.info.text')),
          _Quote(original),
          if (versions.length > 1) ...[
            const SizedBox(height: 12),
            _Label(tr('geoui.info.current')),
            _Quote(shown),
            const SizedBox(height: 12),
            _Label(trn('geoui.info.versions', versions.length)),
            EditHistoryList(
                scrollable: false,
                versions: ValueNotifier<List<Map<String, dynamic>>>(versions)),
          ] else if (m['edited'] == true) ...[
            const SizedBox(height: 6),
            Text(tr('geoui.info.edited'),
                style: TextStyle(color: cs.onSurfaceVariant)),
            if (details == null && onHistory != null)
              TextButton(
                onPressed: () => onHistory!(m),
                child: Text(tr('geoui.chat.info.history')),
              ),
          ],
        ]),

        // ── who and when ───────────────────────────────────────────────
        _Section(title: tr('geoui.info.section.people'), children: [
          _Row(tr('geoui.chat.info.from'),
              outgoing ? tr('geoui.info.you') : (from.isEmpty ? '—' : from),
              copy: outgoing ? null : from),
          if (convo.isNotEmpty)
            _Row(tr('geoui.info.to'),
                outgoing || convo.startsWith('#') ? convo : tr('geoui.info.you'),
                copy: convo),
          if (net.isNotEmpty) _Row(tr('geoui.chat.info.network'), net),
          if (tsSent != null)
            _Row(tr('geoui.info.written'), _when(tsSent))
          else if ((m['time'] ?? '').toString().isNotEmpty)
            _Row(tr('geoui.info.written'), '${m['date'] ?? ''} ${m['time']}'),
          if (tsHeard != null && !outgoing)
            _Row(
                tr('geoui.info.received'),
                tsSent != null && tsHeard - tsSent >= 60
                    ? '${_when(tsHeard)}  (${tr('geoui.info.later', {'d': _span(tsHeard - tsSent)})})'
                    : _when(tsHeard)),
        ]),

        // ── the journey ────────────────────────────────────────────────
        _Section(title: tr('geoui.info.section.route'), children: [
          _Route(
            nodes: outgoing
                ? [tr('geoui.info.this_station'), ...relays, convo]
                : [from.isEmpty ? '?' : from, ...relays, tr('geoui.info.this_station')],
            bearer: bearer,
          ),
          const SizedBox(height: 8),
          if (bearer.isNotEmpty)
            _Row(outgoing ? tr('geoui.info.sent_on') : tr('geoui.info.arrived_on'),
                _bearerName(bearer)),
          if (!outgoing && _num(packet['rssi']) != null && _num(packet['rssi']) != 0)
            _Row(tr('geoui.info.signal'), '${packet['rssi']} dBm'),
          _Row(
              tr('geoui.chat.info.relayed'),
              relays.isEmpty
                  ? tr('geoui.info.direct')
                  : relays.join(' → ')),
          if ((_num(packet['heard']) ?? 0) > 1)
            _Row(tr('geoui.info.copies'), '${packet['heard']}'),
          if ((details?['parts'] ?? '').toString().isNotEmpty)
            _Row(tr('geoui.info.parts'),
                (details!['parts'] as Object).toString().split('/').last),
          if ((details?['scope'] ?? '').toString().isNotEmpty)
            _Row(tr('geoui.info.reach'), details!['scope'].toString()),
          if (_num(details?['bytes']) != null)
            _Row(tr('geoui.info.size'), trBytes(_num(details!['bytes'])!)),
          if (details != null && packet.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tr('geoui.info.not_archived'),
                  style: TextStyle(color: cs.onSurfaceVariant)),
            ),
        ]),

        // ── privacy and authorship ─────────────────────────────────────
        _Section(title: tr('geoui.info.section.security'), children: [
          _Row(tr('geoui.chat.info.signature'), _sig(auth)),
          _Row(
              tr('geoui.info.sealed'),
              enc || details?['sealedWire'] == true
                  ? tr('geoui.info.sealed.yes')
                  : (status == 'key'
                      ? tr('geoui.info.sealed.waiting')
                      : tr('geoui.info.sealed.no'))),
          if (details?['sealedRoom'] != null)
            _Row(
                tr('geoui.info.room_default'),
                details!['sealedRoom'] == true
                    ? tr('geoui.info.room_default.sealed')
                    : tr('geoui.info.room_default.plain')),
        ]),

        // ── what became of ours ────────────────────────────────────────
        if (outgoing && status.isNotEmpty)
          _Section(title: tr('geoui.info.section.delivery'), children: [
            Row(children: [
              Icon(_statusIcon(status), size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(_statusText(status))),
            ]),
            if (status == 'key' && onSendPlain != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.lock_open, size: 18),
                  label: Text(tr('geoui.chat.menu.send_plain')),
                  onPressed: () {
                    onSendPlain!(m);
                    Navigator.of(context).maybePop();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(tr('geoui.info.send_plain.detail'),
                    style:
                        TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
              ),
            ],
          ]),

        // ── names and the raw packet ───────────────────────────────────
        _Section(title: tr('geoui.info.section.ids'), children: [
          if ((m['mid'] ?? '').toString().isNotEmpty)
            _Row(tr('geoui.info.id'), (m['mid']).toString(),
                copy: (m['mid']).toString(), mono: true),
          if (wire.isNotEmpty) ...[
            const SizedBox(height: 8),
            _Label(tr('geoui.info.wire')),
            _Wire(wire),
          ],
        ]),
      ],
    );
  }

  static int? _num(Object? o) => o is num ? o.toInt() : int.tryParse('$o');

  static String _when(int epochSec) {
    final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static String _span(int s) {
    if (s < 3600) return '${(s / 60).round()} min';
    if (s < 172800) return '${(s / 3600).round()} h';
    return '${(s / 86400).round()} d';
  }

  static String _bearerName(String b) {
    final k = 'geoui.info.bearer.${b.toLowerCase()}';
    final t = tr(k);
    return t == k ? b.toUpperCase() : '$t (${b.toUpperCase()})';
  }

  static String _sig(String auth) => switch (auth) {
        'verified' => tr('geoui.chat.info.sig.verified'),
        'forged' || 'bad' => tr('geoui.chat.info.sig.bad'),
        'unverified' => tr('geoui.chat.info.sig.unknown'),
        'unsigned' => tr('geoui.info.sig.unsigned'),
        _ => tr('geoui.info.sig.not_known'),
      };

  static IconData _statusIcon(String s) => switch (s) {
        'key' => Icons.key,
        'read' => Icons.done_all,
        'delivered' => Icons.done,
        'expired' => Icons.error_outline,
        _ => Icons.schedule,
      };

  static String _statusText(String s) => switch (s) {
        'key' => tr('geoui.info.status.key'),
        'read' => tr('geoui.info.status.read'),
        'delivered' => tr('geoui.info.status.delivered'),
        'expired' => tr('geoui.info.status.expired'),
        _ => tr('geoui.info.status.sent'),
      };

  static ({IconData icon, Color color, String title, String detail}) _privacy(
      Map<String, dynamic> m, bool enc, String status) {
    if (status == 'key') {
      return (
        icon: Icons.key,
        color: const Color(0xFF63B0E8),
        title: tr('geoui.info.waiting'),
        detail: tr('geoui.info.waiting.detail'),
      );
    }
    if (m['private'] == true) {
      return (
        icon: Icons.lock,
        color: const Color(0xFF4FA3E0),
        title: tr('geoui.chat.info.private'),
        detail: tr('geoui.chat.info.private.detail'),
      );
    }
    if (enc) {
      return (
        icon: Icons.lock,
        color: const Color(0xFF63B0E8),
        title: tr('geoui.chat.encrypted'),
        detail: tr('geoui.chat.info.encrypted.detail'),
      );
    }
    if (m['plain'] == true) {
      return (
        icon: Icons.lock_open,
        color: const Color(0xFFE0A030),
        title: tr('geoui.chat.info.plain'),
        detail: tr('geoui.chat.info.plain.detail'),
      );
    }
    return (
      icon: Icons.public,
      color: const Color(0xFFE0A030),
      title: tr('geoui.chat.info.public'),
      detail: tr('geoui.chat.info.public.detail'),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: TextStyle(
                  color: cs.primary,
                  fontSize: 12,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withAlpha(90),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class _Quote extends StatelessWidget {
  final String text;
  const _Quote(this.text);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: cs.primary, width: 3)),
      ),
      child: SelectableText(text.isEmpty ? '—' : text,
          style: const TextStyle(fontSize: 15.5)),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final String? copy;
  final bool mono;
  const _Row(this.label, this.value, {this.copy, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(label,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13.5)),
          ),
          Expanded(
            child: SelectableText(value,
                style: TextStyle(
                    fontSize: 13.5, fontFamily: mono ? 'monospace' : null)),
          ),
          if (copy != null && copy!.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Clipboard.setData(ClipboardData(text: copy!)),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.copy, size: 15, color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

/// The stations a packet passed through, left to right: the author, every
/// relay in `via:` (oldest first, XPRS.md 9), and its destination.
class _Route extends StatelessWidget {
  final List<String> nodes;
  final String bearer;
  const _Route({required this.nodes, required this.bearer});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = <Widget>[];
    for (var i = 0; i < nodes.length; i++) {
      final ends = i == 0 || i == nodes.length - 1;
      items.add(Chip(
        avatar: Icon(
            ends
                ? (i == 0 ? Icons.edit_outlined : Icons.flag_outlined)
                : Icons.cell_tower,
            size: 16),
        label: Text(nodes[i], style: const TextStyle(fontSize: 12.5)),
        visualDensity: VisualDensity.compact,
        backgroundColor: ends ? cs.secondaryContainer : null,
      ));
      if (i < nodes.length - 1) {
        items.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Icon(Icons.arrow_forward, size: 16, color: cs.onSurfaceVariant),
        ));
      }
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 4,
      children: items,
    );
  }
}

class _Wire extends StatelessWidget {
  final String wire;
  const _Wire(this.wire);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(60),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SelectableText(wire,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          const SizedBox(height: 4),
          TextButton.icon(
            icon: Icon(Icons.copy, size: 15, color: cs.primary),
            label: Text(tr('common.copy')),
            onPressed: () => Clipboard.setData(ClipboardData(text: wire)),
          ),
        ],
      ),
    );
  }
}
