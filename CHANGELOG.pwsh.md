# PowerShell Port Changelog

Last updated: 2026-09-05

Upstream sync baseline: `7158aeaec1526d077e0d18784b1d575c7455a087`

The next PowerShell port review should start with commits after this upstream
SHA. In other words, compare `7158aeaec1526d077e0d18784b1d575c7455a087`
against the then-current `upstream/main`.

## 2026-09-05 — Synced through upstream `7158aea`

Ported the applicable changes from upstream commits after `efba3dc` through
`7158aeaec1526d077e0d18784b1d575c7455a087`.

### User data and paths

- Consolidated user-managed data under `$CLI_CONFIG_DIR/my`.
- Changed the data files to:
  - `my/recents.json`
  - `my/videos.json`
  - `my/playlists.json`
  - `my/subscriptions.json`
  - `my/cmds.json`
- Renamed the related PowerShell variables to the upstream `CLI_MY_*` names.
- Updated menus, prompts, generated completions, subscription syncing, saved
  media, recent media, playlists, and custom commands to use the new paths.
- Renamed the visible saved-data menu entries to "My Videos" and
  "My Playlists".
- Renamed the shared fzf preview path variable to
  `$CLI_PREVIEW_FZF_SCRIPT`.
- Removed the unused log directory and log-file setup.

### Browser actions

- Added "Open in Browser" to channel actions.
- Added "Open in Browser (Playlist)" to media actions.
- Added PowerShell-specific guards so missing channel or playlist URLs report
  an error instead of invoking the platform URL opener with an empty target.

### Interface and terminal behavior

- Switched the default fzf configuration to built-in word wrapping with
  `--wrap-word`, `--wrap-sign=''`, and a word-wrapped preview window.
- Kept preview rendering unwrapped in the generated PowerShell preview scripts
  so fzf owns the wrapping behavior.
- Added terminal discovery for Ghostty, GNOME Terminal, Ptyxis, Konsole, Foot,
  and WezTerm in addition to Kitty and Alacritty.
- Preserved the launcher used by the current session after editing and reloading
  the config. A newly configured launcher now takes effect on the next run.

### Updates and project metadata

- Made self-updates atomic by writing the downloaded PowerShell script beside
  the installed script and replacing it only after the write succeeds.
- Preserved argument boundaries when re-executing the updated script.
- Continued invalidating the generated PowerShell preview helper after a
  successful update.
- Added Kitty's `kitten diff` as the preferred interactive update viewer, with
  `git diff --no-index` as the PowerShell fallback.
- Added the upstream Discord URL to help output and generated configuration.

### Reviewed but not ported

- ShellCheck directives and POSIX shell cleanup do not apply to PowerShell.
- The POSIX `awk` menu-order fix does not apply because the PowerShell
  implementation already iterates the requested order deterministically.
- The repository rename from `external-configs` to `configs` required no
  PowerShell runtime change.
- The upstream gum preview branch was not copied verbatim; the PowerShell port
  retains its functional non-preview gum fallback.
