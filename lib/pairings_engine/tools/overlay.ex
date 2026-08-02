defmodule PairingsEngine.Tools.Overlay do
  @moduledoc """
  Merges the "what the files don't contain" fields collected on the public
  arbiter tools page (`PairingsEngineWeb.ToolsNormsLive`, see docs/tools.md)
  — chief arbiter, deputy arbiters, organizer, event code — onto a
  `%Tournament{}` (already produced by `PairingsEngine.Norms.Combine.combine/2`),
  the same shape the Settings page's "Officials & FIDE report data" card
  writes onto a real, persisted tournament (see docs/norms.md).

  Pure: never touches the database. Every field is only applied when
  non-blank, so a `SwarImport`/`TrfImport`-supplied value already on the
  tournament (e.g. a chief arbiter name a TRF file's 092 line carried) isn't
  silently blanked out by an empty form field — the overlay only *adds*
  what's missing.
  """

  alias PairingsEngine.Tournaments.Tournament

  @doc """
  Applies `overlay` (a string-keyed map — see the field list below, all
  optional) onto `tournament`, returning the merged `%Tournament{}`.

  Recognised keys: `"chief_arbiter_name"` / `"chief_arbiter_fide_id"` /
  `"chief_arbiter_email"`, `"deputyN_name"` / `"deputyN_fide_id"` for `N` in
  `1..4` (the IT3 template's own built-in cap — see docs/norms.md),
  `"arbiterN_name"` / `"arbiterN_fide_id"` for `N` in `1..extra_arbiters_count`
  (arbiters beyond that 4-slot cap — see
  `PairingsEngine.Norms.ItThreeExpand`), `"organizer"` / `"organizer_email"`,
  `"event_code"`. Unrecognised keys are ignored.
  """
  def apply(%Tournament{} = tournament, overlay) when is_map(overlay) do
    officials =
      (tournament.officials || %{})
      |> maybe_put_officials("chief_arbiter_fide_id", get(overlay, "chief_arbiter_fide_id"))
      |> maybe_put_officials("chief_arbiter_email", get(overlay, "chief_arbiter_email"))
      |> maybe_put_officials("organizer_email", get(overlay, "organizer_email"))
      |> merge_deputies(overlay)
      |> merge_extra_arbiters(overlay)

    %{
      tournament
      | chief_arbiter:
          first_present(get(overlay, "chief_arbiter_name"), tournament.chief_arbiter),
        organizer: first_present(get(overlay, "organizer"), tournament.organizer),
        event_code: first_present(get(overlay, "event_code"), tournament.event_code),
        officials: officials
    }
  end

  # The IT3 template has exactly 4 deputy slots built in; a 5th and beyond
  # needs a real additional row in the template, not modeled here.
  @max_deputies 4

  defp merge_deputies(officials, overlay) do
    Enum.reduce(1..@max_deputies, officials, fn n, acc ->
      acc
      |> maybe_put_officials("deputy#{n}_name", get(overlay, "deputy#{n}_name"))
      |> maybe_put_officials("deputy#{n}_fide_id", get(overlay, "deputy#{n}_fide_id"))
    end)
  end

  defp merge_extra_arbiters(officials, overlay) do
    count = parse_extra_count(get(overlay, "extra_arbiters_count"))

    officials = maybe_put_officials(officials, "extra_arbiters_count", count_string(count))

    if count > 0 do
      Enum.reduce(1..count, officials, fn n, acc ->
        acc
        |> maybe_put_officials("arbiter#{n}_name", get(overlay, "arbiter#{n}_name"))
        |> maybe_put_officials("arbiter#{n}_fide_id", get(overlay, "arbiter#{n}_fide_id"))
      end)
    else
      officials
    end
  end

  defp count_string(0), do: nil
  defp count_string(n), do: to_string(n)

  defp parse_extra_count(nil), do: 0
  defp parse_extra_count(n) when is_integer(n), do: n

  defp parse_extra_count(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp maybe_put_officials(officials, _key, nil), do: officials
  defp maybe_put_officials(officials, _key, ""), do: officials
  defp maybe_put_officials(officials, key, value), do: Map.put(officials, key, value)

  defp first_present(nil, fallback), do: fallback
  defp first_present("", fallback), do: fallback
  defp first_present(value, _fallback), do: value

  defp get(map, key), do: Map.get(map, key)
end
