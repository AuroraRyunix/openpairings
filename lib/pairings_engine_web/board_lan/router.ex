defmodule PairingsEngineWeb.BoardLan.Router do
  @moduledoc """
  Every route the network listener has (`PairingsEngineWeb.BoardLan`): the
  board link's four, and that is the whole file.

  It is a second router and not a scope of the first one on purpose. The
  first one holds the arbiter's pages, and "a plug in front of it that lets
  only some paths through" is one mistake in a pattern away from serving
  them to the hall. Here there is nothing else to serve: no browser
  pipeline, no session, no LiveView socket, no static files, no dashboard.
  A route that is not in this file does not exist on that port.

  Keep it in step with the `/api/boards/v1` scope of
  `PairingsEngineWeb.Router`; `PairingsEngineWeb.BoardLanPlugTest` compares
  the two.
  """
  use PairingsEngineWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/boards/v1", PairingsEngineWeb do
    pipe_through [:api]

    get "/link", BoardLinkController, :link
    post "/box", BoardLinkController, :box
    get "/tournaments/:id", BoardLinkController, :tournament
    post "/tournaments/:id/games", BoardLinkController, :games
  end
end
