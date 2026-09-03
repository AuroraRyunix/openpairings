defmodule PairingsEngine.FederationTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Federation

  # Direct unit coverage of the normalization helper itself (no fixture
  # needed) - every marker the SWAR importer's `map_federation/1` can hand
  # it, plus the pass-through cases. `PairingsEngine.TrfExport` reuses this
  # same function defensively at export time (see trf_export_test.exs) for a
  # tournament whose `federation` was stored raw before this normalization
  # existed.
  test "normalize/1 collapses every Belgian regional/organizational marker to BEL" do
    for marker <- ~w(FRBE KBSB FEFB VSF SVDB FIDE frbe vsf) do
      assert Federation.normalize(marker) == "BEL"
    end
  end

  test "normalize/1 leaves a real FIDE federation code, blank, or nil untouched" do
    assert Federation.normalize("FRA") == "FRA"
    assert Federation.normalize("") == ""
    assert Federation.normalize(nil) == nil
  end

  test "normalize/1 trims and upcases whatever it passes through" do
    assert Federation.normalize("  fra ") == "FRA"
    assert Federation.normalize(" vsf ") == "BEL"
  end
end
