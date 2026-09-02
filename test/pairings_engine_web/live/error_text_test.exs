defmodule PairingsEngineWeb.ErrorTextTest do
  @moduledoc """
  `SettingsSupport.error_text/1`, the last stop between a context refusal and
  what an arbiter reads.

  Its fallback turns an atom into words by rubbing out the underscores, and
  that fallback is a bad place to land. `:handed_off` landed there and
  rendered as the bare phrase "handed off" - which names the state without
  naming the remedy, and reads like the back half of a sentence somebody
  forgot to finish. Every reason a user can actually meet gets a clause, and
  every clause says two things: what is true, and what to do about it.
  """
  use ExUnit.Case, async: true

  alias PairingsEngineWeb.SettingsSupport

  # Each reason and the word that proves the way out is named, not just the
  # state. The state half is asserted separately below.
  @remedies %{
    archived: "unarchive",
    handed_off: "take it back",
    not_owner: "owner",
    not_handed_off: "not handed off",
    bad_token: "token",
    already_handed_off: "already handed off"
  }

  test "every reason a write path can refuse with has words of its own" do
    for {reason, remedy} <- @remedies do
      text = SettingsSupport.error_text(reason)

      assert text =~ remedy,
             "error_text(#{inspect(reason)}) does not mention #{inspect(remedy)}: #{inspect(text)}"

      # A real sentence, not a rubbed-out atom.
      assert String.ends_with?(text, "."),
             "error_text(#{inspect(reason)}) is not a sentence: #{inspect(text)}"

      refute text == reason |> to_string() |> String.replace("_", " "),
             "error_text(#{inspect(reason)}) fell through to the fallback"
    end
  end

  test "the hand-off refusal says where the tournament is and how to get it back" do
    # The specific one that used to render as "handed off" and nothing else.
    text = SettingsSupport.error_text(:handed_off)

    assert text =~ "handed off"
    assert text =~ "another copy"
    assert text =~ "read-only"
    assert text =~ "take it back"
  end

  test "the archive refusal still says archived, so nothing that matched on it moved" do
    assert SettingsSupport.error_text(:archived) =~ "archived"
  end

  test "an unknown atom still degrades to something readable rather than raising" do
    assert SettingsSupport.error_text(:some_future_reason) == "some future reason"
  end

  test "a binary passes straight through, and a changeset is still formatted" do
    assert SettingsSupport.error_text("already in words") == "already in words"

    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{}, [:name])
      |> Ecto.Changeset.validate_required([:name])

    assert SettingsSupport.error_text(changeset) =~ "name"
  end
end
