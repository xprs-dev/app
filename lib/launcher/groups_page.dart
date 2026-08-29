import 'dart:async';

import 'package:flutter/material.dart';

import '../services/mesh/mesh_service.dart';
import '../services/xprs/xprs_group_keys.dart';
import '../services/xprs/xprs_group_ops.dart';
import '../services/xprs/xprs_groups.dart';

/// Settings → Groups. Closed groups, as section 26 defines them.
///
/// Three things a person has to be able to do, and none of them had a screen:
/// find a group, be let into one, and let somebody in. This is that screen.
///
/// **Discovery here is not a directory.** Section 26 has no registry and no
/// authority to ask, so what this station knows about is exactly what has
/// reached it: groups it holds the key to, plus every group it has heard a
/// signed act for. A group nobody has mentioned in earshot is not missing —
/// it is simply not here yet, and saying so plainly is better than an empty
/// list that reads like a broken one.
///
/// **A grant is an offer.** 26.3.1: being named in a grant makes nobody a
/// member. It puts them in the candidates list until they sign an acceptance,
/// so this screen shows the two states apart and never counts a candidate as
/// a member. That is the whole reason the distinction exists: a roster is
/// public, permanent and non-repudiable, and nobody should be able to write
/// somebody else into one.
class GroupsPage extends StatefulWidget {
  const GroupsPage({super.key});

  @override
  State<GroupsPage> createState() => _GroupsPageState();
}

class _GroupsPageState extends State<GroupsPage> {
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    // Redraw on the packet, not on a timer: a roster moves when an act
    // arrives and never otherwise.
    _sub = XprsGroups.instance.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String get _me => MeshService.instance.tableCallsign.trim().toUpperCase();

  /// Ours first — they are the ones we can act on — then everything heard of.
  List<({String call, String nick, bool mine})> _groups() {
    final mine = XprsGroupKeys.instance.mine();
    final seen = <String>{for (final g in mine) g.callsign};
    return [
      for (final g in mine) (call: g.callsign, nick: g.nick, mine: true),
      for (final c in XprsGroups.instance.known)
        if (!seen.contains(c)) (call: c, nick: '', mine: false),
    ];
  }

  Future<void> _create() async {
    final name = await _askText(
        title: 'New group',
        label: 'Name',
        hint: 'lisboa-net',
        help: 'The callsign is derived from the group’s key, so there is '
            'nothing to choose and nothing to collide with. The name is only '
            'a label, shown once the signature checks out.',
        action: 'Create');
    if (name == null) return;
    final g = XprsGroupOps.create(nick: name);
    if (!mounted) return;
    if (g == null) {
      _say('Could not mint a group — no profile is open.');
      return;
    }
    setState(() {});
    _say('${g.callsign} created and announced.');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final groups = _groups();

    return Scaffold(
      appBar: AppBar(title: const Text('Groups')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('New group'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              groups.isEmpty
                  ? 'No groups yet.\n\nThere is no directory to search: a group '
                      'reaches this station when somebody in earshot mentions '
                      'it, or when you create one.'
                  : '${groups.length} known. There is no directory — these are '
                      'the groups you hold a key to, plus every group this '
                      'station has heard a signed act for.',
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.5),
            ),
          ),
          for (final g in groups) _tile(g.call, g.nick, g.mine),
        ],
      ),
    );
  }

  Widget _tile(String call, String nick, bool mine) {
    final cs = Theme.of(context).colorScheme;
    final r = XprsGroups.instance.rosterOf(call,
        haveKey: XprsGroups.instance.keyResolver?.call(call) != null);
    final role = r.roles[_me] ?? XprsRole.none;
    final members =
        r.roles.entries.where((e) => _isMember(e.value) && e.key != call).length;
    final candidates =
        r.roles.values.where((v) => v == XprsRole.invited).length;

    return Dismissible(
      key: ValueKey(call),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmForget(call, nick, mine),
      onDismissed: (_) {
        XprsGroupOps.forget(call);
        setState(() {});
        _say('Forgot $call on this device.');
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: cs.errorContainer,
        child: Icon(Icons.delete_outline, color: cs.onErrorContainer),
      ),
      child: ListTile(
      leading: CircleAvatar(
        backgroundColor: mine ? cs.primaryContainer : cs.surfaceContainerHighest,
        child: Icon(mine ? Icons.key : Icons.groups,
            size: 20,
            color: mine ? cs.onPrimaryContainer : cs.onSurfaceVariant),
      ),
      title: Text(nick.isEmpty ? call : '$nick  ·  $call'),
      subtitle: Text(
        [
          '$members member${members == 1 ? '' : 's'}',
          if (candidates > 0)
            '$candidates awaiting consent'
          else if (r.roles.length <= 1)
            'nothing heard yet',
        ].join('  ·  '),
        style: TextStyle(color: cs.onSurfaceVariant),
      ),
      trailing: _roleChip(role, pending: r.offers.containsKey(_me)),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => GroupDetailPage(call, nick)))
          .then((_) {
        if (mounted) setState(() {});
      }),
    ),
    );
  }

  /// Say what forgetting actually does before doing it. It is local, it is not
  /// a deletion, and for a group we administer it is irreversible in the one
  /// way that matters: the key cannot be regenerated, because the callsign is
  /// derived from it (26.1, 26.6).
  Future<bool> _confirmForget(String call, String nick, bool mine) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Forget ${nick.isEmpty ? call : nick}?'),
        content: Text(
          mine
              ? 'This drops the group’s KEY from this device. The key cannot '
                  'be regenerated — the callsign is derived from it — so you '
                  'could never sign for $call again, and anybody else who '
                  'heard its record still has it.\n\n'
                  'The group does not stop existing. Only this device forgets.'
              : 'This device forgets $call: its roster and the signed acts it '
                  'kept.\n\nThe group does not stop existing, and you will '
                  'hear about it again if somebody in earshot mentions it.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Widget? _roleChip(XprsRole role, {required bool pending}) {
    if (pending) return const _Chip('Invited', Colors.orange);
    switch (role) {
      case XprsRole.admin:
        return const _Chip('Admin', Colors.deepPurple);
      case XprsRole.mod:
        return const _Chip('Mod', Colors.teal);
      case XprsRole.member:
        return const _Chip('Member', Colors.blue);
      case XprsRole.invited:
        return const _Chip('Invited', Colors.orange);
      case XprsRole.sub:
      case XprsRole.none:
        return null;
    }
  }

  void _say(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m)));

  Future<String?> _askText({
    required String title,
    required String label,
    required String hint,
    required String help,
    required String action,
  }) =>
      _promptText(context,
          title: title, label: label, hint: hint, help: help, action: action);
}

