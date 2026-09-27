# The account page

`/users/settings` - `PairingsEngineWeb.UserLive.Settings`. One page, a card
per section, a rail of section links beside them (a row of chips on a
phone). `/users/features` opens the same page at the federation switches;
the account menu on a local install links that address, as it always has.

## Sections

In the order people look for things:

| Section | What it does | Stored in |
|---|---|---|
| Profile | A display name, shown instead of the address in the audit log, the history, the sharing list, pending invitations, the invitation page and the invitation email. Blank shows the address. | `users.display_name` |
| Sign-in & security | Change the address (confirmation link to the new one), set or change the password, and the list of browsers signed in to the account, with "Sign out" per browser and "Sign out everywhere else". | `users_tokens` (`user_agent` added so each session can be named, e.g. "Firefox on Windows") |
| Preferences | Language, colour theme, accent colour - stored on the account so they follow you. Saved as you choose. | `users.locale`, `users.theme`, `users.accent` |
| New tournaments | What the "New tournament" form starts with: pairing system, rounds, format, rate of play, place, federation, organiser, how rounds are published (and the delay for the timed mode). | `users.tournament_defaults` (JSON, `Accounts.TournamentDefaults`) |
| Federation features | The per-account switches of the national packs (was its own page). | `users.features` |
| Your data | One zip: `account.json` plus a backup of every tournament the account can open (`tournaments/`, `archived/`, `recycle-bin/`), each the same file Settings → Export gives. | - |
| Delete account | Typed confirmation (the account's own address), then the account is gone and every browser signed out. | - |

## Recent sign-in, per action

The page itself needs only an ordinary sign-in. The sections that can lock
somebody out or carry data away - changing the address or password, ending
other sessions, downloading everything, deleting the account - show a
"Confirm it's you" panel in place of their controls until the account has
signed in within the last twenty minutes (`Accounts.sudo_mode?/1`), and the
link takes you to the log-in page's re-authentication form (password, email
link or 02cloud), which brings you back here.

Every one of those handlers checks again, and so does
`PairingsEngineWeb.AccountController` for the download and the delete,
because a LiveView event is whatever the socket sends.

Rate limits (`PairingsEngine.RateLimit`), keyed by account:
`:email_change` (5 confirmation mails an hour - each goes to an address
somebody typed) and `:account_export` (5 zips per ten minutes - each
serialises every tournament).

## Three kinds of account

- **Hosted, local sign-in** - everything.
- **Hosted, address on the 02cloud domain** - the address and password are
  managed by 02cloud (and password sign-in is refused for that domain
  anyway), so those two forms are replaced by a line saying so. Sessions,
  data and deletion work as for anyone. An account on another domain that
  is also linked to 02cloud keeps both, and is told so.
- **Local install** - nothing signs in, so "Sign-in & security" and "Delete
  account" are not shown, and the download needs no recent sign-in. The
  account menu still links only `/users/features` on a local install; the
  page it opens now also shows Profile, Preferences, New tournaments and
  Your data.

## Language, theme and accent

`nil` is the default for all three and means "as before": the browser
decides the language, and each device keeps its own theme and accent in
its own localStorage.

- **Language** is a fact about the person. The top-bar picker
  (`LocaleController`) stores a signed-in pick on the account, and
  `Plugs.AccountLocale` (after the scope in the `:browser` pipeline) puts
  the account's language into the session on every request, so it follows
  the person to a borrowed laptop. "Automatic" on the account page stops
  that; each browser then keeps what it last used.
- **Theme and accent** are facts about a screen as often as about a
  person, so they follow the account only when chosen on the account page.
  "This device decides" (the default) leaves every browser alone. Once one
  is chosen there, the top-bar pickers change it everywhere
  (`POST /users/preferences/appearance`, which ignores a dimension the
  account does not store).

How a stored theme reaches a browser: `PairingsEngineWeb.AccountPreferences.html_attrs/1`
renders `data-account-theme` / `data-account-accent` on `<html>` and
`assets/js/app.js` applies them. **That needs one line in the root layout**
(`lib/pairings_engine_web/components/layouts/root.html.heex`), which is not
in this change:

```heex
<html lang={Gettext.get_locale(PairingsEngineWeb.Gettext)} {PairingsEngineWeb.AccountPreferences.html_attrs(assigns[:current_scope])}>
```

Without it the account page still applies a new choice in the browser it
was made in, and the pickers still write through - only the "another
device picks it up on its next page load" half waits for the line. For no
flash at all on that first load, the inline script can prefer the
attribute over localStorage (`setTheme(document.documentElement.dataset.accountTheme || store.get("phx:theme") || defaultTheme())`,
and the same for `setAccent`); `app.js` corrects it after load either way.

## Defaults for new tournaments

The form fields (system, rounds, format, rate of play, place) are
pre-filled and can be changed before Create; the rest (federation,
organiser, publish mode and delay) are added under what the form submits,
so the form always wins. Read fresh from the database when "New
tournament" is pressed, so a change made in another tab applies. Imports
(SWAR, TRF, backups, hand-offs) are not affected.

Deliberately not offered, and why (see `Accounts.TournamentDefaults`):
tie-breaks (the right list differs per type, and FIDE's default for the
type is applied), the pairing engine (a JaVaFo default would quietly
select the superseded C.04.3 for every event), the chief arbiter (a name
and a FIDE id kept together by the officials picker - half a default makes
a broken report), and scoring (per-event club choices; a new tournament
starts with FIDE's).

## Deleting an account

**Refused while the account owns any tournament** - on the list, archived,
or in the recycle bin - and for the database's only administrator.
`tournaments.user_id` cascades on delete, so deleting an owner would delete
their tournaments with no recycle bin in between, and there is no transfer
of ownership to offer instead. The page says how many are in the way and
links to the Tournaments page; every step there (download, delete, purge)
is an ordinary confirmed act.

When nothing is in the way (`Accounts.delete_user_account/1`, one
transaction):

- Tournaments shared with them stay with their owners. Their collaborator
  rows go, and each accepted one gets a "Left tournament" audit row
  (`details.reason = "account_deleted"`).
- Their past actions stay attributed: the address is written into each of
  their audit rows as `details.former_actor` before the foreign key nulls
  `user_id`, and the Audit page and History show it as "address (account
  deleted)". The TRF/JSON hand-off export carries the address, as it does
  for imported rows. (Restore points they made in other people's
  tournaments have no such column and show as "System".)
- Sessions and pending links go with the account and every open page is
  disconnected; badge events (the account's own) are deleted.
- The controller then signs the browser out (session and remember-me
  cookie).

## Hooks in the layout that are not in this change

`layouts.ex` and the root layout belong to other work. Two one-line
additions finish the picture:

1. The root layout attribute above (theme/accent following the account).
2. The account menu showing the display name: in `layouts.ex`, the
   summary's `{@current_scope.user.email}` becomes
   `{PairingsEngine.Accounts.User.display_label(@current_scope.user)}`
   (keep the email in `account-menu-who` and the `title`).
