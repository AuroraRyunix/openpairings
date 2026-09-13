defmodule PairingsEngine.FailingMailer do
  @moduledoc """
  A Swoosh adapter that always fails, for exercising the `{:error, reason}`
  branch of a mail send in tests without touching the network.

  `Swoosh.Adapters.Test` (the suite's normal adapter, see config/test.exs)
  always succeeds and just records the email for `Swoosh.TestAssertions` -
  by design, since it exists to let tests assert what WOULD have been sent.
  That is exactly why nothing in the suite ever exercised an SMTP failure
  before this: there was no way to make a send fail in-process.

  Swap it in for the length of one test:

      setup do
        previous = Application.get_env(:pairings_engine, PairingsEngine.Mailer)
        Application.put_env(:pairings_engine, PairingsEngine.Mailer, adapter: PairingsEngine.FailingMailer)
        on_exit(fn -> Application.put_env(:pairings_engine, PairingsEngine.Mailer, previous) end)
      end

  `Application.put_env/3` here is test-suite-wide state (the sandbox does
  not isolate it), which is exactly why every test that changes it restores
  the previous value in `on_exit`.
  """

  use Swoosh.Adapter

  @impl Swoosh.Adapter
  def deliver(%Swoosh.Email{}, _config), do: {:error, :test_failure}

  @impl Swoosh.Adapter
  def deliver_many(_emails, _config), do: {:error, :test_failure}
end
