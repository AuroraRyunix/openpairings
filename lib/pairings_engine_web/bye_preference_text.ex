defmodule PairingsEngineWeb.ByePreferenceText do
  @moduledoc """
  The sentences an arbiter reads about what the players' bye preferences
  (not a FIDE rule - docs/pairing-systems.md, "Bye preferences") did in a
  round: the Pairings page's notice and the round explanation's account
  both say it the same way, from the round's stored record
  (`PairingsEngine.Pairing`'s `"bye_preference"` section key).

  Pure words: takes the stored map and a function from player id to name.
  """

  use Gettext, backend: PairingsEngineWeb.Gettext

  @doc """
  `{moved_sentence | nil, [note]}` for one section's `"bye_preference"`
  record: whether the preferences changed who got the bye, and one note per
  preference that was NOT applied, saying why. A preference that was
  honoured, or that concerned a player not in the round, gets no note.
  """
  def account(%{} = record, name) do
    holder = name.(first_holder(record))

    moved =
      if record["moved"] == true do
        fide = name.(record["fide_bye"])

        if fide,
          do:
            gettext(
              "The bye preferences changed this round (an organiser's wish, not a FIDE rule): the pairing-allocated bye went to %{name}; by the FIDE rules alone it would have gone to %{fide}.",
              name: holder || "-",
              fide: fide
            ),
          else:
            gettext(
              "The bye preferences changed this round (an organiser's wish, not a FIDE rule): the pairing-allocated bye went to %{name}.",
              name: holder || "-"
            )
      end

    notes =
      record
      |> Map.get("outcomes", [])
      |> Enum.flat_map(&note(&1, name))

    {moved, notes}
  end

  def account(_record, _name), do: {nil, []}

  defp first_holder(record), do: record["bye"]

  defp note(%{"outcome" => outcome} = o, name) do
    who = name.(o["player"]) || "-"

    case {outcome, o["preference"]} do
      {"honoured", _} ->
        []

      {"not_in_round", _} ->
        []

      {"no_bye_this_round", "want_hard"} ->
        [
          gettext(
            "%{name} must get the pairing-allocated bye, but this round has none (an even number of players).",
            name: who
          )
        ]

      {"no_bye_this_round", _} ->
        []

      {"unpairable", _} ->
        [
          gettext(
            "%{name} must get the pairing-allocated bye, but no legal pairing gives it to them this round: the round was paired as without the preference.",
            name: who
          )
        ]

      {"ineligible", _} ->
        [
          gettext(
            "%{name}'s bye preference was not applied: FIDE's rule C2 rules them out of the pairing-allocated bye (%{reason}).",
            name: who,
            reason: reason(o["reason"])
          )
        ]

      {"conflict", _} ->
        [
          gettext(
            "%{name}'s bye preference was not applied: it contradicts their other bye setting (%{other}), which takes precedence.",
            name: who,
            other: setting(o["with"])
          )
        ]

      {"other_player", _} ->
        [
          gettext(
            "%{name}'s bye preference was not applied: %{holder}'s preference decided the pairing-allocated bye.",
            name: who,
            holder: name.(o["holder"]) || "-"
          )
        ]

      {"outranked", "want_soft"} ->
        [
          gettext(
            "%{name} would rather get the pairing-allocated bye, but could only get it on a higher score or not at all - the FIDE criteria come first.",
            name: who
          )
        ]

      {"outranked", _} ->
        [
          gettext(
            "%{name} would rather not get the pairing-allocated bye, but nobody else on their score could take it.",
            name: who
          )
        ]

      _other ->
        []
    end
  end

  defp reason("pairing_bye"), do: gettext("already had a pairing-allocated bye")
  defp reason("forfeit_win"), do: gettext("already won a game without playing")
  defp reason("full_point_bye"), do: gettext("already had a full-point bye")
  defp reason(other), do: to_string(other)

  @doc "One setting's words, as the player form names it."
  def setting("want_hard"), do: gettext("must get the bye")
  def setting("want_soft"), do: gettext("rather gets the bye")
  def setting("avoid_soft"), do: gettext("rather not the bye")
  def setting("avoid_hard"), do: gettext("excluded from the bye")
  def setting(other), do: to_string(other)
end
