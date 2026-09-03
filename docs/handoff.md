# Hand-off (moving a tournament between machines)

Moves a whole tournament between two copies of OpenPairings - a hosted
server and an arbiter's own laptop, most often - as a **checkout, not a
sync**. Everything lives in `PairingsEngine.Handoff`, built on top of
`PairingsEngine.Tournaments.hand_off/2` / `take_back/2` (the lock itself)
and reusing `PairingsEngine.TournamentExport` / `TournamentImport` for the
file (see [`import-export.md`](import-export.md) for the envelope those two
produce and consume).

## The model: checked out, not synced

A tournament is **live in exactly one place at a time**, like a book checked
out of a library. Handing it off locks the copy left behind - read-only,
with a banner on every page saying where it went - and downloads a file.
Importing that file elsewhere makes the tournament live there. Giving it
back produces a second file that **replaces the original's contents with
whatever was played on the way, then unlocks it** - one transaction, so it
is never partly done.

**Nothing is ever merged, and that is not a limitation to be fixed later.**
Two copies that had both gone on accepting writes could not be reconciled
afterwards: one machine records 1-0 on board 4 and the other a draw, or both
pair round 6 and produce different boards. No rule picks a winner, because
the disagreement is not about data - it is about what actually happened in a
room, and an invented answer to "who won that game" is worse than a
refusal. So the design keeps the two copies from ever being live at the same
time, rather than trying to sort out the mess afterwards.

```
      A                                                   B
      hand off   -- lock A, produce a file -------->      receive        (B live)
                                                          ...event runs...
      take back  <-- returning file: the event, and the key --  give back      (lock B)
      (A live, and holding what was played on B)
```

## What travels, and what does not

A hand-off file is an ordinary `PairingsEngine.TournamentExport` envelope
(settings, officials, teams, every player field, rounds, pairings/results,
byes, forbidden pairings), built with `include_handoff: true`, plus one
extra `"handoff"` block carrying the unlock token. See
[`import-export.md`](import-export.md) for the exact shape.

| | Travels | How |
|---|---|---|
| Tournament content (settings, players, rounds, results, byes, forbidden pairings, teams) | Yes | Ordinary export/import, fresh ids throughout |
| Audit trail | Yes | Verbatim, oldest first - the acting user travels as an email string, never as an account link |
| Collaborators | As invitations | Filed as fresh, **pending** invitations - nobody gains access because a file arrived; each person accepts again |
| OpenResults publishing key | Yes, dormant | Filed as an offer (`openresults_claim`), not adopted automatically - see [`import-export.md`](import-export.md)'s note on why |
| **Helper phone enrolments** | **No** | Deliberately excluded from every envelope, hand-off included |
| Restore points (snapshot history) | No | The new copy starts with no history behind it |
| The lock itself (`handed_off_at`/`handed_off_to`/`handoff_token`/`handoff_origin`) | No | Excluded unconditionally - an imported or restored copy is always live |

**Helper phones deliberately do not travel.** A mobile enrolment
(`PairingsEngine.Mobile.Enrollment`) is a live access token: an 8-digit code
plus a session that lets a phone with no account enter results for this
tournament. A code minted on the hosted copy must not quietly start working
on somebody's laptop because a JSON file moved between them - the helper
holding that phone was given access to an event on *one* machine, not to
every copy of it that will ever exist. Handing a tournament over means the
new machine mints new codes and hands out new phones; the old ones simply
stop mattering when the old copy does. Re-enrolling costs one click per
phone (see [`mobile-results.md`](mobile-results.md)) - nothing an arbiter
cannot recreate at the venue.

**Collaborators travel as invitations, not as access.** The receiving
machine has no account matching a collaborator row from the source
instance, so carrying `user_id` or `status: "accepted"` across would either
dangle or - worse - hand the tournament to whichever unrelated person holds
that address *here*. Every collaborator arrives PENDING instead
(`PairingsEngine.Tournaments.add_collaborator/3`'s own shape - see
[`teams.md`](teams.md)) and has to accept again, exactly as if invited for
the first time. No email is sent by the import itself; the invitee finds it
on their own Tournaments page, or the owner can hand over the `/invites/:token`
link directly.

