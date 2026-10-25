/*
 * XprsSelf -- which of this station's names a packet goes out under.
 *
 * An operator may hold several issued callsigns, one per jurisdiction they
 * operate in (CT1ABC at home, EA/CT1ABC across the border), beside the X1
 * their key derives, which is the profile's base and its folder and never
 * changes. One of them is ACTIVE: the default on the air. But a conversation
 * that began under a particular callsign keeps it -- somebody who wrote to
 * EA/CT1ABC is answered as EA/CT1ABC even after the operator has gone home and
 * made CT1ABC active. That is the operator's rule, and it is the core's to
 * keep: `f:` is written by the core on every packet, so the wapp hands over a
 * message and never learns which name it went under (docs/architecture.md 1).
 *
 * Three questions, answered here and nowhere else:
 *
 *   isMine(call)   is this one of our names?  (signing, receipts, "for us")
 *   forPeer(peer)  which name does a 1:1 to this peer go out under?
 *   note...()      what a conversation has shown us about that
 *
 * The rule for a conversation's name:
 *   - A peer that addresses one of our ISSUED callsigns, or that we write to
 *     under one, is remembered under it.
 *   - A peer that addresses the derived X1 is forgotten: X1 conversations
 *     follow whatever is active, so an operator who sets a licence for the
 *     first time moves every existing conversation onto it.
 *   - A remembered callsign that is no longer held falls back to the active.
 *
 * XPRS.md 6.4.2 binds each issued callsign to the key by its own t:identity,
 * and a packet carries exactly one in `f:`; nothing here changes either.
 */
import 'dart:collection';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../profile/iwi_profile.dart';
import '../../profile/profile_service.dart';
import '../preferences_service.dart';

class XprsSelf {
  XprsSelf._();
  static final XprsSelf instance = XprsSelf._();

  /// How many conversations are remembered per profile; the least recently
  /// used goes first. A forgotten one simply follows the active callsign.
  static const int cap = 256;

  // Injected, so the rule is tested without a profile on disk.
  IwiProfile? Function() profile = () => ProfileService.instance.activeProfile;
  Map<String, String> Function(String profileId) load = (id) =>
      PreferencesService.instanceSync?.xprsConversationCallsigns(id) ??
      <String, String>{};
  void Function(String profileId, Map<String, String> m) save = (id, m) =>
      PreferencesService.instanceSync?.setXprsConversationCallsigns(id, m);

  String? _loadedFor;
  final LinkedHashMap<String, String> _peers = LinkedHashMap();

  static String _base(String c) => c.trim().toUpperCase().split('-').first;

  /// The active profile's memory, loaded on first use and again whenever the
  /// profile changes (each profile is a different person's conversations).
  LinkedHashMap<String, String> _map() {
    final id = profile()?.id;
    if (id != _loadedFor) {
      _peers.clear();
      if (id != null) _peers.addAll(load(id));
      _loadedFor = id;
    }
    return _peers;
  }

  void _persist() {
    final id = _loadedFor;
    if (id != null) save(id, Map<String, String>.of(_peers));
  }

  /// The callsign on the air by default: the active licence, else the X1.
  String active() => (profile()?.wireCallsign ?? '').trim().toUpperCase();

  /// Every base this station answers to, derived X1 first.
  Set<String> mine() {
    final p = profile();
    if (p == null) return const {};
    return {for (final c in p.allCallsigns) _base(c)};
  }

  bool isMine(String call) {
    final b = _base(call);
    return b.isNotEmpty && mine().contains(b);
  }

  /// Is [call] one of our ISSUED callsigns (not the derived X1)?
  bool _isHeldLicence(String call) {
    final p = profile();
    if (p == null) return false;
    final b = _base(call);
    return p.heldLicences.any((c) => _base(c) == b);
  }

  /// The callsign a 1:1 to [peer] goes out under.
  String forPeer(String peer) {
    final key = _base(peer);
    final remembered = key.isEmpty ? null : _map()[key];
    if (remembered != null && _isHeldLicence(remembered)) return remembered;
    return active();
  }

  /// [peer] wrote to us addressed as [to].
  void noteInbound(String peer, String? to) {
    final key = _base(peer);
    final addressed = (to ?? '').trim().toUpperCase();
    if (key.isEmpty || addressed.isEmpty || !isMine(addressed)) return;
    if (_isHeldLicence(addressed)) {
      _remember(key, _canonical(addressed));
    } else {
      _forget(key);              // addressed to the X1: follow the active
    }
  }

  /// We wrote to [peer] under [from].
  void noteOutbound(String peer, String from) {
    final key = _base(peer);
    if (key.isEmpty) return;
    if (_isHeldLicence(from)) {
      _remember(key, _canonical(from));
    } else {
      _forget(key);
    }
  }

  /// The held spelling of [call] (a `-n` device suffix is not a different
  /// licence, and the list is what the profile screen shows).
  String _canonical(String call) {
    final b = _base(call);
    return profile()!.heldLicences.firstWhere((c) => _base(c) == b,
        orElse: () => call.trim().toUpperCase());
  }

  void _remember(String key, String call) {
    final m = _map();
    if (m[key] == call) {
      // Touch it: most recently used.
      m.remove(key);
      m[key] = call;
      return;
    }
    m.remove(key);
    m[key] = call;
    while (m.length > cap) {
      m.remove(m.keys.first);
    }
    _persist();
  }

  void _forget(String key) {
    if (_map().remove(key) != null) _persist();
  }

  /// Forget what is loaded, so the next question reloads from storage.
  @visibleForTesting
  void resetForTest() {
    _loadedFor = null;
    _peers.clear();
  }

  /// Every conversation that currently keeps a non-active callsign, for the
  /// profile screen to say so.
  Map<String, String> pinned() {
    final act = active();
    return {
      for (final e in _map().entries)
        if (_isHeldLicence(e.value) && e.value != act) e.key: e.value,
    };
  }
}
