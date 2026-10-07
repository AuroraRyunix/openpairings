# User manual

The user manual is in [`priv/manual/`](../../priv/manual/), one Markdown file per
chapter (`NN-slug.md`; `NN` sets the order). It is shown in the program under
**Help** (`/help`) and is compiled into the release from those files by
`PairingsEngine.Manual`, so there is one copy only and it ships with every
build. Edit the files there. A change shows after a rebuild, and a new or removed
chapter file is noticed by the compiler.

Chapters link to each other as ordinary relative links
(`[Printing](09-printing.md)`), which work on GitHub and become `/help/printing`
in the program. The text is English only; the page around it is translated.
