# Link cards: a preview of a shared web link, made once by the sender

**Goal.** A person on an Android phone pastes a link into a chat. The message
arrives with the page's picture, title and a short summary. Nobody who
receives it ever contacts the website: what they see came inside the message,
over XPRS, like any other picture and text.

## Decision: an add-on wapp, not the core

By `architecture.md` §3, in order:

1. Does it move bytes between devices? No. Fetching a web page is the sender
   reading the web, not a transport.
2. Does it need a key, the profile or the databases? No. It stores one
   picture through `hal_media_put_file`, the verb every wapp already has.
3. Is it about what a message means to an application? Yes. So it is wapp
   work, and the core learns nothing new (`no-core-changes-for-upper-layer-work`).

Chat, social and forum all want the same card, so it is a **provider**, the
§"One wapp serving another" shape the AI add-on (`ai.chat`) already uses:

- New add-on wapp **`apps/linkcard`** (`tools.xprs.linkcard`, `kind: addon`),
  bundled in `assets/wapps/` and installed by default (cards on by default).
  Shared by people like any wapp (`wapps-shared-by-people`).
- It provides the functionality **`link.card`** (`wapp-interfaces.md` §5).
  Callers find it by capability, never by name. Uninstalled means no cards
  and plain links; nothing breaks.

## What the provider does

`args: {"url": "https://..."}` →
`result: {"url", "title", "summary", "site", "file"}`, or
`error: "unreachable" | "not_html" | "nothing" | "refused"`.

1. **Refuse** anything but `http(s)`, and hosts that are literal private,
   loopback or link-local addresses.
2. **Read the page head only.** `hal_http_stream_open` / `_read`, at most
   512 kB, stopped at `</head>` once the metadata is in. Never the whole
   page into memory (`performance.md` §8.9). The request has no cookies, a
   generic User-Agent, a 10 s timeout and at most 3 redirects.
3. **Parse** in order: `og:*` → `twitter:*` → JSON-LD `headline/description/image`
   → `<title>` / `<meta name=description>`. The title is clamped to 80
   characters and the summary to 160. HTML entities are decoded, tags and
   control characters dropped. This is a small C scanner over the head, not a
   DOM: the head is the only part read.
4. **Picture.** `og:image`, else `apple-touch-icon`, else none. Downloaded with
   `hal_http_request2` (answered by `http.done`, no tick, §8.4), refused above
   2 MB, written to the wapp's temp file and handed to **`hal_media_put_file`**.
   That door already makes the ≤24 kB preview on a worker isolate
   (`MediaPreviews.ensureFor`, §8.14), so the add-on does no image work at all.
5. Answer with the media token in `file`.

The manifest declares `timeout_ms: 20000`, `tick_interval_ms: 0` and hal
`http, file, media, msg, log`. The broker opens it headless per request and
closes it after (§5.2), so it costs nothing while idle.

## On the wire: an ordinary message, nothing new

The card is **written into the message by the sender**:

```
t:message f:X1QZ3N d:X1RD89 ts:… file:<preview>.jpg size:23kB m:look at this https://example.org/a<U+2029>> **Page title**<U+2028>> First words of the summary…
```

- The picture is the message's `file:`, lifted, previewed, companioned,
  advertised, deposited at archivers and fetched by hash exactly as a shared
  photo is (`XprsFileLift`, `airFileCompanion`, `onFileShared`, `MediaFetch`,
  XPRS.md §7.7.7). No new path.
- Title and summary are a quotation in `m:` (XPRS.md §4.11 `> `, U+2028/U+2029
  separators). `chat_view_field` already draws formatted bodies
  (`_bodyText` → `XprsMdText`). Every reader, old or new, shows readable text
  and a picture.
- It is the sender's own signed words. A card cannot be grafted onto someone
  else's message, and the readable link is always the URL in the text.
