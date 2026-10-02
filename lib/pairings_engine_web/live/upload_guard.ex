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

  @doc """
  True while an entry that can still finish is arriving - the one state in
  which a submit button should be disabled.

  Two things have to hold for that state to end, and both are why every
  upload this guard covers is declared with `auto_upload: true`:

    * the bytes must actually move. Without `auto_upload`, LiveView only
      starts sending a file when its form is submitted, so a button disabled
      until the entry is done can never be pressed and the box sits on "0%"
      forever - which is exactly what 0.70.0 to 0.72.0 shipped for every
      import box (a JSON backup "just hangs on 0%").
    * an entry that failed on its own (wrong type, too large) is not "in
      flight": it will never be done, so counting it would lock the button
      for good. It is left pressable, and the submit answers with
      `entry_error_message/0` beside the reason `error_messages/1` shows.
  """
  def in_flight?(%UploadConfig{entries: entries}),
    do: Enum.any?(entries, &(&1.valid? and not &1.done?))

  @doc """
  Every error on an upload as a sentence a person can act on: the
  upload-wide ones (too many files) and each entry's own (wrong type, too
  large), the latter prefixed with the file's name. Replaces rendering the
  bare atoms, and - unlike rendering `upload_errors/1` alone - includes the
  per-entry reasons, which are the ones a refused file actually gets.
  """
  def error_messages(%UploadConfig{} = conf) do
    upload_wide = Enum.map(Phoenix.Component.upload_errors(conf), &error_text(&1, conf))

    per_entry =
      for entry <- conf.entries,
          err <- Phoenix.Component.upload_errors(conf, entry) do
        "#{entry.client_name}: #{error_text(err, conf)}"
      end

    upload_wide ++ per_entry
  end

  defp error_text(:too_large, %UploadConfig{max_file_size: max}),
    do: gettext("This file is larger than %{mb} MB.", mb: max_mb(max))

  defp error_text(:not_accepted, %UploadConfig{acceptable_exts: exts}) do
    case Enum.sort(exts) do
      [] -> gettext("That file type is not accepted here.")
      sorted -> gettext("Only %{types} files are accepted here.", types: Enum.join(sorted, ", "))
    end
  end

  defp error_text(:too_many_files, %UploadConfig{max_entries: 1}),
    do: gettext("One file at a time.")

  defp error_text(:too_many_files, %UploadConfig{max_entries: max}),
    do: gettext("At most %{count} files at a time.", count: max)

  defp error_text(_other, _conf),
    do: gettext("The upload failed. Choose the file again, or reload the page and retry.")

  defp max_mb(bytes) when rem(bytes, 1_000_000) == 0, do: div(bytes, 1_000_000)
  defp max_mb(bytes), do: Float.round(bytes / 1_000_000, 1)

  @doc "The calm message shown while a submit is waiting on the upload to finish."
  def still_uploading_message,
    do: gettext("Still uploading - the import starts as soon as the file has arrived.")

  @doc "Shown when a submit found a non-done entry that is never going to finish on its own."
  def entry_error_message,
    do: gettext("That file could not be uploaded. Fix the problem shown above it and try again.")
end
