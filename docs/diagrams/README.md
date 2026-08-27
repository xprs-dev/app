# Diagrams

Pictures of how this thing works. Each one belongs to a prose document in
`../` and says the same thing in a shape you can take in at a glance — the prose
is the source of truth, these are the map.

| diagram | draws | prose it belongs to |
|---|---|---|
| [relay-gateway-flow.md](relay-gateway-flow.md) | The three roles that move somebody else's packet: **relay** (APRS' digipeater), **gateway** (its iGate) and **carrier** (new in XPRS). Where each one actually runs, what digipeats and what does not, and how a packet crosses from one bearer to another. Seven figures. | [../XPRS.md](../XPRS.md) §13, §36.8, [../store-and-forward.md](../store-and-forward.md), [../aprs.md](../aprs.md) |
| [transports-flow.md](transports-flow.md) | How an XPRS packet finds a radio: the component map, the send sequence and its fallback, the four per-bearer verdicts, the inbound demux and funnel, the life of a 1:1, and the bench instrument that switches a lane off. Seven figures. | [../transports.md](../transports.md), [../private-messages.md](../private-messages.md) |

Each `.md` here has a `.html` beside it — the same figures, standalone, for
opening in a browser when you want them big or want to show somebody.

## Reading them

**Mermaid**, so they render on GitHub, in most editors, and in the HTML copy.
Nothing to install and nothing to regenerate: the diagram *is* the text in the
file, so a change is a diff you can read rather than a binary you have to trust.

That is the whole reason for the format. A picture that cannot be diffed drifts
from the code silently, and a diagram that disagrees with the code is worse than
no diagram — it is a confident wrong answer.

## Adding one

1. Put the `.md` here, named after the prose document it belongs to.
2. Add a row to the table above.
3. Link it from the prose document, and from [../README.md](../README.md) and
   [../index.md](../index.md) — a diagram nobody can find is a diagram nobody
   reads.
4. Say in the caption **what the picture is for**, not what it contains. The
   reader can see what it contains.

Keep the sections numbered the way the specification numbers them
(`../XPRS.md`), and cite them in the figure. A box labelled with a rule is worth
three boxes labelled with a class name — the class name will be renamed and the
rule will not.

## What is deliberately not drawn

Anything that is not built. `transports-flow.md` ends with the §31.1 airtime
budget for that reason: a station should transmit no more often than the
strictest bearer it is transmitting on allows, and a retry is not a new packet.
Both are real rules and neither is implemented, so there is no box to draw — and
drawing one would say the opposite.
