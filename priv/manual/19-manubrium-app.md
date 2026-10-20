# The Manubrium app

Manubrium is a phone app for running a tournament from the playing hall. Its
home screen is the current round: tap a board, tap the result. It keeps
working when the hall's signal does not, and sends what you entered once it
can. The organiser and editors can also pair the next round, publish, look
at the standings and change players from it. An arbiter on the tournament
enters results and logs incidents, as at the desk.

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
| Log incidents | yes | yes |
| Pair the next round, undo the latest round | yes | no |
| Publish a round (pairings, results, standings) | yes | no |
| Standings, with the tournament's tie-breaks | yes | no |
| Late entries, withdraw and re-enter, rounds off, basic player fields | yes | no |
| Settings | read only | no |

Results entered without a signal wait on the phone and go when it can. If
somebody else changed the same board in the meantime, the app does not
overwrite it: it shows what the board says now and leaves the decision to
you. Everything else - pairing, publishing, players - needs a connection, and
the app says so.

Some questions are answered at the desk, never from a phone: the
pairing-number question, leaving FIDE mode, bye exclusions, hand edits to a
round, a round robin's schedule and team events. The app says which one and
leaves the round unpaired.

## Signing a phone out {#signing-out}

On the account page, under **Manubrium app**, click **Sign out** beside the
phone. It is refused from its next request on; results it had not sent yet
stay on the phone, unsent. The app can also sign itself out. Do this for a
phone that is lost, sold or handed to somebody else.
