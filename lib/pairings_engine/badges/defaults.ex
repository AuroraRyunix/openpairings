defmodule PairingsEngine.Badges.Defaults do
  @moduledoc """
  What a new badge event starts with: the printed role names and colours, the
  room names, and the usage conditions on the back.

  Everything here is only a starting point. It is copied into the event when
  the event is created and edited there - a Belgian event prints its roles and
  conditions in two languages, so none of this text goes through gettext. It is
  English because that is what an international chess event prints by default.
  """

  # `key` is what an import looks a role up by, so renaming a role's label
  # (to "ARBITRE / SCHEIDSRECHTER", say) keeps imports working. The four
  # import roles cannot be removed from an event for the same reason.
  @roles [
    %{"key" => "chief_arbiter", "label" => "CHIEF ARBITER", "color" => "#0A5624"},
    %{"key" => "deputy_chief_arbiter", "label" => "DEPUTY CHIEF ARBITER", "color" => "#12692D"},
    %{"key" => "arbiter", "label" => "ARBITER", "color" => "#1B7E39"},
    %{"key" => "player", "label" => "PLAYER", "color" => "#1E5899"},
    %{"key" => "pairing_officer", "label" => "PAIRING OFFICER", "color" => "#0284C7"},
    %{"key" => "fair_play_officer", "label" => "FAIR PLAY OFFICER", "color" => "#B91C1C"},
    %{"key" => "organizer", "label" => "ORGANIZER", "color" => "#BE2A2A"},
    %{"key" => "official", "label" => "OFFICIAL", "color" => "#15803D"},
    %{"key" => "vip", "label" => "VIP", "color" => "#C98816"},
    %{"key" => "press", "label" => "PRESS / MEDIA", "color" => "#DD6118"},
    %{"key" => "staff", "label" => "STAFF", "color" => "#374151"},
    %{"key" => "security", "label" => "SECURITY", "color" => "#111827"},
    %{"key" => "volunteer", "label" => "VOLUNTEER", "color" => "#0D9488"},
    %{"key" => "delegate", "label" => "DELEGATE", "color" => "#6D28D9"},
    %{"key" => "guest", "label" => "GUEST", "color" => "#9672A5"}
  ]

  @import_role_keys ~w(chief_arbiter deputy_chief_arbiter arbiter player)

  @room_names %{
    "1" => "PLAYING HALL",
    "2" => "VIEWING AREA",
    "3" => "EXHIBITION ROOM",
    "4" => "MEDIA ROOM",
    "5" => "BROADCAST ROOM",
    "6" => "VIP LOUNGE",
    "7" => "OPERATIONS",
    "8" => "BACKSTAGE",
    "9" => "DELEGATES LOUNGE",
    "10" => "CONFERENCE ROOM",
    "11" => "INTERVIEW ROOM",
    "12" => "SECURITY OFFICE"
  }

  @conditions """
  1) This accreditation may only be used for $tournament-name and does not constitute usage for any other purpose.
  2) $organiser reserves the right to approve/reject/request further information on all applications in its sole discretion and without providing reasons for doing so.
  3) At any time, $organiser may revoke accreditation:
  if it is put to improper use;
  if it has been used to abuse the privileges so extended;
  if personal or public conduct is not consistent with the best interest of the organization.
  4) The accreditation card must not be loaned to another person; any pass in the possession of any individual to whom it was not issued will be confiscated.
  5) By using this card, I agree to be filmed, televised, photographed, identified and otherwise recorded during the event under the conditions and for the purposes now or hereafter authorised by $organiser in relation with the promotion of the event.
  6) The cards issued remain the property of $organiser and must be returned upon request.
  """

  @max_rooms 12

  @doc "The role list a new event starts with."
  def roles, do: @roles

  @doc "The role keys an import assigns, which an event must always keep."
  def import_role_keys, do: @import_role_keys

  @doc "The room names a new event starts with, keyed by the room number as a string."
  def room_names, do: @room_names

  @doc "The most numbered rooms a badge has space for."
  def max_rooms, do: @max_rooms

  @doc """
  The usage conditions a new event starts with. `$tournament-name` and
  `$organiser` stay in the stored text and are filled in when the badge is
  drawn, so renaming the event later needs no edit here.
  """
  def conditions, do: String.trim(@conditions)

  @doc "Fills in the two placeholders `conditions/0` may contain."
  def fill_conditions(text, event_name, organiser) do
    name = if blank?(event_name), do: "the event", else: event_name
    org = if blank?(organiser), do: "the organiser", else: organiser

    (text || "")
    |> String.replace("$tournament-name", name)
    |> String.replace("$organiser", org)
  end

  defp blank?(value), do: value in [nil, ""]
end
