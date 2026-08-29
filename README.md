# codex-auth

A lightweight Bash tool for managing multiple Codex CLI accounts. It stores account credentials in a local pool and lets you view usage, add accounts, and switch between them interactively.

## Features

- Automatically syncs the current `~/.codex/auth.json` to the credential pool
- Displays usage and reset times for ChatGPT accounts
- Provides an interactive account picker
- Adds newly authenticated accounts to the pool automatically
- Leaves Codex sessions, history, and other data untouched

## Requirements

- Bash
- `jq`
- `curl`
- [Codex CLI](https://github.com/openai/codex) (required when adding an account)
- Python 3 (used to parse some timestamps and account details)

## Installation

Run the script directly:

```bash
chmod +x codex-auth.sh
./codex-auth.sh
```

Or install it in your local binary directory:

```bash
mkdir -p ~/.local/bin
install -m 755 codex-auth.sh ~/.local/bin/codex-auth
```

Make sure `~/.local/bin` is included in your `PATH`.

## Usage

```bash
# List accounts and usage
codex-auth

# Log in and save a new account
codex-auth login

# Switch accounts interactively
codex-auth switch
```

In the account picker, use `↑` / `↓` to move, `Enter` to confirm, and `q` to quit.

Default file locations:

| File | Path |
| --- | --- |
| Current credentials | `~/.codex/auth.json` |
| Credential pool | `~/.codex/auth-poll.json` |
| Codex configuration | `~/.codex/config.toml` |

Override these paths with the `CURRENT_AUTH_FILE`, `AUTH_POOL_FILE`, and `CONFIG_TOML` environment variables.

> [!WARNING]
> The credential pool contains access tokens or API keys. Do not share it or commit it to version control. The script sets its permissions to `600`. Running `codex-auth login` backs up the current credentials before starting a new Codex login flow.

## License

[MIT](LICENSE)
