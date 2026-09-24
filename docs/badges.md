# Accreditation badges

`/badges` designs and prints accreditation badges for a chess event: A6 cards
(105 x 148.5 mm), front and back, printed two to a portrait A4 sheet. It was
ported from the stand-alone "handoff-badgemaker" Phoenix app; the rendering is
the same, the storage, access control and tournament import are OpenPairings'.

Signed-in only. Everything belongs to one user: another account cannot list,
open, print or fetch the images of your events, and gets a 404 if it tries.
On a local (desktop) install the owner is always signed in, so it simply works.

## What a badge shows

**Front:** the event emblem, name, subtitle, city and year; the photo in a
39 x 49 mm box; first and last name, with title, federation and FIDE ID on a
small line underneath; the role banner in the role's colour; the numbered
rooms or zones (1 to 12), filled black where the badge gives access; the left
footer logo (FIDE unless replaced), the QR code and the right footer logo.

**Back:** the same header, the usage conditions under their own heading, the
QR code with every room's number and name (the badge's own rooms in bold),
and the two footer logos.

All printed text - role names, room names, the conditions and their heading -
is set per event and not translated by the app: a Belgian event writes
"SCHEIDSRECHTER / ARBITRE" itself. The defaults are English.

## Pages

| Page | Route | Reached from |
|---|---|---|
| Badge events, and "New badge event" | `/badges` | Tools page (signed in), or a tournament's Advanced menu → Badges |
| Badge list, import buttons | `/badges/:id` | the events list |
| Badge editor with live preview | `/badges/:id/badge/:badge_id` | a name in the list, "Add badge" |
| Event settings | `/badges/:id/settings` | "Event settings" |
| Print sheets | `/badges/:id/print` (`?badge=ID` for one) | "Print all", the printer icon on a row, "Print this badge" |

`/t/:id/badges` (the tournament's Advanced menu, and the "Badges…" row on its
Print page) opens the user's badge event for that tournament, or the new-event
form with the tournament already picked.

The print page is a standalone document like the ones in
[`printing.md`](printing.md): it opens the browser's print dialog on load.
Print at 100% with no margins; cut along the dashed line across the middle and
fold each half on the dashed line down its centre.

## Data model

Migration `20260924075805_create_badge_events_and_badges` adds two tables and
changes nothing else, so it is safe on an existing database; its `down` drops
both.

`badge_events` - one per event:

| column | |
|---|---|
| `user_id` | owner (cascade on user delete) |
| `tournament_id` | optional link; set to NULL if the tournament is purged |
| `name`, `subtitle`, `organiser`, `city`, `year` | header and conditions text |
| `qr_url` | what the QR code on both sides encodes (empty: no QR code) |
| `conditions_title`, `usage_conditions` | back of the badge; `$tournament-name` and `$organiser` are filled in when printing |
| `room_count`, `room_names` | 1-12, and a map `"1" => "PLAYING HALL"` |
| `roles` | list of `%{"key", "label", "color"}`; the keys `chief_arbiter`, `deputy_chief_arbiter`, `arbiter` and `player` are what imports use and cannot be removed |
| `emblem_*`, `logo_left_*`, `logo_right_*` | the three logos, as `_data` blob + `_content_type` |

`badges` - one per person:

| column | |
|---|---|
| `event_id` | cascade on event delete |
| `first_name`, `last_name`, `title`, `federation`, `fide_id` | printed on the front |
| `role`, `role_color` | the banner's text and `#RRGGBB` colour (copied from the event's role when chosen) |
| `room_access` | list of room numbers |
| `photo_data`, `photo_content_type`, `photo_source` | the photo; source `upload` or `fide` |
| `photo_fetched_at` | last "Fetch from FIDE" attempt |
| `source` | `player`, `official` or `manual` |
| `source_player_id` / `source_official_slot` | what an import matches on (unique per event) |
| `edited_fields` | imported fields changed by hand |

The context is `PairingsEngine.Badges`; every function takes the caller's
scope first.

## Linking and importing

An event can stand alone or link to one tournament. Only tournaments the user
may open can be linked - `Tournaments.get_authorized_tournament/2`, the rule
every tournament page uses (owner or accepted collaborator) - and the check is
repeated on every import, so losing access also stops the import.

Imports are explicit buttons on the badge list.

**Import players** makes one badge per player of the tournament:

| badge | from |
|---|---|
| first / last name | `player.name`, split at the comma ("Carlsen, Magnus"), else at the first space |
| title, federation | `player.title`, `player.federation` |
| FIDE ID | `player.fide_id` |
| role | the event's `player` role |
| rooms (new badges only) | room 1 |

**Import officials** makes one badge per named official, from the same data
the FIDE reports use ([`norms.md`](norms.md), "Officials"):

