# Bridges

A bridge is for boards that are somewhere other than the computer that runs Alnasl: a Raspberry Pi in the next room, or in a hall in another town. The bridge program is called Arkab. It reads the boards and sends them to Alnasl over the internet. This chapter is about the Alnasl side. The bridge has a small page of its own (port 4050 on the bridge) with a short help of its own.

## What a bridge is for {#what-a-bridge-is}

The hosted server has no boards of its own, so every board on it arrives through a bridge. A box in a hall can take bridges as well, for a second room.

The bridge dials out to Alnasl. Nothing has to be opened in the hall's network: no port forwarding, no fixed address. Its boards appear among the others, with the bridge's name in front of the port, and are numbered, paired and repaired like any board.

## Arkab, the bridge program {#arkab}

**Arkab** is the bridge: Alnasl's board reading and nothing else - the board drivers, the serial bus, a queue that keeps every move until the server has it, and the outgoing line to one or more Alnasls. No rounds, no logins, no games of its own. It is a separate program with its own repository, [github.com/teapot-chess/Arkab](https://github.com/teapot-chess/Arkab), Apache-2.0 like Alnasl, and it shares its board code with Alnasl, so a board reads the same on both.

> [!NOTE] Getting Arkab
> Download it from [its releases page](https://github.com/teapot-chess/Arkab/releases/latest): a Windows installer, Linux archives for a PC and for a Raspberry Pi (with a one-line installer that makes it a service), and a Mac app. Install it on the computer the boards are plugged into, and start it. Its page then answers on port 4050 of that computer. The Setup wizard (Setup, first section) lists these steps for your hall and ticks them off as the bridge joins.

## Joining a bridge {#joining}

One action, in one place, and nobody types a key.

1. On Alnasl, open the page of the hall the boards are in: Halls, then the hall, then its **Bridges** tab (Setup, Access - This server on the server - has a "Bridges of this hall" button that leads straight there for the hall you are looking at). Press "Add a bridge".
2. It shows a link and the same thing as a QR code. The link is good for **one bridge and fifteen minutes**, and says until when.
3. On the bridge's page (on the computer beside the boards, port 4050), "Join a server": paste the link, or scan the code with the camera. Press Join. (A phone that opens the link in its own browser gets a page saying the link is for a bridge, and where to paste it.)
4. The bridge shows "Joined." and the server appears in its list. On Alnasl the bridge appears in the hall's list of bridges, with its name and "connected".

After that the bridge has a key of its own, which it fetched itself. Nobody ever sees it, reads it aloud or copies it, and Alnasl keeps only a hash of it. If the link runs out before it was used, press "Add a bridge" again.

> [!NOTE] Who may add a bridge
> Adding and removing a bridge is for the hall's owner. An arbiter can use the bridge's boards but not add or remove it. See [Accounts, halls and roles](06-accounts-and-halls.md).

## One bridge, several servers {#several-servers}

Integration is the point: one bridge can feed several Alnasls, the club's own box and the hosted server, say. The same step again joins the next one. The bridge keeps a list, and each server has its own key and its own place in the bridge's queue.

- A server that is down holds up nobody else.
- An event leaves the bridge's queue only when every server has acknowledged it.
- Commands from two servers can contradict each other. The bridge applies them in the order they arrive, and only a server the bridge joined as owner may make it forget a board or a port.

## What you can do to a bridge from Alnasl {#ports-and-commands}

While a bridge is connected, its panel lists the ports it sees and the boards on them.

| Button | What it does |
| --- | --- |
| Read | Starts reading a port on the bridge |
| Read again | Asks the line again who is on it |
| Forget | Stops reading a port on the bridge (it asks first) |
| Send every board again | The bridge sends what it has of every board from the start |

If a command cannot be done, the panel says so in words: "The bridge is not connected.", "The bridge does not know that.", or what the bridge itself answered.

## When the line drops {#line-drops}

Nothing is lost. The bridge writes every event to a queue on its own disk, numbered, before it sends it, and removes it only when the server says it has it. A bridge that is not connected keeps reading and recording the boards. On the server, the bridge shows as "not connected".

When the line is back, the bridge sends what it missed, in order. The server ignores what it already has. After a long outage it does not replay every position on the live view: it feeds the moves to the tracker in order and then shows where the game stands.

A bridge that is switched off by accident is the same: switch it on, and it carries on from where its queue says it was.

## Removing a bridge {#removing}

"Remove" ends the bridge here and on the bridge itself, and its boards go with it. Removing this server on the bridge's page does the same from the other end, and either side ends the link for both.

A bridge that was removed can join again with a new link. It comes back as the same bridge, with a new key. Losing a bridge is one Remove on the server. A bridge that is still in a hall is not taken by the link of another hall: the server refuses it, and the bridge's page says it is not a server it can join. Remove it from its hall first, or let an admin move it (below).

## Moving a bridge to another hall {#moving}

An admin can move a bridge to another hall. Its boards follow, into that hall's own tournament, without table numbers: they have to be numbered again.
