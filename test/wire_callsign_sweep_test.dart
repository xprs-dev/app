/*
 * Nothing on the way to the air reads the DERIVED callsign.
 *
 * This is here because the bug it catches is silent, and a live run on the
 * bench is what found it rather than any of the unit tests above. The whole
 * change rests on one distinction:
 *
 *   IwiProfile.callsign      derived from the key, self-proving, also the
 *                            profile id and its folder on disk
 *   IwiProfile.wireCallsign  what goes in f:, which is the operator's
 *                            licensed callsign when they have one
 *
 * Seventeen call sites were repointed by matching `activeProfile?.callsign`.
 * Two more read a LOCAL profile variable and so did not match, and one of
 * them was XprsPublisher.publishIdentity: the section 6.4.2 binding itself.
 * The station aired `t:identity f:X16JK8` while every other packet it sent
 * said `CT1ABC`, so the licensed callsign was bound to nothing and no peer
 * could check a signature of ours. Everything still "worked"; it just bound
 * the wrong name.
 *
 * A grep is a blunt instrument and that is the point: the failure mode is a
 * reader nobody thought to look at, so the test looks at all of them.
 */
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Reads of `IwiProfile.callsign` that are CORRECT, each with the reason.
///
/// Add to this only when the derived name is genuinely what is wanted, and say
/// why. If the answer is "the name this station is known by", it is wrong.
const Map<String, String> _allowed = {
  // The avatar colour and the identicon seed: setting a licence must not
  // recolour an operator's icon everywhere it has already been seen.
  'lib/profile/profile_avatar.dart':
      'avatar colour and identicon seed stay on the derived name',
  // A backup carries BOTH names so a restore reproduces the identity: the
  // derived one is the folder on disk, the licensed one is what went on air.
  'lib/profile/identity_backup.dart': 'a backup carries both names',
  // The profile editor shows the derived name in its own read-only row.
  'lib/profile/profile_edit_page.dart': 'shown as itself, read-only',
  // The vanity generator is about derivation by definition.
  'lib/profile/vanity_callsign_page.dart': 'about derivation itself',
  // The model defines both.
  'lib/profile/iwi_profile.dart': 'defines them',
  // The derived name becomes the ALIAS the receive door answers to, which is
  // exactly what this read is for.
  'lib/services/mesh/mesh_service.dart': 'computes the alias set',
};

void main() {
  test('no path to the air reads the derived callsign', () {
    final offenders = <String>[];
    // A read off the active profile, or off a local holding one. The three
    // spellings that actually occur; a new one would be caught by review of
    // this list rather than by it.
    final pattern = RegExp(
        r'(activeProfile[?!]?|\bprofile\?|\bp\?|\bprofile\b)\.callsign\b');

    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final rel = f.path.replaceAll(r'\', '/');
      if (_allowed.containsKey(rel)) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.trimLeft().startsWith('//') || l.trimLeft().startsWith('///')) {
          continue;
        }
        // One read in a file that is otherwise held to the rule, marked
        // where it stands with its reason.
        if (l.contains('// derived-callsign:')) continue;
        if (pattern.hasMatch(l)) {
          offenders.add('$rel:${i + 1}  ${l.trim()}');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: 'These read the DERIVED callsign where the name on the air '
            '(wireCallsign) is almost certainly meant. If one is genuinely '
            'right, add its file to _allowed with the reason:\n'
            '${offenders.join('\n')}');
  });

  test('the allow-list names files that exist', () {
    // A stale entry here silently stops guarding a real file.
    for (final path in _allowed.keys) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
  });
}
