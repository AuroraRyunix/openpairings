defmodule PairingsEngine.Repo.Migrations.AddUserFeatures do
  @moduledoc """
  Which optional national-federation features an account has switched on.

  See `PairingsEngine.Features` for what the keys mean and for the rule they
  all obey: **the pack owns entrances, never stored values.** Nothing this
  column says can change how an existing tournament scores, pairs, prints or
  exports.

  ## Why a column on `users` and not a joined table

  The enablement has no attributes of its own - no "when", no "granted by",
  no expiry - so a `user_features` table would carry a surrogate key, a
  foreign key and nothing else. It would also have to be read on the path
  that matters most: `enabled?/2` is called from inside `render/1`, several
  times per page, and the user row is ALREADY loaded on every request by
  `fetch_current_scope_for_user`. A column makes those checks a field read;
  a joined table makes them either a preload welded onto the authentication
  path or a query per check.

  `{:array, :string}` rather than five booleans, because a sixth feature (a
  Dutch pack, a German one) should be an entry in `Features.catalogue/0`, not
  a migration. It is also already this schema's idiom for a short list of
  short strings - `tournaments.tiebreaks`, `tournaments.categories`,
  `tournaments.public_hidden_tiebreaks` - which ecto_sqlite3 stores as JSON
  text.

  ## Nobody loses a button they were relying on

  The default is empty: a new account, and every installation that has never
  touched anything Belgian, gets a plain application with no federation pack
  in the way. That is the whole point.

  But this ships to boxes where the pack is in daily use, and switching
  somebody's buttons off underneath them is not an upgrade, it is a fault.
  So two rules grandfather the people already using it, and both are
  deliberately generous - a switch that is on and unused costs a line on a
  settings page, a switch that is off and needed costs an arbiter their
  workflow mid-tournament:

    * **Anyone connected to a tournament that came from SWAR.** A non-nil
      `swar_guid` is proof: only `Federations.BEL.SwarImport` writes it.
      Owners AND accepted collaborators, because a collaborator was pressing
      the same buttons on the same tournament.
    * **Everyone, if this installation has the KBSB roster API configured.**
      `KBSB_API_URL` + `KBSB_API_KEY` both set is what
      `Federations.BEL.Api.configured?/0` calls configured, and an operator
      only sets them on a box that syncs the Belgian list. The env is read
      here directly rather than through that module: a migration that calls
      application code is a migration that changes meaning the next time
      that code is edited, and this one has to keep meaning what it meant on
      the day it ran.

  `down` drops the column, which is the only reversal available and loses
  nothing that cannot be re-ticked on the settings page.
  """
  use Ecto.Migration

  import Ecto.Query

  # Mirrors `PairingsEngine.Features.keys/0` as of this migration, spelled
  # out rather than called for the same reason the env is read directly
  # below: what this migration granted must not change when the catalogue
  # grows a sixth key.
  @keys ~w(bel_ratings_sync bel_player_lookup bel_club_sync bel_swar_import bel_swar_export)

  def up do
    alter table(:users) do
      add :features, {:array, :string}, null: false, default: []
    end

    flush()

    grandfather(grandfathered_user_ids())
  end

  def down do
    alter table(:users) do
      remove :features
    end
  end

  defp grandfathered_user_ids do
    if kbsb_api_configured?() do
      from(u in "users", select: u.id) |> repo().all()
    else
      swar_owner_ids() ++ swar_collaborator_ids()
    end
  end

  defp swar_owner_ids do
    from(t in "tournaments",
      where: not is_nil(t.swar_guid) and not is_nil(t.user_id),
      select: t.user_id,
      distinct: true
    )
    |> repo().all()
  end

  # An invitation that was never accepted has no `user_id` and nobody behind
  # it, so `not is_nil(c.user_id)` is both the join condition and the
  # "actually used this" test.
  defp swar_collaborator_ids do
    from(c in "tournament_collaborators",
      join: t in "tournaments",
      on: t.id == c.tournament_id,
      where: not is_nil(t.swar_guid) and not is_nil(c.user_id),
      select: c.user_id,
      distinct: true
    )
    |> repo().all()
  end

  defp grandfather([]), do: :ok

  defp grandfather(ids) do
    encoded = Jason.encode!(@keys)

    from(u in "users", where: u.id in ^Enum.uniq(ids))
    |> repo().update_all(set: [features: encoded])
  end

  # `Federations.BEL.Api.configured?/0` in longhand: both variables set and
  # neither of them blank.
  defp kbsb_api_configured? do
    present?(System.get_env("KBSB_API_URL")) and present?(System.get_env("KBSB_API_KEY"))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
