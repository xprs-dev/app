/// `$type:"secret"` fields: a password, a private key.
///
/// A wapp's field values are ordinarily kept by the host in two places: the
/// wapp's KV (every keystroke is mirrored there, so a settings form takes
/// effect) and the saved field values a headless run of the wapp reads. Both
/// are right for a callsign or a radius and wrong for a WiFi password, which
/// must reach the wapp with the one action that uses it and then exist
/// nowhere. This is that rule, in one place, so the page and its tests agree.
library;

import 'geoui/geoui_ast.dart';

/// Is [block] a field whose value the host must never store?
bool geoUiFieldIsSecret(GeoUiBlock block) =>
    block.keyword == 'field' && block.type == 'secret';

/// Every secret field's name under [block], added to [out].
void collectSecretFields(GeoUiBlock block, Set<String> out) {
  final name = block.name;
  if (name != null && geoUiFieldIsSecret(block)) out.add(name);
  for (final child in block.children) {
    collectSecretFields(child, out);
  }
}

/// [fields] without the secret ones: what the host may write down.
Map<String, dynamic> wappStorableFields(
        Map<String, dynamic> fields, Set<String> secrets) =>
    {
      for (final e in fields.entries)
        if (!secrets.contains(e.key)) e.key: e.value,
    };
