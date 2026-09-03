defmodule PairingsEngine.EncodingTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Encoding

  # The codec had no unit tests of its own while it lived inside the SWAR
  # importer - it was covered only through .swar and TRF fixtures. These
  # pin the three ranges that actually differ between CP-1252 and Latin-1,
  # which is the whole reason this is not `:unicode.characters_to_binary/2`
  # with `:latin1`.
  test "cp1252_decode/1 maps the 0x80-0x9F bytes CP-1252 reassigns" do
    assert Encoding.cp1252_decode(<<0x80>>) == "€"
    assert Encoding.cp1252_decode(<<0x92>>) == "’"
    assert Encoding.cp1252_decode(<<0x9F>>) == "Ÿ"
  end

  test "cp1252_decode/1 passes ASCII and Latin-1 through unchanged" do
    assert Encoding.cp1252_decode("Gaetan") == "Gaetan"
    assert Encoding.cp1252_decode(<<"Ga", 0xEB, "tan">>) == "Gaëtan"
  end

  test "cp1252_decode/1 never fails - the five unassigned bytes fall back to their codepoint" do
    for byte <- [0x81, 0x8D, 0x8F, 0x90, 0x9D] do
      assert Encoding.cp1252_decode(<<byte>>) == <<byte::utf8>>
    end

    assert is_binary(Encoding.cp1252_decode(<<0, 255, 1, 2, 3>>))
  end

  test "cp1252_encode/1 round-trips everything CP-1252 can represent" do
    for str <- ["Gaëtan", "€uro", "quote ’ here", "Ÿ", "plain ascii"] do
      assert str |> Encoding.cp1252_encode() |> Encoding.cp1252_decode() == str
    end
  end

  test "cp1252_encode/1 replaces what CP-1252 cannot represent with ?" do
    assert Encoding.cp1252_encode("♞") == "?"
  end
end