**The audit trail does travel**, and is the one exception to "nothing about
who-did-what survives the trip". It carries over verbatim - same actions,
same timestamps - because it is the tournament's own history, and a hand-off
is supposed to be a seamless continuation of the same event on a new
machine, not a break in its record. The acting user is written as an email
string rather than a link to an account, since a user id from the source
installation names nobody (or, worse, a real stranger) here.

## The lock and the banner

Handing a tournament off stamps `handed_off_at`/`handed_off_to` and mints a
fresh token; from that moment `PairingsEngine.Tournaments.ensure_writable/1`
- the same gate every write path in the app already funnels through, right
alongside the archived check - refuses every write with `{:error,
:handed_off}`. The tournament stays fully readable: viewing, printing and
exporting all keep working, because it is the record of an event still
running somewhere else.

Every authenticated tournament page shows a banner while the lock is on,
rendered once in the layout (`PairingsEngineWeb.Layouts`) rather than
per-page, so it can never be forgotten on one:

- **Handed away**: *"This tournament has been handed off to \<place>. It
  left this copy on \<time>, and is live there now. It's read-only here -
  every change is refused until it's handed back."* with a **Bring it back**
  button.
- **Received** (on a copy currently checked out to this machine, before it
  is given back): shown on the Tournaments page as an "on loan" badge with
  the origin, rather than a full-page banner - the copy is fully writable
  here, so there is nothing to warn about on every page.

The banner's button leads to the Tournaments page rather than unlocking
anything itself: taking a tournament back needs a file from the machine
that holds it, and that file has to be picked from somewhere - the
Tournaments page is where every other import already lives.

## Handing a tournament off

1. From the Tournaments page, **Hand off** (or **Give back**, on a copy that
   was itself received - see below) opens a modal explaining what does and
   does not travel, with a free-text **"Where is it going?"** field ("the
   club laptop", a hostname - whatever the arbiter will recognise later,
   since it becomes the banner's own wording on the copy left behind).
2. Submitting POSTs to `POST /t/:id/export/handoff`
   (`PairingsEngineWeb.ExportController.hand_off/2`) rather than going
   through the LiveView socket, because a download has to be a real HTTP
   response and a LiveView cannot hand the browser a file.
3. `PairingsEngine.Handoff.hand_off/3` locks the tournament and builds the
   envelope in **one transaction**: the lock is taken first, then the
   payload is built from the now-locked row. If building the payload fails,
   the lock rolls back with it - a tournament that is read-only here with no
   file anywhere else is a tournament nobody can run. Refused outright
   (before anything is locked) for a blank destination, an archived
   tournament, or one that is already handed off elsewhere.
4. The browser downloads `<tournament-slug>-handoff.json`.

A tournament already received from somewhere else (call it B, received from
A) can be sent on again to a third machine C instead of straight back to A -
the modal offers both: "Give it back to A" right above the ordinary hand-off
form, with a hint that sending it on to C is also possible. Forwarding to C
is a plain hand-off like any other - it mints B a brand-new token for C and
locks B, exactly as if B were the original source. What it does *not* do is
touch B's own record of having come from A (`handoff_origin`, excluded from
every export - see [`import-export.md`](import-export.md)): that stays right where it is,
untouched by however many more machines the tournament passes through next.
So the key that lets B give the tournament back to A is not carried inside
the file sent to C at all - it stays dormant on B's own row and simply
becomes usable again the next time B holds the tournament live, whether that
is because C gave it back or because B's owner forced the lock open.

## Receiving a hand-off

**Receive a hand-off**, on the Tournaments page, opens a dedicated upload
panel (separate from the ordinary "Import backup (JSON)" panel, though see
below for what happens if the wrong one is used). Submitting calls
`PairingsEngine.Handoff.receive/2`, which:

