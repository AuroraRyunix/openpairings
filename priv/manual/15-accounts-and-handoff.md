# Accounts, sharing, hand-off and backups

## Accounts (online)

On a server, everyone has an account. You sign in with an e-mail link (a
one-time link sent to your address), a password, or the organisation's single
sign-on where the installation uses one. The log-in page also registers a new
account. Every tournament belongs to the account that created it. The desktop
build has no accounts: it signs you in as the owner of that computer.

**Account menu** (your name or address, top right):

- **Settings** (online only): the account page.
- **Features**: the switches of the national features (below).
- **Log out** (online only).

### The account page

Account, **Settings** (`/users/settings`). One page with a section for each of:

| Section | What it does |
| --- | --- |
| Profile | A display name, shown instead of the address in the audit trail, the history, sharing lists and invitations. |
| Sign-in & security | Change the address (a confirmation link goes to the new one), set or change the password, see the browsers that are signed in, and *Sign out* one or *Sign out everywhere else*. |
| Preferences | Language, colour theme and accent, stored on the account so that they follow you to another computer. |
| New tournaments | What the New tournament form starts with: system, rounds, format, rate of play, place, federation, organiser and how rounds are published. |
| Federation features | The switches below. |
| Your data | One zip with your account data and a backup of every tournament you can open. |
| Delete account | Typed confirmation; refused while the account owns any tournament (on the list, archived or in the recycle bin). |

Changing the address or password, ending sessions, downloading everything and
deleting the account ask for a recent sign-in (within the last twenty minutes);
you are taken to the log-in page and brought back. Accounts on an organisation's
single sign-on keep the address and password with the organisation.

### National features

Account, **Features**. The parts of the program that belong to one federation
are separate switches, all off by default. At the moment they belong to
the Belgian pack: the national rating list sync, the national player lookup,
the bulk club update, SWAR import, SWAR export, the SWAR results page, the
next-round preview and the bye preferences. An arbiter outside Belgium never sees any of them. Switching a
feature off only hides its controls: a tournament that used it keeps all its data.

### Limits on a shared server

A server is shared by every account on it, so it keeps one account from
taking all of it. The limits are generous; an ordinary tournament never
meets them. The desktop build has none.

| What | Limit |
| --- | --- |
| Tournaments one account owns | 200 (the recycle bin does not count) |
| Files read on the Tournaments page (backup, TRF, SWAR, hand-off, *Duplicate*) | 20 an hour per account |
| New phone codes ([Phone entry](07-results.md)) | 40 an hour per account |
| Rounds paired at the same time, on the whole server | 2 |
| Time one pairing may take | 3 minutes |

The server's administrator can change the tournament count, the number of
rounds paired at once and the time limit. When the server is already pairing
other tournaments, a team Swiss round waits its turn and the button says it
is queued; an individual round that cannot start within a few seconds says
the engine is busy, and pressing the button again a moment later pairs it. A
round that is already being paired, from another tab or by a co-arbiter, is
not paired a second time. A pairing stopped at the time limit, or refused,
leaves nothing behind: the round is still waiting to be paired.

## Sharing a tournament

The owner can invite other arbiters. Settings, **Tournament**, card
**Share / Team**: enter an e-mail address and **Add collaborator**.

- The invitation grants no access by itself. The person receives an e-mail
  with a link (`/invites/…`) and must be signed in with that address and press
  **Accept** (or **Decline**). Pending invitations are also listed on the
  Tournaments page. If the e-mail could not be sent, the page shows the link to
  pass on by hand.
- A collaborator can do everything the owner can except managing collaborators
  and deleting the tournament.
- Everyone sees changes as they happen: when a colleague pairs a round or
  enters a result, your pages update by themselves. When it was a round that
  changed (paired, unpaired, paired again, published or withdrawn from
  publication) on the Pairings or Players page, a short notice says so, for
  example "Round 4 was just paired elsewhere"; the session that did it
  hears nothing, and the notice never names a person. That includes the audit
  trail: a row written while you have it open appears within a moment, on the
  page and filter you were looking at, and every collaborator sees the same
  rows as the owner.
