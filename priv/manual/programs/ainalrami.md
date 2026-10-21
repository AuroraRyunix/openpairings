# The pairing engine

Ainalrami is the engine that pairs every Swiss round in OpenPairings. It
follows the FIDE Dutch system (C.04.3, as it stands from 1 February 2026),
pairs team Swiss events (C.04.6) and computes the FIDE tie-breaks (C.07). It
is also a program of its own, run from the command line, that reads and
writes TRF files (TRF16 and FIDE's TRF26) and takes the same command-line
shape as JaVaFo.

**When you need it.** Inside OpenPairings, never: there is nothing to
install or choose, and the pairing button names it. This page is for the
times you want to pair a TRF file outside OpenPairings, check a round with a
second tool, or read how the engine was checked and where a question of the
rules is still open. Each release carries the ready-built `ainalrami` file,
which needs only Erlang/OTP 29 or newer.

**Where it fits.** [Pairing a round](06-pairing.md) is the arbiter's side of
it; the engine is named under *Swiss engine* in
[Creating a tournament and its settings](03-tournament-setup.md#options-page).
