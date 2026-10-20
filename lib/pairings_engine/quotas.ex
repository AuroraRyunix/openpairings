defmodule PairingsEngine.Quotas do
  @moduledoc """
  What one account may pile onto the hosted server: how many tournaments it
  keeps, and how many files it has this machine read in an hour.

  Every account on the hosted edition shares one two-core box and one disk.
  A tournament is cheap until somebody makes a few thousand of them, and an
  import is ten megabytes of JSON or twenty thousand TRF records parsed on
  the spot - fine once, a denial of service on a loop. Neither had a ceiling;
  trusting everybody to stop on their own is a lovely idea for somebody
  else's server.

  The ceilings are generous on purpose. They are not a pricing plan; they
  are there so the one account that loses its mind cannot take the other
  two dozen down with it.

  A desktop install has none of this (`PairingsEngine.Authz.local_mode?/0`):
  the only person on it is the one whose laptop it is, and they are welcome
  to fill their own disk.
  """
  use Gettext, backend: PairingsEngineWeb.Gettext

  import Ecto.Query

  alias PairingsEngine.{Authz, RateLimit, Repo}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Tournaments.Tournament

  @default_max_tournaments 200

  @doc """
  How many tournaments one account may own on the hosted edition (the
  recycle bin not counted - it empties itself), `:infinity` on a desktop
  install. `config :pairings_engine, :max_tournaments_per_account`, or
  `PAIRINGS_MAX_TOURNAMENTS`; #{@default_max_tournaments} when neither says.
  """
  @spec max_tournaments() :: pos_integer() | :infinity
  def max_tournaments do
    if Authz.local_mode?() do
      :infinity
    else
      case Application.get_env(:pairings_engine, :max_tournaments_per_account) do
        n when is_integer(n) and n > 0 -> n
        _ -> @default_max_tournaments
      end
    end
  end

  @doc """
  `:ok` when `scope`'s account may own `adding` more tournaments, else
  `{:error, :tournament_quota}`. A scope without a user (an importer run
  from a mix task) owns nothing and is never refused.
  """
  @spec check_tournaments(Scope.t() | nil, non_neg_integer()) ::
          :ok | {:error, :tournament_quota}
  def check_tournaments(scope, adding \\ 1)

  def check_tournaments(%Scope{user: %{id: user_id}}, adding) when is_integer(adding) do
    case max_tournaments() do
      :infinity ->
        :ok

      max ->
        if owned_count(user_id) + adding <= max, do: :ok, else: {:error, :tournament_quota}
    end
  end

  def check_tournaments(_scope, _adding), do: :ok

  defp owned_count(user_id) do
    Repo.aggregate(
      from(t in Tournament, where: t.user_id == ^user_id and is_nil(t.deleted_at)),
      :count
    )
  end

  @doc """
  Counts one file import for `scope`'s account and says whether it may go
  ahead: `:ok`, or `{:error, :import_quota}` once the account has spent the
  `:tournament_import` allowance for the hour (see
  `PairingsEngine.RateLimit`). Always `:ok` on a desktop install.

  Counted when ASKED, not when it succeeds: the cost is the reading, and a
  file that turns out to be rubbish was read all the same.
  """
  @spec check_import(Scope.t() | nil) :: :ok | {:error, :import_quota}
  def check_import(%Scope{user: %{id: user_id}}) do
    key = Integer.to_string(user_id)

    cond do
      Authz.local_mode?() ->
        :ok

      RateLimit.allow?(:tournament_import, key) ->
        RateLimit.record(:tournament_import, key)
        :ok

      true ->
        {:error, :import_quota}
    end
  end

  def check_import(_scope), do: :ok

  @doc "What to tell the arbiter who hit `reason`."
  @spec message(:tournament_quota | :import_quota) :: String.t()
  def message(:tournament_quota),
    do:
      gettext(
        "This account already has %{max} tournaments, the most one account can keep on this server. Delete some you no longer need - export them first to keep a copy - then try again.",
        max: max_tournaments()
      )

  def message(:import_quota),
    do:
      gettext(
        "That is a lot of imports for one hour. Wait a while before importing another file - the server reads every one of them in full."
      )
end