1. Confirms the file actually has a `"handoff"` block with a token - an
   ordinary backup has none, and is refused outright as *"That is not a
   hand-off file"* rather than quietly imported and treated as a checkout of
   nothing.
2. Confirms the file describes exactly one tournament - a hand-off moves one
   event, and a multi-tournament export carries one token that cannot say
   which of them it belongs to.
3. Confirms this machine has not already received this exact hand-off
   (matched by token, constant-time compare, across the whole installation
   including the Recycle bin) - importing twice would produce two live
   copies of the same event on the same machine.
4. Runs the ordinary `TournamentImport.import/2` (fresh ids throughout,
   audit log and collaborators carried in as described above), then records
   `handoff_origin` - who it came from and the token that will unlock them
   later.

If the write that records the origin fails, the newly imported tournament is
soft-deleted rather than left behind live with no way to ever give it back -
a partially-received hand-off would otherwise strand the source locked
forever with nothing on this end able to release it.

**A hand-off file can always be opened as an ordinary backup instead** (the
"Import backup (JSON)" panel accepts it too, since it is a valid export
envelope with one extra block that route ignores) - useful for recovering
the data on a machine that only needs a look, not the checkout. **The
reverse is not true**: an ordinary backup has no token, so there is nothing
for "Receive a hand-off" to find, and it is refused rather than treated as a
checkout of an event that was never locked anywhere.

## Giving it back, and bringing it back

These are two different actions with two different files, because a
hand-off is not symmetric - only one side is currently locked:

- **Give back**, on the machine currently holding a *received* tournament,
  produces the file that unlocks the source. `POST
  /t/:id/export/handoff/return` locks *this* copy (same one-transaction
  pattern as handing off) and downloads `<tournament-slug>-return.json`. No
  destination is asked for - a return goes back where the tournament came
  from, read off the row itself.
- **Bring it back**, on the machine that originally handed the tournament
  away, is where the returning file is uploaded - and it does more than
  unlock. `PairingsEngine.Handoff.release/3` **replaces this copy's
  contents with what came back, then unlocks it, in one transaction**: all
  of it or none of it. That is safe *because* the source was read-only for
  the whole trip - `ensure_writable/1` refused every write here while
  `handed_off_at` was set - so it cannot have diverged from what went out,
  and replacing it wholesale loses nothing.

  The order inside that transaction matters:

  1. A **pinned restore point** of the current, frozen state is captured
     first, before anything else is touched - the one way an arbiter who
     applies the wrong file, or who simply wants to see what was here
     before, gets it back. Unlike every other snapshot in the app, this one
     is *not* fire-and-forget: if it cannot be written, the whole release is
     refused outright with `{:error, :no_restore_point}` rather than
     proceeding without it. It is the only copy of what is about to be
     destroyed, and refusing costs the arbiter nothing - the file is still
     in their hands and this copy is still locked.
  2. The frozen contents are wiped and the returning envelope's tournament
     is imported into the row that is already there
     (`PairingsEngine.Snapshots.wipe_contents/1` then
     `PairingsEngine.TournamentImport.restore_into!/2` - the same pair a
     restore point uses to bring an *earlier* state of this same tournament
     back, just fed a different source here).
  3. `PairingsEngine.Tournaments.take_back/2` unlocks last, so the copy only
     becomes writable once its contents are already correct, never before.
     A bad token discovered here rolls back everything, contents included -
     the source stays locked and untouched.

  **Three things have to agree before any of that happens**, because the
  token only authenticates the *envelope* - it says nothing about the
  tournament sitting inside it, which is a separate block of the same file:

  - the envelope's echoed `handoff.returning_to.handed_off_at` must match
    this row's own `handed_off_at` - which departure this file claims to be
    returning from;
  - the payload's own audit trail must contain the `handoff.handed_off` row
    for that exact instant and destination - written by *this* machine
    before the outbound file was ever built, so it travels inside the
    tournament entry itself rather than the envelope wrapper. This is what
    binds the *body* to the claim: a returning file spliced together from
    two different exports cannot carry a departure row it was never present
    for;
  - and the token itself, compared constant-time, same as before.

  A file that fails one of the first two is refused as
  `{:error, :not_this_tournament}`; a bad token is `{:error, :bad_token}` -
  either way nothing is replaced.

