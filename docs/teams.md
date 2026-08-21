# Team sharing (share a tournament with other users)

The owner of a tournament can invite other people to it by email, without
sharing a password or handing over ownership. **Being invited does not by
itself grant access** - the invitee must explicitly accept the invitation
(via an emailed link, or from the "Pending invitations" section on the
Tournaments page) before they can open the tournament at all. Once accepted,
that person logs in with their own email (the app's existing magic-link
auth) and can open, edit, pair, enter results, print, export and generate
norms on the tournament exactly like the owner - everything except managing
collaborators and deleting the tournament, which stay owner-only.

**Naming note:** the app already has a *chess* concept called "team" -
`PairingsEngine.Tournaments.Team` (table `teams`), the roster of a team
tournament (name/captain/players). This feature is unrelated and, to avoid
confusion at the code level, is named **collaborators** throughout:
`PairingsEngine.Tournaments.Collaborator`, table `tournament_collaborators`.
The UI is free to call it "Share" or "Team" (the Settings page card is
titled "Share / Team"), but nothing in the schema/context ever reuses the
word "team" for this.

## Roles

| Role | Granted by | Can do |
|---|---|---|
| **Owner** | `tournaments.user_id` - whoever created the tournament (or imported it) | Everything, including managing collaborators and deleting the tournament |
| **Collaborator** (`role: "editor"`, v1's only role) | A row in `tournament_collaborators` | Everything an owner can, **except** managing collaborators and deleting the tournament |

There's deliberately no row in `tournament_collaborators` for the owner -
ownership is `tournaments.user_id`, not a collaborator entry. `role` exists
on the schema for future use (e.g. a read-only role) but only `"editor"` is
valid today.

## The invite flow (by email, must be explicitly accepted)

1. On the tournament's **Settings** page, the owner sees a **Share / Team**
   card (hidden entirely for non-owners) with a form to add a collaborator
   by email, and a list of current collaborators with their status and a
   Remove button.
2. Adding an email creates a `tournament_collaborators` row
   (`PairingsEngine.Tournaments.add_collaborator/3`) with `status: "pending"`
   and a fresh `invite_token` - **this alone grants no access**. If a user
   with that email already has an OpenPairings account, `user_id` is linked
   immediately as a courtesy (so `list_pending_invitations/1` can find it by
   `user_id`, not just by email); otherwise it stays `nil` until that person
   logs in (see `link_pending_collaborators/1`) or accepts. The owner's own
   email and a duplicate email for the same tournament are both rejected
   gracefully (no crash, just an inline error).
3. `add_collaborator/3` emails the invitee an invitation
   (`PairingsEngine.Accounts.UserNotifier.deliver_invitation/4`) linking to
   `/invites/:token`. If delivery raises (e.g. an SMTP hiccup), the row is
   still created - the LiveView shows "invite saved, email could not be
   sent, share this link manually: /invites/<token>" instead of crashing.
4. `/invites/:token` (`PairingsEngineWeb.InviteLive`) requires login - an
   invitee with no account is routed through the normal magic-link
   login/registration flow first, then lands back here. It shows the
   tournament name and inviter, with Accept/Decline buttons. **The logged-in
   user's email must case-insensitively match the invitation's email** -
   otherwise the page shows "this invitation was sent to a different
   address" and does nothing (`{:error, :email_mismatch}`), so a
   forwarded/leaked invite link can't be used by anyone but the invited
   address.
   - **Accept** (`PairingsEngine.Tournaments.accept_invitation/2`) sets
     `status: "accepted"`, links `user_id`, and clears `invite_token`
     (single-use) - only now does the tournament become reachable.
     Redirects to the tournament's Players page.
   - **Decline** (`PairingsEngine.Tournaments.decline_invitation/2`) deletes
     the row outright. Redirects home.
5. The same accept/decline actions are also available inline, without
   visiting the emailed link, from a **"Pending invitations"** section on
   the Tournaments page (shown whenever `list_pending_invitations/1` returns
   rows for the current user, matched by `user_id` or by `email`).
6. `link_pending_collaborators/1` (called from
   `PairingsEngineWeb.UserAuth.log_in_user/3` on every login) still backfills
   `user_id` onto matching pending rows by email - purely for lookup
   convenience (so `list_pending_invitations/1` matches by `user_id` even
   before the invite is accepted). It grants **no access by itself**; only
   `accept_invitation/2` does that.

## Data model

```
tournament_collaborators
  id
  tournament_id  → tournaments.id, on_delete: :delete_all
  user_id        → users.id, on_delete: :delete_all, nullable until linked
  email          string, not null, case-insensitive (collate: nocase), downcased on write
  role           string, not null, default "editor" - only "editor" is valid in v1
  status         string, not null, default "pending" - "pending" | "accepted"
  invite_token   string, nullable, unique - the secret in the /invites/:token URL;
                 cleared once accepted (single-use)
  inserted_at / updated_at
```

Unique index on `(tournament_id, email)` - the same email can't be added
twice to the same tournament. Unique index on `invite_token`. Index on
`user_id` for the login-time backfill query.

Rows created before the `status`/`invite_token` columns existed (i.e. under
the old "added = instant access" semantics) were grandfathered in as
`status: "accepted"` by the migration that added these columns
(`20260711120000_add_invite_status_to_collaborators.exs`), so nobody's
existing access was revoked by the upgrade.

## The access layer (`PairingsEngine.Tournaments`)

**Security rationale - pending ≠ access:** every access check below only
honours `status == "accepted"` rows. Being added as a collaborator creates a
row immediately, but that row is inert until the invitee explicitly proves
control of the invited email address by visiting `/invites/:token` (or the
Pending invitations section) and clicking Accept. This closes the gap where
mistyping an email, or an invite sitting unread in someone's inbox, used to
mean "that address can already open the tournament" - now it can't, until
someone actively opts in.

| Function | Used for |
|---|---|
| `get_authorized_tournament!/2`, `get_authorized_tournament/2` | Every tournament-scoped page/action a collaborator should also reach: players, pairings, standings, settings (the general form), live view, norms, print, and every TRF/JSON/xlsx export/download. Grants access if `scope.user` owns the tournament **or** has an **accepted** `tournament_collaborators` row matching by `user_id` **or** by `email`. A pending row grants nothing. Raises `Ecto.NoResultsError` (→ 404) otherwise - same failure mode as the owner-only check below, so a collaborator and a stranger are indistinguishable from the outside. |
| `get_user_tournament!/2`, `get_user_tournament/2` | Kept **owner-only**, used for: deleting a tournament, and managing collaborators (`add_collaborator/3`, `remove_collaborator/3` re-check ownership themselves too, as defense in depth against a forged event). |
| `list_tournaments/1` | Returns `{tournament, player_count, owner?}` for every tournament the user owns *or* has **accepted** a collaborator invite on, so the Tournaments page can show a "shared" badge and hide the Delete button. A pending invite does not appear here - it appears in `list_pending_invitations/1` instead. |
| `owner?/2` | `true`/`false` helper used by LiveViews to gate owner-only UI (the Share/Team card, the Delete button). |
| `list_collaborators/1` | Lists a tournament's collaborators (pending and accepted) for the Settings page. |
| `list_pending_invitations/1` | Lists the scope's user's own pending invites (matched by `user_id` or `email`) across all tournaments, for the Tournaments page's "Pending invitations" section. |
| `add_collaborator/3` | Owner-only; creates a `status: "pending"` row and emails an invitation. Returns `{:ok, collaborator}` where `collaborator.mail_status` (virtual, not persisted) is `:sent` or `:failed`. |
| `accept_invitation/2`, `decline_invitation/2` | Take the scope and either the `invite_token` or the collaborator's `id`. Require the scope's user's email to case-insensitively match the invitation's email (`{:error, :email_mismatch}` otherwise). Accept sets `status: "accepted"` + links `user_id` + clears the token; decline deletes the row. |
| `find_invitation/1` | Looks up a collaborator row by `invite_token` or `id`; used by `InviteLive` and by accept/decline internally. |
| `remove_collaborator/3` | Owner-only; removes a collaborator row whether pending or accepted - for a pending row this revokes the invitation outright. |
| `link_pending_collaborators/1` | Called from `PairingsEngineWeb.UserAuth.log_in_user/3` on every login; idempotent; backfills `user_id` only, never grants access. |

All of the above broadcast `:collaborators` on the tournament's topic and/or
the affected user's tournament-list topic (`user_tournaments_topic/1`), so
both the owner's Settings page and the invitee's Tournaments page update
live without a refresh.

## What a collaborator cannot do

- **Manage collaborators.** The Share/Team card only renders for the owner
  (`@owner?` assign in `SettingsLive`); `add_collaborator/3` and
  `remove_collaborator/3` also re-check `tournament.user_id == scope.user.id`
  themselves, so forging the LiveView event directly still returns
  `{:error, :not_owner}`.
- **Delete the tournament.** `TournamentsLive`'s delete flow
  (`delete_start` → the type-DELETE-to-confirm modal → `delete_confirmed`)
  uses `get_user_tournament!/2`, so a collaborator hitting that path gets a
  404 the same way a stranger would. The Delete button itself is hidden for
  shared tournaments in the Tournaments list.

Everything else - players, pairings/results, standings, the general
Settings form (name, rounds, tiebreaks, officials, ...), the live
projector view, norms/FIDE report downloads, print documents, and TRF/JSON
export - goes through `get_authorized_tournament!/2` and works identically
for the owner and every collaborator.
