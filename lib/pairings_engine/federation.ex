defmodule PairingsEngine.Federation do
  @moduledoc """
  Federation codes: the three-letter FIDE country code that
  `tournament.federation` and `player.federation` are supposed to carry, and
  the normalization that gets a stored value back to one.

  Import formats do not all store a FIDE code. Some store *which federation
  entity* runs the event - a regional league, or the national body under one
  of its own language's names - which is a different question with a
  different answer, and never a value TRF export may emit. `normalize/1`
  collapses those markers to the country code they all mean.

  The marker table below is Belgian because SWAR is the only format so far
  that needs one; the *function* is not, which is why it lives here and not
  in the Belgian federation pack. A second pack adding its own markers would
  add them here, next to these.
  """

  # Regional/organizational markers that all mean "Belgium" for FIDE-reporting
  # purposes - never a genuine ISO/FIDE country code in their own right, so
  # they must never end up in `tournament.federation` / `player.federation`
  # (TRF export reads those fields directly - see docs/import-export.md).
  # "FIDE" (SWAR federation code 6, "direct FIDE homologation, no specific
  # sub-federation") is included too - the SWAR importer only ever sees
  # KBSB/FRBE-organized tournaments, so it's still Belgium, just not
  # attributed to one of the named regional leagues. Any other value (a
  # real FIDE federation code, or "" for "none selected") passes through
  # unchanged.
  @belgian_markers ~w(FRBE KBSB FEFB VSF SVDB FIDE)

  @doc """
  Collapses a regional/organizational federation marker (any of
  `#{inspect(@belgian_markers)}`) to the FIDE country code it means, here
  "BEL"; any other value (a real FIDE federation code, or "" for "none
  selected") passes through unchanged, upcased and trimmed.

  Applied on the way in by the SWAR importer, and again defensively at
  export time by `PairingsEngine.TrfExport`, for a tournament whose
  `federation` field was stored raw in the database (e.g. imported before
  this normalization existed) - see `docs/swar-import.md`.
  """
  def normalize(code) when is_binary(code) do
    upcased = code |> String.trim() |> String.upcase()
    if upcased in @belgian_markers, do: "BEL", else: upcased
  end

  def normalize(other), do: other
end
