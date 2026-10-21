# The Manubrium app

Manubrium is a phone app for running a tournament from the playing hall. Its
home screen is the current round: tap a board, tap the result. It keeps
working when the hall's signal does not, and sends what you entered once it
can. The organiser and editors can also pair the next round, change the
pairings by hand, publish, look at the standings, change players and the
settings an arbiter touches mid-event. An arbiter on the tournament enters
results, logs incidents (with a photo if you like) and confirms or rejects
what Manubrium Lite phones entered.

One app can hold several servers - pairings.cloud, a club's own server, the
desktop copy on the hall's laptop - and switch between them.

> [!NOTE] Manubrium or Manubrium Lite?
> Manubrium Lite is the result page a phone opens from a Phone QR code
> ([Results](07-results.md)), in the browser, with no account and nothing to
> install. The app is for the people who run the tournament: it needs an
> account on the server and does more than results.

> [!WARNING] A first build
> The server side is built and tested. The app itself has not yet been
> through the App Store or Google Play; until it has, it is installed by hand
> from its own build.

## Connecting the app {#connecting}

1. On the server, open your account page (your name, top right, then
   **Account**) and go to **Manubrium app**.
2. Click **Connect a phone**. A QR code appears, with the same thing as a
   link under it.
3. In the app, tap **Add a server** and scan the code. If the camera cannot
   be used, copy the link and paste it in instead.
4. The phone appears in the list on the account page, with its name and the
   last four characters of its token.

The code works once, for ten minutes, and is shown only that one time. If it
runs out, click **Connect a phone** again. Each phone gets a code of its
own: two phones cannot share one.

A connected phone can do what your account can do, in the tournaments you
work in, and nothing more. If someone takes you off a tournament, the phone
loses it at the same moment.

## On a desktop copy {#desktop}

The desktop version has no accounts and listens only on the computer itself,
which a phone cannot reach. So connecting takes one step more:

1. In any tournament, open **Phone QR** and switch on **Let phones on this
   network connect**. Pick the computer's address on the hall's network.
2. Then make the code on the account page as above. The code points the app
   at that address, not at the computer's own one.

The phone has to be on the same network (the hall's Wi-Fi). Without the
switch, the account page refuses to make a code and says why.

## What the app can do {#what-it-does}

| | Organiser, editor | Arbiter |
| --- | --- | --- |
| See the round, enter and clear results | yes | yes |
| Confirm or reject a result from a Manubrium Lite phone | yes | yes |
| Log incidents, with a photo | yes | yes |
| Look at incident photos, add one to a logged incident | yes | no |
| Pair the next round, undo the latest round | yes | no |
| Change the pairings by hand, finish hand edits | yes | no |
| Publish a round (pairings, results, standings) | yes | no |
| Standings, with the tournament's tie-breaks | yes | no |
| Late entries, withdraw and re-enter, rounds off, basic player fields | yes | no |
| Mid-event settings | change | no |

Results entered without a signal wait on the phone and go when it can. If
somebody else changed the same board in the meantime, the app does not
overwrite it: it shows what the board says now and leaves the decision to
you. Everything else - pairing, hand edits, publishing, players, settings -
needs a connection, and the app says so.

Some questions are answered at the desk, never from a phone: the
pairing-number question, leaving FIDE mode, bye exclusions, pairing while a
round's hand edits are still open, a round robin's schedule, and team
events. The app says which one and leaves the round unpaired.

## Changing the pairings by hand {#hand-edits}

The same hand edits as on the Pairings page ([Pairing a round](06-pairing.md)),
from the round screen:

- **Swap two players.** Tap a board, **Change the pairing**, **Swap with
  another player**, and pick the other one: on another board, on the same
  board (a colour swap), or someone not on a board at all (a substitution).
- **A player is not playing.** **Not playing this round** empties the seat.
  Where the tournament asks the bye type, pick it; otherwise the player is
  absent.
- **An empty seat.** Tap the board: give the remaining player the bye, fill
  the seat from the players not on a board, or swap them elsewhere.
- **Not on a board.** Under the boards, tick two players to pair them on a
  new board, or one to give the bye. An empty last board can be removed.
- **Finish hand edits** checks the round, as at the desk. If the pairing
  checker would pair it differently, the app shows its boards and keeps
  yours only when you say so; the difference is recorded with the round.

When the desk would ask something first - the round is not the latest, it
was already sent for rating, the new boards break a pairing rule, a second
half-point bye - the app asks the same question with the same sentences,
and changes nothing until you answer. Team events are changed at the desk.

## Results from Manubrium Lite phones {#lite-results}

A result entered on a Manubrium Lite phone shows on its board with
**Phone**, and a line above the boards counts how many wait for a look. Tap
the board: it says which phone entered what. **Confirm** keeps it and marks
it checked; **Reject** clears the board, and the audit trail says which
phone's result you turned down. If the board changed in the meantime, the
app says what it shows now and does nothing. Results you, or another arbiter
with the app, enter are your own and need no confirming.

## Incident photos {#photos}

When you log an incident, **Take a photo** adds one: the camera on the
phone, shrunk before it is sent. It waits with the incident if there is no
signal. The organiser and editors can add a photo to an incident logged
earlier (**More**, **Incidents**, **Add photo**) and look at one
(**Photo**). An incident has at most one photo; only JPEGs of a sane size
are taken. Photos are never public, and an arbiter's phone can send one but
not open anyone's.

## Settings from the phone {#settings}

**More**, **Settings**, **Change the mid-event settings**: the time
control, the chief and deputy arbiter, the venue and city, the number of
rounds, what the pairing bye scores, whether the bye type is asked, shared
places and the tie-breaks. Anything the tournament has locked by now - in
FIDE mode the rounds, the bye's value and the tie-breaks once round 1 is
paired - is shown greyed out, and the server refuses it with the same
sentence as the Settings page. Everything else in the settings stays at the
desk.

## Signing a phone out {#signing-out}

On the account page, under **Manubrium app**, click **Sign out** beside the
phone. It is refused from its next request on; results it had not sent yet
stay on the phone, unsent. The app can also sign itself out. Do this for a
phone that is lost, sold or handed to somebody else.
