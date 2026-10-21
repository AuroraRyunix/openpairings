# User manual

The user manual is in [`priv/manual/`](../../priv/manual/), one Markdown file per
chapter (`NN-slug.md`; `NN` sets the order). It is shown in the program under
**Help** (`/help`) and is compiled into the release from those files by
`PairingsEngine.Manual`, so there is one copy only and it ships with every
build. Edit the files there. A change shows after a rebuild, and a new or removed
chapter file is noticed by the compiler.

Chapters link to each other as ordinary relative links
(`[Printing](09-printing.md)`), which work on GitHub and become `/help/printing`
in the program. Each chapter has a Dutch translation in `priv/manual/nl/`, with the
same section ids; the page around it is translated through gettext.

The contents are grouped in parts (Preparing the tournament, Round by round,
Reports and exports, Team tournaments, Publishing and sharing, Live boards,
Manubrium). Which chapter is in which part is `@parts` in
`PairingsEngineWeb.HelpLive`, by slug: a new chapter goes there too, and the
file is numbered so that its part still reads in order.

The other programs (Ainalrami, OpenResults, Alnasl, Arkab, Polis, Nunki,
Ascella) have their own pages under `/help/other/`. Their text is vendored by
`mix help.sync_family` into `priv/manual/family/`; the introduction above each
one is written here, in `priv/manual/programs/` (see
`PairingsEngine.Manual.Family`).
