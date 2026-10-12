defmodule PairingsEngine.Tournaments.ByeChoice do
  @moduledoc """
  The player dialog's ONE control for the pairing-allocated bye, and its
  translation to and from the five stored fields.

  The dialog used to offer a tickbox (the organiser's exclusion) beside a
  select (the preference), which let an arbiter tick one and choose "no
  preference" in the other, or want the bye while barred from it. The dialog
  now asks one question and the answer is one of:

    * `""`           - the FIDE rules decide (the default)
    * `"never"`      - `no_bye` in every round
    * `"rounds"`     - `no_bye` in the rounds typed, plus, optionally, what
      the player prefers in all the OTHER rounds (`other`)
    * `"avoid_soft"` - rather not (`bye_preference`)
    * `"want_soft"`  - rather gets it
    * `"want_hard"`  - must get it, if a legal pairing allows

  Nothing is stored under those names. `expand/2` turns the answer back into
  the five stored fields (`no_bye`, `no_bye_scope`, `no_bye_rounds`,
  `bye_preference`, `bye_preference_scope`, `bye_preference_rounds`) that
  every reader, export and engine call still uses, and `from_form/2` reads
  them back for a stored player. "The other rounds" is the complement of the
  excluded rounds within the tournament's round count, written out as rounds:
  that is what the stored `bye_preference_rounds` has always been, and what
  keeps "want it" from overlapping an exclusion (`Player.bye_settings_clash/1`
  refuses that overlap).
  """

  alias PairingsEngine.Tournaments.Player

  @prefs ~w(avoid_soft want_soft want_hard)
  @choices ["", "never", "rounds"] ++ @prefs

  def choices, do: @choices
  def preferences, do: @prefs

  @doc """
  What the form shows for `form` (a string-keyed map: either the stored
  player's `player_to_form/1`, or the params of the last `phx-change`):
  `%{choice:, other:, clash?:}`.

  `other` is meaningful under `"rounds"` only: a preference, `""`, or `"keep"`
  for a stored preference that is not simply "the other rounds" (it is left
  as stored unless the arbiter picks something else). `clash?` is true for a
  stored player who is both barred from the bye in every round and carries a
  preference; the form says so and a save clears the preference.
  """
  def from_form(form, rounds_count) do
    case form["bye_choice"] do
      choice when choice in @choices ->
        %{choice: choice, other: form["bye_other"] || "", clash?: false}

      _ ->
        stored(form, rounds_count)
    end
  end

  defp stored(form, rounds_count) do
    no_bye? = form["no_bye"] in [true, "true"]
    pref = pref_of(form["bye_preference"])
    excluded = to_string(form["no_bye_rounds"] || "")

    cond do
      no_bye? and excluded == "" ->
        %{choice: "never", other: "", clash?: pref != ""}

      no_bye? ->
        other =
          cond do
            pref == "" ->
              ""

            to_string(form["bye_preference_rounds"] || "") == complement(excluded, rounds_count) ->
              pref

            true ->
              "keep"
          end

        %{choice: "rounds", other: other, clash?: false}

      true ->
        %{choice: pref, other: "", clash?: false}
    end
  end

  defp pref_of(pref) when pref in @prefs, do: pref
  defp pref_of(_), do: ""

  @doc """
  The rounds `1..rounds_count` that `excluded` (the typed rounds) leaves, as
  the canonical comma list, or `""` when it leaves none or does not parse.
  """
  def complement(excluded, rounds_count) when is_integer(rounds_count) do
    with {:ok, canonical} <- Player.parse_absent_rounds_input(to_string(excluded)) do
      taken = Player.parse_absent_rounds(canonical)
      Enum.join(Enum.reject(1..max(rounds_count, 1), &(&1 in taken)), ",")
    else
      _ -> ""
    end
  end

  def complement(_excluded, _rounds_count), do: ""

  @doc """
  The stored-field params for the form's answer; `params` come back without
  `bye_choice` / `bye_other`. Params with no `bye_choice` (the control was
  not on the form) are returned as they are.

  Options: `keep_preference: true` for a tournament where preferences are
  ignored (FIDE-rated): the stored preference is neither shown nor touched.
  """
  def expand(params, rounds_count, opts \\ [])

  def expand(%{"bye_choice" => choice} = params, rounds_count, opts) when choice in @choices do
    other = params["bye_other"] || ""
    params = Map.drop(params, ["bye_choice", "bye_other"])
    keep? = Keyword.get(opts, :keep_preference, false)

    case choice do
      "" ->
        params |> exclusion(false, "all") |> preference(keep?, "", "all", "")

      "never" ->
        params |> exclusion(true, "all") |> preference(keep?, "", "all", "")

      "rounds" ->
        params = exclusion(params, true, "rounds")
        rounds = complement(params["no_bye_rounds"], rounds_count)

        cond do
          keep? or other == "keep" -> params
          other in @prefs and rounds != "" -> preference(params, false, other, "rounds", rounds)
          true -> preference(params, false, "", "all", "")
        end

      pref ->
        scope = if params["bye_preference_scope"] == "rounds", do: "rounds", else: "all"
        params |> exclusion(false, "all") |> preference(false, pref, scope, nil)
    end
  end

  def expand(params, _rounds_count, _opts), do: params

  defp exclusion(params, on?, scope) do
    params = Map.merge(params, %{"no_bye" => to_string(on?), "no_bye_scope" => scope})
    if on?, do: params, else: Map.put(params, "no_bye_rounds", "")
  end

  defp preference(params, true, _pref, _scope, _rounds), do: params

  defp preference(params, false, pref, scope, rounds) do
    params = Map.merge(params, %{"bye_preference" => pref, "bye_preference_scope" => scope})

    cond do
      pref == "" -> Map.put(params, "bye_preference_rounds", "")
      is_binary(rounds) -> Map.put(params, "bye_preference_rounds", rounds)
      true -> params
    end
  end
end
