# The board bridge

Arkab carries the moves of electronic boards from the hall to Alnasl. It is
a small program on the computer the boards are plugged into, such as a
Raspberry Pi: it reads every board on its ports, writes each move to disk
before it sends anything, and passes the moves over an outgoing connection
to one or more Alnasl servers. Nothing in the hall's network has to be
opened for it.

**When you need it.** When the boards are in one place and Alnasl runs in
another: the hosted Alnasl server, which has no boards of its own, or a
second room of a hall. A box in the hall with the boards plugged straight
into it does not need a bridge. Joining one takes a link from Alnasl (the
hall's *Bridges* tab, *Add a bridge*), good for one bridge and fifteen
minutes, pasted into the bridge's own page.

**Where it fits.** Arkab only carries the boards; everything else happens in
[Alnasl](/help/other/alnasl), whose chapter on bridges is the other half of
this page. [Setting up electronic boards](18-setting-up-boards.md) covers the
whole chain from OpenPairings' side.
