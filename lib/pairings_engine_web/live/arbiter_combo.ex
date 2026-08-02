defmodule PairingsEngineWeb.Live.ArbiterCombo do
  @moduledoc """
  Shared mechanics behind the officials FIDE-lookup combobox on both
  `PairingsEngineWeb.NormsLive` (signed-in) and
  `PairingsEngineWeb.ToolsNormsLive` (public) — kept in ONE place because the
  two pages used to have genuinely different search behavior for the exact
  same kind of field: one searched the name box on every keystroke, the
  other only on a button click, and neither let you search by typing a FIDE
  ID directly (the ID was a read-only hint, or on the public page, a plain
  text box you could type an unverified number into and have it saved
  as-is). Same search, same result rendering, same commit rule, on both
  pages now — see `PairingsEngineWeb.Components.ArbiterCombo` for the shared
  markup this drives.

  A "role" identifies one official slot (`"chief_arbiter"`, `"deputy1"`,
  `"person_responsible_pairings"`, ...). Each role has two boxes — a name
  box and a FIDE-ID box — and typing in EITHER searches the same way:
  `PairingsEngine.Fide.search/1` already treats an all-digit query as an id
  lookup and anything else as a name search, so one search function serves
  both boxes without either caller having to know which kind of thing it's
  looking at.
  """

  alias PairingsEngine.Fide

  @doc """
  `{role, :name | :id}` for a form-change event's params, or `nil` if the
  changed field isn't part of any arbiter combobox.

  `_target`'s last segment is always exactly the field name the caller
  built (`"deputy1_fide_id"`, `"chief_arbiter"`, `"chief_arbiter_name"`,
  `"person_responsible_pairings"`, ...) — the two pages spell the chief
  arbiter's name field differently (`NormsLive` posts straight to
  `Tournament.chief_arbiter`, `ToolsNormsLive` keeps a flat
  `chief_arbiter_name` key alongside its `_fide_id` sibling, following the
  same convention every other role already uses), so both spellings map to
  the same `{"chief_arbiter", :name}` result.
  """
  def target_role_and_field(%{"_target" => target}) when is_list(target) do
    target |> List.last() |> parse_field()
  end

  def target_role_and_field(_params), do: nil

  defp parse_field("chief_arbiter"), do: {"chief_arbiter", :name}
  defp parse_field("chief_arbiter_name"), do: {"chief_arbiter", :name}
  defp parse_field("chief_arbiter_fide_id"), do: {"chief_arbiter", :id}
  defp parse_field("person_responsible_pairings"), do: {"person_responsible_pairings", :name}

  defp parse_field("person_responsible_pairings_fide_id"),
    do: {"person_responsible_pairings", :id}

  defp parse_field("deputy" <> rest) do
    case Regex.run(~r/^(\d)_(name|fide_id)$/, rest) do
      [_, n, "name"] -> {"deputy#{n}", :name}
      [_, n, "fide_id"] -> {"deputy#{n}", :id}
      _ -> nil
    end
  end

  defp parse_field(_), do: nil

  @doc """
  The value the user actually typed, read by walking `_target`'s own path
  through `params` — works regardless of the surrounding param namespace
  (`tournament[...]` on the Norms page, `overlay[...]`/`fide_id_search[...]`
  on the public tools page), since `_target` already names that exact path.
  """
  def target_value(%{"_target" => target} = params) when is_list(target) do
    Enum.reduce(target, params, fn
      key, acc when is_map(acc) -> Map.get(acc, key)
      _key, _acc -> nil
    end)
  end

  def target_value(_params), do: nil

  @doc "New `arbiter_search` assign for a search on `query`, typed into `role`'s `field` box."
  def search(role, field, query) do
    results =
      if String.length(String.trim(to_string(query))) >= 2 do
        Fide.search(query)
      else
        []
      end

    %{role: role, field: field, results: results}
  end

  @doc "Results to show under `role`'s `field` box — `[]` unless that's the box currently searched."
  def results_for(%{role: role, field: field, results: results}, role, field), do: results
  def results_for(_search, _role, _field), do: []

  @doc "The FIDE player a pick's `fide_id` param refers to, or `nil` (an unrecognised id, or none)."
  def picked_player(fide_id), do: Fide.get_player(fide_id)

  @doc """
  Form field name for `role`'s FIDE-ID **search** box.

  Deliberately built OUTSIDE the page's own `tournament[...]`/`overlay[...]`
  namespace, and never the name a save/sync actually reads — typing a FIDE
  id here searches for it exactly like typing a name does, but only picking
  a result from either dropdown commits it (see
  `PairingsEngineWeb.Components.ArbiterCombo`). Without that separation, a
  hand-typed id would be indistinguishable, at submit time, from one a
  lookup actually verified — which defeats the entire reason this combobox
  exists (every arbiter FIDE reports on is registered with FIDE, so an
  official's FIDE ID either came from a real lookup or the record is wrong).
  """
  def id_search_name(role), do: "fide_id_search[#{role}_fide_id]"
end
