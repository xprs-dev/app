# Link previews: made once by the sender

**Goal.** A person on an Android phone shares a web link in a chat. The
people who receive it see the page's picture, title and a few words without
their devices ever contacting the site.

**Shape.** Nothing new on the wire. The sender's message is an ordinary
message, as if the person had typed it and attached a picture (the line
break is shown as `<LS>`; on the wire it is the U+2028 character, as for any
message with lines):

```
t:message … file:<small preview>.jpg size:18kB m:look at this https://example.org/a<LS>Page title — first words of the summary
```

- the words with the link, as written;
- the page's title and summary as a plain line after them;
- the page's picture, downscaled, as the message's one attachment. It
  travels, is kept by archivers and is fetched by hash like any shared
  picture (XPRS.md 7.7.7). No companion, no full-size original.

## The crawler: a system wapp

`apps/linkcard` (`tools.xprs.linkcard`, `kind: system`): in the launcher's
System folder, never on the main view; installed by default, with one switch
on its screen to turn previews off. It provides the functionality
`link.card` (`wapp-interfaces.md` 5.4):

1. Refuses anything but a public `http(s)` address.
2. Reads at most the page's first 1 MB (`hal_http_request2` with a `Range`
   header the host also enforces as a read cap; YouTube names its title
   ~850 kB into the page).
3. Reads the head with `sdk/wapp_page_meta.h`: Open Graph, then Twitter
   cards, then JSON-LD, then `<title>` and the description.
4. Downloads the picture (at most 1 MB) and hands it to the media store with
   `hal_media_put_bytes`, which makes the small preview off the UI isolate.
5. Answers `{url, title, summary, site, file}`.

No clock: every step is woken by `http.done`. The broker opens it for a
request and closes it after.

## The chat box

`ChatViewField` (every chat screen): 700 ms after typing stops, the first
link is asked of `link.card` (`FunctionalityBroker.ask`, `LinkCards`). The
preview shows above the box with ✕. On send, `LinkCards.withCard` adds the
title and summary line, and the preview picture is attached, unless the
person attached a picture themselves (one file per message). The full-size
download is deleted once the preview exists.

## The web chat

Shows the picture any message carries (its `file:`, from the station by
reference) and the message's line breaks. Nothing link-specific.

## Tests

- `apps/linkcard/tests/native`: the reader on fixture pages and the address
  rules.
- `app/test/link_cards_test.dart`, `functionality_broker_test.dart`.
- On a phone: paste a link, send, see the picture and summary on the other
  side and in the web chat; the receiver contacts nothing but XPRS.
