# Accounts, halls and roles

Who may see and do what. On a box in a hall there are no accounts until you make one. On the hosted server there are always accounts, and you get one by invitation.

## Open until the first account {#open-until-the-first-account}

A box without accounts is open: everybody on the hall's network may do everything, behind the PIN if there is one. That is how Alnasl has always worked, and an update does not change it.

Under Setup, Access, "Accounts", you can make the first account. You become the box's owner and admin, and from then on every page asks who is there, the box's own screen included. The PIN has no say any more then.

> [!IMPORTANT] This switches the login on
> Make the first account when you are ready to sign in on every device in the hall, phones included. The phone sign-in below makes that painless.

## The hosted server {#the-hosted-server}

The server at alnasl.zerotwo.cloud reads no boards of its own, so there every page asks who is there, always. Accounts come **by invitation only**: nobody can register. The people the deployment names as admins sign in first, with 02cloud, and their account is made then. An admin invites the first owners of each hall; an owner may then invite people.

A 02cloud login alone gets nobody in. Only an invitation, or being named an admin, does.

## Halls {#halls}

The box's own ports are one hall. Every bridge belongs to a hall, and so do its boards and tournaments. An admin makes more halls on the Halls page. Each account sees its own halls and nothing of the others.

With more than one hall, the hall picker at the top of the rail says which one the pages are about, and how many of its boards are live. Press it for your halls, each with your role there and its live boards (a search field appears from seven halls on); picking one keeps you on the page you were on, now about that hall. "All halls" at the bottom opens the Halls page, which lists every hall in a table: your role in it, boards live, bridges connected, and what needs an arbiter.

A hall's own page has tabs, each with an address of its own: **People**, **Invitations**, **Bridges** and **Settings** (rename, delete). Invitations and Settings are an owner's; an arbiter or a viewer has People and Bridges.

### What a page shows {#scope}

Every page is about the hall you are looking at: Live, Boards, the pages that number and find boards, Games, the Results page (its lists, its counts and the number in the frame), the Log and Recordings. Boards offers only the tournaments played in this hall for each board, and the one the board plays in now.

The Log and Recordings can also show **All my halls**: tick it and they list every hall you may see. They hold fifty lines or files a page, with a search box. A box without accounts has no halls to tell apart, and shows everything.

## Tournaments and halls {#placements}

Where a tournament is played is said on Setup, Tournaments: open the tournament, and there is **Halls and tables**. Each row is one hall, with its tables from and to and the first board those tables play. The two common cases:

- **Two tournaments, one hall.** The Open on tables 1 to 8, the under-twelves on tables 9 to 16: each tournament has one row in the hall, and table 9 is board 1 of the under-twelves. This is what "Tables from ... to ..." has always done, and still does.
- **One tournament, two halls.** Boards 1 to 8 in the main hall on its tables 1 to 8, boards 9 to 16 in the annex on its tables 1 to 8: the Open has two rows, the second starting at board 9. Table 4 of the annex plays board 12.

**Add a hall** lists only the halls where you are an arbiter or an owner (an admin sees them all). A hall added takes the next free tables there - after every other tournament's range, and after the tables where another tournament's boards sit - and the board after the highest one already placed; change either before the round. A table whose board has a game under way in another tournament is never taken by adding a hall: the box says which board, and changes nothing. A tournament without a range in a hall has every table there that no other range holds.

What is refused: two tournaments on the same table of one hall, the same board in two halls, and taking a tournament out of the last hall it is in. A hall taken away sends its boards back to that hall's own tournament; the games stay.

A tournament is listed and opened in every hall it is played in. A board is still recognised by its serial only in its own hall: one tournament in two halls does not make them one room.

## Roles {#roles}

In each hall an account is an owner, an arbiter or a viewer. The same person can be an owner in one hall and a viewer in the next.

| Role | May |
| --- | --- |
| Viewer | Follow the games. Changes nothing |
| Arbiter | Run them: tables, rounds, results, corrections, the links to OpenPairings and OpenResults |
| Owner | All that, and add and remove bridges, and invite people |
| Admin | See every hall and Alnasl itself: its name, updates, the tracker, the switches on the Results page |

One thing is the owner's alone, whatever an admin may otherwise do: [fair play](08-fair-play.md). An admin who is not an owner of the hall sees nothing of it.

A changed role counts at once: when an owner demotes someone or takes them out of a hall (or the hall is deleted), that person's open pages reconnect by themselves and come back with what they may do now, instead of keeping the old role until they reload.

For a tournament played in more than one hall, the highest role you have in any of them counts - for what happens to it in that hall. The rest needs the role where it happens:

- **The hall you are standing in.** Giving its tables to a tournament, adding a code, its bridges: your role in this hall, whatever you are in the tournament's other halls.
- **The whole tournament.** Removing it, its Lichess round and key, starting it by itself, the next round: your role in its home hall, the hall it came from.
- **One board.** A result or a new game on the Live page, anything on a board's page, or a game from the Games page attached to it or played on a simulator as that board: your role in the hall that board is played in.

"Also play it in this hall" needs only an arbiter's role in the hall whose own code reaches the tournament: having the code is the permission.

A viewer who presses a button that changes something is told that their role lets them follow the games, not change them.

## Inviting people {#inviting}

On a hall's **Invitations** tab, "Invite" makes a link for one address and one role, good once and for a week. Alnasl sends no mail: copy the link to the person yourself. Whoever opens it makes the account for that address, with a password or with 02cloud, or signs in and joins the hall. An open invitation can be withdrawn.

A hall keeps at least one owner: you cannot take the last one out. Make someone else owner first.

## Deleting a hall {#deleting-a-hall}

On a hall's **Settings** tab, an owner (or an admin) finds "Delete this hall". It asks you to type the hall's name, and only then does the button work. The people, the open invitations, the join codes and the boards of the hall go with it.

A hall that still has bridges, tournaments or a connection to OpenPairings is not deleted: the message says what is left ("2 bridges and 1 tournament"), and you remove those first. That way no game is ever thrown away by this button. Alnasl's own hall (on a box, the hall of its own ports) can never be deleted. Anyone who had the deleted hall open lands on another hall of theirs.

## Signing in {#signing-in}

### With 02cloud {#sign-in-with-02cloud}

Where the deployment has set it up, the sign-in page has a "Sign in with 02cloud" button. It signs in the account with the same verified address, and links the two the first time. It makes no account by itself.

### Phones: the QR code {#phone-sign-in}

With accounts, the QR code under "Open this site on your phone" (on Boards and Setup, Access) is a sign-in code. "Make a sign-in code" shows one that signs the phone in as you, once, within five minutes. A phone stays signed in for thirty days. Each arbiter can also use an account of their own.

### A forgotten password {#forgotten-password}

There is no mail to reset it with. An admin opens the hall's **People** tab and gives the account a temporary password; the next sign-in asks for one of the account's own, and every other browser signed in as it is signed out. Your own password is changed under Account, in the account menu (the button at the foot of the rail, top right on a phone), which also says your role in the hall you are in.
