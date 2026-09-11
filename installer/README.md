# Mac installer — maintainer notes

The customer-facing walkthrough is **https://theleadrouter.com/install**. That page tells people to paste

```bash
curl -fsSL https://theleadrouter.com/install.sh | bash
```

into Terminal. `theleadrouter.com/install.sh` serves [`../install.sh`](../install.sh) from this repository's `main` branch, so **editing and pushing `install.sh` here is the release**; nothing on the website needs to change.

## What `install.sh` does

It first asks one question, **Are you a Lead Router customer?**, and if yes, asks for the Lead Router API key (a `pk_` posting key is rejected; `skip` leaves the placeholder). Then, unattended:

| # | Step | What happens |
|---|---|---|
| 1 | Homebrew | Official installer, non-interactive; needs the Mac password once. Also installs Apple's Command Line Tools (git). |
| 2 | GitHub CLI | `brew install gh` (`--with-github-desktop` adds the GitHub Desktop app). |
| 3 | Claude Code | Anthropic's native installer → `~/.local/bin/claude`. |
| 4 | Orca | Latest DMG from `github.com/stablyai/orca` (arm64/x64 auto), → `/Applications/Orca.app`, Gatekeeper-verified. |
| 5 | Lead Router kit | `~/Development` (+ Finder sidebar favorite), this repo cloned to `~/Development/leadrouter`, `.env` written there with `LEADROUTER_API_KEY=` (key or the `paste-your-key-here` placeholder), mode 600. |
| 6 | `claude --dsp` | Shell function in `~/.zshrc`/`~/.bashrc` so `claude --dsp …` = `claude --dangerously-skip-permissions …`. Skipped, visibly, if a custom `claude` already exists. |
| 7 | Open in Orca | Opens Orca, registers the folder as project **Lead Router**, opens a "Claude Code" tab and starts `claude --dangerously-skip-permissions` in it. |

Safe to re-run: every step detects work already done, including the Orca project and tab. Failures are listed in a summary, anything needing a human goes in a "To do by hand" list, and the log is `~/Library/Logs/mac-dev-installer.log`.

Flags: `--dry-run`, `--no-open` (skip step 7), `--with-github-desktop`, `--help`. Env for unattended runs: `LEADROUTER_CUSTOMER=yes|no`, `LEADROUTER_API_KEY=lr_…`, `APPS_DIR=/path` (where Orca.app goes).

## Rules for editing it

- It runs under macOS's stock `/bin/bash` **3.2** (that is what a double-clicked `.command` uses). No bash 4+ features, and never put a non-ASCII character directly after a `$variable` — bash 3.2 swallows it into the variable name and dies with "unbound variable".
- Test with `/bin/bash install.sh --dry-run`, not `bash` (Homebrew's bash 5 hides the 3.2 problems). `shellcheck -x install.sh` must be clean.
- Questions are read from `/dev/tty`, so they work when the script is piped from `curl`.
- Orca CLI (1.4.x) quirks the step 7 code works around: `terminal create --command "claude …"` and `--focus` time out, so it opens a plain tab, `terminal send`s the command, waits for `tui-idle`, then `terminal switch`. `project setup-existing-folder` ignores `--display-name`, so the project is renamed with `setup-update`. JSON replies nest as `result.result`.
- The Finder favorite uses the shared-file-list API through a tiny Swift helper compiled at run time (`swiftc` ships with the Command Line Tools); the insert call goes through a raw C signature because Swift otherwise retains the `kLSSharedFileListItemLast` sentinel and crashes.

## Building the double-click fallback

```bash
bash installer/build.sh      # → installer/dist/lead-router-installer.zip
```

The zip keeps the executable bit (a bare `.command` sent through Slack loses it). Because it is not code-signed, macOS 15+ shows "Apple could not verify" on first launch; the user must go to System Settings → Privacy & Security → Open Anyway. A signed and notarized `.dmg` (Apple Developer ID required) is the fix for that and is not built yet.

## Verification status

Tested 2026-09-11 on macOS 26.5 / Apple Silicon, Orca 1.4.198, Claude Code 2.1.269: shellcheck clean on bash 3.2; prompts driven through a pseudo-terminal; real runs against scratch home directories (non-customer, customer with key substituted into an existing `.env`, then a re-run with everything reported as already done); Finder favorite added and read back; Orca project created, renamed, Claude reached its trust prompt in the tab, tab reused on re-run; Orca fresh-install DMG path; `.command` launched via Terminal.

Not tested (no clean Mac): Homebrew and Claude Code fresh-install paths, Intel, Orca's very first launch on a machine that has never run it, the Gatekeeper dialog for a downloaded `.command`.
