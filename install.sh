#!/bin/bash
#
# mac-dev-installer — one-shot setup for a new Mac.
#
#   1. Homebrew        package manager (also installs Apple's Command Line Tools + git)
#   2. GitHub CLI      `gh` via Homebrew (git itself arrives with the Command Line Tools)
#   3. Claude Code     Anthropic's official native installer (~/.local/bin/claude)
#   4. Orca            latest release from github.com/stablyai/orca → /Applications
#   5. Lead Router     ~/Development (added to Finder favorites) → ~/Development/leadrouter
#                      cloned from github.com/jasonakatiff/theleadrouter.com-onboarding,
#                      with a .env carrying LEADROUTER_API_KEY (your key if you are a customer)
#   6. `claude --dsp`  shell shortcut for `claude --dangerously-skip-permissions`
#   7. Orca project    "Lead Router" project attached to ~/Development/leadrouter, with a
#                      Claude Code session (--dangerously-skip-permissions) open in it
#
# then tells you to go through the walkthrough in Orca.
#
# Safe to re-run: every step checks whether its work is already done.
# Runs on macOS's stock /bin/bash (3.2) — keep it free of bash 4+ features, and keep
# non-ASCII characters away from "$variables" (bash 3.2 swallows them into the name).
#
# Usage:
#   bash install.sh [--dry-run] [--no-open] [--with-github-desktop] [--help]
#
# Environment (all optional; the interactive questions are skipped when these are set):
#   LEADROUTER_CUSTOMER   yes|no   answer to "Are you a Lead Router customer?"
#   LEADROUTER_API_KEY    lr_...   the API key to write into ~/Development/leadrouter/.env
#   APPS_DIR              where Orca.app is installed (default: /Applications)

set -euo pipefail

INSTALLER_VERSION="1.1.0"
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
CLAUDE_INSTALL_URL="https://claude.ai/install.sh"
ORCA_DOWNLOAD_BASE="https://github.com/stablyai/orca/releases/latest/download"
LEADROUTER_REPO_URL="https://github.com/jasonakatiff/theleadrouter.com-onboarding.git"
LEADROUTER_PROJECT_ID="github:jasonakatiff/theleadrouter.com-onboarding"
LEADROUTER_PROJECT_NAME="Lead Router"
ENV_KEY_PLACEHOLDER="paste-your-key-here"
CLAUDE_DSP_FLAG="--dangerously-skip-permissions"
CLAUDE_TERMINAL_TITLE="Claude Code"
ORCA_OPEN_TIMEOUT_SECONDS=180
APPS_DIR="${APPS_DIR:-/Applications}"
DEV_DIR="$HOME/Development"
LEADROUTER_DIR="$DEV_DIR/leadrouter"
LOG_FILE="$HOME/Library/Logs/mac-dev-installer.log"
ZPROFILE="$HOME/.zprofile"
MIN_MACOS_MAJOR=13

DRY_RUN=0
NO_OPEN=0
WITH_GITHUB_DESKTOP=0

