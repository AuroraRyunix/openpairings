defmodule PairingsEngineWeb.SettingsSupportTest do
  @moduledoc """
  `error_text/1`'s wording for the team Swiss engine's refusals
  (`:budget_exhausted`, `:no_legal_pairing`, `:no_legal_bye`) and crash
  guard, and the individual path's own crash guard - what an arbiter reads
  on the Pairings page when pairing gives up or breaks, in English and
  Dutch (`use Gettext`, `mix gettext.extract --merge`).
  """
  use ExUnit.Case, async: true

  import PairingsEngineWeb.SettingsSupport, only: [error_text: 1]

  describe "the team Swiss engine's refusals - English" do
    test "budget_exhausted names the round, says nothing changed, and gives options" do
      text = error_text({:team_pairing, :budget_exhausted, 7})
      assert text =~ "round 7"
      assert text =~ "search limit"
      assert text =~ "nothing changed"
      assert text =~ "pair this round manually"
      assert text =~ "contact support"
    end

    test "no_legal_pairing names the round and explains the FIDE-rules refusal" do
      text = error_text({:team_pairing, :no_legal_pairing, 3})
      assert text =~ "Round 3 can't be paired"
      assert text =~ "teams meeting twice"
      assert text =~ "pair the round manually"
    end

    test "no_legal_bye names the round and explains the bye-specific refusal" do
      text = error_text({:team_pairing, :no_legal_bye, 5})
      assert text =~ "Round 5 can't be paired"
      assert text =~ "already had one or won a match by forfeit"
    end

    test "pairing_crashed is generic - no atom, no exception name" do
      text = error_text({:team_pairing, :pairing_crashed, 1})
      assert text =~ "Pairing failed unexpectedly"
      assert text =~ "Nothing was changed"
      refute text =~ "pairing_crashed"
    end

    test "an unrecognised reason still names the round rather than crashing the page" do
      text = error_text({:team_pairing, {:invalid_option, :absent, [99]}, 2})
      assert text =~ "round 2"
      assert text =~ "invalid_option"
    end
  end

  describe "the individual (JaVaFo/Ainalrami) path's own crash guard - English" do
    test "no category: a plain generic message" do
      text = error_text({:pairing_crashed, 4, nil})
      assert text =~ "Pairing failed unexpectedly"
      refute text =~ "category"
    end

    test "a category: names it" do
      text = error_text({:pairing_crashed, 4, "Girls U16"})
      assert text =~ "Girls U16"
      assert text =~ "Pairing failed unexpectedly"
    end
  end

  describe "Dutch (je-form, no raw atoms)" do
    setup do
      previous = Gettext.get_locale(PairingsEngineWeb.Gettext)
      Gettext.put_locale(PairingsEngineWeb.Gettext, "nl")
      on_exit(fn -> Gettext.put_locale(PairingsEngineWeb.Gettext, previous) end)
    end

    test "every new team-pairing and crash message has a Dutch translation" do
      for reason <- [:budget_exhausted, :no_legal_pairing, :no_legal_bye, :pairing_crashed] do
        text = error_text({:team_pairing, reason, 1})
        refute text =~ "%{", "#{reason}: untranslated placeholder leaked through"
        assert String.length(text) > 10
      end

      refute error_text({:pairing_crashed, 1, nil}) =~ "%{"
      refute error_text({:pairing_crashed, 1, "U16"}) =~ "%{"
    end

    test "uses je-form and ploeg, not the forbidden word" do
      assert error_text({:team_pairing, :budget_exhausted, 1}) =~ "Je kunt"
      assert error_text({:team_pairing, :no_legal_pairing, 1}) =~ "ploeg"

      for reason <- [:budget_exhausted, :no_legal_pairing, :no_legal_bye, :pairing_crashed] do
        refute error_text({:team_pairing, reason, 1}) =~ "gerateerd"
      end
    end
  end
end