- **"Only if it fits".** The chat wapp builds the text, and if the result is
  over the message's limit (9 parts, §7.6; one packet where the conversation
  already allows only one), it drops the summary, then the title, then the
  card. Whether the picture travels on LoRa is the core's existing rule
  (`MediaFetch.decide`), unchanged.
- No new wire word, no new `kind:`, no spec vocabulary. XPRS.md §7.7.7 gets
  one worked example, "a link shared with its card", so other implementations
  write the same shape.

## The chat wapp (first caller)

- While composing, when the text gains its first `http(s)://` URL, send
  `widget.request link.card` once per URL (debounced on the composer event,
  not a tick). Show the returned card above the text box with ✕ to remove it.
- On send, append the quotation and the `file:` token the same way an
  attachment's token is appended today. The core does the rest.
- When there is no provider, a timeout or an error, send the plain link.
  The message never waits on the card.
- The renderer: the existing picture + formatted body. A tidier card layout
  (picture beside the quotation when the body is URL + quote) is a local
  change in `chat_view_field`, with no network access ever from the
  renderer.

Social and forum callers come next with the same request.

## The web chat (station-assisted)

The page cannot read another site (CORS), so the **station fetches, the page
decides** (`webchat-one-page-everywhere`, `xprs-api-generic-logic-in-js`):

- One generic endpoint, `POST /api/xprs/file?url=<https url>&session=…`:
  the station GETs the URL with the same limits as the provider, stores the
  bytes in the file store it already has (a deposit, §12.11.1 class 1/2) and
  answers `{"ok":true,"ref","size","type"}`. Session required, the same rate
  limit as `/api/xprs/send`, private addresses refused. It knows nothing
  about cards. It is listed in `/api/services` as `file.fetch`, so engines
  that cannot fetch (the boards) do not offer it, and the page hides the
  feature.
- It lives in core's `WebChatApi` because that is the engine both the app and
  the server run. It is a file-store primitive, not chat logic, and is written
  in `spec/API-HTTP.md` beside `GET/POST /api/xprs/file/{ref}`, with a
  conformance case in `contract/conformance.py`.
- Page JS: fetch the page head through it, read it with `DOMParser` using the
  same rule order as the provider, fetch the image through it, shrink with
  `galThumb`, store with `galPut(…, preview=true)` and compose the same
  message text. Then regenerate every copy of the page.

## Tests

- `apps/linkcard/tests`: one directory of fixture heads (OG only, Twitter
  only, JSON-LD only, bare `<title>`, entities, a 600 kB head, a redirect
  loop, a private address), run by the wapp's `WAPP_TEST` runner. **The same
  fixtures** drive the page test in `webchat/test`, so the C and JS readers
  cannot drift.
- The chat wapp: card text trimmed to fit; no provider means a plain link.
- A receiver-side check: rendering a card message makes zero HTTP requests.
- `arch_guard` clean, and the full app flutter suite before any release
  (`run-app-tests-before-tagging`).

## Reuse notes (to `docs/reusable.md` of each repo)

- apps: the head scanner (`linkcard/head.c`): meta/JSON-LD reading for any
  wapp that needs a page's title.
- apps: "fetch to temp, `hal_media_put_file`" for any wapp that brings a
  picture in from the web: the core makes the preview.
- webchat: the head reader in JS, and `galThumb`/`galPut` already listed.
- core: `POST /api/xprs/file?url=` for any page feature that needs a web
  resource as a stored file.

## Order of work

1. `apps/linkcard`: scanner and fixtures first, then the provider, built and
   bundled.
2. The chat wapp: request, composer card, appended text, fit rule.
3. `chat_view_field`: card layout for URL + quote + picture.
4. XPRS.md §7.7.7 example; API-HTTP.md `file.fetch`; core `WebChatApi`
   endpoint and its conformance case.
5. The web chat page; regenerate all copies.
6. Test on a real Android phone (`test-as-the-real-client`): paste a link,
   send to a second phone, and confirm the second phone made no request to
   the site.
