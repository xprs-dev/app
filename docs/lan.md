# XPRS on the local network

A station attached to a WiFi or an ethernet has a bearer that costs nothing and
carries everything: the wire itself. This is that bearer -- XPRS packets
broadcast to everyone on the network, and heard from everyone on it.

[ble5.md](ble5.md) is the Bluetooth bearer's page; this is the LAN's.
[XPRS.md](XPRS.md) already assigns it: `link:lan` is a bearer (section 10.6) and
`scope:local` explicitly permits "the network it is attached to"
(section 13.11.1).

## What this is not

**Not Reticulum, and not the internet.** No links, no identities, no routing, no
gateway, nothing that leaves the wire it is attached to. A packet on this bearer
reaches the machines in the building and stops there.

XPRS's Reticulum LAN discovery uses UDP 42671 and is a different protocol on a
different socket. The ESP32 firmware listens to it separately
(`xprs_lanwatch`) and nothing here changes that.

Three sockets travel this wire, and it is worth being able to name them:

| | |
|---|---|
| **UDP 4242** | this bearer — XPRS broadcast, everyone hears everyone |
| **TCP 4242** | XPRS and Reticulum on one connection, told apart by the first byte ([XPRS.md](XPRS.md) section 24.4) |
| **UDP 42671** | Reticulum's LAN discovery. Not XPRS, and not touched here |

## The wire

```
UDP, broadcast to 255.255.255.255, port 4242
one XPRS packet per datagram, verbatim, no header
```

The port is the one XPRS already answers on over TCP (section 24.4). Broadcast
needs it on UDP because TCP needs an address and the first station on a network
knows nobody's; the two sockets never collide, so it is one number rather than
two.

There is nothing else to it. The packet is what was composed and signed
(section 4), it arrives byte for byte, and a receiver decides what it is by
parsing it: a datagram that is not a well-formed XPRS packet is dropped.

**A station with its own hotspot airs twice.** 255.255.255.255 leaves by the
default route, and once a station has joined a network that is the network,
not its hotspot: a phone on the hotspot, setting the station up (XPRS.md
11.10), stopped hearing it the moment the station got onto the WiFi it had
just been given. So the station also sends every packet to its hotspot's own
subnet broadcast, 192.168.4.255 by default (`xprslan_set_extra_bcast()`,
`xprs_hotspot_bcast()`). A phone that hears both copies keeps one: the
identifier is the same.

That is deliberate. There is no version to negotiate, no envelope to strip and
no framing to get wrong, so a new station joins the bearer by opening a socket.
A packet is at most 250 bytes, so it always fits one datagram and is never
fragmented.

## Asking who is there (2026-09-15)

A station on this bearer is found when it beacons, every five minutes, and a
device behind a controller (XPRS.md 11.7.1) when its controller next airs for
it. Somebody opening a list of what is around wants the answer now, so the
core can ask: `XprsLan.sweep()`, reached by a wapp as `hal_xprs_discover()`
through `MeshService.discoverNearby()`. The wapp asks for the answer; that the
answer comes from a LAN sweep is the core's choice.

```
t:request f:<us> ts:<now> q:identity        no d:, unsigned
-> 255.255.255.255:4242, then unicast to every host of each local /24
<- t:identity from every station that speaks XPRS, one per device a
   controller operates, through the ordinary receive door
```

- **The words are XPRS.md 8's, unchanged.** `q:identity` "asks for one directly
  rather than waiting for the next period" (29.1); with no `d:` it is addressed
  to whoever hears it, and the firmware already answers it that way. Nothing
  about a sweep is new vocabulary.
- **Unicast to every host**, because this bearer's own header says why: WiFi
  drops and rate-limits broadcast, asymmetrically per device. The broadcast
  copy goes first anyway.
- **Where**: the /24 around each private (RFC 1918, link-local) address this
  machine holds, never its own address, never a container or VM bridge
  (docker0, br-, veth, virbr, vmnet), at most four subnets.
  `xprsLanSweepTargets` is pure and is a test table.