bool _isMember(XprsRole r) =>
    r == XprsRole.member || r == XprsRole.mod || r == XprsRole.admin;

/// One group: who belongs, who is still being asked, and what this station may
/// do about it.
class GroupDetailPage extends StatefulWidget {
  const GroupDetailPage(this.group, this.nick, {super.key});
  final String group;
  final String nick;

  @override
  State<GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends State<GroupDetailPage> {
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = XprsGroups.instance.changes.listen((g) {
      if (mounted && g == widget.group) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String get _me => MeshService.instance.tableCallsign.trim().toUpperCase();
  bool get _amAdmin => XprsGroupKeys.instance.scalarFor(widget.group) != null;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final haveKey =
        XprsGroups.instance.keyResolver?.call(widget.group) != null;
    final r = XprsGroups.instance.rosterOf(widget.group, haveKey: haveKey);
    final myRole = r.roles[_me] ?? XprsRole.none;
    final myOffer = r.offers[_me];

    final members = r.roles.entries
        .where((e) => _isMember(e.value) && e.key != widget.group)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final candidates = r.offers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.nick.isEmpty ? widget.group : widget.nick),
        actions: [
          if (_amAdmin)
            IconButton(
              tooltip: 'Invite',
              icon: const Icon(Icons.person_add_alt),
              onPressed: _invite,
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'forget') _forget();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'forget', child: Text('Forget on this device')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _header(cs, r.verified),
          if (myOffer != null) _invitation(cs, myOffer),
          _section('Members', members.isEmpty ? 'Nobody yet.' : null),
          for (final e in members) _person(e.key, e.value),
          _section(
              'Candidates',
              candidates.isEmpty
                  ? 'Nobody is waiting. A grant only becomes membership when '
                      'the person signs an acceptance, so anyone invited '
                      'appears here until they do.'
                  : null),
          for (final e in candidates) _candidate(e.key, e.value),
          if (_isMember(myRole)) _leave(),
        ],
      ),
    );
  }

  Widget _header(ColorScheme cs, bool verified) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(widget.group,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 16, height: 1.4)),
            const SizedBox(height: 6),
            Text(
              _amAdmin
                  ? 'You hold this group’s key, so you are its admin. The '
                      'key cannot be rotated — the callsign is derived from it.'
                  : 'The group signs its own decisions. Yours are signed by you.',
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
            ),
            if (!verified) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'This group’s announcement has not arrived, so nothing '
                  'below can be checked. It is shown anyway rather than shown '
                  'as empty — a group you cannot verify must look unverified, '
                  'not look like it has no members.',
                  style: TextStyle(color: cs.onErrorContainer, height: 1.4),
                ),
              ),
            ],
          ],
        ),
      );

  /// The invitation, from the invitee's side. This is the screen 26.3.1 exists
  /// for: nobody is written into a public roster without saying yes here.
  Widget _invitation(ColorScheme cs, String offerId) => Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You have been invited',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: cs.onPrimaryContainer)),
            const SizedBox(height: 6),
            Text(
              'Being named in a grant is not membership. Joining is a signed '
              'act by you, naming this invitation ($offerId) — and so is '
              'leaving, which is why nobody can claim you joined or deny you '
              'left.',
              style: TextStyle(color: cs.onPrimaryContainer, height: 1.4),
            ),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton.icon(
                onPressed: () => _accept(offerId),
                icon: const Icon(Icons.check),
                label: const Text('Join'),
              ),
              const SizedBox(width: 8),
              TextButton(
                  onPressed: _leaveNow, child: const Text('Not interested')),
            ]),
          ],
        ),
      );

  Widget _section(String title, String? empty) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title.toUpperCase(),
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary)),
            if (empty != null) ...[
              const SizedBox(height: 6),
              Text(empty,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.4)),
            ],
          ],
        ),
      );

  Widget _person(String call, XprsRole role) => ListTile(
        dense: true,
        leading: const Icon(Icons.person_outline),
        title: Text(call, style: const TextStyle(fontFamily: 'monospace')),
        subtitle: Text(role == XprsRole.mod
            ? 'Moderator — may revoke and hide'
            : role == XprsRole.admin
                ? 'Admin'
                : 'Member'),
        trailing: _amAdmin && call != _me
            ? TextButton(
                onPressed: () => _revoke(call), child: const Text('Remove'))
            : null,
      );

  Widget _candidate(String call, String offerId) => ListTile(
        dense: true,
        leading: const Icon(Icons.hourglass_empty),
        title: Text(call, style: const TextStyle(fontFamily: 'monospace')),
        subtitle: Text('Invited as offer $offerId — waiting for them to accept'),
        trailing: _amAdmin
            ? TextButton(
                onPressed: () => _revoke(call), child: const Text('Withdraw'))
            : null,
      );

  Widget _leave() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
        child: OutlinedButton.icon(
          onPressed: _leaveNow,
          icon: const Icon(Icons.logout),
          label: const Text('Leave this group'),
        ),
      );

  Future<void> _invite() async {
    final call = await _promptText(context,
        title: 'Invite to ${widget.group}',
        label: 'Callsign',
        hint: 'X1ABCD',
        help: 'They are not a member until they accept. Until then they show '
            'as a candidate, here and on every station that hears this.',
        action: 'Invite');
    if (call == null || call.isEmpty) return;
    _report(XprsGroupOps.grant(widget.group, [call.toUpperCase()],
        role: 'member'));
  }

  void _revoke(String call) =>
      _report(XprsGroupOps.revoke(widget.group, [call]));

  void _accept(String offerId) => _report(
      XprsGroupOps.accept(widget.group, _me, offerId),
      done: 'Joined ${widget.group}.');

  void _leaveNow() => _report(XprsGroupOps.leave(widget.group, _me),
      done: 'Left ${widget.group}.');

  Future<void> _forget() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Forget ${widget.group}?'),
        content: Text(_amAdmin
            ? 'This drops the group’s KEY from this device. It cannot be '
                'regenerated — the callsign is derived from it — so you could '
                'never sign for this group again. It does not stop existing: '
                'everybody who heard its record still holds it.'
            : 'This device forgets the group’s roster and the signed acts it '
                'kept. The group does not stop existing, and you will hear of '
                'it again if somebody in earshot mentions it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    XprsGroupOps.forget(widget.group);
    if (mounted) Navigator.of(context).pop();
  }

  void _report(XprsGroupOpResult r, {String? done}) {
    if (mounted) setState(() {});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.ok ? (done ?? 'Signed and sent.') : r.error!)));
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.colour);
  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                color: colour, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String label,
  required String hint,
  required String help,
  required String action,
}) async {
  final c = TextEditingController();
  final v = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(help,
              style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  height: 1.4)),
          const SizedBox(height: 14),
          TextField(
            controller: c,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                border: const OutlineInputBorder()),
            onSubmitted: (s) => Navigator.of(ctx).pop(s.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(c.text.trim()),
            child: Text(action)),
      ],
    ),
  );
  c.dispose();
  return (v == null || v.isEmpty) ? null : v;
}
