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

  Recognised keys: `"chief_arbiter_name"` / `"chief_arbiter_fide_id"`,
  `"deputyN_name"` / `"deputyN_fide_id"` for `N` in `1..2`, `"organizer"`,
  `"event_code"`. Unrecognised keys are ignored.
  """
  def apply(%Tournament{} = tournament, overlay) when is_map(overlay) do
    officials =
      (tournament.officials || %{})
      |> maybe_put_officials("chief_arbiter_fide_id", get(overlay, "chief_arbiter_fide_id"))
      |> merge_deputies(overlay)

    %{
      tournament
      | chief_arbiter:
          first_present(get(overlay, "chief_arbiter_name"), tournament.chief_arbiter),
        organizer: first_present(get(overlay, "organizer"), tournament.organizer),
        event_code: first_present(get(overlay, "event_code"), tournament.event_code),
        officials: officials
    }
  end

  defp merge_deputies(officials, overlay) do
    Enum.reduce(1..2, officials, fn n, acc ->
      acc
      |> maybe_put_officials("deputy#{n}_name", get(overlay, "deputy#{n}_name"))
      |> maybe_put_officials("deputy#{n}_fide_id", get(overlay, "deputy#{n}_fide_id"))
    end)
  end

  defp maybe_put_officials(officials, _key, nil), do: officials
  defp maybe_put_officials(officials, _key, ""), do: officials
  defp maybe_put_officials(officials, key, value), do: Map.put(officials, key, value)

  defp first_present(nil, fallback), do: fallback
  defp first_present("", fallback), do: fallback
  defp first_present(value, _fallback), do: value

  defp get(map, key), do: Map.get(map, key)
end
