defmodule PairingsEngineWeb.UploadGuard do
  @moduledoc """
  Shared guard for every LiveView `consume_uploaded_entries/3` /
  `consume_uploaded_entry/3` call site.

  `Phoenix.LiveView.Upload.consume_uploaded_entries/3` raises `ArgumentError`
  ("cannot consume uploaded files when entries are still in progress") the
  moment it is called while an entry has not yet finished arriving - which is
  exactly what happens when a submit reaches the server a beat before a slow
  upload (over Cloudflare, on a websocket or long-poll connection) has
  completed. Production crashed on this importing an ordinary 20 KB SWAR file
  - see CHANGELOG.

  `status/2` tells a submit handler what it is looking at *before* it calls
  `consume_uploaded_entries/3`, so it can act instead of crash:

    * `:ready` - every entry is done (or there are none); safe to consume.
    * `:uploading` - at least one entry is genuinely still arriving, with no
      error of its own. Consuming now would crash. The handler should keep
      the dialog open, say so calmly (`still_uploading_message/0`), remember
      the request in an assign, and let the upload's own `progress:` callback
      finish the job once `status/2` reports `:ready` again - the entry
      never needs a second click.
    * `:errored` - at least one non-done entry already carries its own error
      (too large, wrong type, ...). It will never finish on its own - there
      is nothing to wait for - so the handler should show
      `entry_error_message/0` (the per-entry reason is already rendered
      beside the dropzone) instead of claiming it is still uploading.
  """

  use Gettext, backend: PairingsEngineWeb.Gettext

  alias Phoenix.LiveView.UploadConfig

  @doc "See the module doc."
  def status(socket, name) do
    conf = Map.fetch!(socket.assigns.uploads, name)

    case Phoenix.LiveView.uploaded_entries(socket, name) do
      {_done, []} ->
        :ready

      {_done, in_progress} ->
        if Enum.any?(in_progress, &entry_errored?(conf, &1)) do
          :errored
        else
          :uploading
        end
    end
  end

  defp entry_errored?(%UploadConfig{} = conf, entry),
    do: Phoenix.Component.upload_errors(conf, entry) != []

  @doc "The calm message shown while a submit is waiting on the upload to finish."
  def still_uploading_message,
    do: gettext("Still uploading - the import starts as soon as the file has arrived.")

  @doc "Shown when a submit found a non-done entry that is never going to finish on its own."
  def entry_error_message,
    do: gettext("That file could not be uploaded. Fix the problem shown above it and try again.")
end
