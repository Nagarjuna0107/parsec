#!/bin/bash
# Shared by every component's postinstall (sourced, never executed).
#
# Installer.app runs package scripts as ROOT, after its one authentication
# dialog. That root context is the reason the .pkg exists — it is what lets
# the Claude Desktop component trust mitmproxy's CA in the System keychain
# with no `sudo` prompt of its own. Everything ELSE parsec writes is user
# scoped (~/.parsec, ~/.claude/settings.json, ~/Library/LaunchAgents, the
# tray bundle, Homebrew), so it runs through `run_as_user` below: inside the
# console user's GUI session (so `launchctl bootstrap gui/<uid>` works), as
# that user, with the environment `parsec` expects.
#
# Output goes to stdout → /var/log/install.log. Nothing here may fail the
# install: every postinstall exits 0 and reports through `write_summary`.

LOG_TAG="parsec-installer"
log() { echo "[$LOG_TAG] $*"; }

# The person sitting at the machine. Installer.app sets $USER/$HOME
# inconsistently for scripts (often root's), so ask the console device first.
console_user() {
  local u
  u="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)"
  if [ -n "$u" ] && [ "$u" != root ] && [ "$u" != _mbsetupuser ]; then
    printf '%s' "$u"
    return 0
  fi
  # `sudo installer …` from a terminal: the invoking user.
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    printf '%s' "$SUDO_USER"
    return 0
  fi
  if [ -n "${USER:-}" ] && [ "$USER" != root ]; then
    printf '%s' "$USER"
    return 0
  fi
  return 1
}

# Populate USER_NAME/USER_UID/USER_HOME/USER_SHELL/USER_PATH/PARSEC/PAYLOAD_BIN.
# Returns 1 when there is no user to install for (headless, SSH as root).
init_user() {
  USER_NAME="$(console_user)" || return 1
  USER_UID="$(id -u "$USER_NAME")"
  USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [ -n "$USER_HOME" ] || USER_HOME="/Users/$USER_NAME"
  USER_SHELL="$(dscl . -read "/Users/$USER_NAME" UserShell 2>/dev/null | awk '{print $2}')"
  [ -n "$USER_SHELL" ] || USER_SHELL=/bin/zsh
  # What `parsec`, `claude`, `brew`, and `mitmdump` resolve through. A root
  # postinstall inherits a minimal PATH with none of the user's tool dirs.
  USER_PATH="$USER_HOME/.parsec/bin:$USER_HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  PARSEC="$USER_HOME/.parsec/bin/parsec"
  PAYLOAD_BIN="/usr/local/parsec/bin/parsec"
  SUMMARY="$USER_HOME/.parsec/install-summary.txt"
  export USER_NAME USER_UID USER_HOME USER_SHELL USER_PATH PARSEC PAYLOAD_BIN SUMMARY
  return 0
}

gui_session_available() {
  launchctl print "gui/$USER_UID" >/dev/null 2>&1
}

# Run a command as the console user, inside their GUI session when there is
# one. HOME and SHELL are passed explicitly: `parsec` reads $HOME for every
# path it writes (setup.rs home_dir) and keys its shell-rc choice on $SHELL,
# and root's values would send both to /var/root. stdin is /dev/null: under
# Installer.app it already is, but `sudo installer` from a terminal hands the
# scripts the terminal, and a CLI that asks a question there (a first-run
# prompt in `claude`) would sit on it until the user noticed.
run_as_user() {
  local envs=(
    HOME="$USER_HOME" USER="$USER_NAME" LOGNAME="$USER_NAME" SHELL="$USER_SHELL"
    PATH="$USER_PATH"
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1
    PARSEC_INSTALLER=pkg
  )
  if gui_session_available; then
    launchctl asuser "$USER_UID" sudo -u "$USER_NAME" -H env "${envs[@]}" "$@" </dev/null
  else
    sudo -u "$USER_NAME" -H env "${envs[@]}" "$@" </dev/null
  fi
}

# Like run_as_user, but detached: the child outlives this script, with its
# output in a user-owned log. For `parsec login`, which must keep listening
# for the browser's callback long after the installer has moved on. nohup +
# full fd redirection: Installer.app waits on the script's stdout pipe, and a
# child still holding it would stall the wizard.
spawn_as_user() { # logfile cmd...
  local logfile="$1"; shift
  local envs=(
    HOME="$USER_HOME" USER="$USER_NAME" LOGNAME="$USER_NAME" SHELL="$USER_SHELL"
    PATH="$USER_PATH" PARSEC_INSTALLER=pkg
  )
  if gui_session_available; then
    launchctl asuser "$USER_UID" sudo -u "$USER_NAME" -H env "${envs[@]}" \
      nohup "$@" >>"$logfile" 2>&1 </dev/null &
  else
    sudo -u "$USER_NAME" -H env "${envs[@]}" nohup "$@" >>"$logfile" 2>&1 </dev/null &
  fi
  disown 2>/dev/null || true
}

# `printf` text onto the end of a user-owned file, as the user.
append_as_user() { # file text
  run_as_user sh -c 'mkdir -p "$(dirname "$1")" && printf "%s" "$2" >> "$1"' sh "$1" "$2"
}

# One line per thing the user still has to do (or that went wrong). The
# conclusion pane points here; the tray menu shows the live Desktop state.
write_summary() { # component message
  append_as_user "$SUMMARY" "$1: $2"$'\n'
  log "$1: $2"
}

# Port of scripts/install.sh's PATH step: one guarded line in the user's
# login-shell rc so `parsec` resolves in new terminals. Idempotent.
add_path_line() {
  local bin_dir="$USER_HOME/.parsec/bin" rc line
  case "$(basename "$USER_SHELL")" in
    zsh) rc="$USER_HOME/.zshrc" ;;
    bash) rc="$USER_HOME/.bashrc" ;;
    fish) rc="$USER_HOME/.config/fish/conf.d/parsec.fish" ;;
    *) rc="$USER_HOME/.profile" ;;
  esac
  if run_as_user grep -qs '\.parsec/bin' "$rc"; then
    return 0
  fi
  if [ "${rc##*.}" = fish ]; then
    line="$(printf '\n# parsec\nfish_add_path --prepend "%s"\n' "$bin_dir")"
  else
    line="$(printf '\n# parsec\nexport PATH="%s:$PATH"\n' "$bin_dir")"
  fi
  append_as_user "$rc" "$line"$'\n'
  log "added $bin_dir to PATH in $rc"
}
