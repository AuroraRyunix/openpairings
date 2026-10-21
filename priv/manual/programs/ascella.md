# The hall's installer

Ascella installs, updates, starts and stops the hall's programs on one
computer. Those are OpenPairings, Alnasl, Arkab, Polis and Nunki, each a
tile on one local page (the version installed, the version out, whether it
runs), with an *Update all* button. Every download is checked against its
release's checksums before it is run, and Ascella never touches a program's
data: not on an update, not on a rollback.

**When you need it.** When one computer in the hall runs several of these
programs and you would rather keep them current from one page than from five
installers. It refuses to update a program that is open, so an update never
lands in the middle of a round. Using OpenPairings on the hosted server only,
you do not need it.

**Where it fits.** It installs [Alnasl](/help/other/alnasl),
[Arkab](/help/other/arkab), [Polis](/help/other/polis) and
[Nunki](/help/other/nunki), and OpenPairings itself; how OpenPairings is
installed and updated without it is in
[Getting started](01-getting-started.md#installing-the-desktop-build).
