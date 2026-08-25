defmodule PairingsEngineWeb.RichTextTest do
  @moduledoc """
  `rich_text/1` is the thing that lets a sentence with a link inside it stay
  a single msgid. Two properties matter and neither is obvious from reading
  it: it must not introduce whitespace around the substituted markup (a
  stray space before a full stop is a visible defect), and the placeholder
  must be free to MOVE, because putting the link where Dutch wants it is the
  entire reason the component exists.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PairingsEngineWeb.CoreComponents

  defp html(text) do
    assigns = %{text: text}

    rendered_to_string(~H"""
    <.rich_text text={@text}>
      <:part name="players"><a href="/players">Players</a></:part>
      <:part name="settings"><b>Settings</b></:part>
    </.rich_text>
    """)
    # LiveView stamps its own change-tracking marker onto slot roots. It is
    # not part of what the reader sees, and asserting on it would make these
    # tests break on a LiveView upgrade for no reason.
    |> String.replace(~r/ phx-r\b/, "")
  end

  test "substitutes a part without adding whitespace around it" do
    assert html("on the %[players] page.") == ~s(on the <a href="/players">Players</a> page.)
  end

  test "leaves no gap when the placeholder is flush against punctuation" do
    assert html("see %[players].") == ~s(see <a href="/players">Players</a>.)
  end

  test "puts the markup wherever the translation moved it" do
    assert html("%[players] is where they live.") ==
             ~s(<a href="/players">Players</a> is where they live.)
  end

  test "substitutes more than one part" do
    assert html("%[players], then %[settings].") ==
             ~s(<a href="/players">Players</a>, then <b>Settings</b>.)
  end

  test "escapes the surrounding text rather than trusting it" do
    assert html("a & b %[players]") == ~s(a &amp; b <a href="/players">Players</a>)
  end

  test "renders an unknown placeholder literally instead of eating it" do
    assert html("hello %[nobody] there") == "hello %[nobody] there"
  end

  test "leaves gettext's own %{} interpolation syntax alone" do
    # The two markers coexist in one sentence: `%{version}` is a binding
    # gettext already substituted before this component sees the string, so
    # anything shaped like one here is literal text by the time we run.
    assert html("v%{version}, see %[players]") ==
             ~s(v%{version}, see <a href="/players">Players</a>)
  end

  test "renders a sentence with no placeholder at all unchanged" do
    assert html("nothing to substitute") == "nothing to substitute"
  end
end
