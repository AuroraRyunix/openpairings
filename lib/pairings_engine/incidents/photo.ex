defmodule PairingsEngine.Incidents.Photo do
  @moduledoc """
  The one photo an incident may carry (docs/manubrium.md): a JPEG the phone
  shrank before sending, kept in the database beside the tournament like
  its print logo, so a backup carries it and deleting the tournament takes
  it along (`ON DELETE CASCADE`, twice: the tournament and the incident).

  Served only to someone who may open the tournament's desk pages
  (`PairingsEngineWeb.IncidentPhotoController`), never on a public page and
  never to a phone.
  """
  use Ecto.Schema

  schema "incident_photos" do
    field :content_type, :string
    field :byte_size, :integer
    field :data, :binary

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :incident, PairingsEngine.Incidents.Incident

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
