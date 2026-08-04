defmodule PairingsEngineWeb.Components.PublicTournamentMeta do
  @moduledoc """
  A compact line of tournament facts — chief arbiter, deputy, tempo/time
  control, round dates — for the public (no-login) standings/pairings pages
  (`PairingsEngineWeb.PublicStandingsLive` / `PublicPairingsLive`, see
  docs/public-pages.md). These pages previously showed only the tournament
  name and the table itself; a spectator or player following the link had no
  way to see who's arbiting or what the time control is, information every
  printed pairing sheet carries as a matter of course. Deliberately terse —
  one line, only the fields that have a value — this isn't meant to
  replicate a full report, just cover the baseline facts a spectator page
  shouldn't be missing.
  """

  use Phoenix.Component

  attr :tournament, :map, required: true

  def public_tournament_meta(assigns) do
    ~H"""
    <p :if={meta_parts(@tournament) != []} class="hint" style="margin: 4px 0 0">
      {Enum.join(meta_parts(@tournament), " · ")}
    </p>
    """
  end

  defp meta_parts(tournament) do
    [
      present("Arbiter", tournament.chief_arbiter),
      present("Deputy", tournament.deputy_arbiter),
      present("Tempo", tournament.rate_of_play),
      round_dates_part(tournament.round_dates)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp present(_label, value) when value in [nil, ""], do: nil
  defp present(label, value), do: "#{label}: #{value}"

  defp round_dates_part(nil), do: nil
  defp round_dates_part([]), do: nil

  defp round_dates_part(dates) do
    case Enum.reject(dates, &(&1 in [nil, ""])) do
      [] -> nil
      [single] -> "Date: #{single}"
      real -> "Dates: #{List.first(real)} – #{List.last(real)}"
    end
  end
end
