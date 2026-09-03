defmodule PairingsEngine.Encoding do
  @moduledoc """
  Legacy text-encoding conversions, for the file formats that predate UTF-8.

  Windows-1252 is the only one so far, and it turns up in three unrelated
  places: `.swar` files, TRF files and the KBSB rating-list CSV. It lived in
  `PairingsEngine.SwarImport` for as long as SWAR was the only caller; it is
  here now because a byte-to-codepoint table is not specific to any one
  format, let alone to any one federation.
  """

  # Bytes 0x80-0x9F differ between Windows-1252 and ISO-8859-1/Latin-1.
  # Unmapped bytes in that range (81, 8D, 8F, 90, 9D) have no Windows-1252
  # assignment; we fall back to the raw codepoint so decoding never crashes.
  @cp1252_high %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  @doc "Decodes a Windows-1252 (CP-1252) byte string to a UTF-8 Elixir string."
  def cp1252_decode(bytes) when is_binary(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn
      byte when byte >= 0x80 and byte <= 0x9F -> Map.get(@cp1252_high, byte, byte)
      byte -> byte
    end)
    |> List.to_string()
  end

  # codepoint -> byte, for the 27 characters that are genuinely remapped in
  # 0x80-0x9F. None of their codepoints falls in 0-0xFF (they're all in the
  # 0x2000s or Latin Extended-A), so it never collides with the plain
  # identity range `cp1252_encode/1` handles directly below.
  @cp1252_encode_table for {byte, cp} <- @cp1252_high, into: %{}, do: {cp, byte}

  @doc """
  Encodes a UTF-8 Elixir string to Windows-1252 (CP-1252) bytes - the
  inverse of `cp1252_decode/1`.

  Every codepoint 0-0xFF is its own byte: that covers plain ASCII, ordinary
  Latin-1 (À-ÿ), AND the five CP-1252 bytes with no assignment of their own
  (0x81/0x8D/0x8F/0x90/0x9D) - `cp1252_decode/1` already treats those as
  identity, so encoding keeps them that way rather than round-tripping
  through the lookup table meant for the other 27. Any codepoint outside
  what CP-1252 can represent at all becomes `?`, the same lossy-but-safe
  fallback this codebase takes for legacy encodings it can't avoid.
  """
  def cp1252_encode(str) when is_binary(str) do
    str
    |> String.to_charlist()
    |> Enum.map(fn
      cp when cp <= 0xFF -> cp
      cp -> Map.get(@cp1252_encode_table, cp, ?\?)
    end)
    |> :binary.list_to_bin()
  end
end
