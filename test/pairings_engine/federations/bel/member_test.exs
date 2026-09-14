defmodule PairingsEngine.Federations.BEL.MemberTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Federations.BEL.Member

  describe "club_label/1" do
    test "shows the club name when known" do
      member = %Member{club_name: "KGSRL", club_number: 42}
      assert Member.club_label(member) == "KGSRL"
    end

    test "falls back to the bare number when no name is known" do
      member = %Member{club_name: "", club_number: 42}
      assert Member.club_label(member) == "#42"
    end

    test "nil when there is no club at all" do
      member = %Member{club_name: "", club_number: nil}
      assert Member.club_label(member) == nil
    end
  end

  describe "full_name/1" do
    test "just the last name with no first name" do
      assert Member.full_name(%Member{last_name: "Peeters", first_name: ""}) == "Peeters"
    end

    test "\"Last, First\" with both" do
      assert Member.full_name(%Member{last_name: "Peeters", first_name: "Jan"}) == "Peeters, Jan"
    end
  end
end
