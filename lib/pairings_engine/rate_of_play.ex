defmodule PairingsEngine.RateOfPlay do
  @moduledoc """
  The rate-of-play (time-control cadence) preset catalogue, keyed by the
  tournament's `standard` classification - Standard / Rapid / Blitz.

  Single source of truth for both the "New tournament" form
  (`PairingsEngineWeb.TournamentsLive`) and the Options settings page
  (`PairingsEngineWeb.SettingsOptionsLive`), so the two never drift apart and
  the create form offers the same rich, cadence-appropriate list the settings
  page does. The lists follow the FIDE-style descriptors SWAR's own Cadence
  field uses (e.g. `"90min/40moves+30min/end+30sec/move from move 1"`).

  The `standard` value is the tournament's own classification; anything other
  than `"rapid"`/`"blitz"` (including `""`/`nil`) falls back to the Standard
  list, matching how the rest of the app defaults `standard`.
  """

  @standard_options [
    {"standard", "Standard"},
    {"rapid", "Rapid"},
    {"blitz", "Blitz"}
  ]

  @standard [
    "90min/40moves+30min/end+30sec/move from move 1",
    "100min/40moves+50min/20moves+15min/end+30sec/move from move 1",
    "100min/end+30sec/move from move 1",
    "105min/40moves+15min/end",
    "120min/40moves+15min/end+30sec/move from move 40",
    "120min/40moves+30min/end",
    "120min/10moves+30min/end+30sec/move from move 40",
    "120min/end",
    "120min/end+10sec/move from move 40",
    "120min/end+30sec/move from move 1",
    "120min/end+30sec/move from move 40",
    "150min/end",
    "90min/40moves+15min/end+30sec/move from move 1",
    "90min/end",
    "90min/end+10sec/move from move 1",
    "90min/end+30sec/move from move 1",
    "90min/end+30sec DELAY /move from move 1",
    "75min/end+30sec/move from move 1",
    "65min/end",
    "60min/end",
    "60min/end+30sec/move from move 1",
    "40min/end+30sec/move from move 1",
    "30min/end+30sec/move from move 1"
  ]

  @rapid [
    "15min/end+10sec/move from move 1",
    "15min/end",
    "15min/end+5sec/move from move 1",
    "15min/end+15sec/move from move 1",
    "25min/end+10sec/move from move 1",
    "25min/end+15sec/move from move 1",
    "25min/end+5sec/move from move 1",
    "25min/end",
    "20min/end",
    "20min/end+10sec/move from move 1",
    "20min/end+15sec/move from move 1",
    "20min/end+5sec/move from move 1",
    "30min/end",
    "30min/end+10sec/move from move 1",
    "30min/end+20sec/move from move 1",
    "10min/end+5sec/move from move 1",
    "10min/end+10sec/move from move 1",
    "10min/end+15sec/move from move 1",
    "10min/end+2sec/move from move 1",
    "10min/end+5sec DELAY /move from move 1",
    "12min/end",
    "12min/end+3sec/move from move 1",
    "12min/end+5sec/move from move 1",
    "12min/end+10sec/move from move 1",
    "13min/end+3sec/move from move 1",
    "13min/end+5sec/move from move 1",
    "11min/end",
    "40min/end+10sec/move from move 1",
    "45min/end",
    "59min/end",
    "8min/end+4sec/move from move 1"
  ]

  @blitz [
    "5min/end+3sec/move from move 1",
    "5min/end+2sec/move from move 1",
    "5min/end",
    "5min/end+3sec DELAY /move from move 1",
    "3min/end+2sec/move from move 1",
    "3min/end+3sec/move from move 1",
    "4min/end+2sec/move from move 1",
    "4min/end+3sec/move from move 1",
    "6min/end+2sec/move from move 1",
    "6min/end+3sec/move from move 1",
    "7min/end+2sec/move from move 1",
    "7min/end+3sec/move from move 1",
    "8min/end+2sec/move from move 1",
    "8min/end+3sec/move from move 1",
    "10min/end"
  ]

  @doc "The `{value, label}` pairs for the Standard / Rapid / Blitz classification select."
  def standard_options, do: @standard_options

  @doc """
  The ordered list of preset cadences for `standard` - the Rapid list for
  `"rapid"`, the Blitz list for `"blitz"`, otherwise the Standard list.
  """
  def list_for("rapid"), do: @rapid
  def list_for("blitz"), do: @blitz
  def list_for(_standard), do: @standard

  @doc """
  The options to render in a rate-of-play `<select>` for `standard`: a leading
  blank (`""`, shown as "- none -") plus `list_for/1`. If `current` is a
  non-blank value that isn't one of the presets for this classification (a
  custom cadence, or one carried over from a different classification), it is
  prepended so the select still shows the saved value rather than silently
  dropping it.
  """
  def select_options(standard, current) do
    list = list_for(standard)

    if current not in [nil, ""] and current not in list do
      [current, "" | list]
    else
      ["" | list]
    end
  end
end
