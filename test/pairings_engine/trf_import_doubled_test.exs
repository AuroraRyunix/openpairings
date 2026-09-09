defmodule PairingsEngine.TrfImportDoubledTest do
  @moduledoc """
  What happens when the same tournament arrives twice.

  Two different accidents, and they fail in two different ways:

    * **one file containing two documents**, which is what a careless `copy
      /b` or a shell `cat a.trf b.trf > both.trf` produces. There is nothing
      in the format to stop it - TRF has no end marker, no length and no
      envelope, so a doubled file is a syntactically valid file with every
      starting rank in it twice.
    * **the same file uploaded twice**, which is the ordinary human one: a
      click that seemed not to work, a page reloaded, a colleague doing it
      as well.

  Only the first is a silent corruption, and it is the one this checks
  refuses. The second is loud by construction and is checked here so the
  difference is written down rather than assumed.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{TrfImport, Tournaments}

  # A whole, valid, two-player TRF. Column positions matter: 001 lines are
  # fixed-width, and `place/3` is how the other import tests build them.
  defp document(name) do
    player = fn rank, who, points, opponent, colour, result ->
      ""
      |> place(1, "001")
      |> place(5, String.pad_leading(to_string(rank), 4))
      |> place(15, who)
      |> place(81, String.pad_leading(points, 4))
      |> place(86, String.pad_leading(to_string(rank), 4))
      |> place(92, String.pad_leading(to_string(opponent), 4))
      |> place(97, colour)
      |> place(99, result)
    end

    Enum.join(
      [
        place("", 1, "012") |> place(5, name),
        player.(1, "Alpha, One", "1.0", 2, "w", "1"),
        player.(2, "Bravo, Two", "0.0", 1, "b", "0")
      ],
      "\r\n"
    ) <> "\r\n"
  end

  defp document_ranked(name, r1, r2) do
    player = fn rank, who, points, opponent, colour, result ->
      ""
      |> place(1, "001")
      |> place(5, String.pad_leading(to_string(rank), 4))
      |> place(15, who)
      |> place(81, String.pad_leading(points, 4))
      |> place(86, String.pad_leading(to_string(rank), 4))
      |> place(92, String.pad_leading(to_string(opponent), 4))
      |> place(97, colour)
      |> place(99, result)
    end

    Enum.join(
      [
        place("", 1, "012") |> place(5, name),
        player.(r1, "Alpha #{r1}", "1.0", r2, "w", "1"),
        player.(r2, "Bravo #{r2}", "0.0", r1, "b", "0")
      ],
      "
"
    ) <> "
"
  end

  defp place(line, position, text) do
    padded = String.pad_trailing(line, position - 1)
    prefix = binary_part(padded, 0, position - 1)
    rest = binary_part(padded, position - 1, byte_size(padded) - (position - 1))

    tail =
      if byte_size(rest) > byte_size(text),
        do: binary_part(rest, byte_size(text), byte_size(rest) - byte_size(text)),
        else: ""

    prefix <> text <> tail
  end

  describe "one file that contains the document twice" do
    test "is refused, and says which ranks collided" do
      one = document("Gent Spring Open")

      assert {:ok, _tournament, _warnings} = TrfImport.import_text(one)

      # `cat a.trf a.trf` - no marker in the format says this is wrong, so
      # the only thing that can catch it is the content.
      assert {:error, {:parse_failed, message}} = TrfImport.import_text(one <> one)

      # Named as what it is - two documents - rather than as the collision
      # that happens to give it away. The rank check is still there and still
      # catches a genuinely malformed single document.
      assert message =~ "contains 2 tournaments"
      assert message =~ "Import them separately"
    end

    test "and so is a file carrying two DIFFERENT tournaments" do
      # The more plausible accident of the two: a directory of exports
      # concatenated by a script. The names differ, so nothing about the
      # header is suspicious - it is still every rank twice.
      both = document("Gent Spring Open") <> document("Bruges Autumn Open")

      assert {:error, {:parse_failed, message}} = TrfImport.import_text(both)
      assert message =~ "contains 2 tournaments"
    end
  end

  describe "two documents whose starting ranks do NOT collide" do
    test "is refused too - by counting the documents, not the ranks" do
      # The rank guard is what catches a doubled file, and it works because
      # the ranks repeat. They do not always repeat: a file holding two
      # different tournaments whose numbering continues rather than restarts
      # has no collision to find.
      both =
        document_ranked("Gent Spring Open", 1, 2) <> document_ranked("Bruges Autumn Open", 3, 4)

      # Before the 012 count existed this imported CLEANLY as one tournament
      # holding all four players, named "Bruges Autumn Open" - the second
      # document's name, because it was read last. Nothing warned.
      assert {:error, {:parse_failed, message}} = TrfImport.import_text(both)

      assert message =~ "contains 2 tournaments"
      assert message =~ "012"
      assert message =~ "Import them separately"
    end
  end

  describe "the same file uploaded twice" do
    test "makes two separate tournaments, and nothing is merged into either" do
      # Deliberately NOT refused. An import has no identity to compare
      # against - TRF carries no id, and two clubs can legitimately run
      # tournaments with the same name on the same dates. Refusing would
      # block a real case to prevent a visible one.
      one = document("Gent Spring Open")

      assert {:ok, first, _} = TrfImport.import_text(one)
      assert {:ok, second, _} = TrfImport.import_text(one)

      refute first.id == second.id

      # The point: the second import did not land inside the first. Each
      # tournament has its own two players and its own single round.
      assert length(Tournaments.list_players(first.id)) == 2
      assert length(Tournaments.list_players(second.id)) == 2
      assert length(Tournaments.list_rounds(first.id)) == 1
      assert length(Tournaments.list_rounds(second.id)) == 1
    end
  end
end