**What still does not come home: the far side's audit trail.** The results
return; the record of who typed them over there stays in the file.
`TournamentImport.restore_into!/2` writes contents, not history, and
re-inserting the returning file's trail here would duplicate the prefix
that never left this machine in the first place. The departure and the
release are both on *this* copy's own trail already; the file itself
remains the only record of what happened on the other machine, for as long
as it's kept. That is a real limit, not a footnote.

**Releasing is not idempotent.** Applying the same returning file twice
fails the second time (`{:error, :bad_token}`), because the first attempt
already erased the thing the token is compared against - deliberately: by
the time somebody applies a file twice, the tournament may be legitimately
checked out somewhere else entirely, and silently succeeding would unlock a
copy that is in active use elsewhere.

**A force-unlocked tournament refuses a returning file outright**
(`{:error, :force_unlocked}`). See "The break-glass unlock" below for why:
after a break-glass, this copy is live and can have diverged, so both
copies may hold real work and replacing this one wholesale would destroy
some of it rather than recover it. The refusal names the safe route
instead: import the file as a separate tournament under "Import backup
(JSON)" and carry the missing results across by hand.

**Using the wrong file for a return is a mistake worth catching.** The
outbound (`-handoff.json`) and returning (`-return.json`) files can look
identical in a downloads folder, and only one of them unlocks or replaces
anything. Feeding the *outbound* file back into "Bring it back" is refused
(`{:error, :not_a_return}`) rather than accepted, because it carries the
same token and would otherwise unlock the source while the other machine is
still running the event on its own live copy - exactly the two-live-copies
state this whole feature exists to prevent. This check is a field in a JSON
file, so it stops an honest mix-up, not an attacker: anyone holding the
right file already holds the token.

## The break-glass unlock

`take_back/2` needs the token, and the token lives in exactly one place -
the copy the tournament was handed to. That is fine until that copy is
stolen, wiped, or lost outright, at which point the lock would otherwise be
**permanent**: the round this copy is holding can never be paired again and
the event is finished as a working document. A lock whose failure mode is
"the tournament cannot continue" has traded a recoverable problem for an
unrecoverable one, so an escape hatch exists.

On the Tournaments page, opening "Bring it back" for a handed-off tournament
reveals a folded-shut **"The copy this was handed to is gone"** panel
(`<details>`, deliberately not expanded by default) with:

- A plain statement of what forcing the lock does **not** do: the other copy
  still exists, still holds whatever it holds, and must never be opened
  again once this is used - anything entered there afterwards is lost, and
  nothing about this action makes that safe. It only removes the lock on
  *this* copy.
- A field requiring the arbiter to **type `UNLOCK` to confirm** before the
  button is even enabled - deliberately more friction than the ordinary
  take-back, because this is the one button on this screen that nobody
  should learn what it does by pressing it.

Rules, enforced in `PairingsEngine.Tournaments.force_take_back/2`:

- **Owner only.** A collaborator can pair and enter results, but abandoning
  a copy of a live event outright is not on that list; refused with
  `{:error, :not_owner}`.
- **Only on a tournament that is actually handed off** - refused with
  `{:error, :not_handed_off}` otherwise, so the button cannot be pressed on
  a live tournament to "see what it does".
- **Logged distinctly from an ordinary take-back**, as
  `"tournament.handoff_forced"` (`Tournaments.forced_unlock_action/0`)
  rather than `"handoff.released"`, in the same transaction as the unlock
  itself. When two divergent copies of a tournament surface months later,
  this row is the only record of which one was forced open - and it names
  who made that call, deliberately, since the decision to declare a copy
  lost has to be a person's and has to be answerable for later. The token
  itself is dead by then and is deliberately not written to the row, but a
  one-way digest of it is (`Tournaments.handoff_token_digest/1`, under
  `"was_handoff_token"`) - useless as a key, but the exact fingerprint of
  *which* trip was broken open.

