defmodule PairingsEngine.Tournaments do
  @moduledoc "Tournament, player, team and round management."

  import Ecto.Query
  alias PairingsEngine.Repo
  alias PairingsEngine.Tiebreaks
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Tournaments.{Tournament, Player, Team, Round, Pairing}

  ## Tournaments

  @doc "Lists only the tournaments owned by the scope's user."
  def list_tournaments(%Scope{} = scope) do
    Repo.all(
      from t in Tournament,
        left_join: p in assoc(t, :players),
        where: t.user_id == ^scope.user.id,
        group_by: t.id,
        select: {t, count(p.id)},
        order_by: [desc: t.inserted_at]
    )
  end

  def get_tournament!(id), do: Repo.get!(Tournament, id)

  @doc """
  Gets a tournament owned by the scope's user.

  Raises `Ecto.NoResultsError` if the tournament doesn't exist or isn't
  owned by the scope's user (so URL guessing can't leak other users' data).
  """
  def get_user_tournament!(%Scope{} = scope, id) do
    Repo.get_by!(Tournament, id: id, user_id: scope.user.id)
  end

  @doc """
  Creates an unowned tournament (no `user_id`).

  Kept for internal callers that don't have a scope (e.g. the SWAR
  importer). Prefer `create_tournament/2` from user-facing code so the
  tournament is owned by whoever created it.
  """
  def create_tournament(attrs) do
    type = attrs["type"] || attrs[:type] || "swiss"

    %Tournament{tiebreaks: Tiebreaks.fide_defaults(type)}
    |> Tournament.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Creates a tournament owned by the scope's user."
  def create_tournament(%Scope{} = scope, attrs) do
    type = attrs["type"] || attrs[:type] || "swiss"

    %Tournament{tiebreaks: Tiebreaks.fide_defaults(type), user_id: scope.user.id}
    |> Tournament.changeset(attrs)
    |> Repo.insert()
  end

  def update_tournament(%Tournament{} = tournament, attrs) do
    tournament
    |> Tournament.changeset(attrs)
    |> Repo.update()
  end

  def delete_tournament(%Tournament{} = tournament), do: Repo.delete(tournament)

  def change_tournament(%Tournament{} = tournament, attrs \\ %{}) do
    Tournament.changeset(tournament, attrs)
  end

  ## Players

  def list_players(tournament_id) do
    Repo.all(
      from p in Player,
        where: p.tournament_id == ^tournament_id,
        order_by: [
          desc: fragment("CASE WHEN ? > 0 THEN ? ELSE ? END", p.fide_rating, p.fide_rating, p.national_rating),
          asc: p.name
        ]
    )
  end

  def count_players(tournament_id) do
    Repo.aggregate(from(p in Player, where: p.tournament_id == ^tournament_id), :count)
  end

  def get_player!(id), do: Repo.get!(Player, id)

  def create_player(tournament_id, attrs) do
    fide_id = attrs["fide_id"] || attrs[:fide_id]

    duplicate? =
      fide_id not in [nil, ""] and
        Repo.exists?(
          from p in Player,
            where: p.tournament_id == ^tournament_id and p.fide_id == ^fide_id
        )

    if duplicate? do
      {:error, :duplicate_fide_id}
    else
      %Player{tournament_id: tournament_id}
      |> Player.changeset(attrs)
      |> Repo.insert()
    end
  end

  def update_player(%Player{} = player, attrs) do
    player
    |> Player.changeset(attrs)
    |> Repo.update()
  end

  def delete_player(%Player{} = player), do: Repo.delete(player)

  def change_player(%Player{} = player, attrs \\ %{}), do: Player.changeset(player, attrs)

  ## Teams

  def list_teams(tournament_id) do
    Repo.all(from t in Team, where: t.tournament_id == ^tournament_id, order_by: t.name)
  end

  ## Rounds & pairings (round lifecycle is filled in by the pairing engine)

  def get_round(tournament_id, number) do
    Repo.one(
      from r in Round,
        where: r.tournament_id == ^tournament_id and r.number == ^number,
        preload: [pairings: [:white_player, :black_player]]
    )
  end

  def list_rounds(tournament_id) do
    Repo.all(from r in Round, where: r.tournament_id == ^tournament_id, order_by: r.number)
  end

  def update_pairing_result(%Pairing{} = pairing, result) do
    pairing
    |> Pairing.changeset(%{result: result})
    |> Repo.update()
  end
end
