defmodule PairingsEngine.Norms.CountsBreakdown do
  @moduledoc """
  The actual player-by-player reasoning behind IT3's rated/titled/federation
  count cells (`Norms.Forms.it3_fills/3`'s `B27`-`B58` block) — same
  category rules (`rated?/1`, title membership, the untitled CM/WCM
  exclusion `Norms.Forms.titled?/1` already documents), but keeping each
  category's actual player list instead of collapsing straight to a count,
  so a UI can show *why* a number is what it is, not just the number.

  Exists because "why does this say 14 rated players" was a real support
  question — arbiters have the underlying player list already, but nothing
  surfaced the same grouping the report itself used, so a discrepancy (a
  wrong federation code, a rating that didn't import) looked like a bug
  first and a data problem second.
  """

  alias PairingsEngine.Tournaments.Player

  @type category :: %{total: integer(), feds: integer(), host: integer(), players: [Player.t()]}

  @categories [
    {:rated, "Rated", "FIDE-rated (a nonzero standard rating)"},
    {:unrated, "Unrated", "No FIDE standard rating on file"},
    {:gm, "GM", "Titled Grandmaster"},
    {:im, "IM", "Titled International Master"},
    {:fm, "FM", "Titled FIDE Master"},
    {:wgm, "WGM", "Titled Woman Grandmaster"},
    {:wim, "WIM", "Titled Woman International Master"},
    {:wfm, "WFM", "Titled Woman FIDE Master"}
  ]

  @doc "The `{key, label, explanation}` triples `breakdown/2`'s map is keyed by, in report order."
  def categories, do: @categories

  @doc """
  `%{rated: category, unrated: category, gm: category, ...}` — one entry per
  `categories/0` row, each with the same `{total, feds, host}` shape
  `Norms.Forms.it3_fills/3` writes to the report, plus the actual `players`
  that landed in it (in their original list order — not re-sorted, so this
  reads in the same order as wherever `players` itself came from).
  """
  def breakdown(players, host_federation) do
    rated_players = Enum.filter(players, &rated?/1)
    unrated_players = Enum.reject(players, &rated?/1)

    %{
      rated: category(rated_players, host_federation),
      unrated: category(unrated_players, host_federation),
      gm: category(by_title(players, ["GM"]), host_federation),
      im: category(by_title(players, ["IM"]), host_federation),
      fm: category(by_title(players, ["FM"]), host_federation),
      wgm: category(by_title(players, ["WGM"]), host_federation),
      wim: category(by_title(players, ["WIM"]), host_federation),
      wfm: category(by_title(players, ["WFM"]), host_federation)
    }
  end

  defp category(list, host_federation) do
    %{
      total: length(list),
      feds:
        list |> Enum.map(& &1.federation) |> Enum.reject(&blank?/1) |> Enum.uniq() |> length(),
      host: Enum.count(list, &(&1.federation == host_federation and not blank?(host_federation))),
      players: list
    }
  end

  defp rated?(%{fide_rating: r}), do: (r || 0) > 0

  defp by_title(players, titles), do: Enum.filter(players, &(&1.title in titles))

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
