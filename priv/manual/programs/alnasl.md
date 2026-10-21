# Live boards in the hall

Alnasl follows the games on the electronic boards of a playing hall. It
works out the moves from where the pieces stand and sends the moves and the
clock times to the results site while the games are played. Who plays whom
it learns from OpenPairings, and what each board saw goes back there, beside
the pairing. It never enters a result: a mate on the board is a suggestion
that you confirm.

**When you need it.** When the tournament has electronic boards and the
games should be followed live, in the hall or online. It runs on a box in
the hall with the boards plugged into it, which needs no internet, or as a
hosted server that takes its boards through a bridge. It also keeps every
game as text (PGN), and can screen the games for fair play, for the hall's
owner only.

**Where it fits.** [Live boards and Alnasl](17-live-boards.md) and
[Setting up electronic boards](18-setting-up-boards.md) are the OpenPairings
side. Boards that are not plugged into the computer running Alnasl reach it
through [Arkab](/help/other/arkab); the moves go to
[OpenResults](/help/other/openresults).
