# Plan: multi-language support for the core app

Status: phases 0 to 5 implemented 2026-10-24 in `en`, `pt` (European), `es`,
`de`, `fr`, uncommitted. 18 area files, 1176 keys; wapps chat, mail, mesh,
circles, social, maps, install and forum carry all five languages. Every
translation is machine-drafted and marked `reviewed: false`. The hardware
page's schedule sentence (`trSchedule`) and every byte size (`trBytes`,
decimal comma, `Ko`/`Mo` in French) are localised too. Open: a device run;
the functionality tester stays English by design.

## 1. What exists and is reused

The wapps already have a working translation architecture, and the host
already has the preference and the live-switch. Nothing here invents a second
mechanism; the core adopts the wapp one.

| Piece | Where | Reused as |
|---|---|---|
| `@key` sentinel: a string starting with `@` is a key, anything else passes through | `lib/wapp/i18n_context.dart` `I18nContext.resolve` | the same resolver, the same rule |
| Fallback chain `lang/<pt_PT>.json` → `lang/<pt>.json` → `lang/en.json` → the key itself | `I18nContext.loadFromPackage` | the same chain over the core's folders |
| Flat JSON map, `"namespace.subject": "text"` | every `apps/<wapp>/lang/<code>.json` | the same file shape, so the App Creator's translation editor and any script works on both |
| Locale preference, `Auto` = the OS locale | `PreferencesService.localePreference`, `activeLocale()`, `activeLanguageCode()` | unchanged |
| Settings → Language row, fires `LocaleChangedEvent`; every open `WappPage` reloads | `settings_page.dart`, `event_bus.dart`, `wapp_page.dart` | the root widget subscribes too |
| `hal_i18n_get(key)` for wapp C code | `xprs_wasm_hal.h`, `wapp_engine.dart` | untouched |

Where the wapps stand today: `maps` and `install` ship `en`, `pt`, `de` and
use `@keys` in their screens; `forum` has keys and English only; `chat`,
`circles`, `mesh`, `social`, `mail` have no keys at all (chat and circles ship
an unused `lang/en.json`). The core app has **no** translation of its own:
about 770 English literals reach a person from Dart, plus three strings in
`BgService.kt`.

## 2. Folder layout

One dedicated folder, one subfolder per language, several files per language,
each file one area of the app:

```
assets/lang/
  en/                     the source of truth; every key exists here
    common.json           Cancel, Save, OK, Remove, Back, Close, Retry …
    launcher.json         home, drawer, all-apps sheet, hero, quick launch, status bar
    settings.json         Settings page, every section
    permissions.json      permissions intro: row titles, descriptions, buttons
    onboarding.json       welcome, callsign choice, apps intro, unlock page
    profile.json          profile edit, avatar, identity backup, vanity callsign
    groups.json           groups page, muted accounts
    hardware.json         hardware page, add a radio, flashing
    updates.json          update page, update notifications, mirror
    notifications.json    notification centre + every XprsNotification the core shows
    wapp_host.json        the chrome around a wapp: menus, dialogs, pickers, share, file associations
    geoui.json            renderer defaults: empty states, "Loading…", field hints, media viewer
    editor.json           App Creator
    radio.json            Bluetooth/mesh/Reticulum texts a person sees (not logs)
    errors.json           error sentences shown to a person
  pt/
    common.json …         same file names; a missing file or key falls back to en
  de/
    …
```

Rules:

- A key's first segment names its file: `settings.language` lives in
  `settings.json`. A checker enforces it (section 6), so nobody has to
  remember where a key went.
- Files are flat `{"key": "text"}`, strings only. A `"_meta"` object is
  ignored by the loader by type and may hold `{"reviewed": false,
  "translator": "..."}`.
- Placeholders are `{name}`: `"peers.count": "{n} stations nearby"`. Plurals
  are two keys, `.one` and `.other`; the helper picks by `n`. No ICU, no
  code generation.
- The subfolder name is the tag the preference stores (`pt`, `pt_BR`, `de`).
  `Settings → Language` lists the subfolders found in the asset manifest
  instead of a hard-coded list.
- The wapps keep their own `lang/<code>.json` (one flat file per language per
  wapp). A wapp is already an area of its own, so that is the same partition
  from the other side; changing their layout would break installed wapps and
  the App Creator for no gain.

Why files per area and not one file per language: a translator takes one
area at a time, a diff names the screen it touches, a missing-key report
reads as a to-do list per screen, and a build that ships without `editor.json`
in Portuguese loses only the App Creator. The loader merges them, so the code
never knows the files exist.

## 3. Code shape

```
lib/services/i18n/
  i18n_context.dart      MOVED here from lib/wapp/ (a re-export shim stays in lib/wapp/
                         so the wapp host and its tests do not change)
  core_i18n.dart         CoreI18n singleton: loads assets/lang/en/* and
                         assets/lang/<active>/* once, merges each into one map,
                         exposes an I18nContext; reloads on LocaleChangedEvent
  tr.dart                tr('settings.language'), tr('peers.count', {'n': 3}),
                         trPlural('x', n), and a Text helper
```

