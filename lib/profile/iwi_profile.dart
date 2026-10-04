/*
 * IwiProfile — slimmed-down profile model for the iwi launcher.
 *
 * Ported shape from xprs/lib/models/profile.dart but stripped to the
 * fields that the launcher actually cares about. The parent project's
 * Profile carries ~20 station/location/relay fields that iwi doesn't
 * need. If iwi ever needs them, add them here rather than importing
 * the parent class — the two lifecycles are intentionally decoupled.
 *
 * Persistence: written as a JSON entry inside `profiles.json` at the
 * XPRS root by [ProfileService]. Never persist [nsec] anywhere
 * outside this file — it is the private signing key and must stay
 * inside the profile folder.
 */

class IwiProfile {
  /// Stable identifier. We use the callsign so paths on disk are
  /// human-readable (`devices/X1ABCD/`) and a profile can be swapped
  /// across machines by copying its folder name.
  final String id;

  /// Display label shown in the launcher AppBar and the welcome card.
  /// Free text chosen by the user. Falls back to [callsign] if empty.
  final String nickname;

  /// Callsign derived from the npub (X1 + first 4 bech32 chars). Stays
  /// stable for the life of the profile because it is also the [id].
  ///
  /// This is the SELF-PROVING name: it is an arithmetic function of [npub], so
  /// nobody can wear it without the key (XPRS.md 3). It never changes, even
  /// for an operator who sets [licenceCallsign], because it is also the folder
  /// on disk. What goes on the air is [wireCallsign].
  final String callsign;

  /// The callsign a radio authority issued this operator, or empty.
  ///
  /// A licensed amateur transmits under the callsign on their licence and
  /// nothing else will do (XPRS.md 6.4.1): an `X1` is self-generated, no
  /// register lists it, and on licensed spectrum it identifies nobody. So when
  /// this is set it is what goes in `f:` on every packet this station
  /// originates, and a signed `t:identity` binds it to [npub] (XPRS.md 6.4.2).
  ///
  /// **Be exact about what holding this field proves: nothing.** An issued
  /// callsign has no arithmetic relationship to any key, XPRS has no registry
  /// and issues no credentials, and a second station can announce this same
  /// callsign with a different key. Whether it was issued to this operator is
  /// answered by their administration's public register, out of band, and
  /// never by anything this app transmits.
  ///
  /// Validated on entry by `xprsIssuedCallsignRefusal`
  /// (lib/services/xprs/xprs_callsign.dart), which rejects what certainly was
  /// not issued: an `X1` to `X5` name, a foreign node number, and anything
  /// that is not callsign-shaped.
  final String licenceCallsign;

  /// Bech32-encoded Nostr public key (`npub1...`). Shown to users,
  /// safe to share, used as the publisher identity when signing wapps.
  final String npub;

  /// Bech32-encoded Nostr private key (`nsec1...`). **Secret**. Kept
  /// only in the profile's own JSON entry so a profile export/backup
  /// is a single file copy.
  ///
  /// Encrypted profiles: empty while locked; hydrated in memory after
  /// unlock. [toJson] never writes it when [nsecEnvelope] is set.
  final String nsec;

  /// AES-GCM envelope holding the nsec at rest for encrypted profiles
  /// (see ProfileCrypto/NsecEnvelope). Null for plain profiles. When set,
  /// the plaintext [nsec] is never persisted.
  final Map<String, dynamic>? nsecEnvelope;

  /// Free-text bio / status the user can edit. Optional.
  final String description;

  /// Preferred avatar colour name (one of [kProfileColors]). Empty falls
  /// back to a deterministic colour derived from the callsign.
  final String color;

  /// Relative filename of the avatar image inside this profile's folder
  /// (`devices/<id>/<avatar>`), or empty when none is set (then the avatar
  /// renders as a coloured circle with the callsign initials).
  final String avatar;

  /// Unix epoch ms of creation. Used to sort profiles in the switcher.
  final int createdAt;

  const IwiProfile({
    required this.id,
    required this.nickname,
    required this.callsign,
    required this.npub,
    required this.nsec,
    required this.createdAt,
    this.description = '',
    this.color = '',
    this.avatar = '',
    this.licenceCallsign = '',
    this.nsecEnvelope,
  });

  /// What this station calls itself ON THE AIR: the licensed callsign when the
  /// operator has one, else the one their key derives (XPRS.md 6.4.1).
  ///
  /// Every `f:`, every announce name and `hal_identity` read this. NOT
  /// [callsign], which is also [id] and the folder name on disk, and NOT
  /// [displayName], which may be a nickname.
  String get wireCallsign =>
      licenceCallsign.isNotEmpty ? licenceCallsign : callsign;

  String get displayName => nickname.isNotEmpty ? nickname : wireCallsign;

  IwiProfile copyWith({
    String? id,
    String? nickname,
    String? callsign,
    String? npub,
    String? nsec,
    int? createdAt,
    String? description,
    String? color,
    String? avatar,
    String? licenceCallsign,
    Map<String, dynamic>? nsecEnvelope,
    bool clearNsecEnvelope = false,
  }) {
    return IwiProfile(
      id: id ?? this.id,
      nickname: nickname ?? this.nickname,
      callsign: callsign ?? this.callsign,
      npub: npub ?? this.npub,
      nsec: nsec ?? this.nsec,
      createdAt: createdAt ?? this.createdAt,
      description: description ?? this.description,
      color: color ?? this.color,
      avatar: avatar ?? this.avatar,
      // '' clears it, so there is no clearLicenceCallsign flag to forget:
      // unlike nsecEnvelope this field is not nullable, and an empty string
      // already means "no licence".
      licenceCallsign: licenceCallsign ?? this.licenceCallsign,
      nsecEnvelope:
          clearNsecEnvelope ? null : (nsecEnvelope ?? this.nsecEnvelope),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'nickname': nickname,
        'callsign': callsign,
        'npub': npub,
        // Encrypted profile: persist the envelope, NEVER the plaintext key
        // (the in-memory nsec is hydrated after unlock and must not leak
        // back to disk through a routine profile save).
        if (nsecEnvelope != null) 'nsec_enc': nsecEnvelope else 'nsec': nsec,
        'createdAt': createdAt,
        'description': description,
        'color': color,
        'avatar': avatar,
        // Only when set: every existing profiles.json stays byte-identical,
        // and an older build reading a newer file ignores the key.
        if (licenceCallsign.isNotEmpty) 'licenceCallsign': licenceCallsign,
      };

  factory IwiProfile.fromJson(Map<String, dynamic> json) {
    final envelope = json['nsec_enc'];
    return IwiProfile(
      id: json['id'] as String,
      nickname: (json['nickname'] as String?) ?? '',
      callsign: json['callsign'] as String,
      npub: json['npub'] as String,
      nsec: (json['nsec'] as String?) ?? '',
      createdAt: (json['createdAt'] as int?) ??
          DateTime.now().millisecondsSinceEpoch,
      description: (json['description'] as String?) ?? '',
      color: (json['color'] as String?) ?? '',
      avatar: (json['avatar'] as String?) ?? '',
      // Absent means "no licence", which is every profile written before this
      // existed. That is the whole migration.
      licenceCallsign: (json['licenceCallsign'] as String?) ?? '',
      nsecEnvelope: envelope is Map ? envelope.cast<String, dynamic>() : null,
    );
  }
}

/// The eight avatar colour choices, matching the original XPRS palette.
const List<String> kProfileColors = [
  'red', 'blue', 'green', 'yellow', 'purple', 'orange', 'pink', 'cyan',
];
