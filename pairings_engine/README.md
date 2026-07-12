# OpenPairings

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Email setup (optional for local development)

In development, emails are captured locally at http://localhost:4000/dev/mailbox — no setup required.

To send real emails during testing or to add SMTP support, create a `.env` file in this directory with Gmail app-password credentials:

```
SMTP_USERNAME=your-email@gmail.com
SMTP_PASSWORD=your-app-password
```

The `.env` file is gitignored and loaded at boot time by `config/runtime.exs`. See [`../docs/email.md`](../docs/email.md) for full details on generating an app password and production deployment.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