- The owner can remove a collaborator; a collaborator can **Leave** a shared
  tournament from the list. Either way, the hall-box codes that person made
  for the tournament are withdrawn with them ([Live boards](17-live-boards.md)),
  and a code someone made only works while they can still open the tournament.

## The tournament list

**Tournaments** lists every tournament with its pairing system, number of
players, dates and status. Each row has one **More** menu with these actions
(the name still opens the tournament; **Delete** or **Leave** is last, in red):

| Action | What it does |
| --- | --- |
| Export | The tournament as a JSON file ([Import and export](10-import-export.md)). |
| Copy | A whole new tournament named *Copy of …*, with everything in it (settings, players, rounds, results), owned by you. It is not published and has no collaborators. |
| Archive | Makes the tournament read-only (no more rounds can be paired and nothing changed); *Unarchive* undoes it. The page says how many postponed games are still unplayed. |
| Delete | Moves the tournament to the **Recycle bin** after you type `DELETE`. |
| Hand off / Give back / Bring it back | See below. |
| Leave | For a shared tournament that is not yours. |

The **Archived** table below the list has the same **More** menu on each row, with *Export*, *Unarchive* and, last in red, *Delete* or *Leave*.

The **Recycle bin** lists deleted tournaments; **Restore** brings one back.

> [!WARNING]
> **Delete permanently** removes a tournament from the bin for good (after
> confirmation).

A tournament with postponed games still open shows that the standings are
provisional.

## Hand-off: moving a tournament between two computers

A hand-off moves a tournament from one copy of the program to another, for
example from a server to the arbiter's own laptop at the venue, as a
**checkout**: the tournament is live in exactly one place at a time. Nothing is
merged, because two copies that both took results cannot be reconciled.

1. On the machine that has the tournament, **Hand off**: type where it is
   going (*the club laptop*), and press **Hand off and download the file**.
   The tournament on this machine becomes **read-only**, with a banner on
   every page that says where it went and a button **Bring it back**; you can
   still view, print and export it. The file is downloaded.
2. On the other machine, **Receive a hand-off** and choose the file. The
   tournament is live there, marked *on loan*.
3. When the event is over, on the second machine **Give back**: it makes a
   *return file* and locks that copy.
4. On the first machine, **Bring it back** with the return file: the copy here is
   replaced by what was played on the other machine and unlocked. A restore point
   of the frozen copy is saved first; if it cannot be saved nothing is replaced.

What travels: the settings, players, rounds, results, byes, teams, forbidden
pairings and pairing rules, the audit trail and the record of what was sent to the rating office.
What does not: the restore points, the phones enrolled for result entry, and
the collaborators, who arrive as pending invitations. A hand-off file can also
be opened as an ordinary backup.

> [!WARNING]
> While a tournament is handed off, **Send…** for the rating report is refused
> on the locked copy, so that only one machine can send.

![The tournament list with the Hand off action and a handed-off tournament marked read-only](screenshots/15-handoff-list.png "The Tournaments page with a hand-off")

## Backups and restore points

- **Restore points** are copies of one tournament, taken automatically before
  an action that is hard to undo and by hand: Advanced, **History**
  ([Categories, norms and the Advanced tools](13-categories-and-norms.md)).
- **Backups of the whole database** are written by the program about once a day
  (the first a few minutes after the program starts, if the newest is older than a
  day) and kept for 30 days. They hold the tournaments, players, results,
  snapshots and settings, not the downloaded rating lists (these are fetched
  again). **Connections**, section *Backups* lists them (*Taken*, *Size*,
  **Download**) and has **Back up now**. The name of the folder that holds the
  older ones is shown there too.
- Settings, **Export** and the Tournaments page **Export all (JSON)** are backups you
  keep wherever you want.

> [!TIP]
> Before an important event, make sure that a current backup exists and that you
> can find it.

## Connections (the administrator's page)

**Connections** is for the person who runs the installation (on a desktop copy,
you). It shows the FIDE database and the national list with their update
buttons, the version, the backups, the update check (on or off) and the
connection to the results site ([Players and rating lists](04-players-and-ratings.md),
[Publishing](14-publishing.md)). On a server the page can be read by a support
role, but changes are made only by an administrator.
