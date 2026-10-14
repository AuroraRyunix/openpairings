# Theme packs

A theme pack is a theme that is not part of the program: a folder the program
finds at run time and offers in the theme picker after the built-in themes.
The user-facing description is in the manual, chapter 1, *Custom themes*. This
page is for whoever writes a pack or touches the code that loads one.

## Where packs are read from

`PairingsEngine.ThemePacks.dir/0`:

1. `PAIRINGS_THEMES_DIR` (`config :pairings_engine, :themes_dir`) if set and
   non-empty - the hosted edition;
2. otherwise, in local mode, `<data dir>/themes`
   (`config :pairings_engine, :local_data_dir`, set by `config/runtime.exs`);
3. otherwise nowhere: no packs.

Each subfolder holding a `theme.json` is a candidate. Nothing is installed by
default. The production deploy script copies every pack folder from the
sibling `openpairings_themes` repository to the server's
`PAIRINGS_THEMES_DIR`.

## The format

```
<id>/
  theme.json
  theme.css
  fonts/*.woff2     optional
  LICENSE, README   optional, never served
```

`theme.json`:

| key | required | rule |
|---|---|---|
| `id` | yes | `[a-z0-9][a-z0-9-]{0,39}`, equal to the folder name, not a built-in theme id |
| `name` | yes | at most 40 characters, shown in the picker |
| `name_nl` | no | Dutch name |
| `author` | yes | shown as the picker item's title |
| `version` | yes | free text |
| `dark` | yes | boolean; `true` sets `data-theme-dark` on `<html>`, which switches the core's dark-background accents, checkbox marks and `color-scheme` |
| `swatch` | yes | 3 or 4 `#rrggbb` colours, the picker preview |
| `users` | no | 1 to 100 email addresses (case-insensitive). When present, the pack exists only for those signed-in accounts: picker, bootstrap list and storable themes. Visitors never get it. The stylesheet URL itself stays public; nothing loads it for anyone else. An empty list is refused rather than read as "everybody" |

Limits: `theme.css` at most 200 KB, each font at most 1 MB, font names
`[a-z0-9_-]+\.woff2`.

## What the scanner refuses

`PairingsEngine.ThemePacks.Scanner.scan/2` tokenises the stylesheet (comments
become whitespace, strings stay whole, so neither can hide or fake a brace)
and refuses:

- `@import`, and any at-rule other than `@font-face`, `@keyframes`
  (also `-webkit-`), `@media`, `@supports`;
- `url()` pointing anywhere but `fonts/<name>.woff2`; `image-set()`,
  `-webkit-image-set()`, `image()`, `src()`, `element()`;
- `expression(`, `javascript:`, `vbscript:`, `behavior:`, `-moz-binding`,
  anywhere, strings included;
- a backslash outside a string (CSS escapes would let `@\69mport` past any
  text match);
- nested rules, unbalanced braces, unterminated strings or comments, invalid
  UTF-8;
- any selector whose first compound does not contain
  `[data-theme="<id>"]` (any quoting) or `:where(...)` / `:is(...)` of exactly
  that. So `:root[data-theme="x"]`, `html[data-theme="x"] body` and
  `[data-accent="blue"]:where([data-theme="x"])` pass; `body`,
  `.x [data-theme="x"]` and `[data-theme*="x"]` do not.

A refused pack is logged, left out of the picker and the allowed theme list,
and named under the picker with the reason. The Content-Security-Policy is
unchanged: pack CSS and fonts are same-origin files served by
`PairingsEngineWeb.ThemePackController` at `/themes/:id/theme.css` and
`/themes/:id/fonts/:file`, both whitelisted against the loaded pack and
answering 404 with an empty body to everything else.

## How the page uses it

The root layout carries `<meta name="op-theme-packs">` with
`[{id, dark, css}]` as JSON data (not interpolated into the script). The
bootstrap script adds the pack ids to the allowed themes and, only when a
pack is the chosen theme, inserts `<link id="op-theme-pack">` to its
stylesheet (versioned by a content hash) and sets `data-theme-dark` if it
says `dark: true`. A saved theme that is no longer installed falls back to
*System*, both in the browser and in `Preferences.theme?/1` on the server.

## Writing one

A pack is mostly a token block:

```css
[data-theme="mytheme"] {
  --bg: #f6f1e4; --surface: #fff; --surface-alt: #faf6ec; --surface-hover: #f0e9d8;
  --border: #c9bfa8; --text: #1d1a14; --text-soft: #5a5244;
  --accent: #1d40c8; --accent-hover: #1633a3; --accent-soft: #e3e8fb;
  --accent-ink: #fff; --accent-lift: ...; /* and the rest */
}
```

The full token list is in the manual. Tokens left out keep the Light theme's
values. Anything beyond tokens is ordinary CSS scoped as above; prefer
`:where()` around the part after the scope so the pack does not win
specificity fights it did not mean to.

Animation is allowed. Keep it inside the pack, switch it off under
`@media (prefers-reduced-motion: reduce)`, and leave tables of numbers
(standings, scores) alone: people read those.

## Checking one

```
mix pairings.theme_check path/to/mytheme
```

Loads the pack exactly as the program does (so every refusal above shows),
then runs `PairingsEngineWeb.ThemeContrast.pack_failures/4` - the same WCAG
rules `test/pairings_engine_web/contrast_test.exs` holds the built-in themes
to - against `assets/css/app.css` plus the pack, for every accent. It lists
each failing pair and exits non-zero if there is one. A pack that fails still
loads; the check is for its author.

## The first pack

`jorian`, the cartoon theme, lives in the separate `openpairings_themes`
repository beside this one, with its fonts (Bangers and Nunito, OFL) vendored
so it works offline.