usage() {
  cat <<EOF
mac-dev-installer $INSTALLER_VERSION

Sets up a Mac for The Lead Router: Homebrew, GitHub CLI, Claude Code, Orca, the
Lead Router onboarding project (~/Development/leadrouter) with your API key in
.env, a \`claude --dsp\` shell shortcut, and a Claude Code session open in Orca.
Safe to re-run.

Usage: bash install.sh [options]

  --dry-run              Show what would be done without changing anything
  --no-open              Do not open Orca / Claude Code at the end
  --with-github-desktop  Also install the GitHub Desktop app
  --help                 Show this help

Environment (skips the questions): LEADROUTER_CUSTOMER=yes|no  LEADROUTER_API_KEY=lr_...
Log: $LOG_FILE
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-open) NO_OPEN=1 ;;
    --with-github-desktop) WITH_GITHUB_DESKTOP=1 ;;
    --help|-h) usage; exit 0 ;;
    --version) echo "$INSTALLER_VERSION"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- output ----

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}
say()  { printf '%s\n' "$*"; log "$*"; }
ok()   { printf '%s✔%s %s\n' "$GREEN" "$RESET" "$*"; log "OK: $*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; log "WARN: $*"; }
fail() { printf '%s✘ %s%s\n' "$RED" "$*" "$RESET" >&2; log "FAIL: $*"; }
die()  { fail "$*"; exit 1; }

# Run a command, echoing it to the log. In --dry-run, print it and do nothing.
run() {
  log "  \$ $*"
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s(dry-run) $ %s%s\n' "$DIM" "$*" "$RESET"
    return 0
  fi
  "$@"
}

# Append a line to a shell profile unless an equivalent line is already there.
#   ensure_line <file> <line> <grep-pattern-that-means-already-present> <comment>
ensure_line() {
  local file="$1" line="$2" pattern="$3" comment="$4"
  if [ -f "$file" ] && grep -q -- "$pattern" "$file"; then
    return 0
  fi
  say "Adding to $file: $line"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  printf '\n# %s\n%s\n' "$comment" "$line" >> "$file"
}

# Ask a question on the terminal (works even when the script itself is piped in).
#   ask <prompt>  -> REPLY
ask() {
  REPLY=""
  if [ ! -r /dev/tty ]; then return 1; fi
  printf '%s' "$1" > /dev/tty
  IFS= read -r REPLY < /dev/tty || return 1
  # trim surrounding whitespace
  REPLY="$(printf '%s' "$REPLY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------- results ---

RESULT_NAMES=()
RESULT_STATES=()
MANUAL_STEPS=()
FAILED=0
STEP_N=0
STEP_TOTAL=7

record() { RESULT_NAMES+=("$1"); RESULT_STATES+=("$2"); }
manual_step() { MANUAL_STEPS+=("$1"); warn "$1"; }

run_step() {
  local name="$1" fn="$2"
  STEP_N=$((STEP_N + 1))
  printf '\n%s[%d/%d] %s%s\n' "$BOLD" "$STEP_N" "$STEP_TOTAL" "$name" "$RESET"
  log "=== [$STEP_N/$STEP_TOTAL] $name ==="
  # Inside this `if`, errexit is suspended — step functions must `|| return 1`.
  if "$fn"; then
    :
  else
    record "$name" "${RED}FAILED${RESET}"
    FAILED=1
  fi
}

# ---------------------------------------------------------------- cleanup ---

TMP_DIR=""
MOUNTED=""
KEEPALIVE_PID=""

cleanup() {
  if [ -n "$MOUNTED" ]; then hdiutil detach -quiet "$MOUNTED" >/dev/null 2>&1 || true; fi
  if [ -n "$KEEPALIVE_PID" ]; then kill "$KEEPALIVE_PID" >/dev/null 2>&1 || true; fi
  case "$TMP_DIR" in
    */mac-dev-installer.*) rm -rf "$TMP_DIR" ;;
  esac
}
trap cleanup EXIT

# ---------------------------------------------------------------- sudo ------

SUDO_READY=0

# Homebrew's installer needs a cached sudo ticket in non-interactive mode.
ensure_sudo() {
  if [ "$SUDO_READY" = 1 ]; then return 0; fi
  say "Administrator rights are needed for this step. Enter your Mac login password if asked."
  if [ "$DRY_RUN" = 1 ]; then SUDO_READY=1; return 0; fi
  if ! sudo -v; then
    fail "Could not get administrator rights. Your account must be an Administrator."
    return 1
  fi
  # Keep the sudo ticket alive for the duration of the script.
  ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  KEEPALIVE_PID=$!
  SUDO_READY=1
}

# ---------------------------------------------------------------- preflight -

ARCH=""

preflight() {
  [ "$(uname -s)" = "Darwin" ] || die "This installer is for macOS only."
  if [ "$(id -u)" -eq 0 ]; then
    die "Run this as your normal user, not with sudo or as root. (Homebrew and Claude Code refuse to install as root.)"
  fi

  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
    ARCH="arm64"
  else
    ARCH="x64"
  fi

  local macos_version macos_major
  macos_version="$(sw_vers -productVersion)"
  macos_major="${macos_version%%.*}"
  if [ "$macos_major" -lt "$MIN_MACOS_MAJOR" ]; then
    warn "macOS $macos_version is older than $MIN_MACOS_MAJOR. Homebrew may not support it; continuing anyway."
  fi

  if ! curl -fsS --max-time 15 -o /dev/null https://github.com/; then
    die "No internet connection (could not reach github.com). Connect and re-run."
  fi

  say "macOS $macos_version · $ARCH · apps → $APPS_DIR"
  say "Log: $LOG_FILE"
  if [ "$DRY_RUN" = 1 ]; then warn "DRY RUN — nothing will be installed or changed."; fi
}

# ---------------------------------------------------------------- questions -

IS_CUSTOMER=0
API_KEY=""

ask_questions() {
  local answer
  answer="$(lower "${LEADROUTER_CUSTOMER:-}")"
  case "$answer" in
    y|yes|1|true)  IS_CUSTOMER=1 ;;
    n|no|0|false)  IS_CUSTOMER=0 ;;
    "")
      printf '\n%sBefore we start, one question.%s\n' "$BOLD" "$RESET"
      if ask "Are you a Lead Router customer? [y/N] "; then
        case "$(lower "$REPLY")" in
          y|yes) IS_CUSTOMER=1 ;;
          *)     IS_CUSTOMER=0 ;;
        esac
      else
        warn "No terminal to ask on; assuming you are NOT a Lead Router customer. Set LEADROUTER_CUSTOMER=yes to change that."
      fi
      ;;
    *) die "LEADROUTER_CUSTOMER must be yes or no (got: $LEADROUTER_CUSTOMER)" ;;
  esac
  log "customer=$IS_CUSTOMER"

  if [ "$IS_CUSTOMER" = 1 ]; then
    API_KEY="${LEADROUTER_API_KEY:-}"
    while [ -z "$API_KEY" ]; do
      printf '\nYour Lead Router API key lets your assistant work with your account.\n'
      printf 'It must be a %sSystem%s key (theleadrouter.com > System > API Keys). It starts with lr_ .\n' "$BOLD" "$RESET"
      printf 'Type "skip" to leave the placeholder in .env and paste the key in later.\n'
      if ! ask "Paste your Lead Router API key: "; then
        warn "No terminal to ask on; leaving the placeholder in .env. Set LEADROUTER_API_KEY to supply it."
        break
      fi
      case "$(lower "$REPLY")" in
        skip) warn "Skipping the API key. Edit $LEADROUTER_DIR/.env later."; break ;;
        "")   continue ;;
      esac
      case "$REPLY" in
        pk_*) warn "That starts with pk_, which is a posting key. It will not work here. Create a System key instead."; continue ;;
        *[[:space:]]*) warn "The key contains spaces; paste just the key."; continue ;;
        lr_*) ;;
        *) warn "Keys normally start with lr_. Using it anyway." ;;
      esac
      API_KEY="$REPLY"
    done
    if [ -n "$API_KEY" ]; then ok "API key received (ends with ...${API_KEY#"${API_KEY%????}"})"; fi
    log "api key: $([ -n "$API_KEY" ] && echo provided || echo none)"
  fi
  printf '\nThanks. The rest runs on its own. You will be asked for your Mac password once if Homebrew needs installing.\n'
}

# ---------------------------------------------------------------- 1 brew ----

brew_path() {
  if [ "$ARCH" = "arm64" ]; then echo "/opt/homebrew/bin/brew"; else echo "/usr/local/bin/brew"; fi
}

install_homebrew() {
  local brew
  brew="$(brew_path)"

  if [ -x "$brew" ]; then
    ok "Homebrew already installed ($("$brew" --version 2>/dev/null | head -1))"
    record "Homebrew" "already installed"
  else
    ensure_sudo || return 1
    say "Installing Homebrew. This also installs Apple's Command Line Tools and can take 5-15 minutes."
    run curl -fsSL -o "$TMP_DIR/brew-install.sh" "$HOMEBREW_INSTALL_URL" || { fail "Could not download the Homebrew installer."; return 1; }
    run env NONINTERACTIVE=1 /bin/bash "$TMP_DIR/brew-install.sh" || { fail "Homebrew installer exited with an error (see output above)."; return 1; }
    if [ "$DRY_RUN" = 0 ] && [ ! -x "$brew" ]; then
      fail "Homebrew installer finished but $brew is missing."
      return 1
    fi
    ok "Homebrew installed"
    record "Homebrew" "installed"
  fi

  # Make brew usable for the rest of this run and for every future terminal.
  if [ -x "$brew" ]; then eval "$("$brew" shellenv)"; fi
  ensure_line "$ZPROFILE" "eval \"\$($brew shellenv)\"" 'brew shellenv' "Homebrew (added by mac-dev-installer)"
}

# ---------------------------------------------------------------- 2 gh ------

install_github_cli() {
  local brew
  brew="$(brew_path)"
  if [ ! -x "$brew" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      say "(dry-run) would run: brew install gh"
      record "GitHub CLI" "would install"
      return 0
    fi
    fail "Homebrew is not available, so gh cannot be installed."
    return 1
  fi

  local state="already installed"
  if "$brew" list --formula gh >/dev/null 2>&1; then
    ok "gh already installed"
  else
    say "Installing gh..."
    run "$brew" install gh || { fail "brew install gh failed."; return 1; }
    state="installed"
  fi

  if [ "$WITH_GITHUB_DESKTOP" = 1 ]; then
    if "$brew" list --cask github >/dev/null 2>&1; then
      ok "GitHub Desktop already installed"
    else
      say "Installing GitHub Desktop..."
      run "$brew" install --cask github || { fail "brew install --cask github failed."; return 1; }
      state="installed"
    fi
  fi

  if [ "$DRY_RUN" = 0 ]; then
    command -v gh >/dev/null 2>&1 || { fail "gh is installed but not on PATH. Open a new terminal and re-run."; return 1; }
    ok "$(gh --version | head -1)"
  fi
  record "GitHub CLI" "$state"
}

# ---------------------------------------------------------------- 3 claude --

install_claude_code() {
  local claude_bin="$HOME/.local/bin/claude"
  export PATH="$HOME/.local/bin:$PATH"

  if [ -x "$claude_bin" ] || command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed ($(claude --version 2>/dev/null | head -1))"
    record "Claude Code" "already installed"
  else
    say "Installing Claude Code..."
    run curl -fsSL -o "$TMP_DIR/claude-install.sh" "$CLAUDE_INSTALL_URL" || { fail "Could not download the Claude Code installer."; return 1; }
    run /bin/bash "$TMP_DIR/claude-install.sh" || { fail "Claude Code installer exited with an error (see output above)."; return 1; }
    if [ "$DRY_RUN" = 0 ] && [ ! -x "$claude_bin" ]; then
      fail "Claude Code installer finished but $claude_bin is missing."
      return 1
    fi
    ok "Claude Code installed ($("$claude_bin" --version 2>/dev/null | head -1))"
    record "Claude Code" "installed"
  fi

  # Claude's installer normally adds ~/.local/bin to PATH; make sure a fresh
  # login shell can find it either way.
  if [ "$DRY_RUN" = 0 ] && ! zsh -lc 'command -v claude' >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # literal $HOME belongs in .zprofile
    ensure_line "$ZPROFILE" 'export PATH="$HOME/.local/bin:$PATH"' '\.local/bin' "Claude Code (added by mac-dev-installer)"
  fi
}

# ---------------------------------------------------------------- 4 orca ----

orca_version() {
  defaults read "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?"
}

install_orca() {
  local app="$APPS_DIR/Orca.app"

  if [ -d "$app" ]; then
    ok "Orca already installed (v$(orca_version "$app") at $app)"
    record "Orca" "already installed"
    return 0
  fi

  local dmg_name
  if [ "$ARCH" = "arm64" ]; then dmg_name="orca-macos-arm64.dmg"; else dmg_name="orca-macos-x64.dmg"; fi
  local url="$ORCA_DOWNLOAD_BASE/$dmg_name"
  local dmg="$TMP_DIR/$dmg_name"
  local mnt="$TMP_DIR/orca-dmg"

  say "Downloading Orca ($dmg_name, about 200 MB)..."
  run curl -fL --progress-bar -o "$dmg" "$url" || { fail "Download failed: $url"; return 1; }

  run mkdir -p "$mnt"
  run hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "$dmg" || { fail "Could not mount $dmg_name."; return 1; }
  if [ "$DRY_RUN" = 0 ]; then MOUNTED="$mnt"; fi

  local src
  if [ "$DRY_RUN" = 1 ]; then
    src="$mnt/Orca.app"
  else
    src="$(find "$mnt" -maxdepth 1 -name '*.app' -print 2>/dev/null | head -1)"
    [ -n "$src" ] || { fail "No .app found inside $dmg_name."; return 1; }
  fi

  say "Copying $(basename "$src") to $APPS_DIR..."
  if [ -w "$APPS_DIR" ]; then
    run ditto "$src" "$app" || { fail "Could not copy Orca into $APPS_DIR."; return 1; }
  else
    ensure_sudo || return 1
    run sudo ditto "$src" "$app" || { fail "Could not copy Orca into $APPS_DIR (even with sudo)."; return 1; }
  fi

  run hdiutil detach -quiet "$mnt" || warn "Could not unmount the DMG; it will be cleaned up on exit."
  MOUNTED=""

  if [ "$DRY_RUN" = 0 ]; then
    # Gatekeeper must accept the app or `open` will refuse to launch it.
    if ! spctl -a -t exec "$app" >/dev/null 2>&1; then
      fail "Orca was copied but macOS Gatekeeper rejects it. Delete $app and re-run, or download it manually from https://onOrca.dev"
      return 1
    fi
    ok "Orca v$(orca_version "$app") installed and verified by Gatekeeper"
  else
    ok "(dry-run) Orca would be installed to $app"
  fi
  record "Orca" "installed"
}

# ---------------------------------------------------------------- 5 project -

# Finder has no scriptable sidebar, so this talks to the same shared-file-list
# API Finder uses, through a tiny Swift helper compiled on the spot (swiftc ships
# with the Command Line Tools that Homebrew installed in step 1).
write_sidebar_helper_source() {
  cat > "$1" <<'SWIFT'
import Foundation
import CoreServices

// Declared with raw pointers so Swift never retains the kLSSharedFileListItemLast
// sentinel (it is the literal pointer 0x2, not an object).
@_silgen_name("LSSharedFileListInsertItemURL")
func rawInsertItemURL(_ list: UnsafeRawPointer, _ after: UnsafeRawPointer?, _ name: UnsafeRawPointer?,
                      _ icon: UnsafeRawPointer?, _ url: UnsafeRawPointer, _ props: UnsafeRawPointer?,
                      _ propsToClear: UnsafeRawPointer?) -> UnsafeRawPointer?

let argv = CommandLine.arguments
guard argv.count >= 3 else { print("usage: sidebar add|has <path>"); exit(2) }
guard let list = LSSharedFileListCreate(kCFAllocatorDefault, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil)?.takeRetainedValue() else {
    print("failed: cannot open Finder favorites list"); exit(1)
}
func items() -> [LSSharedFileListItem] {
    var seed: UInt32 = 0
    guard let snap = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() else { return [] }
    return snap as! [LSSharedFileListItem]
}
func urlOf(_ item: LSSharedFileListItem) -> URL? {
    var err: Unmanaged<CFError>?
    guard let cf = LSSharedFileListItemCopyResolvedURL(item, 0, &err)?.takeRetainedValue() else { return nil }
    return (cf as URL).standardizedFileURL
}
let url = URL(fileURLWithPath: argv[2]).standardizedFileURL
let present = items().contains(where: { urlOf($0) == url })
switch argv[1] {
case "has":
    print(present ? "yes" : "no"); exit(present ? 0 : 1)
case "add":
    if present { print("already"); exit(0) }
    let cfurl = url as CFURL
    let listPtr = UnsafeRawPointer(Unmanaged.passUnretained(list).toOpaque())
    let urlPtr = UnsafeRawPointer(Unmanaged.passUnretained(cfurl).toOpaque())
    let last = UnsafeRawPointer(bitPattern: 2)   // kLSSharedFileListItemLast
    if rawInsertItemURL(listPtr, last, nil, nil, urlPtr, nil, nil) == nil { print("failed"); exit(1) }
    print("added")
default: exit(2)
}
SWIFT
}

add_finder_favorite() {
  local folder="$1"
  local drag_hint="Add it by hand: open a Finder window, drag the Development folder into the sidebar under Favorites."
  if [ "$DRY_RUN" = 1 ]; then
    say "(dry-run) would add $folder to Finder favorites"
    return 0
  fi
  # xcode-select -p is safe to call without the Command Line Tools; xcrun is not
  # (it pops the install dialog), so check the former before touching the latter.
  if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    manual_step "Could not add Development to Finder favorites (no Swift compiler; are the Command Line Tools installed?). $drag_hint"
    return 0
  fi
  local src="$TMP_DIR/sidebar.swift" bin="$TMP_DIR/sidebar"
  write_sidebar_helper_source "$src"
  say "Adding Development to Finder favorites (building a small helper, up to 30 seconds)..."
  if ! xcrun swiftc -suppress-warnings -O -o "$bin" "$src" >>"$LOG_FILE" 2>&1; then
    manual_step "Could not add Development to Finder favorites (helper failed to build; see the log). $drag_hint"
    return 0
  fi
  local result
  result="$("$bin" add "$folder" 2>>"$LOG_FILE" || true)"
  case "$result" in
    added)   ok "Development added to Finder favorites" ;;
    already) ok "Development is already in Finder favorites" ;;
    *)       manual_step "Could not add Development to Finder favorites ($result). $drag_hint" ;;
  esac
}

clone_leadrouter_repo() {
  local origin
  if [ -d "$LEADROUTER_DIR/.git" ]; then
    origin="$(git -C "$LEADROUTER_DIR" remote get-url origin 2>/dev/null || true)"
    case "$origin" in
      *theleadrouter.com-onboarding*)
        ok "Onboarding kit already cloned at $LEADROUTER_DIR"
        if ! run git -C "$LEADROUTER_DIR" pull --ff-only --quiet; then
          warn "Could not update it (offline, or local changes). Leaving it as it is."
        fi
        return 0 ;;
      *)
        fail "$LEADROUTER_DIR is a different git repository ($origin). Move it aside and re-run."
        return 1 ;;
    esac
  fi
  if [ -d "$LEADROUTER_DIR" ] && [ -n "$(ls -A "$LEADROUTER_DIR" 2>/dev/null)" ]; then
    fail "$LEADROUTER_DIR exists and is not empty, but is not the onboarding kit. Move it aside and re-run."
    return 1
  fi
  command -v git >/dev/null 2>&1 || { fail "git is not available (it comes with the Command Line Tools installed by Homebrew)."; return 1; }
  say "Downloading the Lead Router onboarding kit..."
  run git clone --quiet "$LEADROUTER_REPO_URL" "$LEADROUTER_DIR" || { fail "git clone failed for $LEADROUTER_REPO_URL"; return 1; }
  ok "Onboarding kit cloned to $LEADROUTER_DIR"
}

write_env_file() {
  local env_file="$LEADROUTER_DIR/.env" example="$LEADROUTER_DIR/.env.example"
  if [ "$DRY_RUN" = 1 ]; then
    if [ -n "$API_KEY" ]; then say "(dry-run) would write $env_file with LEADROUTER_API_KEY=<your key>"
    else say "(dry-run) would write $env_file with LEADROUTER_API_KEY=$ENV_KEY_PLACEHOLDER"; fi
    return 0
  fi
  if [ ! -f "$env_file" ]; then
    if [ -f "$example" ]; then
      cp "$example" "$env_file" || { fail "Could not create $env_file"; return 1; }
    else
      printf 'LEADROUTER_API_KEY=%s\n' "$ENV_KEY_PLACEHOLDER" > "$env_file" || { fail "Could not create $env_file"; return 1; }
    fi
    log "created $env_file"
  fi
  if [ -n "$API_KEY" ]; then
    if grep -q '^LEADROUTER_API_KEY=' "$env_file"; then
      if ! awk -v k="$API_KEY" '/^LEADROUTER_API_KEY=/ { print "LEADROUTER_API_KEY=" k; next } { print }' "$env_file" > "$env_file.tmp"; then
        fail "Could not update $env_file"; return 1
      fi
      mv -f "$env_file.tmp" "$env_file" || { fail "Could not update $env_file"; return 1; }
    else
      printf '\nLEADROUTER_API_KEY=%s\n' "$API_KEY" >> "$env_file"
    fi
    chmod 600 "$env_file"
    ok "API key saved in $env_file"
  else
    chmod 600 "$env_file"
    if grep -q "^LEADROUTER_API_KEY=$ENV_KEY_PLACEHOLDER" "$env_file"; then
      manual_step "No API key was entered. When you have one, open $env_file and replace $ENV_KEY_PLACEHOLDER with it."
    else
      ok "$env_file already has a key; leaving it alone"
    fi
  fi
}

setup_leadrouter_project() {
  if [ -d "$DEV_DIR" ]; then
    ok "$DEV_DIR already exists"
  else
    run mkdir -p "$DEV_DIR" || { fail "Could not create $DEV_DIR"; return 1; }
    ok "Created $DEV_DIR"
  fi
  add_finder_favorite "$DEV_DIR"
  clone_leadrouter_repo || return 1
  write_env_file || return 1
  record "Lead Router kit" "ready at $LEADROUTER_DIR"
}

# ---------------------------------------------------------------- 6 --dsp ---

install_claude_dsp_shortcut() {
  local rc shell_name
  shell_name="$(basename "${SHELL:-/bin/zsh}")"
  case "$shell_name" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    *)
      manual_step "Your shell is $shell_name, which this installer does not know. Add the claude --dsp shortcut to its config by hand: claude() { if [ \"\$1\" = --dsp ]; then shift; command claude $CLAUDE_DSP_FLAG \"\$@\"; else command claude \"\$@\"; fi; }"
      record "claude --dsp" "skipped ($shell_name)"
      return 0 ;;
  esac

  if [ -f "$rc" ] && grep -q 'added by mac-dev-installer' "$rc" && grep -q -- '--dsp' "$rc"; then
    ok "claude --dsp shortcut already in $rc"
    record "claude --dsp" "already installed"
    return 0
  fi
  if [ -f "$rc" ] && grep -qE '^[[:space:]]*(function[[:space:]]+claude|claude[[:space:]]*\(\)|alias[[:space:]]+claude=)' "$rc"; then
    manual_step "$rc already defines its own 'claude' function or alias, so the --dsp shortcut was not added. Add --dsp handling to that definition if you want it."
    record "claude --dsp" "skipped (custom claude in $rc)"
    return 0
  fi

  say "Adding the claude --dsp shortcut to $rc"
  if [ "$DRY_RUN" = 0 ]; then
    cat >> "$rc" <<EOF

# claude --dsp shortcut (added by mac-dev-installer)
# \`claude --dsp ...\` runs \`claude $CLAUDE_DSP_FLAG ...\`
claude() {
  if [ "\${1:-}" = "--dsp" ]; then
    shift
    command claude $CLAUDE_DSP_FLAG "\$@"
  else
    command claude "\$@"
  fi
}
EOF
  fi
  ok "claude --dsp shortcut added (takes effect in new terminal windows)"
  record "claude --dsp" "installed"
}

# ---------------------------------------------------------------- 7 orca ----

ORCA=""

orca_cli() {
  if [ -x "$APPS_DIR/Orca.app/Contents/Resources/bin/orca" ]; then
    ORCA="$APPS_DIR/Orca.app/Contents/Resources/bin/orca"
  elif command -v orca >/dev/null 2>&1; then
    ORCA="$(command -v orca)"
  else
    return 1
  fi
}

# Pull one value out of an Orca --json reply. Orca nests replies as result.result.
#   orca_json <file> <what> [arg]
orca_json() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, sys
path, what, arg = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(path))
except Exception:
    if what == "error":
        try:
            print(open(path).read().strip()[:300])
        except Exception:
            pass
    sys.exit(0)
r = d.get("result", d) if isinstance(d, dict) else {}
if isinstance(r, dict) and isinstance(r.get("result"), dict):
    r = r["result"]
if what == "ok":
    print("yes" if d.get("ok") else "no")
elif what == "error":
    e = d.get("error") or {}
    print(e.get("message") or e.get("code") or json.dumps(e)[:200])
elif what == "setup-id":
    print((r.get("setup") or {}).get("id", ""))
elif what == "setup-id-by-path":
    print(next((s.get("id", "") for s in r.get("setups", []) if s.get("hostId") == "local" and s.get("path") == arg), ""))
elif what == "terminal-handle":
    print((r.get("terminal") or {}).get("handle", ""))
elif what == "claude-terminal":
    # prints "<handle> <agentIdentity>" for the live terminal tab with the given title
    t = next((t for t in r.get("terminals", [])
              if t.get("title") == arg and t.get("connected", True) and not t.get("orphaned", False)), None)
    print("%s %s" % (t.get("handle", ""), t.get("agentIdentity") or "-") if t else "")
PY
}

# `orca open` waits for the runtime with no timeout of its own; bound it here.
orca_open_bounded() {
  local out="$TMP_DIR/orca-open.json" pid i
  "$ORCA" open --json > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt "$ORCA_OPEN_TIMEOUT_SECONDS" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" && [ "$(orca_json "$out" ok)" = "yes" ]
      return $?
    fi
    sleep 1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  return 124
}

open_in_orca() {
  local manual="Do it by hand in Orca: add $LEADROUTER_DIR as a project, open a terminal in it, and run: claude $CLAUDE_DSP_FLAG"
  if [ "$NO_OPEN" = 1 ]; then
    say "Skipping (--no-open). $manual"
    record "Orca project" "skipped (--no-open)"
    return 0
  fi
  if ! orca_cli; then
    if [ "$DRY_RUN" = 1 ]; then
      say "(dry-run) would open Orca, add the $LEADROUTER_PROJECT_NAME project and start Claude Code in it"
      record "Orca project" "would create"
      return 0
    fi
    fail "The orca command-line tool was not found inside $APPS_DIR/Orca.app. $manual"
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || { fail "python3 is missing (it comes with the Command Line Tools). $manual"; return 1; }

  if [ "$DRY_RUN" = 1 ]; then
    say "(dry-run) would run: orca open; orca project setup-existing-folder --path $LEADROUTER_DIR; orca project setup-update --display-name \"$LEADROUTER_PROJECT_NAME\"; orca terminal create --command \"claude $CLAUDE_DSP_FLAG\""
    record "Orca project" "would create"
    return 0
  fi

  say "Opening Orca..."
  if ! orca_open_bounded; then
    fail "Orca did not become ready within $ORCA_OPEN_TIMEOUT_SECONDS seconds. Open Orca, finish its first-run setup, then re-run this installer. $manual"
    return 1
  fi

  local out="$TMP_DIR/orca-out.json" setup_id
  "$ORCA" project setups --host local --json > "$out" 2>&1 || true
  setup_id="$(orca_json "$out" setup-id-by-path "$LEADROUTER_DIR")"
  if [ -n "$setup_id" ]; then
    ok "$LEADROUTER_PROJECT_NAME project already in Orca"
  else
    say "Adding the $LEADROUTER_PROJECT_NAME project to Orca..."
    if ! "$ORCA" project setup-existing-folder --project "$LEADROUTER_PROJECT_ID" --host local --path "$LEADROUTER_DIR" --kind git --json > "$out" 2>&1; then
      fail "Orca refused to add the project: $(orca_json "$out" error). $manual"
      return 1
    fi
    setup_id="$(orca_json "$out" setup-id)"
    [ -n "$setup_id" ] || { fail "Orca added the project but returned no setup id (see the log). $manual"; cat "$out" >> "$LOG_FILE"; return 1; }
    ok "$LEADROUTER_PROJECT_NAME project added to Orca"
  fi
  # The import names the project after the folder; give it its real name.
  if ! "$ORCA" project setup-update --setup "$setup_id" --display-name "$LEADROUTER_PROJECT_NAME" --json > "$out" 2>&1; then
    warn "Could not rename the Orca project to \"$LEADROUTER_PROJECT_NAME\" (it is called leadrouter). $(orca_json "$out" error)"
  fi

  # Reuse the "Claude Code" tab if it is already there; only start Claude if it is not running in it.
  local handle agent found
  "$ORCA" terminal list --worktree "path:$LEADROUTER_DIR" --json > "$out" 2>&1 || true
  found="$(orca_json "$out" claude-terminal "$CLAUDE_TERMINAL_TITLE")"
  handle="${found%% *}"
  agent="${found##* }"
  if [ -n "$handle" ] && [ "$agent" = "claude" ]; then
    ok "A Claude Code session is already open in the project"
    "$ORCA" terminal switch --terminal "$handle" --json >/dev/null 2>&1 || true
    record "Orca project" "already open"
    return 0
  fi

  if [ -z "$handle" ]; then
    # Orca 1.4.x times out when an agent CLI is passed as the tab's --command, and
    # --focus makes even a plain create fail, so open a plain shell tab, type the
    # command into it, and switch to the tab afterwards.
    say "Opening a terminal inside the project..."
    if ! "$ORCA" terminal create --worktree "path:$LEADROUTER_DIR" --title "$CLAUDE_TERMINAL_TITLE" --json > "$out" 2>&1; then
      fail "Orca could not open a terminal in the project: $(orca_json "$out" error). $manual"
      return 1
    fi
    handle="$(orca_json "$out" terminal-handle)"
    [ -n "$handle" ] || { fail "Orca opened a terminal but returned no handle (see the log). $manual"; cat "$out" >> "$LOG_FILE"; return 1; }
    sleep 3   # let the shell come up before typing into it
  fi

  say "Starting Claude Code inside the project..."
  if ! "$ORCA" terminal send --terminal "$handle" --text "claude $CLAUDE_DSP_FLAG" --enter --json > "$out" 2>&1; then
    fail "Orca could not type into the new terminal: $(orca_json "$out" error). $manual"
    return 1
  fi
  if "$ORCA" terminal wait --terminal "$handle" --for tui-idle --timeout-ms 90000 --json > "$out" 2>&1; then
    ok "Claude Code is running in Orca (project $LEADROUTER_PROJECT_NAME)"
  else
    warn "Claude Code was started in Orca but did not report ready within 90 seconds. Check the \"$CLAUDE_TERMINAL_TITLE\" tab in Orca."
  fi
  "$ORCA" terminal switch --terminal "$handle" --json >/dev/null 2>&1 || true
  record "Orca project" "opened with Claude Code"
}

# ---------------------------------------------------------------- main ------

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  log "=== mac-dev-installer $INSTALLER_VERSION start (args: $*) ==="

  printf '%smac-dev-installer %s%s\n' "$BOLD" "$INSTALLER_VERSION" "$RESET"
  printf '%sHomebrew · GitHub CLI · Claude Code · Orca · Lead Router project%s\n\n' "$DIM" "$RESET"

  preflight
  ask_questions
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-dev-installer.XXXXXX")"

  run_step "Homebrew"            install_homebrew
  run_step "GitHub CLI"          install_github_cli
  run_step "Claude Code"         install_claude_code
  run_step "Orca"                install_orca
  run_step "Lead Router project" setup_leadrouter_project
  run_step "claude --dsp shortcut" install_claude_dsp_shortcut
  run_step "Open in Orca"        open_in_orca

  printf '\n%sSummary%s\n' "$BOLD" "$RESET"
  local i
  for i in "${!RESULT_NAMES[@]}"; do
    printf '  %-18s %s\n' "${RESULT_NAMES[$i]}" "${RESULT_STATES[$i]}"
  done

  if [ "${#MANUAL_STEPS[@]}" -gt 0 ]; then
    printf '\n%sTo do by hand%s\n' "$BOLD" "$RESET"
    for i in "${!MANUAL_STEPS[@]}"; do
      printf '  - %s\n' "${MANUAL_STEPS[$i]}"
    done
  fi

  if [ "$FAILED" = 1 ]; then
    printf '\n%sSome steps failed.%s Fix the problem shown above and run this installer again; it skips anything already done.\n' "$RED" "$RESET"
    printf 'Full log: %s\n' "$LOG_FILE"
    log "=== finished with failures ==="
    exit 1
  fi

  local app="$APPS_DIR/Orca.app"
  printf '\n%s%sAll set.%s\n\n' "$GREEN" "$BOLD" "$RESET"
  printf '%sNext step:%s go to Orca and go through the walkthrough.\n' "$BOLD" "$RESET"
  printf '  The %s project is open with a Claude Code session in it. Claude first asks whether you trust the folder: choose Yes.\n' "$LEADROUTER_PROJECT_NAME"
  printf '  Project folder: %s\n\n' "$LEADROUTER_DIR"
  printf 'In any %snew%s terminal window you can also run:  claude --dsp\n' "$BOLD" "$RESET"

  log "=== finished OK ==="

  if [ "$NO_OPEN" = 0 ] && [ "$DRY_RUN" = 0 ] && [ -d "$app" ]; then
    open "$app" || warn "Could not bring Orca to the front. Open it from $APPS_DIR."
  fi
}

main "$@"
