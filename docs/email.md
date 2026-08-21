# Email / SMTP

OpenPairings sends transactional emails for account confirmation, login links, and email changes.

## Local development

By default, emails are captured in a local preview mailbox. After registering an account or requesting a magic link, visit **http://localhost:4000/dev/mailbox** to view sent emails without leaving the browser.

No setup required - this works out of the box.

## Real email delivery

To send emails to actual inboxes (on a live server or during testing), configure Gmail SMTP.

### Generate a Gmail app password

1. Enable 2-factor authentication on your Google account (https://myaccount.google.com/security)
2. Generate an app password: https://myaccount.google.com/apppasswords
3. Select "Mail" and "Windows Computer" (or your platform)
4. Google will generate a 16-character password; copy it

### Set environment variables

Create a `.env` file in the repository root with two lines:

```
SMTP_USERNAME=your-gmail-address@gmail.com
SMTP_PASSWORD=your-16-char-app-password
```

Replace the placeholders with your actual email and app password. **The `.env` file is gitignored and should never be committed.** On a production server, set these via systemd `Environment=` directives instead (see deployment guides).

### How it works

At boot time, `config/runtime.exs` reads the `.env` file if it exists:
- Parses each `KEY=value` line
- Calls `System.put_env/2` to load them into the runtime environment
- Skips blank lines and comments (lines starting with `#`)
- Does not overwrite variables already set in the actual process environment (so systemd `Environment=` lines take precedence on a real server)

If both `SMTP_USERNAME` and `SMTP_PASSWORD` are present and non-empty, the mailer is configured to use Swoosh's SMTP adapter with Gmail's relay (smtp.gmail.com:587, TLS, STARTTLS).

If either variable is missing or empty, the local mailbox adapter remains active (dev = Swoosh.Adapters.Local, test = Swoosh.Adapters.Test).

### From address

Outgoing emails use the `SMTP_USERNAME` as the from address at send time. If not set, they use the placeholder `contact@example.com`. No email address is hardcoded into source code.

### Testing

The test suite (`config/test.exs`) is pinned to `Swoosh.Adapters.Test` and never sends real email. Tests should not depend on network connectivity or real SMTP credentials.