| slot | name | FIDE ID | role |
|---|---|---|---|
| `chief` | `tournament.chief_arbiter` | `officials["chief_arbiter_fide_id"]` | `chief_arbiter` |
| `deputy1`, `deputy2` | `officials["deputyN_name"]` (deputy 1 falls back to the old `deputy_arbiter` field, as SWAR imports fill it) | `officials["deputyN_fide_id"]` | `deputy_chief_arbiter` |
| `arbiter1`..`arbiterN` | `officials["arbiterN_name"]`, N up to `extra_arbiters_count` | `officials["arbiterN_fide_id"]` | `arbiter` |

Title and federation come from the local FIDE rating list when the official's
FIDE ID is in it. New official badges open every room. A slot with no name is
skipped.

### Re-importing

Running an import again updates badges in place, matched by player id or by
official slot, and never creates a second badge for the same player or slot.
It never touches:

- manual badges (added by hand, or duplicated from another badge);
- a field listed in the badge's `edited_fields`;
- room access, and the badge's existence: a player removed from the tournament
  keeps their badge until you delete it;
- an uploaded photo. A photo fetched from FIDE is dropped when the slot's FIDE
  ID changes, since it would now be somebody else's face.

**How "edited" is detected:** it is recorded, not guessed. When you save a
change to one of the imported fields (name, title, federation, FIDE ID, role,
role colour) on an imported badge, that field's name is added to
`edited_fields`. The list shows such badges as "edited", and the editor has
"Use the tournament's data again", which clears the list and re-runs the
import.

## Images

Photos and logos are stored in the database, in the rows above - the same
approach as the tournament print logo (`Tournaments.set_logo/2`). There is no
upload directory: the images travel with the SQLite file, so the desktop app
keeps them in its data folder and a server deploy, a backup or a restore
carries them like any other data.

- Accepted: PNG, JPEG, GIF and WebP, recognised by the file's own signature
  (never its name or the browser's content type). SVG is refused.
- Photos: up to 1 MB and 2400 x 2400 pixels. Logos: up to 1 MB and 3000 x
  3000 pixels. The pixel size is read from the image header; nothing is
  resized.
- Uploads go through LiveView (`allow_upload`, one file, saved as soon as it
  arrives).
- Pages load images from `/badges/:id/photo/:badge_id` and
  `/badges/:id/logo/:slot`, owner-only, with a version parameter so the
  browser can cache them. That keeps a 400-badge list light and needs nothing
  beyond the existing `img-src 'self'` in the Content-Security-Policy.

## Fetch from FIDE

"Fetch from FIDE" in the editor reads the player's public profile page on
ratings.fide.com and stores the photo on the badge (`photo_source = "fide"`),
so it is fetched once; blank name and federation fields are filled in too, and
nothing else is overwritten.

It is only ever one explicit button press for one badge. Nothing fetches
photos in bulk, and an import never contacts FIDE. The guards:

- the button is disabled without a FIDE ID, while a fetch is running, and once
  a FIDE photo is stored (remove the photo to fetch again);
- each badge may ask FIDE once a minute, whatever the outcome
  (`photo_fetched_at`, stored before the request is made);
- each user may make 10 fetches a minute across all badges
  (`RateLimit` bucket `:fide_photo`);
- one press is one request (two when FIDE serves the photo as a separate file,
  which is only ever followed to a `fide.com` address); Req's automatic
  retries are off.

FIDE publishes no API for this, so it parses HTML
(`PairingsEngine.Badges.FideProfile`, Req + Floki). When the page no longer
has the name or photo where it used to, the editor says: "FIDE's profile page
has changed and the photo could not be found on it. Please upload the photo by
hand." Unknown IDs, a profile without a photo, FIDE being down and a photo
that is not a usable image each get their own message; none of them raise.

Tests stub every request with `Req.Test`
(`config :pairings_engine, :fide_profile_req_plug`), so the suite never
reaches ratings.fide.com.

## What was ported, and what was cut

Ported nearly as is: the card, graphics and print-sheet components (now
`PairingsEngineWeb.BadgeCard`, `BadgeGraphics`, `BadgePrintSheet`) with their
sizes, the watermark backgrounds and the FIDE logo (`/images/badges/`), the
role presets and default conditions.

Cut: the badge maker's own accounts and JSON store (replaced by the app's
login and the tables above), its A5 single-badge print mode, the unused
`badge_assets` SVG tiles, the Phoenix logo used as a placeholder emblem, the
KBSB logo as a default right-hand logo (upload it per event), the "sample
players", and the image `onerror` handlers (inline script, which the app's
CSP blocks anyway).

Personal data: badge photos are personal data and live until the badge or
event is deleted; unlike tournaments they are not purged on a schedule.
