# Screenshots for the manual

Every screenshot slot in the chapters, in reading order. There are none at the
moment: the chapters shipped with "Screenshot to come" placeholders for
months, and the placeholders were dropped. The renderer still supports slots, so
when a real picture is taken, add the slot to the chapter (EN and NL) and a row
to the table below. Until a file exists the manual shows a checkered placeholder
naming it; once the file is in place the placeholder becomes the picture (after
a rebuild, or a recompile in development).

**Where the files go:** `priv/static/images/manual/<file>` (served as
`/images/manual/<file>`). The chapters refer to them as
`![alt text](screenshots/<file> "caption")`; see `PairingsEngine.Manual.Markup`
for the convention.

**How to take them**

- Light theme (the default), accent unchanged, English interface, browser zoom 100%.
- Window size as listed: the inner size of the browser window (the page, not
  the window frame). 1280x800 unless the slot says otherwise.
- PNG. Crop to the window's page area: no browser chrome, no desktop.
- Use an invented tournament and invented player names, never a real event.
- A test file in `test/pairings_engine/manual_test.exs` checks that this list
  and the chapters name the same files.

| File | Chapter | Page and state to capture | Window |
| --- | --- | --- | --- |
