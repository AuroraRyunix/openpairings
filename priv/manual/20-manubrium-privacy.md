# Manubrium privacy policy

*Effective 2026-10-21. Applies to the Manubrium app for iOS and Android.*

Manubrium is a phone app for running a chess tournament that is managed
on an [OpenPairings](https://pairings.cloud) server. The app is a client:
it has no servers, no accounts and no analytics of its own.

## What the app talks to

Only the OpenPairings servers you add to it yourself, by scanning or
pasting a connect link from your account page on that server. Nothing is
sent anywhere else. There is no third-party software development kit in
the app, no advertising and no crash reporting.

Connections use HTTPS. Plain HTTP is accepted only for a server on a
private network address (the hall's own network, where a copy of
OpenPairings runs on a laptop in the same room), because such a server
has no certificate; the app refuses plain HTTP to any public address.

## What the app stores on the phone

- **A device token for each server you added**, issued by that server
  when you connected, in the iOS Keychain or the Android Keystore. It
  identifies this phone to that server and nothing else. Removing the
  server in the app deletes it; the account page on the server can revoke
  it at any time, after which the phone is signed out.
- **The server's name and address, and the name and role your account
  has there**, as the server reported them, so the app can show them.
- **An outbox** of results and incidents entered while the phone had no
  connection, until the server has accepted them.
- **The current round and standings** of the tournament you have open,
  as a cache.

Deleting the app deletes all of it.

## What the app sends to a server

What you enter: results, incidents with their text and, when you attach
one, a photo; pairing, publishing, player, bye and settings changes, new
tournaments, and the names you search for in the rating lists, when your
role allows them. Each is sent to the one server the tournament lives on,
under your account there. That server's operator is the controller of
that data; the server's own privacy terms apply to it (for the hosted
service at pairings.cloud, its terms page).

## Camera and photos

The camera is used to scan the QR code that connects the app to a server
and, when you choose, to photograph an incident (a scoresheet, a clock)
for the arbiter's log. The photo library is read only when you pick an
existing photo for an incident. No image leaves the phone except as that
incident attachment, to that server.

## Local network

On iOS the system asks once before the app may talk to devices on the
local network. The app needs it only to reach a copy of OpenPairings on
the hall's own network. Refusing it leaves the hosted service reachable.

## Children

The app is made for tournament arbiters and organisers and is not
directed at children.

## Changes and contact

Changes to this policy appear in the app's repository history at
[github.com/teapot-chess/Manubrium](https://github.com/teapot-chess/Manubrium)
and on this page with a new effective date. Questions: the contact
address on [pairings.cloud](https://pairings.cloud).
