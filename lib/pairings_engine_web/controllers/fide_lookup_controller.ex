defmodule PairingsEngineWeb.FideLookupController do
  @moduledoc """
  The FIDE list, for the results site's entry form.

  ## Why this exists at all

  The local entry form let a player type their name, pick themselves off the
  FIDE list, and have their ID, rating, title, federation and birth year
  filled in. It could, because the FIDE list is right here. The form moved to
  OpenResults on 2026-08-29 and the list did not, so players were left typing
  a FIDE ID from memory - which they get wrong, and which the arbiter then
  fixes by hand for every entry.

  The list stays here. This lends a search of it.

  ## Who may ask

  The same ingest token the results site already holds. It is the shared
  secret between these two applications, and this is the same pair of
  machines talking - a second secret would be a second thing to rotate and
  a second thing to get out of step, for no gain.

  It is thinner authorisation than the publishing side, and deliberately so:
  the FIDE list is a public dataset that FIDE itself distributes. Nothing
  here is about keeping the data secret. What the token and the rate limit
  are for is the arbiter's laptop - stopping a stranger turning a tournament
  machine into somebody's free search API in the middle of a round.

  ## What it is not

  Not a general FIDE API, and not paginated. It answers the question the
  entry form asks - "which of these is me" - and a handful of candidates is
  the honest shape of that answer. Somebody who needs the whole list should
  get it from FIDE.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Fide, Publishing, RateLimit}

  require Logger

  # More than a person picking themselves off a list will ever need, and few
  # enough that a scraper walking the alphabet gets nowhere interesting.
  @limit 15

  def search(conn, params) do
    with :ok <- authorize(conn),
         :ok <- within_rate_limit(conn) do
      query = params |> Map.get("q", "") |> to_string()

      json(conn, %{
        "players" => query |> Fide.search() |> Enum.take(@limit) |> Enum.map(&row(&1, params))
      })
    else
      :unauthorized ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})

      :rate_limited ->
        conn |> put_status(:too_many_requests) |> json(%{"error" => "too many searches"})
    end
  end

  # `rating` is resolved for the tournament's own tempo, not blindly taken
  # from the standard column: a rapid event wants the rapid rating, and a
  # player entered at their standard rating in a blitz tournament is seeded
  # wrong. `Fide.rating_for_tempo/2` already makes that choice for the local
  # paths; the caller passes the tempo it knows.
  #
  # Every other field travels under the name the registration contract uses,
  # so the results site can fill its form without translating anything.
  defp row(player, params) do
    %{
      "fide_id" => player.fide_id,
      "name" => player.name,
      "title" => blank_to_nil(player.title),
      "federation" => blank_to_nil(player.federation),
      "birth_year" => player.birth_year,
      "rating" => Fide.rating_for_tempo(player, Map.get(params, "tempo"))
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # The publishing token, presented as a bearer. See the moduledoc for why
  # this is the same secret rather than a new one.
  #
  # Fails closed: a machine that has never been configured to publish has no
  # token, and answering an unauthenticated search there would turn every
  # fresh install into an open endpoint.
  defp authorize(conn) do
    configured = Publishing.token()

    presented =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> token
        _ -> nil
      end

    cond do
      is_nil(configured) or configured == "" ->
        Logger.warning("FIDE lookup refused: no publishing token is configured")
        :unauthorized

      is_nil(presented) ->
        :unauthorized

      # Constant time, so a wrong token cannot be narrowed down by timing it.
      Plug.Crypto.secure_compare(presented, configured) ->
        :ok

      true ->
        :unauthorized
    end
  end

  # The results site is the only caller and reaches this over localhost, so
  # every request shares one address. That is fine - the limit exists to stop
  # a machine being turned into somebody's search API, and one bucket for the
  # one caller is exactly that. See `PairingsEngine.RateLimit`'s bucket for
  # the numbers.
  defp key(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp within_rate_limit(conn) do
    if RateLimit.allow?(:fide_lookup, key(conn)) do
      RateLimit.record(:fide_lookup, key(conn))
      :ok
    else
      :rate_limited
    end
  end
end