- `tr()` is a map lookup on a cached table. It never touches the asset
  bundle after boot, never decodes JSON on a build, never does I/O
  (performance.md: nothing blocking on the UI isolate; a 30 KB JSON per
  language decodes in a few ms once at boot, async through `rootBundle`).
- The language changes rarely, so the root `IwiApp` rebuilds once on
  `LocaleChangedEvent`; widgets call `tr()` in `build` and nothing subscribes
  individually.
- `MaterialApp` gets `locale`, `supportedLocales` (from the folders) and
  `flutter_localizations` delegates, so Flutter's own dialog buttons, date
  pickers and text-selection menus follow the language too. This is the one
  new dependency.
- Text that reaches a person from a service (`XprsNotification` title/body,
  22 call sites) is resolved with `tr()` at the call site. `LogService` lines
  stay English: they are diagnostics read by developers and `/api/log`, and
  translating them would break every grep in the docs.
- `BgService.kt`'s three defaults ("Running in background", the channel
  name, the tagline) go into `res/values/strings.xml` and
  `res/values-pt/`, `res/values-de/`; Dart already passes the live notification
  text to the service, so the Kotlin defaults matter only between boot and the
  first Dart frame.
- Architecture: i18n is a core capability under `lib/services/`, consumed by
  `lib/launcher`, `lib/profile`, `lib/editor` and the wapp host. No new HAL
  verb: wapps keep `hal_i18n_get`. `arch_guard` is unaffected; one new rule
  is added (section 6).

## 4. Phases, with sizes

Counts are English literals found by regex; expect each to be about 20 %
higher once dialogs built from pieces are included.

| Phase | Scope | Strings | Why this order |
|---|---|---|---|
| 0 | infrastructure: folders, loader, `tr()`, Settings list from folders, `flutter_localizations`, the checker; `common.json` | ~40 | everything else depends on it |
| 1 | the first-run path: permissions intro, welcome and callsign, apps intro, unlock; Settings | ~150 | the person who installs the app next to you sees exactly these, and nothing else, in the first ten minutes |
| 2 | launcher: home, drawer, all-apps, notifications centre, updates, hardware, groups, muted | ~125 | the daily screens |
| 3 | wapp host chrome: `wapp_page.dart` menus and dialogs, GeoUI defaults, pickers, share | ~410 | the biggest block; split across several commits by dialog family |
| 4 | profile pages, editor, service notifications, radio nudges, error sentences | ~215 | lower traffic |
| 5 | wapps: `chat`, `circles`, `mesh`, `social`, `mail` screens to `@keys` and their C strings to `hal_i18n_get`; `pt` and `de` files for each | per wapp | separate repo (`../apps`), separate commits; the mechanism already exists |

Languages at launch: `en` (source), `pt` (the operator's own; `maps` and
`install` already ship it), `de` (already partly present). Every other
language is a folder drop with no code change. Phases 1 and 2 ship `pt` and
`de` complete; later phases may ship `en` only first, since fallback is
per key.

## 5. Conventions for keys and text

- `area.subject[.qualifier]`: `settings.language`, `settings.language.auto`,
  `permissions.bluetooth.title`, `permissions.bluetooth.desc`,
  `common.cancel`.
- Reuse `common.*` for every button that means the same thing. Nineteen
  separate `'Cancel'` literals become one key.
- The English text is the key's documentation; keys are never the English
  sentence (a key that is a sentence breaks the moment the sentence is
  edited).
- Callsigns, wire fields, packet types, file names and anything that goes on
  the air are never translated (XPRS.md 4: the wire is English and the
  decimal separator is `.` in every locale).

## 6. Tooling and enforcement

- `tool/i18n_check.dart` (no dependencies, like `arch_guard.dart`): every
  `tr('x.y')` in `lib/` exists in `assets/lang/en`; every key sits in the file
  its first segment names; every other language is reported per file as
  `pt/settings.json: 3 missing` (warning, never a failure, so a translation
  can lag a release); no key is defined twice. Runs in the pre-commit hook
  next to `arch_guard`.
- `tool/i18n_extract.dart`: lists remaining English literals per directory,
  which is the to-do list for phases 2 to 4 and the proof when one is done.
- A new `arch_guard` rule, `no-raw-ui-string`, baseline-keyed like the others:
  a `Text('…')` or `label: '…'` with an English sentence in a directory that
  has been converted fails the build. Directories enter the rule as their
  phase lands, so the guard never fails on day one and never lets a converted
  screen regress.
- `test/i18n_test.dart`: `en` loads and has no empty strings; placeholders
  used in `pt` exist in `en` for the same key; plural keys come in pairs;
  the resolver's fallback chain, including the `_meta` skip.

## 7. Open choices for the owner

1. Which languages first: `en`, `pt`, `de` are proposed because the wapps
   already have them. Add any now; later ones are folder drops.
2. Should the Settings language choice also be offered on the permissions
   intro, the first screen a new person sees? Proposed: yes, one row at the
   top, since the OS locale already picks the default and this only matters
   when it is wrong.
3. Machine-drafted translations marked `"_meta": {"reviewed": false}` and
   shipped, or English until a person reviews them? Proposed: shipped and
   marked; the checker prints the unreviewed files so they are not forgotten.
