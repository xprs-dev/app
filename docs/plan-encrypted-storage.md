# Encrypted Profile Storage

Status: all five phases implemented (crypto core, encrypted databases (SQLCipher, replaced by zxdb on 2026-11-06), loose files (profile.ear, replaced by profile.zx on 2026-11-06), unlock UI + enable/disable, headless remember-key + locked notification). Android on-device validation pending. This document specifies how XPRS encrypts each profile's user data at rest.

> **Amendment (2026-11-06): zx encrypts everything; SQLCipher,
> `encrypted_archive` and AEF1 are gone.** SQLite was removed completely
> (owner's decision; no backward compatibility, no migration), and the
> owner then asked for the storage to use zx's own encryption instead of
> layers of the app's. Every byte at rest is now encrypted by zx
> (AES-256-CTR + HMAC-SHA-256 per block, names and sizes hidden too):
>
> | What | Where | zx password |
> |---|---|---|
> | every database (`*.zx`, `XDb`) | its own file | `dbKeyHex(relPath)` = hex HKDF(PMK, "aurora-db-v1:" + relPath) |
> | loose user files (kv.json, hal_file_*, avatar, ...) | rows of `files` in `profile.zx`, a zxdb database (replaces `profile.ear`) | `storePassword` = hex HKDF(PMK, "aurora-ear-v1") |
> | files that must stay real files (`rns_identity.key`, `folders.json`, media blobs under `data/media/`) | each a one-entry .zx archive (`zxPackBytes`, `SecureProfileFile`) | `fileKeyHex(relPath)` = hex HKDF(PMK, "aurora-file-v1:" + relPath) |
>
> The derivations are unchanged (frozen labels). The passwords are random
> 256-bit keys, so every file is written with `scryptLog2N: 1`: zx's
> default scrypt cost (about a second per open on a phone) would buy
> nothing and cost two dozen seconds per unlock. The app's own cipher code
> only wraps the PMK and the nsec (keyslot.json, profiles.json); the
> `encrypted_archive` package and the AEF1 wrapper were deleted. A
> one-time sweep (`legacy_storage_sweep_io.dart`) deletes `*.sqlite3`,
> `profile.ear` and AEF1 files on first start. The sections below are the
> original plan, kept as history; where they speak of SQLCipher,
> `profile.ear` or AES-GCM per file, the table above applies instead.

> **Amendment (2026-08-02):** the "fingerprint prompt is the lock" doctrine is
> retired. Device-key profiles now unlock **silently everywhere** (UI and
> headless) — encryption is at-rest protection, not an app lock — so the
> biometric gate (`biometric_gate.dart`, `unlockWithBiometrics`, the
> device-key UnlockPage shape) and the "XPRS is locked" system notification
> were removed. Only password profiles still see UnlockPage, and only they can
> genuinely "Lock now". `local_auth` dropped from pubspec.

## Context

Each XPRS profile (`devices/<id>/`) holds private user data — chat history, messages, media, wallet, folder keys — today all plaintext. Requirement: profile data encrypted at rest, unlocked with a user password (emoji allowed) **mixed with the profile's nsec**. The earlier xprs iteration (`/home/brito/code/xprs/xprs`) already built the hard part: a proven `encrypted_archive` Dart package (SQLite container `EARCH01`, Argon2id → wrapped random master key → HKDF per-file keys → AES-256-GCM chunks, streaming, password change = re-wrap only). Old xprs derived the key from nsec only — the user password + emoji mix is new here.

**Approved decisions:**
1. **No plaintext ever on disk** — extract-to-disk/repack explicitly rejected.
2. **Container = encrypted folder**: `devices/<id>/` holds one `profile.ear` (all loose files) + password-encrypted database files (live DBs can't run inside an archive). Originally SQLCipher `.sqlite3`; since 2026-11-06 zxdb `.zx` files, plus the media archive's per-file encrypted blobs under `data/media/`.
3. **Scope = user data only**: `data/` tree, avatar, identity, folder keystore, and ALL databases (incl. `wapps/<w>/social.zx`); wapp code files (`manifest.json`, `app.wasm`, screens) stay plaintext.
4. **Headless boot = optional remember-key**: "Keep unlocked on this device" caches derived keys app-private; otherwise gated services wait for manual unlock.
5. **nsec encrypted at rest too** (in `profiles.json`, identity-backup-style AES-GCM envelope).
6. Per-profile opt-in toggle. **No data migration**: enabling encryption deletes the old plaintext files and starts fresh encrypted; disabling deletes encrypted data.

## Key hierarchy

```
password  = NFC-normalized user string (emoji OK; ZWJ/skin-tone sequences preserved), utf8-encoded
nsec      = profile secret (bech32 string; use decoded 32 bytes as ikm component)

salt      = random 16 B, stored plaintext in the profile's keyslot
KEK_pw    = Argon2id(password, salt, t=3, m=64 MiB, p=1) → 32 B          # stage 1
nsec_ct   = AES-256-GCM(KEK_pw, nsec)            → stored in profiles.json entry
KEK       = HKDF-SHA256(ikm = KEK_pw ‖ nsecBytes, salt, info="aurora-profile-kek-v1")  # password × nsec mix
PMK       = random 32 B profile master key (generated once at enable)
pmk_ct    = AES-256-GCM(KEK, PMK)                → devices/<id>/keyslot.json
earPass   = hex(HKDF(PMK, info="aurora-ear-v1"))          → password for profile.ear
dbKey(p)  = HKDF(PMK, info="aurora-db-v1:" + relPath) → 32 B → hex = zxdb password (was SQLCipher PRAGMA key = "x'<hex>'")
remember  = {PMK, nsec} in app-private prefs (Android Keystore wrap = later hardening)
```

- Wrong password detected by GCM auth failure on `nsec_ct` (no oracle, constant-time).
- Off-device theft of `devices/<id>/` needs password **and** nsec. Password change = re-derive KEK, re-wrap PMK + nsec (cheap; archive/DBs untouched).
- NFC normalization: add `unorm_dart` (tiny, pure Dart) so the same emoji typed on different keyboards derives the same key.

## Components

### 1. Port `encrypted_archive` package
Copy `/home/brito/code/xprs/xprs/packages/encrypted_archive` → `aurora/packages/encrypted_archive`. All deps already in aurora (`sqlite3`, `cryptography`, `crypto`, `archive`). (Since 2026-11-06 the package runs on zx's `ZxDb` instead of `sqlite3`, same schema; its stats are counted when asked, since zxdb has no triggers.)
**Modification**: add **sync** read/write/exists paths (AES-GCM via `pointycastle`'s `GCMBlockCipher` — sync; the `cryptography` package is Future-only) so the WASM HAL sync callbacks (`ProfileStorage.readBytesSync` etc., `lib/profile/profile_storage.dart:80-96`) work. Argon2id stays async (unlock-time only).

### 2. SQLCipher for live databases (superseded 2026-11-06 by zxdb)

What is built today: `openProfileDb` (`lib/profile/profile_db_io.dart`) opens a
zxdb file with `password = dbKeyHex(relPath)` inside an encrypted, unlocked
profile, with no password in a plain profile, and throws
`ProfileLockedException` in a locked one. reticulum-dart's stores open through
the injected `dbOpener`, and the media archive reads and writes its blob files
through the injected `blobRead`/`blobWrite` (`SecureProfileFile`). There is no
native library to ship or verify on any platform. The original SQLCipher plan
follows as history:

- `pubspec.yaml`: replace `sqlite3_flutter_libs` → `sqlcipher_flutter_libs` (mutually exclusive; `package:sqlite3` API unchanged). **Verify Linux/Windows support first thing in this phase**; fallback = ship libsqlcipher via CMake for desktop.
- New central opener `lib/profile/profile_db.dart`: `Database openProfileDb(String absPath)` — consults `ProfileKeyring`; encrypted profile → `sqlite3.open(path)` + `PRAGMA key="x'<dbKey>'"`, plain profile → open as today (SQLCipher reads plain DBs when no key set).
- `reticulum-dart` (sibling, path dep): add injectable opener hook `Database Function(String path)` used by `MediaArchive`, `observed_store.dart:32`, social/event stores; aurora injects `openProfileDb` at startup.
- Replace direct `sqlite3.open` call sites: `mesh_store.dart:57`, `geo_chat_archive.dart:35-39`, `activity_archive.dart:22-26`, `coin_host_bridge.dart:123,160`, `wapp_social_store.dart:34-35`, `rns_autostart.dart:65-80`, `remote_api_service_io.dart:485-497`, `wapp_engine.dart:2177` (`hal_sqlite_open`), `media_view.dart:43`, `wapp_engine.dart:643-649`.

### 3. `EncryptedProfileStorage` (loose files → profile.ear)
- New `lib/profile/profile_storage_encrypted.dart` implementing the existing `ProfileStorage` interface (`lib/profile/profile_storage.dart:40`, `isEncrypted` flag already there) backed by `devices/<id>/profile.ear`; sync variants via the sync archive API.
- Selection in `ProfileService.activeProfileStorage()/storageForProfile()` (`lib/profile/profile_service.dart:184,233`): keyslot exists → encrypted backend (throws `ProfileLockedException` if keyring locked), else filesystem.
- **Boundary rule** inside encrypted profile: `wapps/<w>/` non-database files + `.seeded.json` + `keyslot.json` stay filesystem-plaintext; every `*.zx` (and its `.zx-lock`) = zxdb encrypted by its own password on the filesystem (was `*.sqlite3` with SQLCipher); `data/media/` = the media archive's blob files, encrypted per file; everything else (data/ loose files, avatar.png, folders.json, disk_folders.json) = inside `profile.ear`.
- Reroute bypass call sites to `ProfileStorage`: `wapp_engine.dart:1747-1807,3397-3400` (`hal_file_*` raw `dart:io`), `disk_folder_manager.dart:268-283`, `folder_keystore.dart` (folder master privs — high-value secrets), remote API file serving (`remote_api_service_io.dart` — audit during phase).

### 4. Unlock flow + keyring
- New `lib/profile/profile_keyring.dart`: singleton holding `{PMK, nsec}` per unlocked profile; `unlock(id, password)` (Argon2id → decrypt nsec → KEK → unwrap PMK), `unlockCached(id)` (remember-key), `lock(id)` (close archive + DB handles, zero keys).
- New `lib/profile/unlock_page.dart`: password field (native keyboard emoji fine), "Keep unlocked on this device" checkbox, wrong-password error. Inserted in `launcher_app.dart _home()` (`lib/launcher/launcher_app.dart:127-180`): active profile encrypted && locked → `UnlockPage` before `LauncherPage`.
- Headless (`main.dart`): after `profile-service` boot task, encrypted+locked → try cached key; none → **skip** `PermissionGate.startGatedServices()` (`main.dart:311`) and post notification "XPRS locked — tap to unlock" via BgService channel.
- Profile switcher (`launcher_page.dart:718-775`): lock badge on encrypted profiles; switching to one routes through UnlockPage.
- Manual "Lock now" in profile edit page. No auto-relock timer in v1.

### 5. Enable/disable — no data migration
No plain↔encrypted data conversion machinery. In profile edit page (near identity-backup passphrase UI, `profile_edit_page.dart:53-134` pattern):
- **Enable**: choose password (twice) + warning ("no recovery; existing profile data will be deleted") → stop gated services & close all profile DB/archive handles → **delete old plaintext data files** (`data/` tree, profile database files, avatar, folder keystore) → generate salt+PMK, write keyslot, encrypt nsec in `profiles.json` → profile continues fresh, all new writes encrypted.
- **Disable**: delete encrypted data files + keyslot, restore nsec to plaintext entry → fresh plaintext profile.
- Password change: re-wrap only (keeps data).
- When encryption on: identity backup mirror (`identity_backup.dart`) must be passphrase-encrypted (force or strongly warn — else nsec leaks to `/storage/emulated/0/XPRS`).

## Phases (each shippable)

1. **Crypto core**: port+modify `encrypted_archive`, `ProfileCrypto` key hierarchy, `unorm_dart`; unit tests incl. emoji/ZWJ passwords, wrong password, password change.
2. **SQLCipher plumbing**: dep swap (verify desktop platforms), `openProfileDb`, reticulum-dart hook, migrate all call sites; plain profiles must behave identically (regression: run app, chat, media). Superseded 2026-11-06: the same `openProfileDb` and `dbOpener` seams now open zxdb files with the derived password.
3. **EncryptedProfileStorage + reroutes**: hal_file, folder keystore, remote API; selection logic.
4. **Unlock UI + enable/disable + nsec envelope**: UnlockPage, enable/disable (delete-old-files, no conversion), switcher badges, password change UI.
5. **Headless remember-key**: cached-key unlock in headless boot, locked notification, gated-services skip.

## Verification

- `flutter analyze` + unit tests (`test/`): key derivation vectors, emoji NFC stability, archive round-trip, encrypted database round-trip (zxdb with password; was sqlcipher), enable/disable flows.
- Desktop live: create profile → enable encryption (confirm old files gone) → use chat/media → restart → unlock (wrong then right password) → data intact. Then `strings`/`hexdump` over `devices/<id>/` files: no plaintext message content anywhere; `profile.ear` and the `.zx` databases must not open without the key.
- Plain-profile regression on desktop after Phase 2 (no key, identical behavior).
- Android: build via `~/bin/android-build-locked`, deploy to C61; test unlock UI, remember-key + headless restart, background chat reception locked vs unlocked.

## Risks

- ~~`sqlcipher_flutter_libs` desktop (Linux/Windows) support~~ — gone with SQLCipher (2026-11-06); zxdb has no native library.
- ~~SQLCipher ~5-15 % DB overhead~~ (SQLCipher-era estimate; zxdb's encryption cost has not been measured here). Argon2id 64 MiB at unlock on low-RAM phones (one-shot, acceptable).
- On web there is no writable zxdb file yet, so encrypted profiles are refused there ([web.md](web.md)).
- `PreferencesService.wappDataDir` override can point `data/` outside the profile — opener still keys those DBs, but loose files there won't be in the .ear; document limitation.
- Deletion of old plaintext files is best-effort on flash (wear-leveling defeats overwrite); enabling encryption early, before data accumulates, is the real protection.
- Changes span two repos (aurora + reticulum-dart).