**A forced unlock is not a permanent mark on the tournament - it marks one
trip.** Try to bring the tournament back from the copy this machine broke
the lock on, and the file is refused (`{:error, :force_unlocked}`, see
"Giving it back, and bringing it back" above) - both copies may hold real
work by then, and nothing here may choose between them. But if this copy is
handed off again afterwards, that second trip has been read-only for its
own entire length, so *that* trip's returning file applies normally when it
comes back; the digest is how `release/3` tells the abandoned trip from the
clean one that came after it, rather than refusing every return this
tournament ever produces again.

**When it is the right answer:** the other machine is genuinely gone -
stolen, wiped, factory-reset, the laptop is at the bottom of a canal - and
there is no way, ever, to produce a returning file from it. **When it is
not:** the other copy still exists and is merely unreachable right now (no
network, a forgotten password, someone on holiday with the laptop). Forcing
the lock in that case does not fix anything - it creates a second live copy
of the same event, which is precisely the state the whole design exists to
prevent, except now by the owner's own hand rather than by a bug.

## Routes and filenames

| Action | Route | Filename |
|---|---|---|
| Hand off | `POST /t/:id/export/handoff` | `<slug>-handoff.json` |
| Give back / bring it back | `POST /t/:id/export/handoff/return` | `<slug>-return.json` |
| Receive / take in | *(upload, no route of its own - `receive_handoff_file` on the Tournaments LiveView)* | - |

The kind is in the filename on purpose: the two files look identical in a
downloads folder otherwise, and only one of them unlocks or replaces
anything.

## What this is not, honestly

Four things worth knowing before trusting this feature with a real event:

- **Releasing replaces what is here, and the audit trail is the exception**
  (see above). Bringing a tournament back applies the returning file's
  contents and then unlocks, in one transaction - safe only because the
  source was read-only for the whole trip and so cannot have diverged. What
  does not come back is the far side's own audit trail: the results return,
  the record of who typed them over there stays in the file. A
  force-unlocked trip is the one case that refuses outright instead, because
  after a break-glass both copies can hold real work.
- **Nothing verifies the two ends are the machines they claim to be.** The
  "where is it going" / origin text is free-form and descriptive only; the
  token proves only that whoever holds it once held the file.
- **Nothing enforces the lock across machines.** The source refuses writes
  because its own database says so. Anyone with direct database access could
  clear the columns by hand; the lock protects against mistakes and against
  every code path this app exposes, not against its own administrator.
- **Helper phones and collaborator grants do not travel as live access** -
  covered above, and worth repeating here because both are usually
  discovered at the worst possible moment (mid-tournament, on the floor)
  otherwise.

### The token proves possession, not exclusivity

Stated plainly, because it is easy to read "checked out like a library book"
as a stronger guarantee than the system actually makes: **the hand-off token
proves that whoever presents it once held the file. It does not, and cannot,
prove that nobody else still does.**

Nothing stops the same `-handoff.json` file from being imported onto three
different machines - emailed to a co-arbiter "just in case", left on a
shared drive, copied to a second laptop as a backup-of-the-backup. Every one
of those imports would succeed, independently, and every one would produce a
live, writable copy of the tournament believing itself to be the only one.
`{:error, :already_received}` only catches a *second* import on the *same*
machine; it has no way to know what happened on a different one.

**"One live copy at a time" is therefore a convention the sending end
enforces on itself, not a property the system can guarantee.** The
*source* copy genuinely is locked and cannot itself be used to create a
second live copy by mistake - that half is real. What is not enforced is
what a person does with the file once it exists: whether they hand it to
one machine or five is entirely outside anything this feature can see or
stop. Treating the file like a credential (which it also is - it can carry
the OpenResults publishing key, see [`import-export.md`](import-export.md))
and not distributing copies of it "just in case" is the arbiter's discipline
to keep, the same way it would be for a physical key.