- **Cost**: about 250 datagrams of ~50 bytes per subnet, paced 8 at a time
  with 120 ms between (about four seconds per /24, in the background), one
  identity airing per station that answers. Unsigned, so no curve operation.
  At most one sweep per 30 s, whoever asks. The pace is set by ARP, not by
  the network: a datagram to an address nobody holds waits about three
  seconds for resolution and holds the socket's send buffer meanwhile, so a
  faster sweep has its tail refused.
- **Readable**: `/api/status` `mesh.lan.sweep` {sweeps, probes, refused,
  skipped, running, agoMs}, and one log line per sweep. `skipped` is a host
  whose datagram the socket would not take even after a pause: at 800 a
  second the bench lost 14 of 253, and 8 with an immediate retry.

The app itself answers `q:identity` only when it is addressed (`d:` names it),
so a sweep finds firmware stations and controllers rather than other phones.

**Not yet proven end to end.** On the bench (2026-09-15) the sweep went out
(253 hosts, one subnet, the docker bridge skipped) and reached X3MEAV at
192.168.178.62, which relayed the request, yet no `t:identity` came back
within 30 s, addressed or not, although `xprs_app.c` answers `q:identity`
from `on_lan`. The firmware that station runs is the next thing to read; no
X4 controller was on that network to try.

## Not everybody at once

> **The phone does not do any of this.** `lib/services/xprs/xprs_lan.dart`
> states it plainly at the top of the file: it is an endpoint, not a relay —
> no `via:` appending, no re-airing of somebody else's packet, no jitter timer,
> no cancel-on-hearing, and no BLE↔LAN cross-relay in either direction. The
> rest of this section describes what a relaying station (the T-Dongle) does
> and what the phone would have to do to become one; it is not a description of
> the app as it stands.

Every station on a broadcast network hears the same packet at the same moment,
and each one willing to relay it would transmit immediately. Section 13.2.1 says
what to do instead:

| | |
|---|---|
| A packet from another bearer | waits **200--1200 ms**, chosen at random |
| The same packet heard meanwhile | the waiting copy is **dropped** |
| A packet this station composed | goes out **immediately**, with no `via:` |

The cancel is what makes it work: with three dongles on one LAN hearing the same
Bluetooth packet, one airs it and the other two throw theirs away. The
identifier they compare is the section 5 one, which ignores `via:` and `sig:`,
so a relayed copy is recognisably the same packet.

A station also remembers what it has already put on the LAN, so it never airs
the same packet twice.

## What crosses to Bluetooth

Both ways, under the ordinary relay rules -- this is a station with two bearers,
not a special case:

- **Bluetooth to LAN.** Every XPRS packet heard on the air is offered to the
  LAN, which appends this station to `via:` and applies the section 13.1 budget
  (`sos` and `warning` 9 hops, everything else 3). A packet that names this
  station in `via:` already is not relayed (section 13.2).
- **LAN to Bluetooth.** The same, in reverse, through the broadcast-parcel
  chunker any XPRS scanner already reassembles.

`scope:local` packets **do** cross, because both are short-range bearers
(section 13.11.1). They still never reach APRS-IS or the internet: that gateway
is a separate path and is not fed from here.

The asymmetry worth knowing: a LAN carries more in a second than the radio
carries in a minute, so the Bluetooth direction is the one that needs a limit,
not the LAN one.

## Its own beacon

Every five minutes a station says it is there, in the shape section 10.6 already
defines for describing a bearer:

```
t:observation f:X3WWAJ link:lan peers:3
```

`peers:` is how many distinct stations it has heard on the LAN. Nothing has to
be discovered for the bearer to work -- a broadcast reaches everyone regardless
-- but a station that never speaks is indistinguishable from one that is not
there.

## On the T-Dongle

`xprs_xprslan` is the implementation, and everything heard on the LAN goes
into the same index as everything heard on the radio (`xprs_xprsindex`), so
`GET /api/xprs` answers about both. The bearer starts by default once WiFi is
initialised, including when the dongle is serving only its own SoftAP -- the
stations joined to it are a local network too.

**One caveat measured on the hardware:** with BLE and WiFi both active, this
board's WiFi association degrades within minutes (`wifi:m f null` in the log,
then no route). That is a coexistence problem in the firmware's radio sharing,
not in this bearer -- it happens with the LAN bearer removed as well -- but it
does mean the two bearers are not yet reliably up at the same time on a
T-Dongle-S3.
