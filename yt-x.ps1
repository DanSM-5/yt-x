#!/usr/bin/env pwsh
# yt-x.ps1 - Windows/PowerShell 7 port of yt-x (https://github.com/Benexl/yt-x)
# MIT License - Copyright (c) 2024-2026 Benexl
#
# This is a LITERAL port of the bash `yt-x` script: same sections (in order),
# same variable/function names, same logic. Only language mechanics change so
# upstream changes can be diffed and ported back. Porting conventions:
#   * bash globals -> PowerShell $script:-scoped vars (so functions can mutate
#     shared state); top-level assignments are already script-scoped.
#   * `readonly X=...`        -> `$X = ...`            (readonly dropped)
#   * `: "${X:=default}"`     -> `$script:X ??= default` (default if unset/$null)
#   * `command -v x`          -> `_dep_ch x` (Get-Command)
#   * coreutils/jq/date math  -> cmdlets / .NET (ConvertFrom-Json, [DateTimeOffset], ...)
#   * platform via uname      -> $IsWindows / $IsMacOS / $IsLinux
#   * CLI flags use a single dash (PowerShell style): -Help, not --help.
#   * paths: native Windows, normalized to FORWARD slashes (C:/…). NO cygpath /
#     wslpath / MSYS conversions — only add one if a path is KNOWN to arrive in
#     MSYS form (/c/…), which shouldn't happen under pwsh.
# Target shell: pwsh 7 (modern syntax: &&, ??, ??=).

# ==============================================================================
# META
# ==============================================================================
$CLI_NAME = 'yt-x.ps1'
$CLI_ARGS = $args
$CLI_APP_NAME = $env:YT_X_APP_NAME ?? $CLI_NAME
# NOTE: CLI_VERSION tracks the upstream Benexl/yt-x version so update checks can
# tell whether this port carries the latest upstream changes. The repo/version/
# release URLs point at the DanSM-5/yt-x fork that hosts this PowerShell port.
$CLI_VERSION = '0.8.6'
$CLI_AUTHOR = 'Benexl'
$CLI_REPO_URL = 'https://github.com/DanSM-5/yt-x'
$CLI_VERSION_URL = 'https://raw.githubusercontent.com/DanSM-5/yt-x/refs/heads/master/version.txt'
$CLI_RELEASES_BASE = 'https://github.com/DanSM-5/yt-x/releases/download'
$CLI_RELEASE_TAG = "$CLI_RELEASES_BASE/v$CLI_VERSION"
$CLI_RELEASE_URL = "$CLI_RELEASE_TAG/yt-x"

# ==============================================================================
# SETUP
# ==============================================================================
$CLI_START_TIME = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

function _dep_ch {
  param([string]$cmd)
  [bool](Get-Command -Name $cmd -ErrorAction SilentlyContinue)
}

# ==============================================================================
# SETUP ENVIRONMENT
# ==============================================================================
# (bash detected bash/zsh/ksh/sh here; for the port the host shell is pwsh)
$CLI_SHELL = 'pwsh'

$CLI_DIR = (Split-Path -Parent $PSCommandPath) -replace '\\', '/'
$CLI_PATH = $PSCommandPath -replace '\\', '/'

if ($IsWindows) { $CLI_PLATFORM = 'windows' }
elseif ($IsMacOS) { $CLI_PLATFORM = 'mac' }
elseif ($IsLinux) { $CLI_PLATFORM = 'linux' }
else { $CLI_PLATFORM = 'linux' }

$CLI_IS_TERMINAL = -not [Console]::IsOutputRedirected

if ($env:COLORTERM -eq 'truecolor' -or $env:COLORTERM -eq '24bit') {
  $CLI_SUPPORTS_TRUE_COLOR = $true
} else {
  $CLI_SUPPORTS_TRUE_COLOR = $false
}

# ==============================================================================
# SETUP PATHS
# ==============================================================================
# Paths use forward slashes (C:/…) throughout — PowerShell cmdlets and the native
# tools (yt-dlp/curl/chafa/fzf/mpv) all accept them, and it avoids backslash
# escaping pitfalls. No cygpath/MSYS conversion is needed (already native paths).
$_home = $HOME -replace '\\', '/'

$XDG_CONFIG_HOME = ($env:XDG_CONFIG_HOME ?? "$_home/.config") -replace '\\', '/'
$XDG_CACHE_HOME = ($env:XDG_CACHE_HOME ?? "$_home/.cache") -replace '\\', '/'
$XDG_DATA_HOME = ($env:XDG_DATA_HOME ?? "$_home/.local/share") -replace '\\', '/'

$CLI_CONFIG_DIR = "$XDG_CONFIG_HOME/$CLI_APP_NAME"

$CLI_EXTENSIONS_DIR = "$CLI_CONFIG_DIR/extensions"
$CLI_EXTENSIONS_SITES_DIR = "$CLI_EXTENSIONS_DIR/sites"
$CLI_EXTENSIONS_THEMES_DIR = "$CLI_EXTENSIONS_DIR/themes"
$CLI_EXTENSIONS_LANGS_DIR = "$CLI_EXTENSIONS_DIR/langs"
$CLI_EXTENSIONS_CMDS_DIR = "$CLI_EXTENSIONS_DIR/cmds"
$CLI_EXTENSIONS_UI_DIR = "$CLI_EXTENSIONS_DIR/ui"

$CLI_CACHE_DIR = "$XDG_CACHE_HOME/$CLI_APP_NAME"

$CLI_STATE_DIR = "$CLI_CACHE_DIR/state"
$CLI_CURRENT_STATE_DIR = "$CLI_STATE_DIR/$CLI_START_TIME-$PID"

$CLI_PREVIEW_DIR = "$CLI_CACHE_DIR/previews"
$CLI_PREVIEW_IMGS_DIR = "$CLI_PREVIEW_DIR/images"
$CLI_PREVIEW_SCRIPTS_DIR = "$CLI_PREVIEW_DIR/text"
# port: shared preview script is PowerShell (.ps1), dot-sourced by the per-item
# preview scripts which fzf runs via --with-shell pwsh (original was .sh)
$CLI_FZF_PREVIEW_SCRIPT = "$CLI_PREVIEW_SCRIPTS_DIR/fzf-preview.ps1"

$CLI_AUTO_GEN_PLAYLISTS = "$CLI_CACHE_DIR/generated-playlists"
$CLI_DOWNLOAD_ARCHIVE_DIR = "$CLI_CACHE_DIR/archives"
$CLI_LOG_DIR = "$CLI_CACHE_DIR/logs"

$CLI_CONFIG_FILE = "$CLI_CONFIG_DIR/config"
$CLI_DEFAULT_THEME_FILE = "$CLI_EXTENSIONS_THEMES_DIR/default.theme"
$CLI_DEFAULT_LANG_FILE = "$CLI_EXTENSIONS_LANGS_DIR/default.lang"
$CLI_RECENT_FILE = "$CLI_CONFIG_DIR/recent.json"
$CLI_SAVED_VIDEOS_FILE = "$CLI_CONFIG_DIR/saved-videos.json"
$CLI_CUSTOM_PLAYLISTS_FILE = "$CLI_CONFIG_DIR/custom-playlists.json"
$CLI_SUBSCRIPTIONS_FILE = "$CLI_CONFIG_DIR/subscriptions.json"
$CLI_CUSTOM_CMDS_FILE = "$CLI_CONFIG_DIR/custom-cmds.json"
$CLI_SEARCH_HISTORY_FILE = "$CLI_CACHE_DIR/search-history.txt"
$CLI_LOG_FILE = "$CLI_LOG_DIR/$CLI_NAME.log"

$null = New-Item -ItemType Directory -Force -Path `
  $CLI_EXTENSIONS_SITES_DIR, `
  $CLI_EXTENSIONS_THEMES_DIR, `
  $CLI_EXTENSIONS_LANGS_DIR, `
  $CLI_EXTENSIONS_CMDS_DIR, `
  $CLI_EXTENSIONS_UI_DIR, `
  $CLI_CURRENT_STATE_DIR, `
  $CLI_PREVIEW_IMGS_DIR, `
  $CLI_PREVIEW_SCRIPTS_DIR, `
  $CLI_AUTO_GEN_PLAYLISTS, `
  $CLI_DOWNLOAD_ARCHIVE_DIR, `
  $CLI_LOG_DIR

# ==============================================================================
# Declarations for lsp
# ==============================================================================
$CMD_EXIT = ''
$CMD_PLAYLIST_RESULTS_SKIP = ''
$CMD_MEDIA_EXIT = ''
$CMD_MEDIA_ACTION = ''
$CMD_MAIN_ACTION = ''
$CMD_MISC_ACTION = ''
$CMD_CHANNEL = ''
$CMD_CHANNEL_ACTION = ''
$CMD_INPUT = ''

# ==============================================================================
# CONFIGURATION & ENVIRONMENT
# ==============================================================================
function __load_default_config {
  $script:CONFIG_AUTOLOADED_EXTENSIONS ??= ''
  $script:CONFIG_ENABLE_COLORS ??= 'true'
  $script:CONFIG_LAUNCHER ??= 'fzf'
  $script:CONFIG_ENABLE_PREVIEW ??= 'false'
  $script:CONFIG_ENABLE_PREVIEW_IMAGES ??= 'false'
  $script:CONFIG_IMAGE_RENDERER ??= 'chafa'
  $script:CONFIG_CHAFA_ARGS ??= ''
  $script:CONFIG_ICAT_ARGS ??= ''
  $script:CONFIG_IMGCAT_ARGS ??= ''
  $script:CONFIG_YT_DLP_OPTS ??= ''
  $script:CONFIG_PLAYER ??= 'mpv'
  $script:CONFIG_DISOWN_PLAYER ??= 'false'
  $script:CONFIG_MPV_ARGS ??= ''
  $script:CONFIG_VLC_ARGS ??= ''
  $script:CONFIG_TPLAY_ARGS ??= ''
  $script:CONFIG_PER_PAGE ??= 30
  $script:CONFIG_BROWSER ??= ''
  $script:CONFIG_CACHE_RETENTION_DAYS ??= 3
  $script:CONFIG_EDITOR ??= ($env:EDITOR ?? 'vi')
  $script:CONFIG_NOTIFICATION_DURATION ??= 5
  $script:CONFIG_DOWNLOAD_DIR ??= "$($HOME -replace '\\', '/')/Videos/$CLI_NAME"
  $script:CONFIG_DOWNLOADS_ENUMERATE ??= 'false'
  $script:CONFIG_CHECK_FOR_UPDATES ??= 'true'
  $script:CONFIG_NO_OF_RECENT ??= 10
  $script:CONFIG_ENABLE_SEARCH_HISTORY ??= 'true'
  $script:CONFIG_ROFI_THEME ??= ''
  $script:CONFIG_GUM_FILTER_OPTS ??= '--prompt.foreground #2ac3de --indicator.foreground #2ac3de --selected-indicator.foreground #2ac3de --unselected-prefix.foreground #585858 --header.foreground #2ac3de --text.foreground #c0caf5 --cursor-text.foreground #c0caf5 --match.foreground #2ac3de --placeholder.foreground #585858  --prompt  > --indicator ◆ --selected-prefix  ◉  --unselected-prefix  ○  --placeholder こんにちは...'
  $script:CONFIG_GUM_INPUT_OPTS ??= '--prompt.foreground #2ac3de --cursor.foreground #c0caf5 --placeholder こんにちは... --cursor.mode blink'
  $script:CONFIG_GUM_PAGER_OPTS ??= '--foreground #c0caf5 --line-number.foreground #585858 --match.foreground #2ac3de --match-highlight.foreground #1a1b26 --match-highlight.background #2ac3de --help.foreground #585858 --show-line-numbers --soft-wrap --border-foreground #2ac3de'
  $script:CONFIG_GUM_SPIN_OPTS ??= '--spinner dot --spinner.foreground #2ac3de --title.foreground #585858  --align left'
  $script:CONFIG_GUM_CONFIRM_OPTS ??= '--prompt.foreground #2ac3de --selected.foreground #1a1b26 --selected.background #2ac3de --unselected.foreground #585858'
  $script:CONFIG_FZF_HEADER ??= $CLI_HEADER
  $script:CONFIG_FZF_OPTS ??= @'
  --ansi
  --border
  --scheme=history
  --style=full
  --color=bg+:#283457
  --color=bg:#16161e
  --color=border:#27a1b9
  --color=fg:#c0caf5
  --color=gutter:#16161e
  --color=header:#2ac3de
  --color=hl+:#2ac3de
  --color=hl:#2ac3de
  --color=info:#545c7e
  --color=marker:#ff007c
  --color=pointer:#ff007c
  --color=prompt:#2ac3de
  --color=query:#c0caf5:regular
  --color=scrollbar:#27a1b9
  --color=separator:#ff9e64
  --color=spinner:#ff007c
  --border=rounded
  --border-label=''
  --prompt=' >'
  --marker=' >'
  --pointer='◆'
  --layout=reverse
  --cycle
  --ghost='こんにちは...'
  --height=100%
  --bind=ctrl-/:toggle-preview,ctrl-space:toggle-wrap+toggle-preview-wrap
  --no-margin
  +m
  -i
  --exact
  --tabstop=1
  --preview-window=border-rounded,left,35%,wrap-word
  --wrap
'@
}

function __load_env_config {
  $script:CONFIG_AUTOLOADED_EXTENSIONS = $env:YT_X_AUTOLOADED_EXTENSIONS ?? $script:CONFIG_AUTOLOADED_EXTENSIONS
  $script:CONFIG_ENABLE_COLORS = $env:YT_X_ENABLE_COLORS ?? $script:CONFIG_ENABLE_COLORS
  $script:CONFIG_LAUNCHER = $env:YT_X_LAUNCHER ?? $script:CONFIG_LAUNCHER
  $script:CONFIG_ENABLE_PREVIEW = $env:YT_X_ENABLE_PREVIEW ?? $script:CONFIG_ENABLE_PREVIEW
  $script:CONFIG_ENABLE_PREVIEW_IMAGES = $env:YT_X_ENABLE_PREVIEW_IMAGES ?? $script:CONFIG_ENABLE_PREVIEW_IMAGES

  $script:CONFIG_IMAGE_RENDERER = $env:YT_X_IMAGE_RENDERER ?? $script:CONFIG_IMAGE_RENDERER
  $script:CONFIG_CHAFA_ARGS = $env:YT_X_CHAFA_ARGS ?? $script:CONFIG_CHAFA_ARGS
  $script:CONFIG_ICAT_ARGS = $env:YT_X_ICAT_ARGS ?? $script:CONFIG_ICAT_ARGS
  $script:CONFIG_IMGCAT_ARGS = $env:YT_X_IMGCAT_ARGS ?? $script:CONFIG_IMGCAT_ARGS

  $script:CONFIG_PLAYER = $env:YT_X_PLAYER ?? $script:CONFIG_PLAYER
  $script:CONFIG_DISOWN_PLAYER = $env:YT_X_DISOWN_PLAYER ?? $script:CONFIG_DISOWN_PLAYER
  $script:CONFIG_MPV_ARGS = $env:YT_X_MPV_ARGS ?? $script:CONFIG_MPV_ARGS
  $script:CONFIG_VLC_ARGS = $env:YT_X_VLC_ARGS ?? $script:CONFIG_VLC_ARGS
  $script:CONFIG_TPLAY_ARGS = $env:YT_X_TPLAY_ARGS ?? $script:CONFIG_TPLAY_ARGS

  $script:CONFIG_DOWNLOAD_DIR = $env:YT_X_DOWNLOAD_DIR ?? $script:CONFIG_DOWNLOAD_DIR
  $script:CONFIG_YT_DLP_OPTS = $env:YT_X_YT_DLP_OPTS ?? $script:CONFIG_YT_DLP_OPTS

  $script:CONFIG_PER_PAGE = $env:YT_X_PER_PAGE ?? $script:CONFIG_PER_PAGE
  $script:CONFIG_BROWSER = $env:YT_X_BROWSER ?? $script:CONFIG_BROWSER

  $script:CONFIG_EDITOR = $env:YT_X_EDITOR ?? $script:CONFIG_EDITOR
  $script:CONFIG_TERMINAL_EXEC = $env:YT_X_TERMINAL_EXEC ?? $script:CONFIG_TERMINAL_EXEC
  $script:CONFIG_NOTIFICATION_DURATION = $env:YT_X_NOTIFICATION_DURATION ?? $script:CONFIG_NOTIFICATION_DURATION

  $script:CONFIG_DOWNLOADS_ENUMERATE = $env:YT_X_ENUMERATE_DOWNLOADS ?? $script:CONFIG_DOWNLOADS_ENUMERATE
  $script:CONFIG_CHECK_FOR_UPDATES = $env:YT_X_CHECK_FOR_UPDATES ?? $script:CONFIG_CHECK_FOR_UPDATES
  $script:CONFIG_NO_OF_RECENT = $env:YT_X_NO_OF_RECENT ?? $script:CONFIG_NO_OF_RECENT
  $script:CONFIG_ENABLE_SEARCH_HISTORY = $env:YT_X_ENABLE_SEARCH_HISTORY ?? $script:CONFIG_ENABLE_SEARCH_HISTORY

  $script:CONFIG_GUM_FILTER_OPTS = $env:YT_X_GUM_OPTS ?? $script:CONFIG_GUM_FILTER_OPTS
  $script:CONFIG_GUM_INPUT_OPTS = $env:YT_X_GUM_INPUT_OPTS ?? $script:CONFIG_GUM_INPUT_OPTS
  $script:CONFIG_GUM_PAGER_OPTS = $env:YT_X_GUM_PAGER_OPTS ?? $script:CONFIG_GUM_PAGER_OPTS
  $script:CONFIG_GUM_SPIN_OPTS = $env:YT_X_GUM_SPIN_OPTS ?? $script:CONFIG_GUM_SPIN_OPTS
  $script:CONFIG_GUM_CONFIRM_OPTS = $env:YT_X_GUM_CONFIRM_OPTS ?? $script:CONFIG_GUM_CONFIRM_OPTS

  $script:CONFIG_FZF_HEADER = $env:YT_X_FZF_HEADER ?? $script:CONFIG_FZF_HEADER
  $script:CONFIG_FZF_OPTS = $env:YT_X_FZF_OPTS ?? $script:CONFIG_FZF_OPTS
  $script:CONFIG_ROFI_THEME_MAIN = $env:YT_X_ROFI_THEME_MAIN ?? $script:CONFIG_ROFI_THEME_MAIN
  $script:CONFIG_ROFI_THEME_PREVIEW = $env:YT_X_ROFI_THEME_PREVIEW ?? $script:CONFIG_ROFI_THEME_PREVIEW
  $script:CONFIG_ROFI_THEME_PROMPT = $env:YT_X_ROFI_THEME_PROMPT ?? $script:CONFIG_ROFI_THEME_PROMPT
  $script:CONFIG_ROFI_THEME_CONFIRM = $env:YT_X_ROFI_THEME_CONFIRM ?? $script:CONFIG_ROFI_THEME_CONFIRM
  $script:CONFIG_ROFI_THEME_PAGER = $env:YT_X_ROFI_THEME_PAGER ?? $script:CONFIG_ROFI_THEME_PAGER
}

function __load_default_lang {
  $script:TXT_BYEBYE = "Have a good day"
  $script:TXT_NO_TERMINAL_EXEC = "No supported terminal emulator found for executing commands. Please set CONFIG_TERMINAL_EXEC to a valid terminal command. Currently set to: $CONFIG_TERMINAL_EXEC"

  $script:TXT_STATE_MALFORMED_CURRENT = "Malformed State. Confirm contents of: $CLI_CURRENT_STATE_DIR/$STATE_CURRENT"

  $script:TXT_MENU_NEXT = "Next"
  $script:TXT_MENU_PREVIOUS = "Previous"
  $script:TXT_MENU_BACK = "Back"
  $script:TXT_MENU_EXIT = "Exit"

  $script:TXT_LAUNCHER_UNKNOWN = "Unknown launcher"
  $script:TXT_LAUNCHER_PREVIEWS_UNSUPPORTED = "The current launcher ($CONFIG_LAUNCHER) does not support previews. Please switch to a supported launcher or disable previews in the config."

  $script:TXT_FZF_PREVIEW_IMAGE_LOADING = "loading preview image..."
  $script:TXT_FZF_PREVIEW_CHANNEL = "Channel"
  $script:TXT_FZF_PREVIEW_DURATION = "Duration"
  $script:TXT_FZF_PREVIEW_VIEW_COUNT = "Views"
  $script:TXT_FZF_PREVIEW_LIVE_STATUS = "Live Status"
  $script:TXT_FZF_PREVIEW_TIMESTAMP = "Uploaded"
  $script:TXT_FZF_PREVIEW_CHANNEL_FOLLOWERS = "Followers"

  $script:TXT_ROFI_NOT_CONFIGURED = "Rofi is not configured. Please set to a valid rofi config file path in your config.sh"
  $script:TXT_ROFI_PAGER_MESSAGE = "Press [Esc] to exit pager"
  $script:TXT_ROFI_PAGER_PROMPT = "Filter lines by typing"

  $script:TXT_MENU_INVALID_ACTION = "Invalid Action"
  $script:TXT_EDITOR_NOT_FOUND = 'No suitable editor found. Please set CONFIG_EDITOR to a valid text editor command or ensure $EDITOR is set.'

  $script:TXT_YES = "y"
  $script:TXT_NO = "n"
  $script:TXT_CONFIRM_DEFAULT = "Default"

  $script:TXT_LOADING = "Loading..."

  $script:TXT_PREVIEW_INSTALL_VIEWER = 'please install a terminal image viewer\neither icat for kitty terminal and wezterm or imgcat or chafa'

  $script:TXT_CONFIG_BROWSER_NOT_SET = "Please set CONFIG_BROWSER to proceed"

  $script:TXT_CUSTOM_CMDS_FILE_NOT_FOUND = "You dont have any custom cmds. Create them here $CLI_CUSTOM_CMDS_FILE or use the ui"
  $script:TXT_SEARCH_HISTORY_FILE_NOT_FOUND = "You dont have any search history. Start searching to generate search history or edit the file here $CLI_SEARCH_HISTORY_FILE"
  $script:TXT_SAVED_VIDEOS_FILE_NOT_FOUND = "You dont have any saved videos. Start saving videos to generate this file or edit the file here $CLI_SAVED_VIDEOS_FILE"
  $script:TXT_CUSTOM_PLAYLISTS_FILE_NOT_FOUND = "You dont have any custom playlists. Start saving playlists to generate this file or edit the file here $CLI_CUSTOM_PLAYLISTS_FILE"
  $script:TXT_SUBS_FILE_NOT_FOUND = "You don't have any channel subscriptions. Please use the miscellaneous menu to add subscriptions to $CLI_SUBSCRIPTIONS_FILE"
  $script:TXT_RECENT_FILE_NOT_FOUND = "You don't have any recent videos. Try watching sth first : ). And an entry will be created at $CLI_RECENT_FILE"

  $script:TXT_MENU_MAIN_PROMPT_ACTION = "Select an action"
  $script:TXT_MENU_MAIN = "Main Menu"
  $script:TXT_MENU_MAIN_FEED = "Your Feed"
  $script:TXT_MENU_MAIN_TRENDING = "Trending"
  $script:TXT_MENU_MAIN_PLAYLISTS = "Playlists"
  $script:TXT_MENU_MAIN_SEARCH = "Search"
  $script:TXT_MENU_MAIN_SEARCH_PROMPT = "Enter search query"
  $script:TXT_MENU_MAIN_SEARCH_OR_HISTORY_PROMPT = "Enter search query or select from history"
  $script:TXT_SEARCH_FILTER_HELP = @'
Filter by upload date –  :hour, :today, :week, :month, :year
Filter by content      –  :video, :movie, :live, :short, :long
Filter by features     –  :4k, :hd, :hdr, :subtitles, :360, :vr, :3d, :local
Sort by                –  :newest, :views, :rating
Recall history         –  !1, !2, … (newest = 1)
'@

  $script:TXT_MENU_MAIN_WATCH_LATER = "Watch Later"
  $script:TXT_MENU_MAIN_SUBS_FEED = "Subscriptions Feed"

  $script:TXT_MENU_MAIN_CHANNELS = "Channels"
  $script:TXT_MENU_MAIN_CHANNELS_PROMPT = "Select Channel"

  $script:TXT_MENU_MAIN_CUSTOM_PLAYLISTS = "Custom Playlists"
  $script:TXT_MENU_MAIN_CUSTOM_PLAYLISTS_PROMPT = "Select Playlist"

  $script:TXT_MENU_MAIN_LIKED = "Liked Videos"

  $script:TXT_MENU_MAIN_SAVED = "Saved Videos"
  $script:TXT_MENU_MAIN_SAVED_PROMPT = "Select video"

  $script:TXT_MENU_MAIN_HISTORY = "Watch History"
  $script:TXT_MENU_MAIN_RECENT = "Recent"
  $script:TXT_MENU_MAIN_CLIPS = "Clips"
  $script:TXT_MENU_MAIN_EDIT_CONFIG = "Edit Config"
  $script:TXT_MENU_MAIN_MISC = "Miscellaneous"

  $script:TXT_MENU_PROMPT_SEARCH = "Enter search query"

  $script:TXT_MENU_MISC_PROMPT = "Select an action"

  $script:TXT_MENU_MISC_EXPLORE_CHANNELS = "Explore Channels"
  $script:TXT_MENU_MISC_EXPLORE_CHANNELS_PROMPT = "Enter channel search term"

  $script:TXT_MENU_MISC_EXPLORE_PLAYLISTS = "Explore Playlists"
  $script:TXT_MENU_MISC_EXPLORE_PLAYLISTS_PROMPT = "Enter playlist search term"

  $script:TXT_MENU_MISC_EXPLORE_SHORTS = "Explore Shorts"
  $script:TXT_MENU_MISC_EXPLORE_SHORTS_PROMPT = "Enter short search term"

  $script:TXT_MENU_MISC_EXPLORE_MOVIES = "Explore Movies"
  $script:TXT_MENU_MISC_EXPLORE_MOVIES_PROMPT = "Enter movie search term"

  $script:TXT_MENU_MISC_SEARCH_HISTORY = "Search History"
  $script:TXT_MENU_MISC_SEARCH_HISTORY_PROMPT = "Search for"
  $script:TXT_MENU_MISC_CLEAR_SEARCH_HISTORY = "Clear Search History"
  $script:TXT_MENU_MISC_CLEAR_SEARCH_HISTORY_PROMPT = "Are you sure you would like to clear your search history at $CLI_SEARCH_HISTORY_FILE?"

  $script:TXT_MENU_MISC_NEW_CUSTOM_CMD = "New Custom Command"
  $script:TXT_MENU_MISC_NEW_CUSTOM_CMD_DESC = @"
# ==============================================================================
# YT-X CUSTOM COMMANDS
# ==============================================================================
Create a custom command that executes a URL with yt-dlp options.
You can use this to create custom searches or actions on specific sites.
For example, you can create a custom command that searches for a query
on a specific site and returns the results in the launcher.
NOTE: There are base options which are given to yt-dlp but can be overriden
    DEFAULT OPTS:
      --dump-single-json
      --flat-playlist
      --playlist-start 1
      --playlist-end $CONFIG_PER_PAGE
      --cookies-from-browser $CONFIG_BROWSER (Dependent on CONFIG_BROWSER)
    Don't recommend to override the first two will break the display logic
# ==============================================================================
# ==============================================================================
"@

  $script:TXT_MENU_MISC_NEW_CUSTOM_CMD_NAME_PROMPT = "Enter a name for the custom command"
  $script:TXT_MENU_MISC_NEW_CUSTOM_CMD_URL_PROMPT = "Enter the URL for the custom command"
  $script:TXT_MENU_MISC_NEW_CUSTOM_CMD_YT_DLP_OPTS_PROMPT = "Enter any extra yt-dlp options for the custom command (optional)"
  $script:TXT_MENU_MISC_CUSTOM_CMDS = "Custom Commands"
  $script:TXT_MENU_MISC_CUSTOM_CMDS_PROMPT = "Enter the name of the custom command to execute"

  $script:TXT_MENU_MISC_EDIT_SEARCH_HISTORY = "Edit Search History"
  $script:TXT_MENU_MISC_EDIT_CUSTOM_PLAYLISTS = "Edit Custom Playlists"
  $script:TXT_MENU_MISC_EDIT_MPV_CONFIG = "Edit MPV Config"
  $script:TXT_MENU_MISC_EDIT_YTDLP_CONFIG = "Edit yt-dlp Config"
  $script:TXT_MENU_MISC_EDIT_CUSTOM_CMDS = "Edit Custom Commands"

  $script:TXT_MENU_MISC_SYNC_SUBS = "Sync YouTube Subscriptions"
  $script:TXT_MENU_MISC_SYNC_SUBS_CONFIRM = "This will erase your local subs, proceed?"
  $script:TXT_MENU_MISC_SYNC_SUBS_START = "Syncing subscriptions..."
  $script:TXT_MENU_MISC_SYNC_SUBS_FAILED = "Failed to sync subs"

  $script:TXT_MENU_CHANNELS_EXPLORER_PROMPT = "Select a channel"

  $script:TXT_MENU_CHANNEL_ACTIONS_PROMPT = "Select action"
  $script:TXT_MENU_CHANNEL_ACTIONS_VIDEOS = "Videos"
  $script:TXT_MENU_CHANNEL_ACTIONS_FEATURED = "Featured"
  $script:TXT_MENU_CHANNEL_ACTIONS_SEARCH = "Search"
  $script:TXT_MENU_CHANNEL_ACTIONS_SEARCH_PROMPT = "Search for"
  $script:TXT_MENU_CHANNEL_ACTIONS_PLAYLISTS = "Playlists"
  $script:TXT_MENU_CHANNEL_ACTIONS_SHORTS = "Shorts"
  $script:TXT_MENU_CHANNEL_ACTIONS_STREAMS = "Streams"
  $script:TXT_MENU_CHANNEL_ACTIONS_PODCASTS = "Podcasts"
  $script:TXT_MENU_CHANNEL_ACTIONS_SUBSCRIBE = "Subscribe"
  $script:TXT_MENU_CHANNEL_ACTIONS_SUBSCRIBE_CONFIRM = "Would you like to import your youtube subscriptions first? You wont be able to do so again unless you delete $CLI_SUBSCRIPTIONS_FILE"

  $script:TXT_MENU_PLAYLISTS_EXPLORER_PROMPT = "Select Playlist"

  $script:TXT_MENU_PLAYLIST_EXPLORER_PROMPT = "Select Media"

  $script:TXT_MENU_PLAYLIST_PROMPT_ACTION = "Select Media Action"
  $script:TXT_MENU_MEDIA_ACTIONS_WATCH = "Watch"
  $script:TXT_MENU_MEDIA_ACTIONS_WATCH_ALL = "Play All"
  $script:TXT_MENU_MEDIA_ACTIONS_LISTEN = "Listen"
  $script:TXT_MENU_MEDIA_ACTIONS_LISTEN_ALL = "Listen To All"
  $script:TXT_MENU_MEDIA_ACTIONS_MIX = "Mix"
  $script:TXT_MENU_MEDIA_ACTIONS_SAVE = "Save"
  $script:TXT_MENU_MEDIA_ACTIONS_UNSAVE = "UnSave"
  $script:TXT_MENU_MEDIA_ACTIONS_SAVE_PLAYLIST = "Save Playlist"
  $script:TXT_MENU_MEDIA_ACTIONS_UNSAVE_PLAYLIST = "UnSave Playlist"
  $script:TXT_MENU_MEDIA_ACTIONS_VISIT_CHANNEL = "Go To Channel"
  $script:TXT_MENU_MEDIA_ACTIONS_SUBSCRIBE = "Subscribe To Channel"
  $script:TXT_MENU_MEDIA_ACTIONS_DOWNLOAD = "Download"
  $script:TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL = "Download All"
  $script:TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_AUDIO = "Download (Audio Only)"
  $script:TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL_AUDIO = "Download All (Audio Only)"
  $script:TXT_MENU_MEDIA_ACTIONS_BROWSER = "Open in Browser"
  $script:TXT_MENU_MEDIA_ACTIONS_TOGGLE_ENUM = "Toggle Enumerate Downloads"
  $script:TXT_MENU_MEDIA_ACTIONS_SHELL = "Shell"
  $script:TXT_MENU_MEDIA_ACTIONS_CHANNEL_NOT_FOUND = "Could not determine a channel URL for this video"

  $script:TXT_ENTER_PLAYLIST_TITLE = "Enter playlist title"

  $script:TXT_PLAYER_START_WATCHING = "Now Watching"
  $script:TXT_PLAYER_START_LISTENING = "Now Listening To"
  $script:TXT_PLAYER_NOT_FOUND = "No suitable media player found. Please set CONFIG_PLAYER to a valid media player command. Currently set to: $CONFIG_PLAYER"
  $script:TXT_MENU_MEDIA_ACTIONS_PROMPT_SAVE_PLAYLIST = "Enter the name of the playlist"

  $script:TXT_DOWNLOAD_COMPLETED = "Completed downloading of "

  $script:TXT_UPDATE_ROOT_WARNING = "It seems you have installed $CLI_NAME as root, which is not recommended. Do you still want to update using sudo? (I recommended reinstalling the cli as non root)"
  $script:TXT_UPDATE_SUDO_MISSING = "Insufficient permissions to update and can't find sudo in PATH"
  $script:TXT_UPDATE_SCRIPT_REEXECUTE = "Script has been updated! Would you like to re-execute it?"
  $script:TXT_UPDATE_FAILED = "Can't update for some reason!"
  $script:TXT_UPDATE_FETCH_FAILED = "Something went wrong fetching the update, can't proceed with the update"
  $script:TXT_UPDATE_FOUND = "An update has been found would you like to see the changes before deciding whether to update?"
  $script:TXT_DEP_MISSING_DIFF = "Could not find diff in path please install it to view update diffs"
  $script:TXT_UPDATE_CONFIRM = "Would you like to proceed with the update?"
  $script:TXT_UPDATE_NOT_FOUND = "No updates found"

  $script:TXT_DEP_MISSING_YTDLP = "yt-dlp is not installed and is a core dep please install it to proceed"
  $script:TXT_DEP_MISSING_JQ = "jq is not installed and is a core dep please install it to proceed"
  $script:TXT_DEP_MISSING_FZF = "fzf is not installed and is a core dep please install it to proceed"

  $script:TXT_MENU_MEDIA_ACTIONS_SHELL_WELCOME = "Welcome to the $CLI_NAME shell."
  $script:TXT_MENU_MEDIA_ACTIONS_SHELL_INTRO = "You can use the following:"
  $script:TXT_MENU_MEDIA_ACTIONS_SHELL_VARIABLES = "variables:"

  $script:TXT_MENU_MEDIA_ACTIONS_OPEN_IN_BROWSER_ERROR = "Could not find a supported URL opener (open, xdg-open, wslview, or cmd.exe)"
  $script:TXT_MENU_MEDIA_ACTIONS_SUBSCRIBE_UNSUPPORTED = "contribute to the project by adding this feature"

  $script:TXT_MENU_MAIN_RECENT_SEARCHES = "Recent searches:"
  $script:TXT_MENU_MAIN_NEW_SEARCH = "New search…"

  $script:TXT_DESKTOP_ENTRY_PROMPT = "Which launcher would you like to configure a desktop entry for"
  $script:TXT_DESKTOP_ENTRY_COMMENT = "Browse Youtube from the terminal plus other sites yt-dlp supports"
  $script:TXT_LAUNCHER_LABEL_ROFI = "rofi"
  $script:TXT_LAUNCHER_LABEL_FZF = "fzf"

  $script:TXT_APP_USAGE = @"
A script written to browse YouTube and other yt‑dlp supported sites from the terminal.

Usage: $CLI_NAME [OPTIONS]
       $CLI_NAME completions [--fish|--bash|--zsh|--help]
       $CLI_NAME channels [OPTIONS]

All options can also be set permanently in the config file ($CLI_CONFIG_FILE).
Environment variables (YT_X_*) override the config.

────────────────────────────────────────────────────────────────────
Options:
  -h, --help                     Show this help message and exit
  -v, --version                  Print version information and exit
  -e, --edit-config              Open the config file in your editor
  -x, --extension <ext>          Load an extension file (absolute path or relative to $CLI_CONFIG_DIR/extensions)
  -E, --generate-desktop-entry   Print a .desktop file to stdout and exit
  -U, --update                   Check for and apply an update for $CLI_NAME
  -l, --launcher <launcher>      Menu launcher: fzf or rofi or gum
  --config-write                 Write the current runtime config to the config file
  --preview                      Enable the preview window (images/text)
  --no-preview                   Disable the preview window
  --preview-images               Enable the image preview window
  --no-preview-images            Disable the image preview window
  -p, --player <player>          Media player: mpv, vlc or tplay
  --mpv-args                     Pass custom mpv args at runtime
  --vlc-args                     Pass custom vlc args at runtime
  --tplay-args                   Pass custom tplay args at runtime
  --disown-player                Detach the player process from the terminal
  --no-disown-player             Keep player attached (default)
  --rofi-theme-main <path>       Path to the rofi main theme file
  --rofi-theme-preview <path>    Path to the rofi preview theme file
  --rofi-theme-prompt <path>     Path to the rofi prompt theme file
  --rofi-theme-confirm <path>    Path to the rofi confirm theme file
  --rofi-theme-pager <path>      Path to the rofi pager theme file
  -xargs, --extension-arguments <args>  The arguments to pass to cmd extension;
                                        every argument passed after it is automatically assumed
                                        to be intend for processing by an extension (available via the readonly CLI_EXTENSION_CMDLINE_ARGS env var)

────────────────────────────────────────────────────────────────────
Direct media action shortcuts (skip the media action menu):
  -me, --media-exit              Exit after performing a media action (watch, listen, etc.)
  --play                         Immediately watch the selected video (you still choose from the list)
  --play-all                     Immediately play the whole playlist (implies --playlist-skip)
  --listen                       Immediately listen to the audio of the selected video
  --listen-all                   Immediately listen to the whole playlist (audio only, implies --playlist-skip)
  --download                     Download the selected video
  --download-all                 Download the whole playlist (video, implies --playlist-skip)
  --download-audio               Download only the audio of the selected video
  --download-audio-all           Download the whole playlist as audio (implies --playlist-skip)
  --save                         Save the selected video to your saved videos list
  --save-playlist                Save the current playlist to your custom playlists (implies --playlist-skip)
  --shell                        Open a subshell with current context variables

────────────────────────────────────────────────────────────────────
Direct menu shortcuts
  -ce, --cmd-exit                Exit after shortcut menu commandline options
  -ps, --playlist-skip           Skip the item selection menu and automatically pick the first entry
  -s, --search <term>            Search for videos directly
  -sp, --search-playlist <term>  Search for playlists directly
  -sc, --search-channel <term>   Search for channels directly
  -ss, --search-short <term>     Search for shorts directly
  -sm, --search-movie <term>     Search for movies directly
  -cp, --custom-playlist <name>  Open a specific custom playlist by its saved name
  -cc, --custom-cmd <name>       Execute a specific custom command by its saved name
  -sv, --saved-video <title>     Open a specific saved video by its title
  --feed                         Open your personalised feed
  --subscriptions-feed           Show latest videos from subscriptions
  --watch-later                  Open the Watch Later playlist
  --playlists                    Show saved YouTube playlists
  --custom-playlists             Browse custom playlists you've saved
  --saved                        Open saved videos
  --recent                       Show recently watched videos
  --liked                        Open your Liked Videos playlist
  --watch-history                Show your watch history
  --clips                        Browse your clips
  --new-custom-cmd               Go straight to creating a custom command
  --custom-cmds                  Execute an existing custom command
  --search-history               Browse your search history
  --edit-search-history          Edit the search history file
  --edit-custom-playlists        Edit the custom playlists JSON file
  --edit-mpv-config              Edit mpv's configuration file
  --edit-yt-dlp-config           Edit yt‑dlp's configuration file
  --edit-custom-cmds             Edit the custom commands JSON file

────────────────────────────────────────────────────────────────────
Sub‑commands:
  channels                       Browse or search within a specific channel
    -n, --name <channel>         Choose the channel by name (exact match)
    -s, --search <query>         Search within the channel's uploads
    -v, --videos                 List the channel's videos
    -f, --featured               Show the channel's featured playlists
    -p, --playlists              List the channel's playlists
    -sh, --shorts                Show the channel's shorts
    -st, --streams               Show live streams & past broadcasts
    -po, --podcasts              Show the channel's podcasts

  completions                    Generate shell completion definitions
    --fish                       Fish shell completions
    --bash                       Bash shell completions
    --zsh                        Zsh shell completions
    --help                       Show help for completions

────────────────────────────────────────────────────────────────────
Examples:
  $CLI_NAME                                 # Start the interactive browser
  $CLI_NAME --feed                          # Open the feed directly
  $CLI_NAME --subscriptions-feed            # Open subscriptions feed
  $CLI_NAME -s 'onepiece elbaf trailer'     # Search immediately
  $CLI_NAME -sp 'rust tutorial'             # Search playlists immediately
  $CLI_NAME -sc 'learn coding'              # Search channels immediately
  $CLI_NAME --launcher rofi --preview --preview-images       # Use rofi with previews

  # Media action shortcuts
  $CLI_NAME --play                          # Play the selected video (interactive selection)
  $CLI_NAME --playlist-skip --play          # Automatically play the first video without selection
  $CLI_NAME --play-all                      # Play the entire current playlist (no selection)
  $CLI_NAME --listen-all                    # Listen to the whole playlist as audio
  $CLI_NAME --download-all                  # Download the whole playlist (video)
  $CLI_NAME --download-audio-all            # Download the whole playlist as audio
  $CLI_NAME --save-playlist                 # Save the current playlist (no selection needed)

  $CLI_NAME --save                          # Save the current video to saved list
  $CLI_NAME --shell                         # Open a subshell with state variables

  # Skip and exit helpers
  $CLI_NAME --playlist-skip --play          # Automatically play the first item
  $CLI_NAME --media-exit --download         # Download and then exit the script
  $CLI_NAME -cp 'Jazz Favourites'           # Open a saved custom playlist by name
  $CLI_NAME -sv 'My favourite video'        # Open a specific saved video by title
  $CLI_NAME -cc 'My Custom Search'          # Execute a specific custom command by name

  # Extensions and desktop entry
  $CLI_NAME -x themes/catppuccin.theme      # Load a theme extension
  $CLI_NAME -x langs/es.lang                # Load a language extension
  $CLI_NAME -x sites/dailymotion.site       # Load a site extension
  $CLI_NAME -x cmd/downloads                # Execute a cmd extension
  $CLI_NAME completions --fish              # Print fish completions
  $CLI_NAME -E > ~/.local/share/applications/yt-x.desktop

  # Channel subcommand examples
  $CLI_NAME channels -n 'Linus Tech Tips' -v   # Browse channel videos
  $CLI_NAME channels -n 'iambenexl' -s 'Top linux tools' # search within a channel
  $CLI_NAME --cmd-exit channels -n 'freeCodeCamp.org' -p # Browse freecodecamp playlists and exit on back
  $CLI_NAME --cmd-exit channels -n 'freeCodeCamp.org' # useful for setting aliases eg a shortcut to always go to freecodecamp channel 'freecodecamp'
  $CLI_NAME --launcher rofi --cmd-exit channels -n 'freeCodeCamp.org' # or as an app eg  'freecodecamp-app'

For more details visit the FAQ:
  https://github.com/Benexl/yt-x#frequently-asked-questions-faq
"@

  $script:TXT_APP_USAGE_CHANNELS = @"
Browse YouTube channels or search within them directly from the command line.

Usage: $CLI_NAME channels [OPTIONS]

Options:
  -n, --name <channel>        Specify the channel name (exact match, case‑sensitive)
  -s, --search <query>        Search inside the channel's uploads
  -v, --videos                List the channel's uploaded videos
  -f, --featured              Show the channel's featured playlists
  -p, --playlists             List the channel's playlists
  -sh, --shorts               Show the channel's short videos
  -st, --streams              Show live streams & past broadcasts
  -po, --podcasts             Show the channel's podcasts

Examples:
  $CLI_NAME channels -n 'Linus Tech Tips' -v     # Open channel and list videos
  $CLI_NAME channels -n 'iambenexl' -s 'Top linux tools'   # Search within a channel
  $CLI_NAME channels -n 'StarTalk' -p          # Show channel playlists
  $CLI_NAME channels -n 'The PrimeTime' -st         # Show channel streams
  $CLI_NAME --cmd-exit channels -n 'freeCodeCamp.org' -p # Browse freecodecamp playlists and immediately exit on back
  $CLI_NAME --cmd-exit channels -n 'freeCodeCamp.org' # useful for setting aliases eg a shortcut to always go to freecodecamp channel 'freecodecamp'
  $CLI_NAME --launcher rofi --cmd-exit channels -n 'freeCodeCamp.org' # or as an app eg  'freecodecamp-app'

If --name is omitted, you'll be asked to pick a channel from your subscriptions.
If --name is given without an action, the interactive channel menu will open.

Note: The channel name must match what appears in your subscriptions exactly.
      Use the Miscellaneous → Explore Channels feature if you haven't subscribed yet.
"@

  $script:TXT_APP_USAGE_COMPLETIONS = @"
Generate shell completions for $CLI_NAME

Options:
  --fish
    print fish completions and exit
  --bash
    print bash completions and exit
  --zsh
    print zsh completions and exit

Example:
  $CLI_NAME completions --fish
  $CLI_NAME completions --bash
  $CLI_NAME completions --zsh
"@

  $script:TXT_ICON_MENU_MEDIA_ACTIONS_WATCH = ""
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_WATCH_ALL = ""
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_LISTEN = "󰎆"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_LISTEN_ALL = ""
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_MIX = ""
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_SAVE = ""
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_UNSAVE = "󰧎"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_SAVE_PLAYLIST = "󰐒"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_UNSAVE_PLAYLIST = "󰐒"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_VISIT_CHANNEL = "󰑈"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_SUBSCRIBE = "󰵀"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_DOWNLOAD = "󱑤"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL = "󰦗"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_DOWNLOAD_AUDIO = "󱑤"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL_AUDIO = "󰦗"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_BROWSER = ""
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_TOGGLE_ENUM = ""
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_SHELL = ""
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_BACK = "󰌍"
  $script:TXT_ICON_MENU_MEDIA_ACTIONS_EXIT = "󰈆"

  $script:TXT_ICON_MENU_CHANNEL_ACTIONS_VIDEOS = ""
  $script:TXT_ICON_MENU_CHANNEL_ACTIONS_FEATURED = "󰩉"
  $script:TXT_ICON_MENU_CHANNEL_ACTIONS_SEARCH = ""
  $script:TXT_ICON_MENU_CHANNEL_ACTIONS_PLAYLISTS = "󰐑"
  $script:TXT_ICON_MENU_CHANNEL_ACTIONS_SHORTS = ""
  $script:TXT_ICON_MENU_CHANNEL_ACTIONS_STREAMS = "󰠿"
  $script:TXT_ICON_MENU_CHANNEL_ACTIONS_PODCASTS = ""
  $script:TXT_ICON_MENU_CHANNEL_ACTIONS_SUBSCRIBE = "󰵀"
  $script:TXT_ICON_MENU_CHANNEL_ACTIONS_BACK = "󰌍"
  $script:TXT_ICON_MENU_CHANNEL_ACTIONS_EXIT = "󰈆"

  $script:TXT_ICON_MENU_MISC_EXPLORE_CHANNELS = "󰵀"
  $script:TXT_ICON_MENU_MISC_EXPLORE_PLAYLISTS = "󰐑"
  $script:TXT_ICON_MENU_MISC_EXPLORE_SHORTS = "󰕧"
  $script:TXT_ICON_MENU_MISC_EXPLORE_MOVIES = "󰿎"
  $script:TXT_ICON_MENU_MISC_SEARCH_HISTORY = "󱘢"
  $script:TXT_ICON_MENU_MISC_NEW_CUSTOM_CMD = "󰆺"
  $script:TXT_ICON_MENU_MISC_CUSTOM_CMDS = "󰡦"
  $script:TXT_ICON_MENU_MISC_EDIT_SEARCH_HISTORY = ""
  $script:TXT_ICON_MENU_MISC_EDIT_CUSTOM_PLAYLISTS = "󰤀"
  $script:TXT_ICON_MENU_MISC_EDIT_MPV_CONFIG = "󱄢"
  $script:TXT_ICON_MENU_MISC_EDIT_YTDLP_CONFIG = "󰮆"
  $script:TXT_ICON_MENU_MISC_EDIT_CUSTOM_CMDS = "󱘫"
  $script:TXT_ICON_MENU_MISC_SYNC_SUBS = "󰓦"
  $script:TXT_ICON_MENU_MISC_CLEAR_SEARCH_HISTORY = "󰆴"
  $script:TXT_ICON_MENU_MISC_BACK = ""
  $script:TXT_ICON_MENU_MISC_EXIT = "󰈆"

  $script:TXT_ICON_MENU_MAIN_FEED = ""
  $script:TXT_ICON_MENU_MAIN_SEARCH = ""
  $script:TXT_ICON_MENU_MAIN_SUBS_FEED = "󰵀"
  $script:TXT_ICON_MENU_MAIN_WATCH_LATER = ""
  $script:TXT_ICON_MENU_MAIN_PLAYLISTS = "󰐑"
  $script:TXT_ICON_MENU_MAIN_CHANNELS = "󰑈"
  $script:TXT_ICON_MENU_MAIN_CUSTOM_PLAYLISTS = ""
  $script:TXT_ICON_MENU_MAIN_SAVED = ""
  $script:TXT_ICON_MENU_MAIN_RECENT = ""
  $script:TXT_ICON_MENU_MAIN_LIKED = ""
  $script:TXT_ICON_MENU_MAIN_HISTORY = ""
  $script:TXT_ICON_MENU_MAIN_CLIPS = ""
  $script:TXT_ICON_MENU_MAIN_MISC = ""
  $script:TXT_ICON_MENU_MAIN_EDIT_CONFIG = ""
  $script:TXT_ICON_MENU_MAIN_EXIT = "󰈆"

  # original: [ -s "$CLI_DEFAULT_LANG_FILE" ] && . "$CLI_DEFAULT_LANG_FILE"
  # (shell lang file can't be sourced in pwsh; best-effort parse of TXT_*=… lines)
  if (Test-Path -LiteralPath $CLI_DEFAULT_LANG_FILE) {
    foreach ($line in (Get-Content -LiteralPath $CLI_DEFAULT_LANG_FILE)) {
      if ($line -match '^\s*(TXT_\w+)\s*=\s*(.*)$') {
        $v = $Matches[2].Trim() -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
        Set-Variable -Name $Matches[1] -Value $v -Scope script
      }
    }
  }
}

function __load_default_theme {
  $script:THEME_ESC = "`e"

  if ($CLI_SUPPORTS_TRUE_COLOR -and $CONFIG_ENABLE_COLORS -eq 'true') {
    # Tokyo Night: Cyan (#2ac3de)
    $script:THEME_FZF_ICON_COLOR_PRIMARY = "`e[38;2;42;195;222m"

    # Tokyo Night: Dark3 (#545c7e)
    $script:THEME_FZF_ICON_COLOR_SECONDARY = "`e[38;2;84;92;126m"

    # Tokyo Night: Orange (#ff9e64)
    $script:THEME_FZF_ICON_COLOR_ACCENT = "`e[38;2;255;158;100m"

    # Tokyo Night: Pink (#ff007c)
    $script:THEME_FZF_ICON_COLOR_ERROR = "`e[38;2;255;0;124m"

    # Tokyo Night: Foreground (#c0caf5)
    $script:THEME_FZF_PREVIEW_TITLE = "`e[38;2;192;202;245m"

    # Tokyo Night: Cyan (#2ac3de)
    $script:THEME_FZF_PREVIEW_KEY = "`e[38;2;42;195;222m"

    # Tokyo Night: Dark3 (#545c7e)
    $script:THEME_FZF_PREVIEW_VALUE = "`e[38;2;88;91;112m"

    # Tokyo Night: Dark3 (#545c7e)
    $script:THEME_FZF_PREVIEW_DIVIDER = "`e[38;2;88;91;112m"

    # Tokyo Night: Green (#9ece6a)
    $script:THEME_PLAYER_START = "`e[38;2;158;206;106m"

    $script:THEME_BOLD = "`e[1m"
    $script:THEME_RESET = "`e[0m"

    # original: [ -s "$CLI_DEFAULT_THEME_FILE" ] && . "$CLI_DEFAULT_THEME_FILE"
    # (best-effort parse of THEME_*=… lines; printf-based theme files won't fully translate)
    if (Test-Path -LiteralPath $CLI_DEFAULT_THEME_FILE) {
      foreach ($line in (Get-Content -LiteralPath $CLI_DEFAULT_THEME_FILE)) {
        if ($line -match '^\s*(THEME_\w+)\s*=\s*(.*)$') {
          $v = $Matches[2].Trim() -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
          Set-Variable -Name $Matches[1] -Value $v -Scope script
        }
      }
    }
  }
}

function __post_config_load {
  $script:CLI_HEADER = $THEME_FZF_ICON_COLOR_PRIMARY + @"
██╗░░░██╗████████╗░░░░░░██╗░░██╗
╚██╗░██╔╝╚══██╔══╝░░░░░░╚██╗██╔╝
░╚████╔╝░░░░██║░░░█████╗░╚███╔╝░
░░╚██╔╝░░░░░██║░░░╚════╝░██╔██╗░
░░░██║░░░░░░██║░░░░░░░░░██╔╝╚██╗
░░░╚═╝░░░░░░╚═╝░░░░░░░░░╚═╝░░╚═╝
"@ + $THEME_RESET

  if ($CONFIG_AUTOLOADED_EXTENSIONS) {
    foreach ($ext in ($CONFIG_AUTOLOADED_EXTENSIONS -split ',')) {
      $ext = $ext.Trim()
      $extPath = Join-Path $CLI_EXTENSIONS_DIR $ext
      # original sources shell extensions; in pwsh we dot-source .ps1 extensions
      if ((Test-Path -LiteralPath $extPath) -and ($extPath -like '*.ps1')) { . $extPath }
    }
  }

  $env:FZF_DEFAULT_OPTS = $CONFIG_FZF_OPTS
}

# ==============================================================================
# CORE: config
# ==============================================================================
function _print_config {
  @"
# ===================================================================================
# 大きな力には大きな責任が伴う
# ===================================================================================
#
#     ██╗░░░██╗████████╗░░░░░░██╗░░██╗  ░█████╗░░█████╗░███╗░░██╗███████╗██╗░██████╗░
#     ╚██╗░██╔╝╚══██╔══╝░░░░░░╚██╗██╔╝  ██╔══██╗██╔══██╗████╗░██║██╔════╝██║██╔════╝░
#     ░╚████╔╝░░░░██║░░░█████╗░╚███╔╝░  ██║░░╚═╝██║░░██║██╔██╗██║█████╗░░██║██║░░██╗░
#     ░░╚██╔╝░░░░░██║░░░╚════╝░██╔██╗░  ██║░░██╗██║░░██╗██║╚████║██╔══╝░░██║██║░░╚██╗
#     ░░░██║░░░░░░██║░░░░░░░░░██╔╝╚██╗  ╚█████╔╝╚█████╔╝██║░╚███║██║░░░░░██║╚██████╔╝
#     ░░░╚═╝░░░░░░╚═╝░░░░░░░░░╚═╝░░╚═╝  ░╚════╝░░╚════╝░╚═╝░░╚══╝╚═╝░░░░░╚═╝░╚═════╝░
#
# ===================================================================================
#
# !! BE CAREFUL WHAT YOU INCLUDE HERE SINCE THE CONFIG FILE IS SOURCED AS A SCRIPT  !!
# !! ITS RECOMMENDED TO ONLY DO VARIABLE ASSIGNMENTS AND CONDITIONAL ASSIGNMENTS    !!
# !! AND DO MORE COMPLEX STUFF USING EXTENSIONS BY CONVENTION                       !!
# !! Environment variables (export YT_X_VAR=...) override these settings.           !!
#
# ===================================================================================

# List of extensions to load automatically on startup
CONFIG_AUTOLOADED_EXTENSIONS="$CONFIG_AUTOLOADED_EXTENSIONS"

# Enable or disable colored/formatted output
# Options: true, false (Default: true)
CONFIG_ENABLE_COLORS="$CONFIG_ENABLE_COLORS"

# The menu launcher tool used for the ui
# Options: fzf, rofi, gum (Default: fzf)
CONFIG_LAUNCHER="$CONFIG_LAUNCHER"

# Enable image/video previews within the selector
# Options: true, false (Default: false)
CONFIG_ENABLE_PREVIEW="$CONFIG_ENABLE_PREVIEW"
CONFIG_ENABLE_PREVIEW_IMAGES="$CONFIG_ENABLE_PREVIEW_IMAGES"

# The tool used to render previews in the terminal
# Options: chafa, icat, imgcat (Default: chafa)
CONFIG_IMAGE_RENDERER="$CONFIG_IMAGE_RENDERER"

# Extra arguments for specific image renderers
CONFIG_CHAFA_ARGS="$CONFIG_CHAFA_ARGS"
CONFIG_ICAT_ARGS="$CONFIG_ICAT_ARGS"
CONFIG_IMGCAT_ARGS="$CONFIG_IMGCAT_ARGS"

# custom opts for yt-dlp
CONFIG_YT_DLP_OPTS="$CONFIG_YT_DLP_OPTS"

# The media player used for playback
# Options: mpv, vlc, tplay (Default: mpv)
CONFIG_PLAYER="$CONFIG_PLAYER"

# Extra arguments for specific media players
CONFIG_MPV_ARGS="$CONFIG_MPV_ARGS"
CONFIG_VLC_ARGS="$CONFIG_VLC_ARGS"
CONFIG_TPLAY_ARGS="$CONFIG_TPLAY_ARGS"

# Whether to disown the player, process to prevent blocking the UI
# options: true, false (Default: false)
CONFIG_DISOWN_PLAYER="$CONFIG_DISOWN_PLAYER"

# Maximum number of search results to fetch per page
# Options: Integer (Default: 30)
CONFIG_PER_PAGE="$CONFIG_PER_PAGE"

# Browser for yt-dlp to get cookies from
# passed to --cookies-from-browser yt-dlp option
# Currently supported browsers are: brave, chrome, chromium, edge, firefox, opera, safari, vivaldi, whale
# NOTE: this option is entirely dependent on what yt-dlp supports
CONFIG_BROWSER="$CONFIG_BROWSER"

# Text editor for manual configuration/metadata editing
# Options: vim, nano, code ... (Default: `$EDITOR or vi)
CONFIG_EDITOR="$CONFIG_EDITOR"

# The terminal to use to execute commands that require a terminal
CONFIG_TERMINAL_EXEC="$CONFIG_TERMINAL_EXEC"

# Duration in seconds for desktop notifications
CONFIG_NOTIFICATION_DURATION="$CONFIG_NOTIFICATION_DURATION"

# Directory where downloads are saved
# Default: $HOME/Videos/$CLI_NAME
CONFIG_DOWNLOAD_DIR="$CONFIG_DOWNLOAD_DIR"
CONFIG_DOWNLOADS_ENUMERATE="$CONFIG_DOWNLOADS_ENUMERATE"

# Automatically check for script updates on startup
# Options: true, false (Default: true)
CONFIG_CHECK_FOR_UPDATES="$CONFIG_CHECK_FOR_UPDATES"

# Number of items to keep in the recent history
CONFIG_NO_OF_RECENT="$CONFIG_NO_OF_RECENT"

# Enable or disable saving search queries to history
# Options: true, false (Default: true)
CONFIG_ENABLE_SEARCH_HISTORY="$CONFIG_ENABLE_SEARCH_HISTORY"

# Custom options passed directly to gum
CONFIG_GUM_OPTS="$CONFIG_GUM_FILTER_OPTS"
CONFIG_GUM_INPUT_OPTS="$CONFIG_GUM_INPUT_OPTS"
CONFIG_GUM_PAGER_OPTS="$CONFIG_GUM_PAGER_OPTS"
CONFIG_GUM_SPIN_OPTS="$CONFIG_GUM_SPIN_OPTS"
CONFIG_GUM_CONFIRM_OPTS="$CONFIG_GUM_CONFIRM_OPTS"

# Custom options passed directly to fzf
CONFIG_FZF_HEADER="\
$CONFIG_FZF_HEADER"
CONFIG_FZF_OPTS="$CONFIG_FZF_OPTS"

# Rofi config all are required to run rofi as a launcher
# get the official ones from $CLI_REPO_URL
CONFIG_ROFI_THEME_MAIN="$CONFIG_ROFI_THEME_MAIN"
CONFIG_ROFI_THEME_PREVIEW="$CONFIG_ROFI_THEME_PREVIEW"
CONFIG_ROFI_THEME_PROMPT="$CONFIG_ROFI_THEME_PROMPT"
CONFIG_ROFI_THEME_CONFIRM="$CONFIG_ROFI_THEME_CONFIRM"
CONFIG_ROFI_THEME_PAGER="$CONFIG_ROFI_THEME_PAGER"

# Number of days to keep cached preview images, playlists, and logs
# Default: 3
CONFIG_CACHE_RETENTION_DAYS="$CONFIG_CACHE_RETENTION_DAYS"
# ==============================================================================
# 楽しんでね
# ==============================================================================
"@
}

function _load_config {
  __load_default_config

  # original: [ -f "$CLI_CONFIG_FILE" ] || _print_config >"$CLI_CONFIG_FILE"
  if (-not (Test-Path -LiteralPath $CLI_CONFIG_FILE)) {
    # write LF + UTF-8 (no BOM) so the bash yt-x can still source the shared config
    [IO.File]::WriteAllText($CLI_CONFIG_FILE, ((_print_config) -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
  }

  # original: . "$CLI_CONFIG_FILE"
  # (per port decision: parse the shared shell config's CONFIG_*=… assignments
  # rather than sourcing it; this overrides the defaults set above)
  foreach ($line in (Get-Content -LiteralPath $CLI_CONFIG_FILE)) {
    if ($line -match '^\s*(?:export\s+)?(CONFIG_\w+)\s*=\s*(.*)$') {
      $v = $Matches[2].Trim() -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
      Set-Variable -Name $Matches[1] -Value $v -Scope script
    }
  }

  __load_env_config
  __load_default_lang
  __load_default_theme
  __post_config_load
}

# ==============================================================================
# CORE: utilities
# ==============================================================================
function _util_terminal_exec {
  $cmd = @($args)

  if (-not $CLI_IS_TERMINAL) {
    if ($CONFIG_TERMINAL_EXEC) { $term = $CONFIG_TERMINAL_EXEC }
    elseif (_dep_ch kitty) { $term = 'kitty --exec' }
    elseif (_dep_ch alacritty) { $term = 'alacritty --command' }
    else { ui_notify_error $TXT_NO_TERMINAL_EXEC; return }
    $termParts = $term -split ' '
    & $termParts[0] @($termParts | Select-Object -Skip 1) @cmd
    return
  }
  & $cmd[0] @($cmd | Select-Object -Skip 1)
}

function _util_open {
  param([string]$target)

  if (_dep_ch open) { & open $target; return ($LASTEXITCODE -eq 0) }
  elseif (_dep_ch xdg-open) { & xdg-open $target; return ($LASTEXITCODE -eq 0) }
  elseif (_dep_ch wslview) { & wslview $target; return ($LASTEXITCODE -eq 0) }
  elseif (_dep_ch cmd.exe) {
    # paths are already native Windows here — no MSYS /c/… (cygpath/wslpath) conversion needed
    & cmd.exe /C start "" "$target" *> $null
    return ($LASTEXITCODE -eq 0)
  } else {
    return $false
  }
}

function _util_file_edit {
  param([string]$file_path)

  if (_dep_ch $CONFIG_EDITOR) {
    _util_terminal_exec $CONFIG_EDITOR $file_path
  } elseif ($env:EDITOR -and (_dep_ch $env:EDITOR)) {
    _util_terminal_exec $env:EDITOR $file_path
  } elseif (-not (_util_open $file_path)) {
    ui_notify_warning $TXT_EDITOR_NOT_FOUND
  }
}

function _util_generate_hash {
  $inputStr = if ($args.Count -gt 0 -and $args[0]) { $args[0] } else { (@($input) -join "`n") }

  $inputStr = $inputStr -replace "`r", ''

  # original tries sha256sum/shasum/sha256/openssl then base64; .NET gives the
  # same lowercase hex sha256 of the (CR-stripped) bytes.
  $bytes = [Text.Encoding]::UTF8.GetBytes([string]$inputStr)
  -join ([Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') })
}

function _util_menu_sort {
  param([string]$sort)
  $lines = @($input)
  foreach ($o in ($sort -split ',')) { $lines[[int]$o - 1] }
}

function _util_byebye {
  "{0} {1}" -f $TXT_BYEBYE, ($env:USER ?? $env:USERNAME)
  # The original relies on main's EXIT trap; PowerShell's `exit` bypasses
  # try/finally, so run the runtime cleanup here on the explicit-exit path.
  _app_runtime_clean_up
  exit
}

# ==============================================================================
# CORE UI: notify
# ==============================================================================
function __ui_notify_terminal {
  param([string]$level, [string]$msg)
  #TODO: finish implementation
  switch ($level) {
    'info' { [Console]::Error.WriteLine($msg); Start-Sleep -Seconds $CONFIG_NOTIFICATION_DURATION }
    'warning' { [Console]::Error.WriteLine($msg); Start-Sleep -Seconds $CONFIG_NOTIFICATION_DURATION }
    'error' { [Console]::Error.WriteLine($msg); Start-Sleep -Seconds $CONFIG_NOTIFICATION_DURATION }
    'critical' { [Console]::Error.WriteLine($msg); exit 1 }
    default { [Console]::Error.WriteLine($msg); Start-Sleep -Seconds $CONFIG_NOTIFICATION_DURATION }
  }
}

function __ui_notify_non_terminal {
  param([string]$level, [string]$msg)
  #TODO: finish implementation
  switch ($level) {
    'info' { & notify-send $msg }
    'warning' { & notify-send $msg }
    'error' { & notify-send $msg }
    'critical' { & notify-send $msg; exit 1 }
  }
}

function _ui_notify {
  if ($CLI_IS_TERMINAL) { __ui_notify_terminal info $args[0] } else { __ui_notify_non_terminal info $args[0] }
}

function _ui_notify_warning {
  if ($CLI_IS_TERMINAL) { __ui_notify_terminal warning $args[0] } else { __ui_notify_non_terminal warning $args[0] }
}

function _ui_notify_error {
  if ($CLI_IS_TERMINAL) { __ui_notify_terminal error $args[0] } else { __ui_notify_non_terminal error $args[0] }
}

function _ui_notify_critical {
  if ($CLI_IS_TERMINAL) { __ui_notify_terminal critical $args[0] } else { __ui_notify_non_terminal critical $args[0] }
}

function ui_notify { _ui_notify @args }
function ui_notify_warning { _ui_notify_warning @args }
function ui_notify_error { _ui_notify_error @args }
function ui_notify_critical { _ui_notify_critical @args }

# ==============================================================================
# CORE UI: launcher
# ==============================================================================
# Port rule: pass `--with-shell $FZF_WITH_SHELL` to ANY fzf call that runs
# scripting logic (--preview, or --bind with execute/reload/become/transform/…)
# so that logic executes pwsh, not MSYS sh — this is what avoids the Windows
# ConPTY input corruption. "Simple" fzf calls (pure fuzzy filter, no
# shell-executing logic) do NOT need it. (Original used fzf's default $SHELL=sh.)
$FZF_WITH_SHELL = 'pwsh.exe -NoLogo -NonInteractive -NoProfile -Command'

function __ui_gum_launcher {
  $custom_opts = @()
  $multi_select = $args[1]

  if ($multi_select -eq 'multi') { $custom_opts += '--no-limit' }
  if ($CONFIG_FZF_HEADER) { $custom_opts += @('--header', $CONFIG_FZF_HEADER) }

  $input | gum filter @($CONFIG_GUM_FILTER_OPTS -split '\s+' | Where-Object { $_ }) --prompt "$($args[0]): " @custom_opts
}

function __ui_fzf_launcher {
  $custom_opts = @()
  $multi_select = $args[1]

  if ($multi_select -eq 'multi') { $custom_opts += '--multi' }
  if ($CONFIG_FZF_HEADER) { $custom_opts += @('--header-first', "--header=$CONFIG_FZF_HEADER") }

  $input | ForEach-Object { $_ -replace "`r", '' } |
    fzf.exe --prompt "$($args[0]): " @custom_opts
}

function __ui_rofi_launcher {
  if (-not (Test-Path -LiteralPath $CONFIG_ROFI_THEME_MAIN)) {
    ui_notify_critical "${TXT_ROFI_NOT_CONFIGURED}: where CONFIG_ROFI_THEME_MAIN=`"$CONFIG_ROFI_THEME_MAIN`""
  }
  $custom_opts = @()
  $multi_select = $args[1]
  if ($multi_select -eq 'multi') { $custom_opts += '-multi-select' }

  $ansi = "$THEME_ESC(\[[0-9;]*[a-zA-Z]|\(B)"
  $input | ForEach-Object { $_ -replace $ansi, '' } |
    rofi -no-config -theme $CONFIG_ROFI_THEME_MAIN -dmenu -i @custom_opts -p $args[0]
}

function _ui_launcher {
  switch ($CONFIG_LAUNCHER) {
    'rofi' { $input | __ui_rofi_launcher @args }
    'fzf' { $input | __ui_fzf_launcher @args }
    'gum' { $input | __ui_gum_launcher @args }
    default { ui_notify_critical "${TXT_LAUNCHER_UNKNOWN}: $CONFIG_LAUNCHER" }
  }
}

function ui_launcher { $input | _ui_launcher @args }

# ==============================================================================
# CORE UI: launcher with preview
# ==============================================================================
function __ui_fzf_launcher_with_preview {
  $custom_opts = @()
  $multi_select = $args[1]

  # Original set these inline in the sh preview wrapper; under --with-shell pwsh
  # the preview process inherits the launcher's environment, so export them.
  $env:TXT_PREVIEW_INSTALL_VIEWER = $TXT_PREVIEW_INSTALL_VIEWER
  $env:CONFIG_IMAGE_RENDERER = $CONFIG_IMAGE_RENDERER
  $env:CLI_PLATFORM = $CLI_PLATFORM
  $env:THEME_FZF_PREVIEW_DIVIDER = $THEME_FZF_PREVIEW_DIVIDER
  # fzf substitutes {1} (quoted) before running this via pwsh; don't add our own
  # quotes (that would double-quote to an empty arg).
  $preview_script = 'if (Test-Path -LiteralPath {1}) { & {1} }'

  if ($multi_select -eq 'multi') { $custom_opts += '--multi' }
  if ($CONFIG_FZF_HEADER) { $custom_opts += @('--header-first', "--header=$CONFIG_FZF_HEADER") }

  if ($CLI_PLATFORM -eq 'windows' -and $CONFIG_ENABLE_PREVIEW_IMAGES -eq 'true') {
    # fzf on windows uses a tcell-based renderer at --height=100% which does not
    # render sixel images. Anything <100% uses the LightRenderer which can.
    # Ref: https://github.com/junegunn/fzf/issues/4065#issuecomment-2439815977
    $custom_opts += '--height=99%'
  }

  $input | ForEach-Object { $_ -replace "`r", '' } |
    fzf.exe --prompt "$($args[0]): " --delimiter '|' --with-nth '{2..}' --accept-nth '{2..}' --with-shell $FZF_WITH_SHELL --preview $preview_script @custom_opts
}

function __ui_rofi_launcher_with_preview {
  if (-not (Test-Path -LiteralPath $CONFIG_ROFI_THEME_PREVIEW)) {
    ui_notify_critical "${TXT_ROFI_NOT_CONFIGURED}: where CONFIG_ROFI_THEME_PREVIEW=`"$CONFIG_ROFI_THEME_PREVIEW`""
  }
  $custom_opts = @()
  $multi_select = $args[1]
  if ($multi_select -eq 'multi') { $custom_opts += '-multi-select' }

  $ansi = "$THEME_ESC(\[[0-9;]*[a-zA-Z]|\(B)"
  $input | ForEach-Object { $_ -replace $ansi, '' } |
    rofi -no-config -theme $CONFIG_ROFI_THEME_PREVIEW -dmenu -i @custom_opts -p $args[0]
}

function _ui_launcher_with_preview {
  if ($CONFIG_ENABLE_PREVIEW -eq 'true') {
    switch ($CONFIG_LAUNCHER) {
      'rofi' { $input | __ui_rofi_launcher_with_preview @args }
      'fzf' { $input | __ui_fzf_launcher_with_preview @args }
      'gum' { $input | __ui_gum_launcher @args }
      default { ui_notify_critical "${TXT_LAUNCHER_UNKNOWN}: $CONFIG_LAUNCHER" }
    }
  } else {
    $input | ui_launcher @args
  }
}

function ui_launcher_with_preview { $input | _ui_launcher_with_preview @args }

# ==============================================================================
# CORE UI: prompt
# ==============================================================================
function __ui_default_prompt {
  $header = $args[1]

  if (_dep_ch gum) {
    gum input @($CONFIG_GUM_INPUT_OPTS -split '\s+' | Where-Object { $_ }) --header $header --prompt "$($args[0]): "
  } else {
    if ($header) { [Console]::Error.WriteLine($header) }
    [Console]::Error.Write("$($args[0]): ")
    [Console]::In.ReadLine()
  }
}

function __ui_rofi_prompt {
  $default = ''
  $filter = ''
  if ([Console]::IsInputRedirected) {
    $default = [Console]::In.ReadToEnd()
    $filter = '-filter'
  }

  if (-not (Test-Path -LiteralPath $CONFIG_ROFI_THEME_PROMPT)) {
    ui_notify_critical "Rofi prompt theme not set: $CONFIG_ROFI_THEME_PROMPT"
  }

  # NOTE: the -mesg variant doesnt look pretty so the original disables it (&& false)
  rofi -no-config -theme $CONFIG_ROFI_THEME_PROMPT $filter $default -dmenu -p $args[0]
}

function _ui_prompt {
  switch ($CONFIG_LAUNCHER) {
    'rofi' { $input | __ui_rofi_prompt @args }
    default { __ui_default_prompt @args }
  }
}

function ui_prompt { $input | _ui_prompt @args }

# ==============================================================================
# CORE UI: confirm
# ==============================================================================
function _ui_default_confirm {
  $yes = $args[2] ?? $TXT_YES
  $no = $args[3] ?? $TXT_NO
  $default = $args[1] ?? $no
  $default_index = if ($default -eq $yes) { 1 } else { 0 }

  if (_dep_ch gum) {
    gum confirm $args[0] --default=$default_index --affirmative=$yes --negative=$no @($CONFIG_GUM_CONFIRM_OPTS -split '\s+' | Where-Object { $_ })
    return ($LASTEXITCODE -eq 0)
  } else {
    [Console]::Error.Write("$($args[0]) ($yes/$no; ${TXT_CONFIRM_DEFAULT}: $default): ")
    $CONFIRMED = [Console]::In.ReadLine()
    switch ($CONFIRMED) {
      $yes { return $true }
      $no { return $false }
      default { return ($default -eq $yes) }
    }
  }
}

function _ui_rofi_confirm {
  if (-not (Test-Path -LiteralPath $CONFIG_ROFI_THEME_CONFIRM)) {
    ui_notify_critical "${TXT_ROFI_NOT_CONFIGURED}: where CONFIG_ROFI_THEME_CONFIRM=`"$CONFIG_ROFI_THEME_CONFIRM`""
  }
  $yes = $args[2] ?? $TXT_YES
  $no = $args[3] ?? $TXT_NO
  $default = $args[1] ?? $no
  $default_index = if ($default -eq $yes) { 0 } else { 1 }

  $selection = @($yes, $no) | rofi -no-config -theme $CONFIG_ROFI_THEME_CONFIRM -dmenu -i -p $args[0] -selected-row $default_index
  return ($selection -eq $yes)
}

function _ui_confirm {
  switch ($CONFIG_LAUNCHER) {
    'rofi' { _ui_rofi_confirm @args }
    default { _ui_default_confirm @args }
  }
}

function ui_confirm { _ui_confirm @args }

# ==============================================================================
# CORE UI: pager
# ==============================================================================
function __ui_default_pager {
  if (_dep_ch bat) { $input | bat --paging=always --theme=TwoDark --color=always }
  elseif (_dep_ch gum) { $input | gum pager @($CONFIG_GUM_PAGER_OPTS -split '\s+' | Where-Object { $_ }) }
  elseif (_dep_ch less) { $input | less -R }
  else { $input | more }
}

function __ui_rofi_pager {
  if (-not (Test-Path -LiteralPath $CONFIG_ROFI_THEME_PAGER)) {
    ui_notify_critical "${TXT_ROFI_NOT_CONFIGURED}: where CONFIG_ROFI_THEME_PAGER=`"$CONFIG_ROFI_THEME_PAGER`""
  }
  rofi -no-config -theme $CONFIG_ROFI_THEME_PAGER -dmenu -i -mesg $TXT_ROFI_PAGER_MESSAGE -p $TXT_ROFI_PAGER_PROMPT
}

function _ui_pager {
  switch ($CONFIG_LAUNCHER) {
    'rofi' { $input | __ui_rofi_pager }
    default { $input | __ui_default_pager }
  }
}

function ui_pager { $input | _ui_pager }

# ==============================================================================
# CORE UI: loader
# ==============================================================================
function __ui_default_loader {
  $cmd = @($args)

  if (_dep_ch gum) {
    gum spin @($CONFIG_GUM_SPIN_OPTS -split '\s+' | Where-Object { $_ }) --show-output -- @cmd
  } else {
    [Console]::Error.WriteLine($TXT_LOADING)
    & $cmd[0] @($cmd | Select-Object -Skip 1)
  }
}

function __ui_rofi_loader {
  $cmd = @($args)
  ui_notify $TXT_LOADING
  & $cmd[0] @($cmd | Select-Object -Skip 1)
}

function _ui_loader {
  switch ($CONFIG_LAUNCHER) {
    'rofi' { __ui_rofi_loader @args }
    default { __ui_default_loader @args }
  }
}

function ui_load { _ui_loader @args }

# ==============================================================================
# Previews
# ==============================================================================
# The shared preview script is PowerShell (dot-sourced by per-item scripts which
# fzf runs via --with-shell pwsh). Image renderers (chafa/icat) emit binary
# (sixel / kitty-graphics); PowerShell is not a transparent byte pipe, so each
# renderer is run to a temp file and its raw bytes are written to stdout. All
# output (image bytes + text) goes through ONE raw stdout stream so ordering and
# UTF-8 are preserved.
function __preview_fzf_create_shared_script {
  if ((Test-Path -LiteralPath $CLI_FZF_PREVIEW_SCRIPT) -and (Get-Item -LiteralPath $CLI_FZF_PREVIEW_SCRIPT).Length -gt 0) { return }

  Set-Content -Encoding utf8 -LiteralPath $CLI_FZF_PREVIEW_SCRIPT -Value @'
# ==============================================================================
# Shared script for fzf previews (PowerShell; dot-sourced by per-item scripts)
# ==============================================================================
$YTX_OUT = [Console]::OpenStandardOutput()
function Emit { param([string]$s) $b = [Text.Encoding]::UTF8.GetBytes($s); $YTX_OUT.Write($b, 0, $b.Length) }
function EmitLine { param([string]$s) Emit ($s + "`n") }
function _dep { param($c) [bool](Get-Command $c -ErrorAction SilentlyContinue) }

function __emit_raw {
  param([string]$path)
  if (Test-Path -LiteralPath $path) { $b = [IO.File]::ReadAllBytes($path); $YTX_OUT.Write($b, 0, $b.Length) }
}

function __render {
  # run a native renderer, capture stdout to a temp file, emit its raw bytes
  param([string]$exe, [string[]]$exeArgs)
  $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
  try {
    Start-Process -NoNewWindow -Wait -FilePath $exe -ArgumentList $exeArgs -RedirectStandardOutput $so -RedirectStandardError $se -ErrorAction SilentlyContinue
    __emit_raw $so
  } catch { }
  Remove-Item -Force $so, $se -ErrorAction SilentlyContinue
}

function draw_divider {
  $cols = 0; [void][int]::TryParse($env:FZF_PREVIEW_COLUMNS, [ref]$cols)
  EmitLine ($env:THEME_FZF_PREVIEW_DIVIDER + ([string]([char]0x2500) * $cols) + $env:THEME_RESET)
}

function fzf_preview {
  param([string]$file)

  $dim = "$($env:FZF_PREVIEW_COLUMNS)x$($env:FZF_PREVIEW_LINES)"
  # (port: dropped the stty/last-line dim shave — relied on /dev/tty; minor cosmetic)

  if ($env:CONFIG_IMAGE_RENDERER -eq 'icat' -and -not $env:GHOSTTY_BIN_DIR) {
    $a = @('icat', '--clear', '--transfer-mode=memory', '--unicode-placeholder', '--stdin=no', "--place=$dim@0x0", $file)
    if (_dep kitten) { __render 'kitten.exe' $a }
    elseif (_dep icat) { __render 'icat.exe' ($a | Select-Object -Skip 1) }
    else { __render 'kitty.exe' $a }
  }
  elseif ($env:GHOSTTY_BIN_DIR) {
    $a = @('icat', '--clear', '--transfer-mode=memory', '--unicode-placeholder', '--stdin=no', "--place=$dim@0x0", $file)
    if (_dep kitten) { __render 'kitten.exe' $a }
    elseif (_dep icat) { __render 'icat.exe' ($a | Select-Object -Skip 1) }
    else { __render 'chafa.exe' @('-s', $dim, $file) }
  }
  elseif (_dep chafa) {
    switch ($env:CLI_PLATFORM) {
      'android' { __render 'chafa.exe' @('-s', $dim, $file) }
      'windows' {
        # sixels, with the symbol-art fallback (original's `|| chafa -s …`)
        $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
        Start-Process -NoNewWindow -Wait -FilePath 'chafa.exe' -ArgumentList @('-f', 'sixels', '--colors=full', '--polite=on', '--animate=off', '-s', $dim, $file) -RedirectStandardOutput $so -RedirectStandardError $se -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $so) -or (Get-Item -LiteralPath $so).Length -eq 0) {
          Start-Process -NoNewWindow -Wait -FilePath 'chafa.exe' -ArgumentList @('-s', $dim, '--animate=off', $file) -RedirectStandardOutput $so -RedirectStandardError $se -ErrorAction SilentlyContinue
        }
        __emit_raw $so
        Remove-Item -Force $so, $se -ErrorAction SilentlyContinue
      }
      default { __render 'chafa.exe' @('-s', $dim, $file) }
    }
    EmitLine ''
  }
  elseif (_dep imgcat) {
    __render 'imgcat.exe' @('-W', ($dim -split 'x')[0], '-H', ($dim -split 'x')[1], $file)
  }
  else {
    Emit $env:TXT_PREVIEW_INSTALL_VIEWER
  }
  $YTX_OUT.Flush()
}
'@
}

# ------------------------------------------------------------------------------
# Format helpers — port of the jq `format_number` / `format_duration` /
# `format_timestamp` defs that the original runs (via jq) inside
# __preview_fzf_generate_script_for_item. Like the original, these run in the
# MAIN process at generation time. Each returns $null for a missing/non-numeric
# value (the jq "null" sentinel), so callers can decide whether to emit the line.
# ------------------------------------------------------------------------------
function __fmt_number {
  param($n)
  if ($null -eq $n -or "$n" -eq '') { return $null }
  $v = [int64]0
  if (-not [int64]::TryParse("$n", [ref]$v)) {
    $d = [double]0
    if (-not [double]::TryParse("$n", [ref]$d)) { return "$n" }
    $v = [int64][math]::Floor($d)
  }
  $v.ToString('N0', [Globalization.CultureInfo]::InvariantCulture)
}

function __fmt_duration {
  param($s)
  if ($null -eq $s -or "$s" -eq '') { return $null }
  $d = [double]0
  if (-not [double]::TryParse("$s", [ref]$d)) { return $null }
  if ($d -ge 3600) {
    $h = [int64][math]::Floor($d / 3600)
    if ($h -eq 1) { "$h hour" } else { "$h hours" }
  } elseif ($d -ge 60) {
    $m = [int64][math]::Floor($d / 60)
    if ($m -eq 1) { "$m min" } else { "$m mins" }
  } else {
    $sec = [int64][math]::Floor($d)
    if ($sec -eq 1) { "$sec sec" } else { "$sec secs" }
  }
}

function __fmt_timestamp {
  param([object]$entry)
  $epoch = $null
  if ($null -ne $entry.timestamp -and "$($entry.timestamp)" -ne '') {
    $tmp = [int64]0
    if ([int64]::TryParse("$($entry.timestamp)", [ref]$tmp)) { $epoch = $tmp }
  } elseif ($entry.upload_date) {
    try {
      $dt = [datetime]::ParseExact("$($entry.upload_date)", 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
      $epoch = [DateTimeOffset]::new([datetime]::SpecifyKind($dt, 'Utc')).ToUnixTimeSeconds()
    } catch { $epoch = $null }
  }
  if ($null -eq $epoch) { return $null }
  $diff = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $epoch
  if ($diff -lt 60) { 'Just now' }
  elseif ($diff -lt 3600) { $m = [int64][math]::Floor($diff / 60); if ($m -eq 1) { '1 minute ago' } else { "$m minutes ago" } }
  elseif ($diff -lt 86400) { $h = [int64][math]::Floor($diff / 3600); if ($h -eq 1) { '1 hour ago' } else { "$h hours ago" } }
  elseif ($diff -lt 2592000) { $dd = [int64][math]::Floor($diff / 86400); if ($dd -eq 1) { '1 day ago' } else { "$dd days ago" } }
  elseif ($diff -lt 31536000) { $mo = [int64][math]::Floor($diff / 2592000); if ($mo -eq 1) { '1 month ago' } else { "$mo months ago" } }
  else { $y = [int64][math]::Floor($diff / 31536000); if ($y -eq 1) { '1 year ago' } else { "$y years ago" } }
}

# PowerShell single-quote escaper — the analogue of jq's @sh used by the original
# to bake values safely into the generated sh script. Wraps an arbitrary value in
# a single-quoted PowerShell literal (doubling any embedded single quotes).
function __psq {
  param($s)
  "'" + (([string]$s) -replace "'", "''") + "'"
}

function __preview_fzf_generate_script_for_item {
  param([object]$data_item)

  $raw_title = "$($data_item.title)"
  $title     = $raw_title -replace '^[0-9]+ ', ''
  $id        = "$($data_item.id)"

  $img_url = ''
  if ($data_item.thumbnails -and @($data_item.thumbnails).Count -gt 0) {
    $img_url = "$(@($data_item.thumbnails)[-1].url)"
  }
  if ($img_url -like '//*') { $img_url = "https:$img_url" }

  $view_count             = __fmt_number $data_item.view_count
  $channel_follower_count = __fmt_number $data_item.channel_follower_count
  $duration               = __fmt_duration $data_item.duration
  $timestamp              = __fmt_timestamp $data_item

  $live_status = switch ("$($data_item.live_status)") {
    'is_live'  { 'Online' }
    'was_live' { 'Offline' }
    default    { $null }
  }
  $description = if ($null -ne $data_item.description -and "$($data_item.description)" -ne '') { "$($data_item.description)" } else { $null }
  $channel     = if ($null -ne $data_item.channel -and "$($data_item.channel)" -ne '') { "$($data_item.channel)" } else { $null }

  $preview_script_path = "$CLI_PREVIEW_SCRIPTS_DIR/$(_util_generate_hash $raw_title).ps1"
  $image_path          = "$CLI_PREVIEW_IMGS_DIR/$(_util_generate_hash $img_url).jpg"

  # Theme pieces baked into the generated script (it runs in a separate pwsh that
  # has no access to these $script: vars; the original likewise bakes them via the
  # heredoc). The KEY label combines KEY colour + BOLD, matching the original.
  $K = $THEME_FZF_PREVIEW_KEY + $THEME_BOLD
  $R = $THEME_RESET
  $V = $THEME_FZF_PREVIEW_VALUE

  # Field presence is known here, so we emit only the lines for present fields
  # (the original bakes every value and skips at runtime via a "null" sentinel —
  # same result). No fold: fzf wraps the preview via --preview-window=…,wrap-word.
  $L = [System.Collections.Generic.List[string]]::new()
  $L.Add('# =============================================================================')
  $L.Add('# This script is generated dynamically for each preview item and is executed by')
  $L.Add('# fzf (via --with-shell pwsh) when that item is previewed. Customize the content')
  $L.Add('# and layout by editing __preview_fzf_generate_script_for_item. It has access to')
  $L.Add("# the helpers in the shared script ($CLI_FZF_PREVIEW_SCRIPT).")
  $L.Add('# =============================================================================')
  $L.Add("if (Test-Path -LiteralPath $(__psq $CLI_FZF_PREVIEW_SCRIPT)) { . $(__psq $CLI_FZF_PREVIEW_SCRIPT) } else { exit 1 }")
  $L.Add('')

  if ($CONFIG_ENABLE_PREVIEW_IMAGES -eq 'true') {
    $L.Add("if (Test-Path -LiteralPath $(__psq $image_path)) { fzf_preview $(__psq $image_path) } else { EmitLine $(__psq $TXT_FZF_PREVIEW_IMAGE_LOADING) }")
    $L.Add('')
  }

  $L.Add('draw_divider')
  $L.Add("EmitLine $(__psq ($THEME_FZF_PREVIEW_TITLE + $title + $THEME_FZF_PREVIEW_TITLE))")
  $L.Add('draw_divider')

  if ($channel) {
    $L.Add("EmitLine $(__psq ($K + $TXT_FZF_PREVIEW_CHANNEL + ': ' + $R + $V + $channel + $R))")
  }
  if ($channel_follower_count) {
    $L.Add("EmitLine $(__psq ($K + $TXT_FZF_PREVIEW_CHANNEL_FOLLOWERS + ': ' + $R + $V + $channel_follower_count + $R))")
  }
  if ($channel -and $duration) {
    $L.Add('draw_divider')
  }
  if ($duration) {
    $L.Add("EmitLine $(__psq ($K + $TXT_FZF_PREVIEW_DURATION + ': ' + $R + $V + $duration + $R))")
  }
  if ($view_count) {
    $L.Add("EmitLine $(__psq ($K + $TXT_FZF_PREVIEW_VIEW_COUNT + ': ' + $R + $V + $view_count + ' views' + $R))")
  }
  if ($live_status) {
    $L.Add("EmitLine $(__psq ($K + $TXT_FZF_PREVIEW_LIVE_STATUS + ': ' + $R + $V + $live_status + $R))")
  }
  if ($timestamp) {
    $L.Add("EmitLine $(__psq ($K + $TXT_FZF_PREVIEW_TIMESTAMP + ': ' + $R + $V + $timestamp + $R))")
  }
  if ($channel -or $channel_follower_count -or $duration -or $view_count -or $live_status -or $timestamp) {
    $L.Add('draw_divider')
  }
  if ($description) {
    $L.Add("EmitLine $(__psq $description)")
  }

  [IO.File]::WriteAllText($preview_script_path, ($L -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}

function _preview_fzf_generate_script {
  param([object]$data_to_preview)

  __preview_fzf_create_shared_script

  $data = if ($data_to_preview -is [string]) { $data_to_preview | ConvertFrom-Json } else { $data_to_preview }
  foreach ($data_item in @($data.entries)) {
    __preview_fzf_generate_script_for_item $data_item
  }
}

function __preview_download_image {
  param([string]$url, [string]$output_path, [string]$images_to_download_file)

  # NOTE: the original converts MSYS paths with `cygpath -m` here because the
  # Windows-shipped curl.exe cannot write to /c/... paths. This port uses native
  # forward-slash Windows paths throughout, so no conversion is needed.
  if (-not (Test-Path -LiteralPath $output_path) -or (Get-Item -LiteralPath $output_path).Length -eq 0) {
    Add-Content -LiteralPath $images_to_download_file -Value "url=$url"
    Add-Content -LiteralPath $images_to_download_file -Value "output=$output_path"
  }
}

function _preview_fzf_download_imgs {
  param([object]$data_to_preview)

  $images_to_download_file = "$CLI_CURRENT_STATE_DIR/images-to-download-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

  $data = if ($data_to_preview -is [string]) { $data_to_preview | ConvertFrom-Json } else { $data_to_preview }
  foreach ($entry in @($data.entries)) {
    $url = ''
    if ($entry.thumbnails -and @($entry.thumbnails).Count -gt 0) { $url = "$(@($entry.thumbnails)[-1].url)" }
    if ($url -like '//*') { $url = "https:$url" }

    $output_path = "$CLI_PREVIEW_IMGS_DIR/$(_util_generate_hash $url).jpg"
    __preview_download_image $url $output_path $images_to_download_file
  }

  if ((Test-Path -LiteralPath $images_to_download_file) -and (Get-Item -LiteralPath $images_to_download_file).Length -gt 0) {
    & curl.exe -sL --parallel --parallel-max 5 --config $images_to_download_file *> $null
    Remove-Item -LiteralPath $images_to_download_file -ErrorAction SilentlyContinue
  }
}

# Background/disowned execution — the PowerShell analogue of bash `<func> & </dev/null`.
# PowerShell has no fork, so a disowned task launches a DETACHED, hidden pwsh that
# re-sources THIS script (defining every function + a fresh _load_config) and then
# invokes $func with data read from a temp file. The worker has its OWN console, so
# its native curl/IO churn cannot corrupt fzf's input (the Windows ConPTY issue).
# Re-sourcing is guarded by $env:YTX_SOURCED so it does not re-enter main.
function __run_disowned {
  param([string]$func, [string]$data)

  $datafile = "$CLI_CURRENT_STATE_DIR/disowned-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())-$func"
  [IO.File]::WriteAllText($datafile, $data, [Text.UTF8Encoding]::new($false))

  $cmd = "`$env:YTX_SOURCED='1'; . '$PSCommandPath'; _load_config *> `$null; $func (Get-Content -Raw -LiteralPath '$datafile'); Remove-Item -LiteralPath '$datafile' -ErrorAction SilentlyContinue"
  Start-Process -FilePath 'pwsh.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoLogo', '-NonInteractive', '-NoProfile', '-Command', $cmd
  ) | Out-Null
}

function _preview_fzf {
  param([object]$data_to_preview)

  # Filter: transform each piped title line into "<per-item script path>|<title>"
  # (fzf splits on '|', shows the title, runs the script for the preview). The
  # hash matches __preview_fzf_generate_script_for_item (both hash the title).
  $inLines = "$(@($input) -join "`n")" -split "`n"
  if ($inLines.Count -gt 0 -and $inLines[-1] -eq '') { $inLines = $inLines[0..($inLines.Count - 2)] }
  foreach ($line in $inLines) {
    if ($CONFIG_ENABLE_PREVIEW -eq 'true') {
      "$CLI_PREVIEW_SCRIPTS_DIR/$(_util_generate_hash $line).ps1|$line"
    } else {
      $line
    }
  }

  if ($CONFIG_ENABLE_PREVIEW -eq 'true') {
    __run_disowned '_preview_fzf_generate_script' "$data_to_preview"
    if ($CONFIG_ENABLE_PREVIEW_IMAGES -eq 'true') {
      __run_disowned '_preview_fzf_download_imgs' "$data_to_preview"
    }
  }
}

function preview_fzf {
  $input | _preview_fzf @args
}

function _preview_rofi {
  param([object]$data_to_preview)

  $stdin = "$(@($input) -join "`n")" -split "`n"
  if ($stdin.Count -gt 0 -and $stdin[-1] -eq '') { $stdin = $stdin[0..($stdin.Count - 2)] }

  $output = "$CLI_CURRENT_STATE_DIR/rofi-preview-output-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
  $images_to_download_file = "$CLI_CURRENT_STATE_DIR/images-to-download-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

  if ($CONFIG_ENABLE_PREVIEW -eq 'true' -and "$data_to_preview" -ne '') {
    $input_titles = $stdin

    $data = if ($data_to_preview -is [string]) { $data_to_preview | ConvertFrom-Json } else { $data_to_preview }
    $outLines = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($data.entries)) {
      $url = ''
      if ($entry.thumbnails -and @($entry.thumbnails).Count -gt 0) { $url = "$(@($entry.thumbnails)[-1].url)" }
      $title = "$($entry.title)"
      if ($url -and $url -ne 'null') {
        if ($url -like '//*') { $url = "https:$url" }
        $img_path = "$CLI_PREVIEW_IMGS_DIR/$(_util_generate_hash $url).jpg"
        __preview_download_image $url $img_path $images_to_download_file
        $outLines.Add("$title$([char]0)icon$([char]0x1f)$img_path")
      } else {
        $outLines.Add($title)
      }
    }
    [IO.File]::WriteAllText($output, ($outLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))

    if ((Test-Path -LiteralPath $images_to_download_file) -and (Get-Item -LiteralPath $images_to_download_file).Length -gt 0) {
      & curl.exe -sL --parallel --parallel-max 5 --config $images_to_download_file *> $null
      Remove-Item -LiteralPath $images_to_download_file -ErrorAction SilentlyContinue
    }

    $input_count = $input_titles.Count
    $output_count = $outLines.Count
    $others = $input_count + 1 - $output_count

    $outLines
    if ($others -gt 0) {
      $input_titles | Select-Object -Last $others
    }
  } else {
    $stdin
  }
}

function preview_rofi {
  $input | _preview_rofi @args
}

function _preview {
  switch ($CONFIG_LAUNCHER) {
    'fzf'  { $input | preview_fzf @args }
    'rofi' { $input | preview_rofi @args }
    default { $input }
  }
}

function preview {
  $input | _preview @args
}

# ==============================================================================
# State Management
# ==============================================================================
function __state_clean_prev {
  $current_state_dir = "$CLI_CURRENT_STATE_DIR/$STATE_CURRENT"
  if (-not (Test-Path -LiteralPath $current_state_dir -PathType Container)) { ui_notify_critical $TXT_STATE_MALFORMED_CURRENT }
  Remove-Item -Recurse -Force -LiteralPath $current_state_dir -ErrorAction SilentlyContinue
}

function _state_init {
  $script:STATE_CURRENT = 0

  $script:STATE_CURRENT_CHANNEL_RESULTS = ''
  $script:STATE_CURRENT_CHANNEL_RESULTS_URL = ''
  $script:STATE_CURRENT_CHANNEL_RESULTS_START = 1
  $script:STATE_CURRENT_CHANNEL_RESULTS_END = $CONFIG_PER_PAGE

  $script:STATE_CURRENT_CHANNEL_URL = ''
  $script:STATE_CURRENT_CHANNEL_TITLE = ''

  $script:STATE_CURRENT_PLAYLISTS_RESULTS = ''
  $script:STATE_CURRENT_PLAYLISTS_RESULTS_URL = ''
  $script:STATE_CURRENT_PLAYLISTS_RESULTS_TITLE = ''
  $script:STATE_CURRENT_PLAYLISTS_RESULTS_START = 1
  $script:STATE_CURRENT_PLAYLISTS_RESULTS_END = $CONFIG_PER_PAGE

  $script:STATE_CURRENT_PLAYLIST_RESULTS = ''
  $script:STATE_CURRENT_PLAYLIST_URL = ''
  $script:STATE_CURRENT_PLAYLIST_TITLE = ''
  $script:STATE_CURRENT_PLAYLIST_START = 1
  $script:STATE_CURRENT_PLAYLIST_END = $CONFIG_PER_PAGE

  $script:STATE_CURRENT_VIDEO = ''
  $script:STATE_CURRENT_VIDEO_URL = ''
  $script:STATE_CURRENT_VIDEO_TITLE = ''
}

# State vars persisted on push / restored on pop. Order is not significant here
# (unlike the original heredoc) because each is written as an independent
# `$script:NAME = '…'` assignment.
$script:_STATE_VARS = @(
  'STATE_CURRENT_CHANNEL_RESULTS', 'STATE_CURRENT_CHANNEL_RESULTS_URL',
  'STATE_CURRENT_CHANNEL_RESULTS_START', 'STATE_CURRENT_CHANNEL_RESULTS_END',
  'STATE_CURRENT_CHANNEL_URL', 'STATE_CURRENT_CHANNEL_TITLE',
  'STATE_CURRENT_PLAYLISTS_RESULTS', 'STATE_CURRENT_PLAYLISTS_RESULTS_URL',
  'STATE_CURRENT_PLAYLISTS_RESULTS_TITLE', 'STATE_CURRENT_PLAYLISTS_RESULTS_START',
  'STATE_CURRENT_PLAYLISTS_RESULTS_END',
  'STATE_CURRENT_PLAYLIST_RESULTS', 'STATE_CURRENT_PLAYLIST_URL', 'STATE_CURRENT_PLAYLIST_TITLE',
  'STATE_CURRENT_PLAYLIST_START', 'STATE_CURRENT_PLAYLIST_END',
  'STATE_CURRENT_VIDEO', 'STATE_CURRENT_VIDEO_URL', 'STATE_CURRENT_VIDEO_TITLE'
)

function _state_push {
  $script:STATE_CURRENT = $STATE_CURRENT + 1
  $current_state_dir = "$CLI_CURRENT_STATE_DIR/$STATE_CURRENT"
  New-Item -ItemType Directory -Force -Path $current_state_dir | Out-Null

  # The original writes an sh `state.env` (VAR='…' with sed-escaped quotes) that
  # _state_pop sources. The port writes a `state.ps1` of `$script:VAR = '…'`
  # assignments (single-quote escaped via __psq) that _state_pop dot-sources.
  $L = [System.Collections.Generic.List[string]]::new()
  foreach ($v in $_STATE_VARS) {
    $val = Get-Variable -Name $v -Scope script -ValueOnly -ErrorAction SilentlyContinue
    $L.Add("`$script:$v = $(__psq $val)")
  }
  [IO.File]::WriteAllText("$current_state_dir/state.ps1", ($L -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}

function _state_pop {
  param([int]$pop_count = 1)

  if ($pop_count -le 0) { return }

  $i = 0
  while ($i -lt $pop_count) {
    __state_clean_prev
    $script:STATE_CURRENT = $STATE_CURRENT - 1
    $i++
  }

  if ($STATE_CURRENT -lt 1) { return }

  $current_state_dir = "$CLI_CURRENT_STATE_DIR/$STATE_CURRENT"
  if (-not (Test-Path -LiteralPath $current_state_dir -PathType Container)) { ui_notify_critical $TXT_STATE_MALFORMED_CURRENT }

  try { . "$current_state_dir/state.ps1" } catch { ui_notify_critical $TXT_STATE_MALFORMED_CURRENT }
}

# ==============================================================================
# Data Fetching
# ==============================================================================
# Port of the jq used (identically) by _fetch_playlist/_fetch_playlists/_fetch_channels
# to prefix each entry's title with its 1-based index, zero-padded to >= 2 digits
# ("01 Title", "02 Title", …, "10 Title"). Mutates and returns the parsed object.
function __number_entry_titles {
  param([object]$obj)
  if ($obj.entries) {
    $k = 0
    foreach ($e in @($obj.entries)) {
      $n = ($k + 1).ToString()
      if ($n.Length -lt 2) { $n = '0' + $n }
      $e.title = "$n $($e.title)"
      $k++
    }
  }
  $obj
}

function __fetch_yt_dlp {
  param([string]$url, $playlist_start, $playlist_end)
  $custom_opts = $args
  ui_load yt-dlp.exe $url `
    --dump-single-json `
    --flat-playlist `
    --playlist-start $playlist_start `
    --playlist-end $playlist_end `
    @custom_opts
}

function __fetch_video_url {
  param([string]$url)
  (ui_load yt-dlp.exe $url --quiet --no-warnings --get-url) | Select-Object -First 1
}

function __fetch_audio_url {
  param([string]$url)
  (ui_load yt-dlp.exe $url --quiet --no-warnings --get-url) | Select-Object -Last 1
}

function __fetch_video_info {
  param([string]$url)
  & yt-dlp.exe --dump-json $url
}

function __fetch_video_info_by_field {
  param([string]$url, [string]$field)
  & yt-dlp.exe --print $field $url
}

function __fetch_video_oembed {
  param([string]$url)
  & curl.exe -s "https://www.youtube.com/oembed?url=$url&format=json"
}

function _fetch_media {
  param([string]$url, $playlist_start, $playlist_end)

  $custom_opts = @()
  if ($CONFIG_BROWSER) { $custom_opts += @('--cookies-from-browser', $CONFIG_BROWSER) }
  if ($CONFIG_YT_DLP_OPTS) { $custom_opts += ($CONFIG_YT_DLP_OPTS -split '\s+' | Where-Object { $_ }) }
  $custom_opts += $args

  __fetch_yt_dlp $url $playlist_start $playlist_end --extractor-args 'youtubetab:approximate_date' @custom_opts
}

function _fetch_playlist {
  param([string]$url)
  $custom_opts = $args

  $obj = __number_entry_titles (($(_fetch_media $url $STATE_CURRENT_PLAYLIST_START $STATE_CURRENT_PLAYLIST_END @custom_opts) -join "`n") | ConvertFrom-Json)
  $script:STATE_CURRENT_PLAYLIST_RESULTS = $obj | ConvertTo-Json -Depth 100 -Compress

  $script:STATE_CURRENT_PLAYLIST_URL = $url
  $script:STATE_CURRENT_PLAYLIST_TITLE = $obj.title
}

function fetch_playlist {
  param([string]$url)
  if (-not ($url -like 'http://*' -or $url -like 'https://*')) { $url = "https://youtube.com/$url" }

  $script:STATE_CURRENT_PLAYLIST_START = 1
  $script:STATE_CURRENT_PLAYLIST_END = [int]$CONFIG_PER_PAGE

  _fetch_playlist $url
  _state_push
}

function fetch_playlist_next {
  $script:STATE_CURRENT_PLAYLIST_START = [int]$STATE_CURRENT_PLAYLIST_END + 1
  $script:STATE_CURRENT_PLAYLIST_END = [int]$STATE_CURRENT_PLAYLIST_END + [int]$CONFIG_PER_PAGE

  _fetch_playlist $STATE_CURRENT_PLAYLIST_URL
  _state_push
}

function fetch_playlist_prev {
  if (([int]$STATE_CURRENT_PLAYLIST_START - 1) -gt 1) { _state_pop }
}

function _fetch_playlists {
  param([string]$url)
  $custom_opts = $args

  $obj = __number_entry_titles (($(_fetch_media $url $STATE_CURRENT_PLAYLISTS_RESULTS_START $STATE_CURRENT_PLAYLISTS_RESULTS_END @custom_opts) -join "`n") | ConvertFrom-Json)
  $script:STATE_CURRENT_PLAYLISTS_RESULTS = $obj | ConvertTo-Json -Depth 100 -Compress

  $script:STATE_CURRENT_PLAYLISTS_RESULTS_URL = $obj.original_url
  $script:STATE_CURRENT_PLAYLISTS_RESULTS_TITLE = $obj.title
}

function fetch_playlists {
  param([string]$url)
  if (-not ($url -like 'http://*' -or $url -like 'https://*')) { $url = "https://youtube.com/$url" }

  $script:STATE_CURRENT_PLAYLISTS_RESULTS_START = 1
  $script:STATE_CURRENT_PLAYLISTS_RESULTS_END = [int]$CONFIG_PER_PAGE

  _fetch_playlists $url
  _state_push
}

function fetch_playlists_next {
  $script:STATE_CURRENT_PLAYLISTS_RESULTS_START = [int]$STATE_CURRENT_PLAYLISTS_RESULTS_END + 1
  $script:STATE_CURRENT_PLAYLISTS_RESULTS_END = [int]$STATE_CURRENT_PLAYLISTS_RESULTS_END + [int]$CONFIG_PER_PAGE

  _fetch_playlists $STATE_CURRENT_PLAYLISTS_RESULTS_URL
  _state_push
}

function fetch_playlists_prev {
  if (([int]$STATE_CURRENT_PLAYLISTS_RESULTS_START - 1) -gt 1) { _state_pop }
}

function _fetch_channels {
  param([string]$url)

  $obj = __number_entry_titles (($(_fetch_media $url $STATE_CURRENT_CHANNEL_RESULTS_START $STATE_CURRENT_CHANNEL_RESULTS_END) -join "`n") | ConvertFrom-Json)
  $script:STATE_CURRENT_CHANNEL_RESULTS = $obj | ConvertTo-Json -Depth 100 -Compress

  $script:STATE_CURRENT_CHANNEL_RESULTS_URL = $obj.original_url
}

function fetch_channels {
  param([string]$url)
  if (-not ($url -like 'http://*' -or $url -like 'https://*')) { $url = "https://youtube.com/$url" }

  $script:STATE_CURRENT_CHANNEL_RESULTS_START = 1
  $script:STATE_CURRENT_CHANNEL_RESULTS_END = [int]$CONFIG_PER_PAGE

  _fetch_channels $url
  _state_push
}

function fetch_channels_next {
  $script:STATE_CURRENT_CHANNEL_RESULTS_START = [int]$STATE_CURRENT_CHANNEL_RESULTS_END + 1
  $script:STATE_CURRENT_CHANNEL_RESULTS_END = [int]$STATE_CURRENT_CHANNEL_RESULTS_END + [int]$CONFIG_PER_PAGE

  _fetch_channels $STATE_CURRENT_CHANNEL_RESULTS_URL
  _state_push
}

function fetch_channels_prev {
  if (([int]$STATE_CURRENT_CHANNEL_RESULTS_START - 1) -gt 1) { _state_pop }
}

function _fetch_yt_subs {
  if (-not $CONFIG_BROWSER) {
    ui_notify_warning $TXT_CONFIG_BROWSER_NOT_SET
    return
  }
  if (ui_confirm $TXT_MENU_MISC_SYNC_SUBS_CONFIRM) {
    ui_notify $TXT_MENU_MISC_SYNC_SUBS_START

    $channels_data = & yt-dlp.exe 'https://www.youtube.com/feed/channels' --flat-playlist --dump-single-json --cookies-from-browser $CONFIG_BROWSER
    if ($channels_data) {
      [IO.File]::WriteAllText($CLI_SUBSCRIPTIONS_FILE, ($channels_data -join "`n"), [Text.UTF8Encoding]::new($false))
    } else {
      ui_notify_error $TXT_MENU_MISC_SYNC_SUBS_FAILED
    }
  }
}

function fetch_yt_subs {
  _fetch_yt_subs
}

# ==============================================================================
# Data parsers
# ==============================================================================
function _parse_search_filter {
  param([string]$filter)
  switch ($filter) {
    'hour'      { 'EgIIAQ%253D%253D' }
    'today'     { 'EgIIAg%253D%253D' }
    'week'      { 'EgIIAw%253D%253D' }
    'month'     { 'EgIIBA%253D%253D' }
    'year'      { 'EgIIBQ%253D%253D' }
    'video'     { 'EgIQAQ%253D%253D' }
    'movie'     { 'EgIQBA%253D%253D' }
    'live'      { 'EgJAAQ%253D%253D' }
    'short'     { 'EgQQARgB' }
    'long'      { 'EgQQARgC' }
    '4k'        { 'EgJwAQ%253D%253D' }
    'hd'        { 'EgIgAQ%253D%253D' }
    'subtitles' { 'EgIoAQ%253D%253D' }
    '360'       { 'EgJ4AQ%253D%253D' }
    'vr'        { 'EgLIAQ%253D%253D' }
    '3d'        { 'EgI4AQ%253D%253D' }
    'hdr'       { 'EgPIAQ%253D%253D' }
    'local'     { 'EgO4AQ%253D%253D' }
    'newest'    { 'CAISAhAB' }
    'views'     { 'CAMSAhAB' }
    'rating'    { 'CAESAhAB' }
  }
}

function parse_search_filter {
  _parse_search_filter @args
}

# ==============================================================================
# Data downloading
# ==============================================================================
function __download_yt_dlp {
  param([string]$url)
  & yt-dlp.exe $url @args
}

function _download_media {
  param([string]$url)

  $custom_opts = @()
  if ($CONFIG_BROWSER) { $custom_opts += @('--cookies-from-browser', $CONFIG_BROWSER) }

  __download_yt_dlp $url @custom_opts @args
}

function _download_video {
  _download_media $STATE_CURRENT_VIDEO_URL `
    --output "$CONFIG_DOWNLOAD_DIR/video/individual/%(channel)s/%(title)s.%(ext)s"
}

function download_video {
  _download_video
}

function _download_audio {
  _download_media $STATE_CURRENT_VIDEO_URL `
    --extract-audio --audio-format mp3 `
    --output "$CONFIG_DOWNLOAD_DIR/audio/individual/%(channel)s/%(title)s.%(ext)s"
}

function download_audio {
  _download_audio
}

function _download_playlist_video {
  $playlist_title = $STATE_CURRENT_PLAYLIST_TITLE | ui_prompt $TXT_ENTER_PLAYLIST_TITLE $STATE_CURRENT_PLAYLIST_TITLE
  if (-not $playlist_title) { return }

  $enumerate_playlist = ''
  if ($CONFIG_DOWNLOADS_ENUMERATE -eq 'true') { $enumerate_playlist = '%(playlist_index)s - ' }

  # TODO: could be more unique by passing in user specified yt-dlp opts
  $download_archive = _util_generate_hash "video - $STATE_CURRENT_PLAYLIST_URL"

  _download_media $STATE_CURRENT_PLAYLIST_URL `
    --output "$CONFIG_DOWNLOAD_DIR/video/$playlist_title/%(channel)s/${enumerate_playlist}%(title)s.%(ext)s" `
    --download-archive "$CLI_DOWNLOAD_ARCHIVE_DIR/$download_archive"
}

function download_playlist_video {
  _download_playlist_video
}

function _download_playlist_audio {
  $playlist_title = $STATE_CURRENT_PLAYLIST_TITLE | ui_prompt $TXT_ENTER_PLAYLIST_TITLE $STATE_CURRENT_PLAYLIST_TITLE
  if (-not $playlist_title) { return }

  $enumerate_playlist = ''
  if ($CONFIG_DOWNLOADS_ENUMERATE -eq 'true') { $enumerate_playlist = '%(playlist_index)s - ' }

  # TODO: could be more unique
  $download_archive = _util_generate_hash "audio - $STATE_CURRENT_PLAYLIST_URL"

  _download_media $STATE_CURRENT_PLAYLIST_URL `
    --extract-audio --audio-format mp3 `
    --output "$CONFIG_DOWNLOAD_DIR/audio/$playlist_title/%(channel)s/${enumerate_playlist}%(title)s.%(ext)s" `
    --download-archive "$CLI_DOWNLOAD_ARCHIVE_DIR/$download_archive"
}

function download_playlist_audio {
  _download_playlist_audio
}

# ==============================================================================
# Data Caching
# ==============================================================================
function __cached_mix_path {
  param([string]$url)

  $video_id = $url -replace '.*RD', ''

  $cached_mix_path = "$CLI_AUTO_GEN_PLAYLISTS/$(_util_generate_hash "https://www.youtube.com/watch?v=$video_id&list=RD$video_id").m3u8"

  if (-not (Test-Path -LiteralPath $cached_mix_path) -or (Get-Item -LiteralPath $cached_mix_path).Length -eq 0) {
    $_mix_data = "$((& yt-dlp.exe "https://www.youtube.com/watch?v=$video_id&list=RD$video_id" --flat-playlist --dump-single-json 2>$null) -join "`n")"
    if (-not $_mix_data) { return $url }

    # NOTE: the extended metadata below is not available in the mix data of yt
    # but other sites may have them. You could easily inject them using jq like:
    # "#EXTALB:\(.album)\n#EXTGENRE:\(.genre)\n#EXTGRP:\(.group)\n"
    $obj = $_mix_data | ConvertFrom-Json
    $L = [System.Collections.Generic.List[string]]::new()
    $L.Add('#EXTM3U')
    foreach ($e in @($obj.entries)) {
      $L.Add("#EXTINF:-1,$($e.title)`n$($e.url)`n")
    }
    [IO.File]::WriteAllText($cached_mix_path, ($L -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
  }

  $cached_mix_path
}

function _cached_mix_path_or_url {
  param([string]$url)

  if ($url -match 'list=RD') {
    __cached_mix_path $url
  } else {
    $url
  }
}

# ==============================================================================
# Data Viewers
# ==============================================================================
function __player_mpv {
  param([string]$input_url, [string]$mode)

  $opts = @($CONFIG_MPV_ARGS -split '\s+' | Where-Object { $_ })
  $ok = $false

  if ($CLI_PLATFORM -eq 'android') {
    $url = if ($mode -eq 'listen') { __fetch_audio_url $input_url } else { __fetch_video_url $input_url }
    Start-Process -FilePath 'am' -ArgumentList @('start', '--user', '0', '-a', 'android.intent.action.VIEW', '-d', $url, '-n', 'is.xyz.mpv/.MPVActivity') | Out-Null
    $ok = $?
  } else {
    $url = $input_url
    if ($mode -eq 'listen') { $opts += @('--no-video', '--force-window=no') }

    if (_dep_ch mpv) { $mpv_cmd = 'mpv' }
    elseif (_dep_ch 'mpv.exe') { $mpv_cmd = 'mpv.exe' }
    else { ui_notify_critical $TXT_PLAYER_NOT_FOUND }

    if ($CONFIG_DISOWN_PLAYER -eq 'true') {
      Start-Process -FilePath $mpv_cmd -ArgumentList (@($url) + $opts) | Out-Null
      $ok = $?
    } else {
      # On Windows the call operator does not block for GUI-subsystem binaries
      # (mpv), so Start-Process -Wait is required to keep the terminal blocked
      # until playback ends (-NoNewWindow shares the console for mpv's output).
      $proc = Start-Process -FilePath $mpv_cmd -ArgumentList (@($url) + $opts) -Wait -NoNewWindow -PassThru
      $ok = ($proc.ExitCode -eq 0)
    }
  }

  if ($ok) { Clear-Host }
}

function __player_vlc {
  param([string]$input_url, [string]$mode)

  $opts = @($CONFIG_VLC_ARGS -split '\s+' | Where-Object { $_ })
  $ok = $false

  if ($CLI_PLATFORM -eq 'android') {
    $url = if ($mode -eq 'listen') { __fetch_audio_url $input_url } else { __fetch_video_url $input_url }
    Start-Process -FilePath 'am' -ArgumentList @('start', '--user', '0', '-a', 'android.intent.action.VIEW', '-d', $url, '-n', 'org.videolan.vlc/org.videolan.vlc.gui.video.VideoPlayerActivity', '-e', 'title', $STATE_CURRENT_VIDEO_TITLE) | Out-Null
    $ok = $?
  } else {
    $url = $input_url

    if (_dep_ch vlc) { $vlc_cmd = 'vlc' }
    elseif (_dep_ch 'vlc.exe') { $vlc_cmd = 'vlc.exe' }
    else { ui_notify_critical $TXT_PLAYER_NOT_FOUND }

    if ($CONFIG_DISOWN_PLAYER -eq 'true') {
      Start-Process -FilePath $vlc_cmd -ArgumentList (@($url) + $opts) | Out-Null
      $ok = $?
    } else {
      $proc = Start-Process -FilePath $vlc_cmd -ArgumentList (@($url) + $opts) -Wait -NoNewWindow -PassThru
      $ok = ($proc.ExitCode -eq 0)
    }
  }

  if ($ok) { Clear-Host }
}

function __player_tplay {
  param([string]$input_url, [string]$mode)

  $opts = @($CONFIG_TPLAY_ARGS -split '\s+' | Where-Object { $_ })
  $ok = $false

  if ($CLI_PLATFORM -eq 'android') {
    $url = if ($mode -eq 'listen') { __fetch_audio_url $input_url } else { __fetch_video_url $input_url }
    Start-Process -FilePath 'am' -ArgumentList @('start', '--user', '0', '-a', 'android.intent.action.VIEW', '-d', $url, '-n', 'is.xyz.mpv/.MPVActivity') | Out-Null
    $ok = $?
  } else {
    $url = $input_url

    if (_dep_ch tplay) { $tplay_cmd = 'tplay' }
    else { ui_notify_critical $TXT_PLAYER_NOT_FOUND }

    # tplay renders inside the terminal, so it shares the console and blocks.
    $proc = Start-Process -FilePath $tplay_cmd -ArgumentList (@($url) + $opts) -Wait -NoNewWindow -PassThru
    $ok = ($proc.ExitCode -eq 0)
  }

  if ($ok) { Clear-Host }
}

function _play {
  param([string]$url, [string]$mode)
  switch ($CONFIG_PLAYER) {
    'mpv'   { __player_mpv $url $mode }
    'vlc'   { __player_vlc $url $mode }
    'tplay' { __player_tplay $url $mode }
    default { ui_notify_critical $TXT_PLAYER_NOT_FOUND }
  }
}

function play {
  _play @args
}

# ==============================================================================
# Data Local
# ==============================================================================
function _update_recent {
  $current_recent = '{"entries":[]}'
  if ((Test-Path -LiteralPath $CLI_RECENT_FILE) -and (Get-Item -LiteralPath $CLI_RECENT_FILE).Length -gt 0) {
    $current_recent = Get-Content -Raw -LiteralPath $CLI_RECENT_FILE
  }

  $video = $STATE_CURRENT_VIDEO | ConvertFrom-Json
  $id = $video.id
  $video.title = "$($video.title)" -replace '^[0-9]+ ', ''

  $data = $current_recent | ConvertFrom-Json
  $entries = @($data.entries | Where-Object { $_.id -ne $id })
  $entries += $video
  $entries = @($entries | Select-Object -Last ([int]$CONFIG_NO_OF_RECENT))

  $out = [pscustomobject]@{ entries = @($entries) }
  [IO.File]::WriteAllText($CLI_RECENT_FILE, ($out | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
}

function _update_saved_videos {
  $current_saved_videos = '{"entries":[]}'
  if ((Test-Path -LiteralPath $CLI_SAVED_VIDEOS_FILE) -and (Get-Item -LiteralPath $CLI_SAVED_VIDEOS_FILE).Length -gt 0) {
    $current_saved_videos = Get-Content -Raw -LiteralPath $CLI_SAVED_VIDEOS_FILE
  }

  $video = $STATE_CURRENT_VIDEO | ConvertFrom-Json
  $id = $video.id
  $video.title = "$($video.title)" -replace '^[0-9]+ ', ''

  $data = $current_saved_videos | ConvertFrom-Json
  $entries = @($data.entries | Where-Object { $_.id -ne $id })
  $entries += $video

  $out = [pscustomobject]@{ entries = @($entries) }
  [IO.File]::WriteAllText($CLI_SAVED_VIDEOS_FILE, ($out | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
}

function _update_saved_playlists {
  $custom_playlists = '[]'
  if ((Test-Path -LiteralPath $CLI_CUSTOM_PLAYLISTS_FILE) -and (Get-Item -LiteralPath $CLI_CUSTOM_PLAYLISTS_FILE).Length -gt 0) {
    $custom_playlists = Get-Content -Raw -LiteralPath $CLI_CUSTOM_PLAYLISTS_FILE
  }

  $playlist_name = $STATE_CURRENT_PLAYLIST_TITLE | ui_prompt $TXT_MENU_MEDIA_ACTIONS_PROMPT_SAVE_PLAYLIST $STATE_CURRENT_PLAYLIST_TITLE
  if (-not $playlist_name) { return }
  $playlist_id = ($STATE_CURRENT_PLAYLIST_RESULTS | ConvertFrom-Json).id

  $arr = @($custom_playlists | ConvertFrom-Json)
  $arr += [pscustomobject]@{ id = $playlist_id; name = $playlist_name; url = $STATE_CURRENT_PLAYLIST_URL }

  [IO.File]::WriteAllText($CLI_CUSTOM_PLAYLISTS_FILE, (ConvertTo-Json -InputObject @($arr) -Depth 100), [Text.UTF8Encoding]::new($false))
}

function _remove_recent {
  $current_recent = '{"entries":[]}'
  if ((Test-Path -LiteralPath $CLI_RECENT_FILE) -and (Get-Item -LiteralPath $CLI_RECENT_FILE).Length -gt 0) {
    $current_recent = Get-Content -Raw -LiteralPath $CLI_RECENT_FILE
  }

  $id = ($STATE_CURRENT_VIDEO | ConvertFrom-Json).id

  $data = $current_recent | ConvertFrom-Json
  $out = [pscustomobject]@{ entries = @($data.entries | Where-Object { $_.id -ne $id }) }
  [IO.File]::WriteAllText($CLI_RECENT_FILE, ($out | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
}

function _remove_saved_video {
  $current_saved_videos = '{"entries":[]}'
  if ((Test-Path -LiteralPath $CLI_SAVED_VIDEOS_FILE) -and (Get-Item -LiteralPath $CLI_SAVED_VIDEOS_FILE).Length -gt 0) {
    $current_saved_videos = Get-Content -Raw -LiteralPath $CLI_SAVED_VIDEOS_FILE
  }

  $id = ($STATE_CURRENT_VIDEO | ConvertFrom-Json).id

  $data = $current_saved_videos | ConvertFrom-Json
  $out = [pscustomobject]@{ entries = @($data.entries | Where-Object { $_.id -ne $id }) }
  [IO.File]::WriteAllText($CLI_SAVED_VIDEOS_FILE, ($out | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
}

function _remove_saved_playlist {
  $custom_playlists = '[]'
  if ((Test-Path -LiteralPath $CLI_CUSTOM_PLAYLISTS_FILE) -and (Get-Item -LiteralPath $CLI_CUSTOM_PLAYLISTS_FILE).Length -gt 0) {
    $custom_playlists = Get-Content -Raw -LiteralPath $CLI_CUSTOM_PLAYLISTS_FILE
  }

  $playlist_id = $STATE_CURRENT_PLAYLIST_URL -replace '.*list=', ''

  # DIVERGENCE: the original runs `jq 'select(.id != $id)'` against the array
  # ROOT, which errors (cannot index array with "id") and — via `>` truncation —
  # empties the whole file (removing one playlist wipes all saved playlists).
  # This ports the apparent INTENT: filter out the element whose id matches.
  $arr = @($custom_playlists | ConvertFrom-Json | Where-Object { $_.id -ne $playlist_id })
  [IO.File]::WriteAllText($CLI_CUSTOM_PLAYLISTS_FILE, (ConvertTo-Json -InputObject @($arr) -Depth 100), [Text.UTF8Encoding]::new($false))
}

function _get_search_history_entry {
  param([int]$n)

  $lines = @(Get-Content -LiteralPath $CLI_SEARCH_HISTORY_FILE)
  $total = $lines.Count
  $n = $total - $n + 1
  if ($n -lt 1) { return }
  $lines[$n - 1]
}

# ==============================================================================
# Menus: playlist actions
# ==============================================================================
function __menu_media_actions_watch {
  Write-Host "${THEME_PLAYER_START}${TXT_PLAYER_START_WATCHING}:${THEME_RESET} $STATE_CURRENT_VIDEO_TITLE"

  play (_cached_mix_path_or_url $STATE_CURRENT_VIDEO_URL) 'watch'
  _update_recent
}

function __menu_media_actions_watch_all {
  Write-Host "${THEME_PLAYER_START}${TXT_PLAYER_START_WATCHING}:${THEME_RESET} $STATE_CURRENT_PLAYLIST_TITLE"

  play (_cached_mix_path_or_url $STATE_CURRENT_PLAYLIST_URL) 'watch'
  _update_recent
}

function __menu_media_actions_listen {
  Write-Host "${THEME_PLAYER_START}${TXT_PLAYER_START_LISTENING}:${THEME_RESET} $STATE_CURRENT_VIDEO_TITLE"

  play (_cached_mix_path_or_url $STATE_CURRENT_VIDEO_URL) 'listen'
  _update_recent
}

function __menu_media_actions_listen_all {
  Write-Host "${THEME_PLAYER_START}${TXT_PLAYER_START_LISTENING}:${THEME_RESET} $STATE_CURRENT_PLAYLIST_TITLE"

  play (_cached_mix_path_or_url $STATE_CURRENT_PLAYLIST_URL) 'listen'
  _update_recent
}

function __menu_media_actions_mix {
  $video_id = ($STATE_CURRENT_VIDEO | ConvertFrom-Json).id
  $url = "watch?v=$video_id&list=RD$video_id"

  fetch_playlist $url
  menu_playlist_explorer
}

function __menu_media_actions_download {
  download_video
  ui_notify "$TXT_DOWNLOAD_COMPLETED $STATE_CURRENT_VIDEO_TITLE"
}

function __menu_media_actions_download_all {
  download_playlist_video
  ui_notify "$TXT_DOWNLOAD_COMPLETED $STATE_CURRENT_PLAYLIST_TITLE"
}

function __menu_media_actions_download_audio {
  download_audio
  ui_notify "$TXT_DOWNLOAD_COMPLETED $STATE_CURRENT_VIDEO_TITLE"
}

function __menu_media_actions_download_all_audio {
  download_playlist_audio
  ui_notify "$TXT_DOWNLOAD_COMPLETED $STATE_CURRENT_PLAYLIST_TITLE"
}

function __menu_media_actions_save {
  # TODO: integerate with watch later maybe
  # though i doubt anyone wants make theirs any longer lol
  # For now a pseudo like feature is just as useful
  _update_saved_videos
}

function __menu_media_actions_unsave {
  _remove_saved_video
}

function __menu_media_actions_save_playlist {
  # TODO: integerate with yt playlists maybe
  # For now a pseudo like feature is just as useful
  _update_saved_playlists
}

function __menu_media_actions_unsave_playlist {
  _remove_saved_playlist
}

function __menu_media_actions_shell {
  # export state + a few CLI vars so the spawned shell can use them
  foreach ($v in $_STATE_VARS) {
    Set-Item -Path "env:$v" -Value ([string](Get-Variable -Name $v -Scope script -ValueOnly -ErrorAction SilentlyContinue))
  }
  $env:CLI_NAME = $CLI_NAME
  $env:CONFIG_DOWNLOAD_DIR = $CONFIG_DOWNLOAD_DIR
  $env:CLI_DOWNLOAD_ARCHIVE_DIR = $CLI_DOWNLOAD_ARCHIVE_DIR

  $init_text = @"
 $CLI_HEADER
 $TXT_MENU_MEDIA_ACTIONS_SHELL_WELCOME
 $TXT_MENU_MEDIA_ACTIONS_SHELL_INTRO
  $TXT_MENU_MEDIA_ACTIONS_SHELL_VARIABLES
  - CLI_ARCHIVE_DIR
  - CONFIG_DOWNLOAD_DIR
  - STATE_CURRENT_CHANNEL_RESULTS
  - STATE_CURRENT_CHANNEL_RESULTS_START
  - STATE_CURRENT_CHANNEL_RESULTS_END
  - STATE_CURRENT_CHANNEL_URL
  - STATE_CURRENT_CHANNEL_TITLE
  - STATE_CURRENT_PLAYLISTS_RESULTS
  - STATE_CURRENT_PLAYLISTS_RESULTS_URL
  - STATE_CURRENT_PLAYLISTS_RESULTS_TITLE
  - STATE_CURRENT_PLAYLISTS_RESULTS_START
  - STATE_CURRENT_PLAYLISTS_RESULTS_END
  - STATE_CURRENT_PLAYLIST_START
  - STATE_CURRENT_PLAYLIST_END
  - STATE_CURRENT_PLAYLIST_RESULTS
  - STATE_CURRENT_PLAYLIST_URL
  - STATE_CURRENT_PLAYLIST_TITLE
  - STATE_CURRENT_VIDEO
  - STATE_CURRENT_VIDEO_URL
  - STATE_CURRENT_VIDEO_TITLE
"@

  # DIVERGENCE: the original detects the parent shell (ps -o comm) and drops into
  # fish or `sh -i` with an init file. On Windows this port drops into an
  # interactive pwsh with the variables exported above, printing the same intro.
  $txt_file = [IO.Path]::GetTempFileName()
  $init_file = "$txt_file.ps1"
  [IO.File]::WriteAllText($txt_file, $init_text, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($init_file, "Get-Content -Raw -LiteralPath '$txt_file' | Write-Host", [Text.UTF8Encoding]::new($false))

  _util_terminal_exec pwsh.exe -NoLogo -NoExit -File $init_file
}

function __menu_media_actions_open_in_browser {
  if (-not (_util_open $STATE_CURRENT_VIDEO_URL)) { ui_notify_error $TXT_MENU_MEDIA_ACTIONS_OPEN_IN_BROWSER_ERROR }
}

function __menu_media_actions_visit_channel {
  $video = $STATE_CURRENT_VIDEO | ConvertFrom-Json

  $channel_url = if ($video.channel_url) { "$($video.channel_url)" } elseif ($video.uploader_url) { "$($video.uploader_url)" } else { '' }
  if ($channel_url -like '//*') { $channel_url = "https:$channel_url" }

  if (-not $channel_url) {
    $channel_id = if ($video.channel_id) { "$($video.channel_id)" } else { '' }
    $uploader_id = if ($video.uploader_id) { "$($video.uploader_id)" } else { '' }

    if ($channel_id) {
      $channel_url = "https://www.youtube.com/channel/$channel_id"
    } elseif ($uploader_id) {
      if ($uploader_id -like '@*') { $channel_url = "https://www.youtube.com/$uploader_id" }
      else { $channel_url = "https://www.youtube.com/channel/$uploader_id" }
    }
  }

  if (-not $channel_url -or $channel_url -eq 'null') {
    if ($STATE_CURRENT_PLAYLIST_RESULTS) {
      $pr = $STATE_CURRENT_PLAYLIST_RESULTS | ConvertFrom-Json
      $channel_url = if ($pr.channel_url) { "$($pr.channel_url)" } elseif ($pr.uploader_url) { "$($pr.uploader_url)" } else { '' }
    }
  }

  if (-not $channel_url -or $channel_url -eq 'null') {
    $oembed = "$(__fetch_video_oembed $STATE_CURRENT_VIDEO_URL)"
    if ($oembed) { try { $channel_url = "$(($oembed | ConvertFrom-Json).author_url)" } catch { $channel_url = '' } }
  }

  if (-not $channel_url -or $channel_url -eq 'null') {
    $channel_url = "$(__fetch_video_info_by_field $STATE_CURRENT_VIDEO_URL 'channel_url')"
  }

  if (-not $channel_url) {
    ui_notify_error $TXT_MENU_MEDIA_ACTIONS_CHANNEL_NOT_FOUND
    return
  }

  $channel_entry = [pscustomobject]@{
    id    = if ($video.channel_id) { "$($video.channel_id)" } elseif ($video.uploader_id) { "$($video.uploader_id)" } else { '' }
    title = if ($video.channel) { "$($video.channel)" } elseif ($video.uploader) { "$($video.uploader)" } else { $channel_url }
    url   = $channel_url
  }

  $script:STATE_CURRENT_CHANNEL_URL = $channel_url
  $script:STATE_CURRENT_CHANNEL_TITLE = $channel_entry.title
  $script:STATE_CURRENT_CHANNEL_RESULTS = [pscustomobject]@{ entries = @($channel_entry) } | ConvertTo-Json -Depth 100 -Compress

  _state_push
  menu_channel_actions
}

function __menu_media_actions_subscribe_to_channel {
  # TODO: use youtube oembed and yt-dlp to enable channel subscriptions
  ui_notify_error $TXT_MENU_MEDIA_ACTIONS_SUBSCRIBE_UNSUPPORTED
}

function __menu_media_actions_toggle_enumerate_downloads {
  if ($CONFIG_DOWNLOADS_ENUMERATE -eq 'true') {
    $script:CONFIG_DOWNLOADS_ENUMERATE = 'false'
  } else {
    $script:CONFIG_DOWNLOADS_ENUMERATE = 'true'
  }
}

function _menu_media_actions {
  param($sort, $menu_options_filter, $extra_menu_options, $extra_menu_options_handler)

  $actions = @"
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_WATCH}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_WATCH}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_WATCH_ALL}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_WATCH_ALL}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_LISTEN}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_LISTEN}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_LISTEN_ALL}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_LISTEN_ALL}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_MIX}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_MIX}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_SAVE}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_SAVE}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_UNSAVE}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_UNSAVE}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_SAVE_PLAYLIST}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_SAVE_PLAYLIST}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_UNSAVE_PLAYLIST}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_UNSAVE_PLAYLIST}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_VISIT_CHANNEL}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_VISIT_CHANNEL}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_SUBSCRIBE}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_SUBSCRIBE}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_DOWNLOAD}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_DOWNLOAD}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_DOWNLOAD_AUDIO}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_AUDIO}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL_AUDIO}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL_AUDIO}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_BROWSER}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_BROWSER}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_TOGGLE_ENUM}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_TOGGLE_ENUM}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_SHELL}${THEME_RESET}  ${TXT_MENU_MEDIA_ACTIONS_SHELL}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MEDIA_ACTIONS_BACK}${THEME_RESET}  ${TXT_MENU_BACK}
 ${THEME_FZF_ICON_COLOR_ERROR}${TXT_ICON_MENU_MEDIA_ACTIONS_EXIT}${THEME_RESET}  ${TXT_MENU_EXIT}
"@

  if ($extra_menu_options -and $extra_menu_options_handler) {
    $actions = "$actions`n$extra_menu_options"
  }

  if ($menu_options_filter) {
    $actions = (($actions -split "`n") | Where-Object { $_ -notmatch $menu_options_filter }) -join "`n"
  }

  if ($sort) {
    $actions = $actions | _util_menu_sort $sort
  }

  :media_loop while ($true) {
    if ($CMD_MEDIA_ACTION) {
      $media_action = $CMD_MEDIA_ACTION
      $script:CMD_MEDIA_ACTION = $null
    } else {
      $media_action = ("$($actions | ui_launcher $TXT_MENU_PLAYLIST_PROMPT_ACTION)") -replace '.*  ', ''
    }

    switch ($media_action) {
      $TXT_MENU_MEDIA_ACTIONS_WATCH { __menu_media_actions_watch }
      $TXT_MENU_MEDIA_ACTIONS_WATCH_ALL { __menu_media_actions_watch_all }
      $TXT_MENU_MEDIA_ACTIONS_LISTEN { __menu_media_actions_listen }
      $TXT_MENU_MEDIA_ACTIONS_LISTEN_ALL { __menu_media_actions_listen_all }
      $TXT_MENU_MEDIA_ACTIONS_MIX { __menu_media_actions_mix }
      $TXT_MENU_MEDIA_ACTIONS_DOWNLOAD { __menu_media_actions_download }
      $TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_AUDIO { __menu_media_actions_download_audio }
      $TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL { __menu_media_actions_download_all }
      $TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL_AUDIO { __menu_media_actions_download_all_audio }
      $TXT_MENU_MEDIA_ACTIONS_SAVE { __menu_media_actions_save }
      $TXT_MENU_MEDIA_ACTIONS_UNSAVE { __menu_media_actions_unsave }
      $TXT_MENU_MEDIA_ACTIONS_SAVE_PLAYLIST { __menu_media_actions_save_playlist }
      $TXT_MENU_MEDIA_ACTIONS_UNSAVE_PLAYLIST { __menu_media_actions_unsave_playlist }
      $TXT_MENU_MEDIA_ACTIONS_VISIT_CHANNEL { __menu_media_actions_visit_channel }
      $TXT_MENU_MEDIA_ACTIONS_SUBSCRIBE { __menu_media_actions_subscribe_to_channel }
      $TXT_MENU_MEDIA_ACTIONS_BROWSER { __menu_media_actions_open_in_browser }
      $TXT_MENU_MEDIA_ACTIONS_TOGGLE_ENUM { __menu_media_actions_toggle_enumerate_downloads }
      $TXT_MENU_MEDIA_ACTIONS_SHELL { __menu_media_actions_shell }
      $TXT_MENU_EXIT { _util_byebye }
      { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } { _state_pop; break media_loop }
      default {
        if ($extra_menu_options -and $extra_menu_options_handler) {
          if (-not (& $extra_menu_options_handler $media_action)) {
            _ui_notify_error "${TXT_MENU_INVALID_ACTION}: $media_action"
          }
        }
      }
    }

    if ("$CMD_MEDIA_EXIT" -eq 'true') {
      _util_byebye
    }
  }
}

function menu_media_actions {
  _menu_media_actions @args
}

# ==============================================================================
# Menus: playlist explorer
# ==============================================================================
function __menu_playlist_explorer_next {
  fetch_playlist_next
}

function __menu_playlist_explorer_previous {
  fetch_playlist_prev
}

function __menu_playlist_explorer {
  param([string]$title)

  $id = $title -replace '^0*([0-9]+) .*', '$1'

  $script:STATE_CURRENT_VIDEO = ($STATE_CURRENT_PLAYLIST_RESULTS | ConvertFrom-Json).entries[[int]$id - 1] | ConvertTo-Json -Depth 100 -Compress
  $script:STATE_CURRENT_VIDEO_URL = ($STATE_CURRENT_VIDEO | ConvertFrom-Json).url
  $script:STATE_CURRENT_VIDEO_TITLE = $title -replace '^[0-9]+ ', ''
  _state_push

  menu_media_actions
}

function _menu_playlist_explorer {
  $base_state = $STATE_CURRENT

  $other_choices = @"
$TXT_MENU_NEXT
$TXT_MENU_PREVIOUS
$TXT_MENU_BACK
$TXT_MENU_EXIT
"@

  :explorer_loop while ($true) {
    $titles = ($STATE_CURRENT_PLAYLIST_RESULTS | ConvertFrom-Json).entries.title

    if ($CMD_PLAYLIST_RESULTS_SKIP -eq 'true') {
      $choice = @($titles)[0]
      $script:CMD_PLAYLIST_RESULTS_SKIP = $null
    } else {
      $choice = "$(@($titles) -join "`n")`n$other_choices" |
        preview $STATE_CURRENT_PLAYLIST_RESULTS |
        ui_launcher_with_preview $TXT_MENU_PLAYLIST_EXPLORER_PROMPT
    }

    switch ($choice) {
      $TXT_MENU_NEXT { __menu_playlist_explorer_next }
      $TXT_MENU_PREVIOUS { __menu_playlist_explorer_previous }
      $TXT_MENU_EXIT { _util_byebye }
      { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } { _state_pop ([int]$STATE_CURRENT - [int]$base_state + 1); break explorer_loop }
      default { __menu_playlist_explorer $choice }
    }
  }
}

function menu_playlist_explorer {
  _menu_playlist_explorer
}

# ==============================================================================
# Menus: playlists explorer
# ==============================================================================
function __menu_playlists_explorer_next {
  fetch_playlists_next
}

function __menu_playlists_explorer_previous {
  fetch_playlists_prev
}

function __menu_playlists_explorer {
  param([string]$title)

  $id = $title -replace '^0*([0-9]+) .*', '$1'

  $current_playlist = ($STATE_CURRENT_PLAYLISTS_RESULTS | ConvertFrom-Json).entries[[int]$id - 1]
  $url = $current_playlist.url

  fetch_playlist $url
  menu_playlist_explorer
}

function _menu_playlists_explorer {
  $base_state = $STATE_CURRENT

  $other_choices = @"
$TXT_MENU_NEXT
$TXT_MENU_PREVIOUS
$TXT_MENU_BACK
$TXT_MENU_EXIT
"@

  :playlists_loop while ($true) {
    $titles = ($STATE_CURRENT_PLAYLISTS_RESULTS | ConvertFrom-Json).entries.title

    $choice = "$(@($titles) -join "`n")`n$other_choices" |
      preview $STATE_CURRENT_PLAYLISTS_RESULTS |
      ui_launcher_with_preview $TXT_MENU_PLAYLISTS_EXPLORER_PROMPT

    switch ($choice) {
      $TXT_MENU_NEXT { __menu_playlists_explorer_next }
      $TXT_MENU_PREVIOUS { __menu_playlists_explorer_previous }
      $TXT_MENU_EXIT { _util_byebye }
      { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } { _state_pop ([int]$STATE_CURRENT - [int]$base_state + 1); break playlists_loop }
      default { __menu_playlists_explorer $choice }
    }
  }
}

function menu_playlists_explorer {
  _menu_playlists_explorer
}

# ==============================================================================
# Menus: channels actions
# ==============================================================================
function __menu_channel_actions_subscribe {
  if (-not ((Test-Path -LiteralPath $CLI_SUBSCRIPTIONS_FILE) -and (Get-Item -LiteralPath $CLI_SUBSCRIPTIONS_FILE).Length -gt 0)) {
    if (ui_confirm $TXT_MENU_CHANNEL_ACTIONS_SUBSCRIBE_CONFIRM) {
      fetch_yt_subs
      $_channels_data = Get-Content -Raw -LiteralPath $CLI_SUBSCRIPTIONS_FILE
    } else {
      $_channels_data = '{"entries":[]}'
    }
  } else {
    $_channels_data = Get-Content -Raw -LiteralPath $CLI_SUBSCRIPTIONS_FILE
  }

  $channel = @(($STATE_CURRENT_CHANNEL_RESULTS | ConvertFrom-Json).entries | Where-Object { $_.title -eq $STATE_CURRENT_CHANNEL_TITLE })[0]
  if ($channel) { $channel.title = "$($channel.title)" -replace '^[0-9]+ ', '' }
  $id = $channel.id

  $data = $_channels_data | ConvertFrom-Json
  $entries = @($data.entries | Where-Object { $_.id -ne $id })
  $entries += $channel

  $out = [pscustomobject]@{ entries = @($entries) }
  [IO.File]::WriteAllText($CLI_SUBSCRIPTIONS_FILE, ($out | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
}

function _menu_channel_actions {
  param($sort, $menu_options_filter, $extra_menu_options, $extra_menu_options_handler)

  $actions = @"
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_CHANNEL_ACTIONS_VIDEOS}${THEME_RESET}  ${TXT_MENU_CHANNEL_ACTIONS_VIDEOS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_CHANNEL_ACTIONS_FEATURED}${THEME_RESET}  ${TXT_MENU_CHANNEL_ACTIONS_FEATURED}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_CHANNEL_ACTIONS_SEARCH}${THEME_RESET}  ${TXT_MENU_CHANNEL_ACTIONS_SEARCH}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_CHANNEL_ACTIONS_PLAYLISTS}${THEME_RESET}  ${TXT_MENU_CHANNEL_ACTIONS_PLAYLISTS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_CHANNEL_ACTIONS_SHORTS}${THEME_RESET}  ${TXT_MENU_CHANNEL_ACTIONS_SHORTS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_CHANNEL_ACTIONS_STREAMS}${THEME_RESET}  ${TXT_MENU_CHANNEL_ACTIONS_STREAMS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_CHANNEL_ACTIONS_PODCASTS}${THEME_RESET}  ${TXT_MENU_CHANNEL_ACTIONS_PODCASTS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_CHANNEL_ACTIONS_SUBSCRIBE}${THEME_RESET}  ${TXT_MENU_CHANNEL_ACTIONS_SUBSCRIBE}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_CHANNEL_ACTIONS_BACK}${THEME_RESET}  ${TXT_MENU_BACK}
 ${THEME_FZF_ICON_COLOR_ERROR}${TXT_ICON_MENU_CHANNEL_ACTIONS_EXIT}${THEME_RESET}  ${TXT_MENU_EXIT}
"@

  if ($extra_menu_options -and $extra_menu_options_handler) {
    $actions = "$actions`n$extra_menu_options"
  }

  if ($menu_options_filter) {
    $actions = (($actions -split "`n") | Where-Object { $_ -notmatch $menu_options_filter }) -join "`n"
  }

  if ($sort) {
    $actions = $actions | _util_menu_sort $sort
  }

  :channel_loop while ($true) {
    if ($CMD_CHANNEL -and $CMD_CHANNEL_ACTION) {
      $action = $CMD_CHANNEL_ACTION
      $script:CMD_CHANNEL = $null
    } else {
      $action = ("$($actions | ui_launcher $TXT_MENU_CHANNEL_ACTIONS_PROMPT)") -replace '.*  ', ''
    }

    switch ($action) {
      $TXT_MENU_CHANNEL_ACTIONS_VIDEOS {
        if ($CMD_CHANNEL_ACTION) { $script:CMD_CHANNEL_ACTION = $null }
        $url = "$STATE_CURRENT_CHANNEL_URL/videos"
        fetch_playlist $url
        menu_playlist_explorer
      }
      $TXT_MENU_CHANNEL_ACTIONS_STREAMS {
        if ($CMD_CHANNEL_ACTION) { $script:CMD_CHANNEL_ACTION = $null }
        $url = "$STATE_CURRENT_CHANNEL_URL/streams"
        fetch_playlist $url
        menu_playlist_explorer
      }
      $TXT_MENU_CHANNEL_ACTIONS_PODCASTS {
        if ($CMD_CHANNEL_ACTION) { $script:CMD_CHANNEL_ACTION = $null }
        $url = "$STATE_CURRENT_CHANNEL_URL/podcasts"
        fetch_playlist $url
        menu_playlist_explorer
      }
      $TXT_MENU_CHANNEL_ACTIONS_SHORTS {
        if ($CMD_CHANNEL_ACTION) { $script:CMD_CHANNEL_ACTION = $null }
        $url = "$STATE_CURRENT_CHANNEL_URL/shorts"
        fetch_playlist $url
        menu_playlist_explorer
      }
      $TXT_MENU_CHANNEL_ACTIONS_FEATURED {
        if ($CMD_CHANNEL_ACTION) { $script:CMD_CHANNEL_ACTION = $null }
        $url = "$STATE_CURRENT_CHANNEL_URL/featured"
        fetch_playlists $url
        menu_playlists_explorer
      }
      $TXT_MENU_CHANNEL_ACTIONS_PLAYLISTS {
        if ($CMD_CHANNEL_ACTION) { $script:CMD_CHANNEL_ACTION = $null }
        $url = "$STATE_CURRENT_CHANNEL_URL/playlists"
        fetch_playlists $url
        menu_playlists_explorer
      }
      $TXT_MENU_CHANNEL_ACTIONS_SEARCH {
        if ($CMD_CHANNEL_ACTION -and $CMD_INPUT) {
          $search_term = [uri]::EscapeDataString("$CMD_INPUT")
          $script:CMD_CHANNEL_ACTION = $null; $script:CMD_INPUT = $null
        } else {
          $search_term = [uri]::EscapeDataString("$(ui_prompt $TXT_MENU_CHANNEL_ACTIONS_SEARCH_PROMPT)")
          if (-not $search_term) { continue channel_loop }
        }
        $url = "$STATE_CURRENT_CHANNEL_URL/search?query=$search_term"
        fetch_playlist $url
        menu_playlist_explorer
      }
      $TXT_MENU_CHANNEL_ACTIONS_SUBSCRIBE { __menu_channel_actions_subscribe }
      $TXT_MENU_EXIT { _util_byebye }
      { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } {
        if ("$CMD_EXIT" -eq 'true') { _util_byebye }
        else { _state_pop; break channel_loop }
      }
      default {
        if ($extra_menu_options -and $extra_menu_options_handler) {
          if (-not (& $extra_menu_options_handler $action)) {
            _ui_notify_error "${TXT_MENU_INVALID_ACTION}: $action"
          }
        }
      }
    }
  }
}

function menu_channel_actions {
  _menu_channel_actions @args
}

# ==============================================================================
# Menus: channels explorer
# ==============================================================================
function __menu_channels_explorer_next {
  fetch_channels_next
}

function __menu_channels_explorer_previous {
  fetch_channels_prev
}

function __menu_channels_explorer {
  param([string]$channel_name)

  $channel = @(($STATE_CURRENT_CHANNEL_RESULTS | ConvertFrom-Json).entries | Where-Object { $_.title -eq $channel_name })[0]

  $script:STATE_CURRENT_CHANNEL_URL = $channel.url
  $script:STATE_CURRENT_CHANNEL_TITLE = $channel.title
  _state_push

  menu_channel_actions
}

function _menu_channels_explorer {
  $base_state = $STATE_CURRENT

  $other_choices = @"
$TXT_MENU_NEXT
$TXT_MENU_PREVIOUS
$TXT_MENU_BACK
$TXT_MENU_EXIT
"@

  :channels_loop while ($true) {
    $channels = ($STATE_CURRENT_CHANNEL_RESULTS | ConvertFrom-Json).entries.title

    $choice = "$(@($channels) -join "`n")`n$other_choices" |
      preview $STATE_CURRENT_CHANNEL_RESULTS |
      ui_launcher_with_preview $TXT_MENU_CHANNELS_EXPLORER_PROMPT

    switch ($choice) {
      $TXT_MENU_NEXT { __menu_channels_explorer_next }
      $TXT_MENU_PREVIOUS { __menu_channels_explorer_previous }
      $TXT_MENU_EXIT { _util_byebye }
      { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } { _state_pop ([int]$STATE_CURRENT - [int]$base_state + 1); break channels_loop }
      default { __menu_channels_explorer $choice }
    }
  }
}

function menu_channels_explorer {
  _menu_channels_explorer
}

# ==============================================================================
# Menus: miscellaneous
# ==============================================================================
function __menu_miscellaneous_explore_channels {
  if ($CMD_INPUT) {
    $search_term = [uri]::EscapeDataString("$CMD_INPUT")
    $script:CMD_MAIN_ACTION = $null; $script:CMD_MISC_ACTION = $null; $script:CMD_INPUT = $null
  } else {
    $search_term = [uri]::EscapeDataString("$(ui_prompt $TXT_MENU_MISC_EXPLORE_CHANNELS_PROMPT)")
    if (-not $search_term) { return }
  }

  $url = "results?search_query=$search_term&sp=EgIQAg%253D%253D"

  fetch_channels $url
  menu_channels_explorer
  if ("$CMD_EXIT" -eq 'true') { _util_byebye }
}

function __menu_miscellaneous_explore_playlists {
  if ($CMD_INPUT) {
    $search_term = [uri]::EscapeDataString("$CMD_INPUT")
    $script:CMD_MAIN_ACTION = $null; $script:CMD_MISC_ACTION = $null; $script:CMD_INPUT = $null
  } else {
    $search_term = [uri]::EscapeDataString("$(ui_prompt $TXT_MENU_MISC_EXPLORE_PLAYLISTS_PROMPT)")
    if (-not $search_term) { return }
  }

  $url = "results?search_query=$search_term&sp=EgIQAw%253D%253D"

  fetch_playlists $url
  menu_playlists_explorer
  if ("$CMD_EXIT" -eq 'true') { _util_byebye }
}

function __menu_miscellaneous_explore_shorts {
  if ($CMD_INPUT) {
    $search_term = [uri]::EscapeDataString("$CMD_INPUT")
    $script:CMD_INPUT = $null
  } else {
    $search_term = [uri]::EscapeDataString("$(ui_prompt $TXT_MENU_MISC_EXPLORE_SHORTS_PROMPT)")
    if (-not $search_term) { return }
  }

  $url = "results?search_query=$search_term&sp=EgIQCQ%253D%253D"

  fetch_playlist $url
  menu_playlist_explorer
  if ("$CMD_EXIT" -eq 'true') { _util_byebye }
}

function __menu_miscellaneous_explore_movies {
  if ($CMD_INPUT) {
    $search_term = [uri]::EscapeDataString("$CMD_INPUT")
    $script:CMD_INPUT = $null
  } else {
    $search_term = [uri]::EscapeDataString("$(ui_prompt $TXT_MENU_MISC_EXPLORE_MOVIES_PROMPT)")
    if (-not $search_term) { return }
  }

  $url = "results?search_query=$search_term&sp=EgIQBA%253D%253D"

  fetch_playlist $url
  menu_playlist_explorer
  if ("$CMD_EXIT" -eq 'true') { _util_byebye }
}

function __menu_miscellaneous_new_custom_command {
  Write-Host $TXT_MENU_MISC_NEW_CUSTOM_CMD_DESC

  $custom_cmd_name = ui_prompt $TXT_MENU_MISC_NEW_CUSTOM_CMD_NAME_PROMPT
  $custom_cmd_url = ui_prompt $TXT_MENU_MISC_NEW_CUSTOM_CMD_URL_PROMPT
  $custom_cmd_yt_dlp_opts = ui_prompt $TXT_MENU_MISC_NEW_CUSTOM_CMD_YT_DLP_OPTS_PROMPT

  if ($custom_cmd_name -and $custom_cmd_url) {
    $custom_cmds = '[]'
    if ((Test-Path -LiteralPath $CLI_CUSTOM_CMDS_FILE) -and (Get-Item -LiteralPath $CLI_CUSTOM_CMDS_FILE).Length -gt 0) {
      $custom_cmds = Get-Content -Raw -LiteralPath $CLI_CUSTOM_CMDS_FILE
    }

    # TODO: maybe switch to a map
    $arr = @($custom_cmds | ConvertFrom-Json)
    $arr += [pscustomobject]@{ name = $custom_cmd_name; url = $custom_cmd_url; 'yt-dlp-opts' = $custom_cmd_yt_dlp_opts }
    [IO.File]::WriteAllText($CLI_CUSTOM_CMDS_FILE, (ConvertTo-Json -InputObject @($arr) -Depth 100), [Text.UTF8Encoding]::new($false))

    $opts = @("$custom_cmd_yt_dlp_opts" -split '\s+' | Where-Object { $_ })
    _fetch_playlist $custom_cmd_url @opts
    $script:STATE_CURRENT_PLAYLIST_START = 1
    $script:STATE_CURRENT_PLAYLIST_END = [int]$CONFIG_PER_PAGE
    _state_push

    menu_playlist_explorer
  }
}

function __menu_miscellaneous_custom_commands {
  if ((Test-Path -LiteralPath $CLI_CUSTOM_CMDS_FILE) -and (Get-Item -LiteralPath $CLI_CUSTOM_CMDS_FILE).Length -gt 0) {
    :custom_loop while ($true) {
      if ($CMD_INPUT) {
        $custom_cmd_name = $CMD_INPUT
        $script:CMD_INPUT = $null
      } else {
        $names = (Get-Content -Raw -LiteralPath $CLI_CUSTOM_CMDS_FILE | ConvertFrom-Json).name
        $custom_cmd_name = "$(@($names) -join "`n")`n$TXT_MENU_BACK" | ui_launcher $TXT_MENU_MISC_CUSTOM_CMDS_PROMPT
      }

      switch ($custom_cmd_name) {
        { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } {
          if ("$CMD_EXIT" -eq 'true') { _util_byebye } else { break custom_loop }
        }
        default {
          $custom_cmd = @((Get-Content -Raw -LiteralPath $CLI_CUSTOM_CMDS_FILE | ConvertFrom-Json) | Where-Object { $_.name -eq $custom_cmd_name })[0]
          $url = $custom_cmd.url
          $yt_dlp_opts = $custom_cmd.'yt-dlp-opts'

          $opts = @("$yt_dlp_opts" -split '\s+' | Where-Object { $_ })
          _fetch_playlist $url @opts
          $script:STATE_CURRENT_PLAYLIST_START = 1
          $script:STATE_CURRENT_PLAYLIST_END = [int]$CONFIG_PER_PAGE
          _state_push

          menu_playlist_explorer
        }
      }
    }
  } else {
    ui_notify_warning $TXT_CUSTOM_CMDS_FILE_NOT_FOUND
  }
}

function __menu_miscellaneous_search_history {
  if ((Test-Path -LiteralPath $CLI_SEARCH_HISTORY_FILE) -and (Get-Item -LiteralPath $CLI_SEARCH_HISTORY_FILE).Length -gt 0) {
    :history_loop while ($true) {
      $hist = @(Get-Content -LiteralPath $CLI_SEARCH_HISTORY_FILE)
      [array]::Reverse($hist)

      $search_term = [uri]::EscapeDataString("$("$(@($hist) -join "`n")`n$TXT_MENU_BACK" | ui_launcher $TXT_MENU_MISC_SEARCH_HISTORY_PROMPT)")

      switch ($search_term) {
        { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } {
          if ("$CMD_EXIT" -eq 'true') { _util_byebye } else { break history_loop }
        }
        default {
          $url = "results?search_query=$search_term&sp=EgIQAQ%253D%253D"
          fetch_playlist $url
          menu_playlist_explorer
        }
      }
    }
  } else {
    ui_notify_warning $TXT_SEARCH_HISTORY_FILE_NOT_FOUND
  }
}

function __menu_miscellaneous_sync_youtube_subscriptions {
  fetch_yt_subs
}

function __menu_miscellaneous_clear_search_history {
  if (ui_confirm $TXT_MENU_MISC_CLEAR_SEARCH_HISTORY_PROMPT) {
    Remove-Item -LiteralPath $CLI_SEARCH_HISTORY_FILE
  }
}

function __menu_miscellaneous_edit_search_history {
  _util_file_edit $CLI_SEARCH_HISTORY_FILE
}

function __menu_miscellaneous_edit_custom_playlists {
  _util_file_edit $CLI_CUSTOM_PLAYLISTS_FILE
}

function __menu_miscellaneous_edit_custom_commands {
  _util_file_edit $CLI_CUSTOM_CMDS_FILE
}

function __menu_miscellaneous_edit_mpv_config {
  _util_file_edit "$XDG_CONFIG_HOME/mpv/mpv.conf"
}

function __menu_miscellaneous_edit_yt_dlp_config {
  _util_file_edit "$XDG_CONFIG_HOME/yt-dlp/config"
}

function _menu_miscellaneous {
  param($sort, $menu_options_filter, $extra_menu_options, $extra_menu_options_handler)

  $actions = @"
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_EXPLORE_CHANNELS}${THEME_RESET}  ${TXT_MENU_MISC_EXPLORE_CHANNELS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_EXPLORE_PLAYLISTS}${THEME_RESET}  ${TXT_MENU_MISC_EXPLORE_PLAYLISTS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_EXPLORE_SHORTS}${THEME_RESET}  ${TXT_MENU_MISC_EXPLORE_SHORTS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_EXPLORE_MOVIES}${THEME_RESET}  ${TXT_MENU_MISC_EXPLORE_MOVIES}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_SEARCH_HISTORY}${THEME_RESET}  ${TXT_MENU_MISC_SEARCH_HISTORY}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_NEW_CUSTOM_CMD}${THEME_RESET}  ${TXT_MENU_MISC_NEW_CUSTOM_CMD}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_CUSTOM_CMDS}${THEME_RESET}  ${TXT_MENU_MISC_CUSTOM_CMDS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_EDIT_SEARCH_HISTORY}${THEME_RESET}  ${TXT_MENU_MISC_EDIT_SEARCH_HISTORY}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_EDIT_CUSTOM_PLAYLISTS}${THEME_RESET}  ${TXT_MENU_MISC_EDIT_CUSTOM_PLAYLISTS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_EDIT_MPV_CONFIG}${THEME_RESET}  ${TXT_MENU_MISC_EDIT_MPV_CONFIG}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_EDIT_YTDLP_CONFIG}${THEME_RESET}  ${TXT_MENU_MISC_EDIT_YTDLP_CONFIG}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_EDIT_CUSTOM_CMDS}${THEME_RESET}  ${TXT_MENU_MISC_EDIT_CUSTOM_CMDS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_SYNC_SUBS}${THEME_RESET}  ${TXT_MENU_MISC_SYNC_SUBS}
 ${THEME_FZF_ICON_COLOR_ERROR}${TXT_ICON_MENU_MISC_CLEAR_SEARCH_HISTORY}${THEME_RESET}  ${TXT_MENU_MISC_CLEAR_SEARCH_HISTORY}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MISC_BACK}${THEME_RESET}  ${TXT_MENU_BACK}
 ${THEME_FZF_ICON_COLOR_ERROR}${TXT_ICON_MENU_MISC_EXIT}${THEME_RESET}  ${TXT_MENU_EXIT}
"@

  if ($extra_menu_options -and $extra_menu_options_handler) {
    $actions = "$actions`n$extra_menu_options"
  }

  if ($menu_options_filter) {
    $actions = (($actions -split "`n") | Where-Object { $_ -notmatch $menu_options_filter }) -join "`n"
  }

  if ($sort) {
    $actions = $actions | _util_menu_sort $sort
  }

  :misc_loop while ($true) {
    if ($CMD_MISC_ACTION) {
      $action = $CMD_MISC_ACTION
      $script:CMD_MISC_ACTION = $null
    } else {
      $action = ("$($actions | ui_launcher $TXT_MENU_MISC_PROMPT)") -replace '.*  ', ''
    }

    switch ($action) {
      $TXT_MENU_MISC_EXPLORE_CHANNELS { __menu_miscellaneous_explore_channels }
      $TXT_MENU_MISC_EXPLORE_PLAYLISTS { __menu_miscellaneous_explore_playlists }
      $TXT_MENU_MISC_EXPLORE_SHORTS { __menu_miscellaneous_explore_shorts }
      $TXT_MENU_MISC_EXPLORE_MOVIES { __menu_miscellaneous_explore_movies }
      $TXT_MENU_MISC_SEARCH_HISTORY { __menu_miscellaneous_search_history }
      $TXT_MENU_MISC_NEW_CUSTOM_CMD { __menu_miscellaneous_new_custom_command }
      $TXT_MENU_MISC_CUSTOM_CMDS { __menu_miscellaneous_custom_commands }
      $TXT_MENU_MISC_EDIT_SEARCH_HISTORY { __menu_miscellaneous_edit_search_history }
      $TXT_MENU_MISC_EDIT_CUSTOM_PLAYLISTS { __menu_miscellaneous_edit_custom_playlists }
      $TXT_MENU_MISC_EDIT_MPV_CONFIG { __menu_miscellaneous_edit_mpv_config }
      $TXT_MENU_MISC_EDIT_YTDLP_CONFIG { __menu_miscellaneous_edit_yt_dlp_config }
      $TXT_MENU_MISC_EDIT_CUSTOM_CMDS { __menu_miscellaneous_edit_custom_commands }
      $TXT_MENU_MISC_SYNC_SUBS { __menu_miscellaneous_sync_youtube_subscriptions }
      $TXT_MENU_MISC_CLEAR_SEARCH_HISTORY { __menu_miscellaneous_clear_search_history }
      $TXT_MENU_EXIT { _util_byebye }
      { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } { break misc_loop }
      default {
        if ($extra_menu_options -and $extra_menu_options_handler) {
          if (-not (& $extra_menu_options_handler $action)) {
            _ui_notify_error "${TXT_MENU_INVALID_ACTION}: $action"
          }
        }
      }
    }
  }
}

function menu_miscellaneous {
  _menu_miscellaneous @args
}

# ==============================================================================
# Menus: main
# ==============================================================================
function __menu_main_feed {
  $url = ''

  fetch_playlist $url
  menu_playlist_explorer
}

function __menu_main_subscriptions_feed {
  $url = 'feed/subscriptions'

  fetch_playlist $url
  menu_playlist_explorer
}

function _search_expand_history_recall {
  param([string]$term)

  if ($term -match '^![^0-9]' -or $term -eq '!') {
    $term
  } elseif ($term -like '!*') {
    $n = $term -replace '^!', ''
    $n = $n -replace '[^0-9].*$', ''
    $rest = $term -replace "^!$n", ''
    $rest = $rest -replace '^ ', ''
    $recalled = ''
    try { $recalled = _get_search_history_entry ([int]$n) } catch { $recalled = '' }
    if ($recalled) {
      $term = "$recalled $rest"
      $term = $term -replace '^[ \t]+', '' -replace '[ \t]+$', ''
    }
    $term
  } else {
    $term
  }
}

function _search_apply_filters {
  param([string]$term)

  $sp = 'EgIQAQ%253D%253D'
  $orig = $term
  $filter_applied = 0

  if ($term -like ':*') {
    $colon_part = $term -replace '[ \t].*$', ''
    $cand = $colon_part -replace '^:', ''
    $maybe_sp = _parse_search_filter $cand
    if ($maybe_sp) {
      $sp = $maybe_sp
      if ($colon_part -eq $term) { $term = '' }
      else { $term = $term -replace '^[^ \t]+[ \t]*', '' }
      $filter_applied = 1
    }
  }

  if ($filter_applied -eq 0) {
    if ($term -match '[ \t]+:([^ \t]+)$') {
      $suffix = $Matches[1]
      $maybe_sp = _parse_search_filter $suffix
      if ($maybe_sp) {
        $sp = $maybe_sp
        $term = $term -replace '[ \t]+:[^ \t]+$', ''
        $filter_applied = 1
      }
    }
  }

  if ($filter_applied -eq 1 -and -not $term) {
    $term = $orig
    $sp = 'EgIQAQ%253D%253D'
  }

  $term
  $sp
}

function __menu_main_search {
  $use_history = 0
  $header = ''

  if ($CMD_INPUT) {
    $raw_search_term = "$CMD_INPUT" -replace '^[ \t]+', '' -replace '[ \t]+$', ''
    $script:CMD_INPUT = $null
  } else {
    if ($CONFIG_ENABLE_SEARCH_HISTORY -eq 'true' -and (Test-Path -LiteralPath $CLI_SEARCH_HISTORY_FILE) -and (Get-Item -LiteralPath $CLI_SEARCH_HISTORY_FILE).Length -gt 0) {
      $hist_list = @(Get-Content -LiteralPath $CLI_SEARCH_HISTORY_FILE | Select-Object -Last 10)
      [array]::Reverse($hist_list)
      $recent = @($hist_list | Select-Object -First 5)
      $header = "$TXT_MENU_MAIN_RECENT_SEARCHES`n$(@($recent) -join "`n")`n`n"
      $choice = "$TXT_MENU_MAIN_NEW_SEARCH`n$(@($hist_list) -join "`n")" | ui_launcher $TXT_MENU_MAIN_SEARCH_OR_HISTORY_PROMPT
      if (-not $choice) {
        return
      } elseif ($choice -ne $TXT_MENU_MAIN_NEW_SEARCH) {
        $raw_search_term = $choice
        $use_history = 1
      }
    }

    $header = "$header$TXT_SEARCH_FILTER_HELP"

    if ($use_history -eq 0) {
      $raw_search_term = "$(ui_prompt $TXT_MENU_MAIN_SEARCH_PROMPT $header)" -replace '^[ \t]+', '' -replace '[ \t]+$', ''
      if (-not $raw_search_term) { return }
    }
  }

  $raw_search_term = _search_expand_history_recall $raw_search_term

  $history_search_term = $raw_search_term

  $filter_output = _search_apply_filters $raw_search_term
  $sp = $filter_output[-1]
  $raw_search_term = $filter_output[0]

  if ($CONFIG_ENABLE_SEARCH_HISTORY -eq 'true') {
    if (Test-Path -LiteralPath $CLI_SEARCH_HISTORY_FILE -PathType Leaf) {
      $kept = @(Get-Content -LiteralPath $CLI_SEARCH_HISTORY_FILE | Where-Object { $_ -ne $history_search_term } | Select-Object -Last 99)
      $content = if ($kept.Count -gt 0) { ($kept -join "`n") + "`n" } else { '' }
      [IO.File]::WriteAllText($CLI_SEARCH_HISTORY_FILE, $content, [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::AppendAllText($CLI_SEARCH_HISTORY_FILE, "$history_search_term`n", [Text.UTF8Encoding]::new($false))
  }

  $encoded_search_term = [uri]::EscapeDataString($raw_search_term)
  $url = "results?search_query=$encoded_search_term&sp=$sp"

  fetch_playlist $url
  menu_playlist_explorer
}

function __menu_main_watch_later {
  $url = 'playlist?list=WL'

  fetch_playlist $url
  menu_playlist_explorer
}

function __menu_main_playlists {
  $url = 'feed/playlists'

  fetch_playlists $url
  menu_playlists_explorer
}

function __menu_main_liked_videos {
  $url = 'playlist?list=LL'

  fetch_playlist $url
  menu_playlist_explorer
}

function __menu_main_watch_history {
  $url = 'feed/history'

  fetch_playlist $url
  menu_playlist_explorer
}

function __menu_main_clips {
  $url = 'feed/clips'

  fetch_playlist $url
  menu_playlist_explorer
}

# NOTE: youtube currently no longer has a trending page
# but other sites may have one so...
function __menu_main_trending {
  $url = 'trending'

  fetch_playlist $url
  menu_playlist_explorer
}

function __menu_main_channels_explorer {
  if ((Test-Path -LiteralPath $CLI_SUBSCRIPTIONS_FILE) -and (Get-Item -LiteralPath $CLI_SUBSCRIPTIONS_FILE).Length -gt 0) {
    $channels = Get-Content -Raw -LiteralPath $CLI_SUBSCRIPTIONS_FILE
    :main_channels_loop while ($true) {
      if ($CMD_CHANNEL) {
        $channel = $CMD_CHANNEL
        if (-not $CMD_CHANNEL_ACTION) { $script:CMD_CHANNEL = $null }
      } else {
        $titles = ($channels | ConvertFrom-Json).entries.title
        $channel = "$(@($titles) -join "`n")`n$TXT_MENU_BACK" |
          preview $channels |
          ui_launcher_with_preview $TXT_MENU_MAIN_CHANNELS_PROMPT
      }

      switch ($channel) {
        { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } { break main_channels_loop }
        default {
          $url = (@(($channels | ConvertFrom-Json).entries | Where-Object { $_.title -eq $channel })[0]).url

          $script:STATE_CURRENT_CHANNEL_URL = $url
          $script:STATE_CURRENT_CHANNEL_TITLE = $channel

          _state_push
          menu_channel_actions
        }
      }
    }
  } else {
    ui_notify_warning $TXT_SUBS_FILE_NOT_FOUND
  }
}

function __menu_main_custom_playlists {
  if ((Test-Path -LiteralPath $CLI_CUSTOM_PLAYLISTS_FILE) -and (Get-Item -LiteralPath $CLI_CUSTOM_PLAYLISTS_FILE).Length -gt 0) {
    :custom_pl_loop while ($true) {
      if ($CMD_INPUT) {
        $playlist_title = $CMD_INPUT
        $script:CMD_INPUT = $null
      } else {
        $arr = @(Get-Content -Raw -LiteralPath $CLI_CUSTOM_PLAYLISTS_FILE | ConvertFrom-Json)
        $names = @($arr); [array]::Reverse($names)
        $playlist_title = "$(@($names.name) -join "`n")`n$TXT_MENU_BACK" | ui_launcher $TXT_MENU_MAIN_CUSTOM_PLAYLISTS_PROMPT
      }

      switch ($playlist_title) {
        { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } { break custom_pl_loop }
        default {
          $url = (@(Get-Content -Raw -LiteralPath $CLI_CUSTOM_PLAYLISTS_FILE | ConvertFrom-Json | Where-Object { $_.name -eq $playlist_title })[0]).url

          _fetch_playlist $url
          $script:STATE_CURRENT_PLAYLIST_START = 1
          $script:STATE_CURRENT_PLAYLIST_END = [int]$CONFIG_PER_PAGE
          _state_push

          menu_playlist_explorer
        }
      }

      if ("$CMD_EXIT" -eq 'true') {
        _util_byebye
      }
    }
  } else {
    ui_notify_warning $TXT_CUSTOM_PLAYLISTS_FILE_NOT_FOUND
  }
}

function __menu_main_saved_videos {
  if ((Test-Path -LiteralPath $CLI_SAVED_VIDEOS_FILE) -and (Get-Item -LiteralPath $CLI_SAVED_VIDEOS_FILE).Length -gt 0) {
    if ($CMD_INPUT) {
      $saved_videos = Get-Content -Raw -LiteralPath $CLI_SAVED_VIDEOS_FILE
    } else {
      $obj = Get-Content -Raw -LiteralPath $CLI_SAVED_VIDEOS_FILE | ConvertFrom-Json
      $rev = @($obj.entries); [array]::Reverse($rev); $obj.entries = $rev
      $saved_videos = __number_entry_titles $obj | ConvertTo-Json -Depth 100 -Compress
    }

    :saved_loop while ($true) {
      if ($CMD_INPUT) {
        $selection = $CMD_INPUT
        $script:CMD_INPUT = $null
      } else {
        $titles = ($saved_videos | ConvertFrom-Json).entries.title
        $selection = "$(@($titles) -join "`n")`n$TXT_MENU_BACK" |
          preview $saved_videos |
          ui_launcher_with_preview $TXT_MENU_MAIN_SAVED_PROMPT
      }

      switch ($selection) {
        { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } { break saved_loop }
        default {
          $video = @(($saved_videos | ConvertFrom-Json).entries | Where-Object { $_.title -eq $selection })[0]

          $script:STATE_CURRENT_VIDEO = $video | ConvertTo-Json -Depth 100 -Compress
          $script:STATE_CURRENT_VIDEO_URL = $video.url
          $script:STATE_CURRENT_VIDEO_TITLE = $selection -replace '^[0-9]+ ', ''

          _state_push
          menu_media_actions
        }
      }
    }
    if ($CMD_EXIT) {
      _util_byebye
    }
  } else {
    ui_notify_warning $TXT_SAVED_VIDEOS_FILE_NOT_FOUND
  }
}

function __menu_main_recent {
  if ((Test-Path -LiteralPath $CLI_RECENT_FILE) -and (Get-Item -LiteralPath $CLI_RECENT_FILE).Length -gt 0) {
    $obj = Get-Content -Raw -LiteralPath $CLI_RECENT_FILE | ConvertFrom-Json
    $rev = @($obj.entries); [array]::Reverse($rev); $obj.entries = $rev
    $saved_videos = __number_entry_titles $obj | ConvertTo-Json -Depth 100 -Compress

    :recent_loop while ($true) {
      $titles = ($saved_videos | ConvertFrom-Json).entries.title
      $selection = "$(@($titles) -join "`n")`n$TXT_MENU_BACK" |
        preview $saved_videos |
        ui_launcher_with_preview $TXT_MENU_MAIN_SAVED_PROMPT

      switch ($selection) {
        { $_ -eq $TXT_MENU_BACK -or $_ -eq '' } { break recent_loop }
        default {
          $video = @(($saved_videos | ConvertFrom-Json).entries | Where-Object { $_.title -eq $selection })[0]

          $script:STATE_CURRENT_VIDEO = $video | ConvertTo-Json -Depth 100 -Compress
          $script:STATE_CURRENT_VIDEO_URL = $video.url
          $script:STATE_CURRENT_VIDEO_TITLE = $selection -replace '^[0-9]+ ', ''

          _state_push
          menu_media_actions
        }
      }
    }
  } else {
    ui_notify_warning $TXT_RECENT_FILE_NOT_FOUND
  }
}

function __menu_main_edit_config {
  _util_file_edit $CLI_CONFIG_FILE
  _load_config
}

function _menu_main {
  param($sort, $menu_options_filter, $extra_menu_options, $extra_menu_options_handler)

  $actions = @"
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_FEED}${THEME_RESET}  ${TXT_MENU_MAIN_FEED}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_SEARCH}${THEME_RESET}  ${TXT_MENU_MAIN_SEARCH}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_SUBS_FEED}${THEME_RESET}  ${TXT_MENU_MAIN_SUBS_FEED}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_WATCH_LATER}${THEME_RESET}  ${TXT_MENU_MAIN_WATCH_LATER}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_PLAYLISTS}${THEME_RESET}  ${TXT_MENU_MAIN_PLAYLISTS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_CHANNELS}${THEME_RESET}  ${TXT_MENU_MAIN_CHANNELS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_CUSTOM_PLAYLISTS}${THEME_RESET}  ${TXT_MENU_MAIN_CUSTOM_PLAYLISTS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_SAVED}${THEME_RESET}  ${TXT_MENU_MAIN_SAVED}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_RECENT}${THEME_RESET}  ${TXT_MENU_MAIN_RECENT}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_LIKED}${THEME_RESET}  ${TXT_MENU_MAIN_LIKED}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_HISTORY}${THEME_RESET}  ${TXT_MENU_MAIN_HISTORY}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_CLIPS}${THEME_RESET}  ${TXT_MENU_MAIN_CLIPS}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_MISC}${THEME_RESET}  ${TXT_MENU_MAIN_MISC}
 ${THEME_FZF_ICON_COLOR_PRIMARY}${TXT_ICON_MENU_MAIN_EDIT_CONFIG}${THEME_RESET}  ${TXT_MENU_MAIN_EDIT_CONFIG}
 ${THEME_FZF_ICON_COLOR_ERROR}${TXT_ICON_MENU_MAIN_EXIT}${THEME_RESET}  ${TXT_MENU_EXIT}
"@

  if ($extra_menu_options -and $extra_menu_options_handler) {
    $actions = "$actions`n$extra_menu_options"
  }

  if ($menu_options_filter) {
    $actions = (($actions -split "`n") | Where-Object { $_ -notmatch $menu_options_filter }) -join "`n"
  }

  if ($sort) {
    $actions = $actions | _util_menu_sort $sort
  }

  :main_loop while ($true) {
    if ($CMD_MAIN_ACTION) {
      $action = $CMD_MAIN_ACTION
      $script:CMD_MAIN_ACTION = $null
    } else {
      $action = ("$($actions | ui_launcher $TXT_MENU_MAIN_PROMPT_ACTION)") -replace '.*  ', ''
    }

    switch ($action) {
      $TXT_MENU_MAIN_FEED { __menu_main_feed }
      $TXT_MENU_MAIN_SEARCH { __menu_main_search }
      $TXT_MENU_MAIN_SUBS_FEED { __menu_main_subscriptions_feed }
      $TXT_MENU_MAIN_WATCH_LATER { __menu_main_watch_later }
      $TXT_MENU_MAIN_PLAYLISTS { __menu_main_playlists }
      $TXT_MENU_MAIN_CHANNELS { __menu_main_channels_explorer }
      $TXT_MENU_MAIN_CUSTOM_PLAYLISTS { __menu_main_custom_playlists }
      $TXT_MENU_MAIN_SAVED { __menu_main_saved_videos }
      $TXT_MENU_MAIN_RECENT { __menu_main_recent }
      $TXT_MENU_MAIN_LIKED { __menu_main_liked_videos }
      $TXT_MENU_MAIN_HISTORY { __menu_main_watch_history }
      $TXT_MENU_MAIN_CLIPS { __menu_main_clips }
      $TXT_MENU_MAIN_MISC { menu_miscellaneous }
      $TXT_MENU_MAIN_EDIT_CONFIG { __menu_main_edit_config }
      { $_ -eq $TXT_MENU_EXIT -or $_ -eq '' } { _util_byebye }
      default {
        if ($extra_menu_options -and $extra_menu_options_handler) {
          if (-not (& $extra_menu_options_handler $action)) {
            _ui_notify_error "${TXT_MENU_INVALID_ACTION}: $action"
          }
        }
      }
    }
  }
}

function menu_main {
  _state_init
  _menu_main
}

# ==============================================================================
# APP: utils
# ==============================================================================
function _app_update_script {
  param([string]$update)

  # DIVERGENCE: self-update fetches the UPSTREAM BASH yt-x and overwrites
  # CLI_PATH (here yt-x.ps1) — it would replace this port with the bash script.
  # The port is meant to be updated by MANUALLY porting upstream changes; this is
  # kept for structural parity only. Unix sudo/exec are adapted to pwsh.
  $writable = $false
  try { $fs = [IO.File]::Open($CLI_PATH, 'Open', 'Write'); $fs.Close(); $writable = $true } catch { $writable = $false }
  if (-not $writable) {
    if (-not (ui_confirm $TXT_UPDATE_ROOT_WARNING)) { exit 1 }
    ui_notify_critical $TXT_UPDATE_SUDO_MISSING
  }

  if (-not $update) { ui_notify_critical $TXT_UPDATE_FETCH_FAILED }

  try {
    [IO.File]::WriteAllText($CLI_PATH, "$update`n", [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $CLI_FZF_PREVIEW_SCRIPT -ErrorAction SilentlyContinue
    if (ui_confirm $TXT_UPDATE_SCRIPT_REEXECUTE) {
      $reArgs = @("$CLI_ARGS" -split '\s+' | Where-Object { $_ })
      & pwsh.exe -NoProfile -File $CLI_PATH @reArgs
      exit $LASTEXITCODE
    } else {
      exit 0
    }
  } catch {
    ui_notify_critical $TXT_UPDATE_FAILED
  }
}

function _app_update_check {
  $latest_version = "$(& curl.exe -s $CLI_VERSION_URL)"
  if (-not $latest_version) { return $false }

  if ($latest_version -ne $CLI_VERSION) {
    $update = "$(& curl.exe -sL "$CLI_RELEASES_BASE/v$latest_version/$CLI_NAME")"
    if (-not $update) { return $false }

    if (_dep_ch diff) {
      $update_diff = "$update" | & diff -u $CLI_PATH -
      if (ui_confirm $TXT_UPDATE_FOUND) { $update_diff | ui_pager }
    } else {
      _ui_notify_warning $TXT_DEP_MISSING_DIFF
    }

    if (ui_confirm $TXT_UPDATE_CONFIRM) { _app_update_script $update }
  } else {
    return $false
  }
}

function _app_auto_update {
  if ($CONFIG_CHECK_FOR_UPDATES -eq 'true') {
    $timestamp_file = "$CLI_CACHE_DIR/.last_update_check"

    $interval = 12 * 60 * 60

    $last_check_time = 0
    if (Test-Path -LiteralPath $timestamp_file) {
      $last_check_time = [int]("$(Get-Content -Raw -LiteralPath $timestamp_file)".Trim())
    }

    if (([int]$CLI_START_TIME - $last_check_time) -ge $interval) {
      _app_cache_clean_up

      _app_update_check | Out-Null
      [IO.File]::WriteAllText($timestamp_file, "$CLI_START_TIME", [Text.UTF8Encoding]::new($false))
    }
  }
}

function _app_edit_config {
  _util_file_edit $CLI_CONFIG_FILE
  _util_byebye
}

function _app_generate_desktop_entry {
  if (ui_confirm $TXT_DESKTOP_ENTRY_PROMPT $TXT_LAUNCHER_LABEL_ROFI $TXT_LAUNCHER_LABEL_ROFI $TXT_LAUNCHER_LABEL_FZF) {
    $entry = @"
[Desktop Entry]
Name=$CLI_NAME
Type=Application
Version=$CLI_VERSION
Path=$HOME
Comment=$TXT_DESKTOP_ENTRY_COMMENT
Terminal=false
Exec=$CLI_PATH --launcher rofi --no-disown-player
Categories=Entertainment
"@
  } else {
    $entry = @"
[Desktop Entry]
Name=$CLI_NAME
Type=Application
Version=$CLI_VERSION
Path=$HOME
Comment=$TXT_DESKTOP_ENTRY_COMMENT
Terminal=true
Exec=$CLI_PATH --launcher fzf
Categories=Entertainment
"@
  }

  Write-Output $entry
  exit 0
}

function _app_core_dep_ch {
  # DIVERGENCE: the original also requires `jq`; this port replaced jq with
  # PowerShell's ConvertFrom-Json/ConvertTo-Json, so jq is not a dependency.
  if (-not (_dep_ch 'yt-dlp')) { ui_notify_critical $TXT_DEP_MISSING_YTDLP }
  if (-not (_dep_ch 'fzf')) { ui_notify_critical $TXT_DEP_MISSING_FZF }
}

function _app_cache_clean_up {
  $retention_days = if ($CONFIG_CACHE_RETENTION_DAYS) { [int]$CONFIG_CACHE_RETENTION_DAYS } else { 3 }
  $cutoff = (Get-Date).AddDays(-$retention_days)

  foreach ($dir in @($CLI_PREVIEW_DIR, $CLI_AUTO_GEN_PLAYLISTS, $CLI_LOG_DIR)) {
    if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
      Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    }
  }
}

function _app_runtime_clean_up {
  Remove-Item -Recurse -Force -LiteralPath $CLI_CURRENT_STATE_DIR -ErrorAction SilentlyContinue
  # NOTE: bash also kills `jobs -p`; the port's background workers are detached,
  # independent pwsh processes (see __run_disowned), so there are no tracked jobs.
}

# ==============================================================================
# APP: usage
# ==============================================================================
function _app_usage {
  param($code = 0)
  Write-Output $TXT_APP_USAGE
  exit ([int]$code)
}

function _app_usage_channels {
  param($code = 0)
  Write-Output $TXT_APP_USAGE_CHANNELS
  exit ([int]$code)
}

function _app_usage_completions {
  param($code = 0)
  Write-Output $TXT_APP_USAGE_COMPLETIONS
  exit ([int]$code)
}

function _app_completions_fish {
  $ext_dir = "$HOME/.config/$CLI_NAME/extensions"

  Write-Output @"
# Fish completions for $CLI_NAME

# ==========================================================================
# Global options 
# ==========================================================================
complete -c $CLI_NAME -n "__fish_use_subcommand" -s h -l help -d "Show help and exit"
complete -c $CLI_NAME -n "__fish_use_subcommand" -s v -l version -d "Show version and exit"
complete -c $CLI_NAME -n "__fish_use_subcommand" -s e -l edit-config -d "Edit config file"
complete -c $CLI_NAME -n "__fish_use_subcommand" -s E -l generate-desktop-entry -d "Print desktop entry info"
complete -c $CLI_NAME -n "__fish_use_subcommand" -s U -l update -d "Update the script"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l config-write -d "Write current config to file"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l launcher -s l -d "Preferred launcher" --require-parameter --no-files -a "fzf rofi gum"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l preview -d "Enable preview window"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l no-preview -d "Disable preview window"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l preview-images -d "Enable image previews"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l no-preview-images -d "Disable image previews"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l player -s p -d "Media player" --require-parameter --no-files -a "mpv vlc tplay"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l mpv-args -d "Pass custom mpv args at runtime"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l vlc-args -d "Pass custom vlc args at runtime"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l tplay-args -d "Pass custom tplay args at runtime"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l disown-player -d "Disown player"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l no-disown-player -d "Do not disown player"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l rofi-theme-main -d "Rofi main theme path" --require-parameter
complete -c $CLI_NAME -n "__fish_use_subcommand" -l rofi-theme-preview -d "Rofi preview theme path" --require-parameter
complete -c $CLI_NAME -n "__fish_use_subcommand" -l rofi-theme-prompt -d "Rofi prompt theme path" --require-parameter
complete -c $CLI_NAME -n "__fish_use_subcommand" -l rofi-theme-confirm -d "Rofi confirm theme path" --require-parameter
complete -c $CLI_NAME -n "__fish_use_subcommand" -l rofi-theme-pager -d "Rofi pager theme path" --require-parameter

complete -c $CLI_NAME -n "__fish_use_subcommand" -s x -l extension -d "Load extension" --require-parameter --no-files -a '(find $ext_dir -follow -maxdepth 3 -type f 2>/dev/null | string replace "$ext_dir/" "" | sort)'
complete -c $CLI_NAME -n "__fish_use_subcommand" -o xargs -l extension-arguments -d "The arguments to parse to cmd extension" --require-parameter --no-files

# ==========================================================================
# Menu shortcuts
# ==========================================================================
complete -c $CLI_NAME -n "__fish_use_subcommand" -o ce -l cmd-exit -d "Exit after shortcut menu commandline options"
complete -c $CLI_NAME -n "__fish_use_subcommand" -o ps -l playlist-skip -d "Skip item selection and auto‑pick first entry"
complete -c $CLI_NAME -n "__fish_use_subcommand" -o me -l media-exit -d "Exit after performing a media action"

complete -c $CLI_NAME -n "__fish_use_subcommand" -l play -d "Watch selected video"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l play-all -d "Play whole playlist"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l listen -d "Listen to selected video"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l listen-all -d "Listen to whole playlist"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l download -d "Download selected video"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l download-all -d "Download whole playlist (video)"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l download-audio -d "Download audio only"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l download-audio-all -d "Download whole playlist as audio"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l save -d "Save video to saved list"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l save-playlist -d "Save playlist to custom list"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l shell -d "Open subshell with context"

complete -c $CLI_NAME -n "__fish_use_subcommand" -s s -l search -d "Search for videos" --require-parameter --no-files -a '(cat "'$CLI_SEARCH_HISTORY_FILE'" 2>/dev/null)'
complete -c $CLI_NAME -n "__fish_use_subcommand" -o sp -l search-playlist -d "Search for playlists" --require-parameter
complete -c $CLI_NAME -n "__fish_use_subcommand" -o sc -l search-channel -d "Search for channels" --require-parameter
complete -c $CLI_NAME -n "__fish_use_subcommand" -o ss -l search-short -d "Search for shorts" --require-parameter
complete -c $CLI_NAME -n "__fish_use_subcommand" -o sm -l search-movie -d "Search for movies" --require-parameter

complete -c $CLI_NAME -n "__fish_use_subcommand" -o sv -l saved-video -d "Open a specific saved video" --require-parameter --no-files -a '(jq -r '.entries[].title' "'$CLI_SAVED_VIDEOS_FILE'" 2>/dev/null)'
complete -c $CLI_NAME -n "__fish_use_subcommand" -o cp -l custom-playlist -d "Open a saved custom playlist" --require-parameter --no-files -a '(jq -r '.[]?.name' "'$CLI_CUSTOM_PLAYLISTS_FILE'" 2>/dev/null)'
complete -c $CLI_NAME -n "__fish_use_subcommand" -o cc -l custom-cmd -d "Execute a specific custom command" --require-parameter --no-files -a '(jq -r '.[]?.name' "'$CLI_CUSTOM_CMDS_FILE'" 2>/dev/null)'

complete -c $CLI_NAME -n "__fish_use_subcommand" -l feed -d "Open your personalised feed"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l subscriptions-feed -d "Show latest videos from subscriptions"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l watch-later -d "Open Watch Later playlist"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l playlists -d "Show saved YouTube playlists"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l custom-playlists -d "Browse custom playlists"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l saved -d "Open saved videos"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l recent -d "Show recently watched videos"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l liked -d "Open Liked Videos playlist"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l watch-history -d "Show watch history"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l clips -d "Browse your clips"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l new-custom-cmd -d "Create a new custom command"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l custom-cmds -d "Execute an existing custom command"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l search-history -d "Show search history"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l edit-search-history -d "Edit search history file"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l edit-custom-playlists -d "Edit custom playlists file"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l edit-mpv-config -d "Edit mpv configuration"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l edit-yt-dlp-config -d "Edit yt‑dlp configuration"
complete -c $CLI_NAME -n "__fish_use_subcommand" -l edit-custom-cmds -d "Edit custom commands file"

# ==========================================================================
# Channels subcommand
# ==========================================================================
complete -c $CLI_NAME -f -n "__fish_use_subcommand" -a channels -d "Browse or search within a specific channel"
complete -c $CLI_NAME -n "__fish_seen_subcommand_from channels" -o n -l name -d "Channel name" --require-parameter --no-files -a '(jq -r '.entries[].title' "'$CLI_SUBSCRIPTIONS_FILE'" 2>/dev/null)'
complete -c $CLI_NAME -n "__fish_seen_subcommand_from channels" -o v -l videos -d "List channel videos"
complete -c $CLI_NAME -n "__fish_seen_subcommand_from channels" -o f -l featured -d "Show featured playlists"
complete -c $CLI_NAME -n "__fish_seen_subcommand_from channels" -o s -l search -d "Search within channel" --require-parameter
complete -c $CLI_NAME -n "__fish_seen_subcommand_from channels" -o p -l playlists -d "List channel playlists"
complete -c $CLI_NAME -n "__fish_seen_subcommand_from channels" -o sh -l shorts -d "Show channel shorts"
complete -c $CLI_NAME -n "__fish_seen_subcommand_from channels" -o st -l streams -d "Show live streams & past broadcasts"
complete -c $CLI_NAME -n "__fish_seen_subcommand_from channels" -o po -l podcasts -d "Show channel podcasts"

# ==========================================================================
# Completions subcommand
# ==========================================================================
complete -c $CLI_NAME -f -n "__fish_use_subcommand" -a completions -d "Generate shell completions"
complete -c $CLI_NAME -n "__fish_seen_subcommand_from completions" -s f -l fish -d "Print fish completions"
complete -c $CLI_NAME -n "__fish_seen_subcommand_from completions" -s b -l bash -d "Print bash completions"
complete -c $CLI_NAME -n "__fish_seen_subcommand_from completions" -s z -l zsh -d "Print zsh completions"
complete -c $CLI_NAME -n "__fish_seen_subcommand_from completions" -s h -l help -d "Show help for completions"
"@

  exit 0
}

# ==============================================================================
# APP: cmdline parser
# ==============================================================================
# Flag matching is CASE-SENSITIVE (via -ccontains/-ceq) to mirror the bash `case`
# — e.g. -e (edit-config) and -E (generate-desktop-entry) differ only by case.
function _app_cmd_line_parser {
  $argv = @($args)
  $i = 0

  while ($i -lt $argv.Count) {
    $shift_count = 1
    $a = $argv[$i]
    $b = if ($i + 1 -lt $argv.Count) { $argv[$i + 1] } else { '' }

    switch ($a) {
      { @('-h', '--help') -ccontains $_ } { _app_usage }
      { @('-v', '--version') -ccontains $_ } { Write-Output "$CLI_NAME v$CLI_VERSION MIT Copyright © 2024 $CLI_AUTHOR"; exit 0 }
      { @('-U', '--update') -ccontains $_ } { if (-not (_app_update_check)) { Write-Output $TXT_UPDATE_NOT_FOUND }; exit 1 }
      { @('-e', '--edit-config') -ccontains $_ } { _app_edit_config }
      { @('-E', '--generate-desktop-entry') -ccontains $_ } { _app_generate_desktop_entry }
      { @('-ce', '--cmd-exit') -ccontains $_ } { $script:CMD_EXIT = 'true' }
      { @('-ps', '--playlist-skip') -ccontains $_ } { $script:CMD_PLAYLIST_RESULTS_SKIP = 'true' }
      { @('-me', '--media-exit') -ccontains $_ } { $script:CMD_MEDIA_EXIT = 'true' }
      { $_ -ceq '--config-write' } { [IO.File]::WriteAllText($CLI_CONFIG_FILE, ("$(_print_config)" + "`n"), [Text.UTF8Encoding]::new($false)) }
      { $_ -ceq '--preview' } { $script:CONFIG_ENABLE_PREVIEW = 'true' }
      { $_ -ceq '--no-preview' } { $script:CONFIG_ENABLE_PREVIEW = 'false' }
      { $_ -ceq '--preview-images' } { $script:CONFIG_ENABLE_PREVIEW_IMAGES = 'true' }
      { $_ -ceq '--no-preview-images' } { $script:CONFIG_ENABLE_PREVIEW_IMAGES = 'false' }
      { @('-x', '--extension') -ccontains $_ } {
        if (-not $b) { _app_usage 1 }
        if ([IO.Path]::IsPathRooted($b)) { . $b } else { . "$CLI_EXTENSIONS_DIR/$b" }
        $shift_count = 2
      }
      { @('-xargs', '--extension-arguments') -ccontains $_ } {
        $i++
        $script:CLI_EXTENSION_CMDLINE_ARGS = if ($i -lt $argv.Count) { $argv[$i..($argv.Count - 1)] -join ' ' } else { '' }
        return
      }
      { @('-l', '--launcher') -ccontains $_ } { if (-not $b) { _app_usage 1 }; $script:CONFIG_LAUNCHER = $b; $shift_count = 2 }
      { @('-p', '--player') -ccontains $_ } { if (-not $b) { _app_usage 1 }; $script:CONFIG_PLAYER = $b; $shift_count = 2 }
      { $_ -ceq '--mpv-args' } { if (-not $b) { _app_usage 1 }; $script:CONFIG_MPV_ARGS = $b; $shift_count = 2 }
      { $_ -ceq '--vlc-args' } { if (-not $b) { _app_usage 1 }; $script:CONFIG_VLC_ARGS = $b; $shift_count = 2 }
      { $_ -ceq '--tplay-args' } { if (-not $b) { _app_usage 1 }; $script:CONFIG_TPLAY_ARGS = $b; $shift_count = 2 }
      { $_ -ceq '--disown-player' } { $script:CONFIG_DISOWN_PLAYER = 'true' }
      { $_ -ceq '--no-disown-player' } { $script:CONFIG_DISOWN_PLAYER = 'false' }
      { $_ -ceq '--rofi-theme-main' } { if (-not $b) { _app_usage 1 }; $script:CONFIG_ROFI_THEME_MAIN = $b; $shift_count = 2 }
      { $_ -ceq '--rofi-theme-preview' } { if (-not $b) { _app_usage 1 }; $script:CONFIG_ROFI_THEME_PREVIEW = $b; $shift_count = 2 }
      { $_ -ceq '--rofi-theme-prompt' } { if (-not $b) { _app_usage 1 }; $script:CONFIG_ROFI_THEME_PROMPT = $b; $shift_count = 2 }
      { $_ -ceq '--rofi-theme-confirm' } { if (-not $b) { _app_usage 1 }; $script:CONFIG_ROFI_THEME_CONFIRM = $b; $shift_count = 2 }
      { $_ -ceq '--rofi-theme-pager' } { if (-not $b) { _app_usage 1 }; $script:CONFIG_ROFI_THEME_PAGER = $b; $shift_count = 2 }
      { $_ -ceq '--play' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_WATCH }
      { $_ -ceq '--play-all' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_WATCH_ALL; $script:CMD_PLAYLIST_RESULTS_SKIP = 'true' }
      { $_ -ceq '--listen' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_LISTEN }
      { $_ -ceq '--listen-all' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_LISTEN_ALL; $script:CMD_PLAYLIST_RESULTS_SKIP = 'true' }
      { $_ -ceq '--download' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_DOWNLOAD }
      { $_ -ceq '--download-all' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL; $script:CMD_PLAYLIST_RESULTS_SKIP = 'true' }
      { $_ -ceq '--download-audio' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_AUDIO }
      { $_ -ceq '--download-audio-all' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_DOWNLOAD_ALL_AUDIO; $script:CMD_PLAYLIST_RESULTS_SKIP = 'true' }
      { $_ -ceq '--save' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_SAVE }
      { $_ -ceq '--save-playlist' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_SAVE_PLAYLIST; $script:CMD_PLAYLIST_RESULTS_SKIP = 'true' }
      { $_ -ceq '--shell' } { $script:CMD_MEDIA_ACTION = $TXT_MENU_MEDIA_ACTIONS_SHELL }
      { $_ -ceq '--feed' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_FEED }
      { $_ -ceq '--subscriptions-feed' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_SUBS_FEED }
      { $_ -ceq '--watch-later' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_WATCH_LATER }
      { $_ -ceq '--playlists' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_PLAYLISTS }
      { $_ -ceq '--custom-playlists' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_CUSTOM_PLAYLISTS }
      { $_ -ceq '--saved' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_SAVED }
      { $_ -ceq '--recent' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_RECENT }
      { $_ -ceq '--liked' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_LIKED }
      { $_ -ceq '--watch-history' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_HISTORY }
      { $_ -ceq '--clips' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_CLIPS }
      { $_ -ceq '--new-custom-cmd' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC; $script:CMD_MISC_ACTION = $TXT_MENU_MISC_NEW_CUSTOM_CMD }
      { $_ -ceq '--custom-cmds' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC; $script:CMD_MISC_ACTION = $TXT_MENU_MISC_CUSTOM_CMDS }
      { $_ -ceq '--search-history' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC; $script:CMD_MISC_ACTION = $TXT_MENU_MISC_SEARCH_HISTORY }
      { $_ -ceq '--edit-search-history' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC; $script:CMD_MISC_ACTION = $TXT_MENU_MISC_EDIT_SEARCH_HISTORY }
      { $_ -ceq '--edit-custom-playlists' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC; $script:CMD_MISC_ACTION = $TXT_MENU_MISC_EDIT_CUSTOM_PLAYLISTS }
      { $_ -ceq '--edit-mpv-config' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC; $script:CMD_MISC_ACTION = $TXT_MENU_MISC_EDIT_MPV_CONFIG }
      { $_ -ceq '--edit-yt-dlp-config' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC; $script:CMD_MISC_ACTION = $TXT_MENU_MISC_EDIT_YTDLP_CONFIG }
      { $_ -ceq '--edit-custom-cmds' } { $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC; $script:CMD_MISC_ACTION = $TXT_MENU_MISC_EDIT_CUSTOM_CMDS }
      { @('-cp', '--custom-playlist') -ccontains $_ } {
        $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_CUSTOM_PLAYLISTS
        if (-not $b) {
          $script:CMD_INPUT = ui_prompt $TXT_MENU_MAIN_CUSTOM_PLAYLISTS_PROMPT
          if (-not $CMD_INPUT) { _app_usage 1 }
        } else { $script:CMD_INPUT = $b; $shift_count = 2 }
      }
      { @('-sv', '--saved-video') -ccontains $_ } {
        $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_SAVED
        if (-not $b) {
          $script:CMD_INPUT = ui_prompt $TXT_MENU_MAIN_SAVED_PROMPT
          if (-not $CMD_INPUT) { _app_usage 1 }
        } else { $script:CMD_INPUT = $b; $shift_count = 2 }
      }
      { @('-cc', '--custom-cmd') -ccontains $_ } {
        $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC
        $script:CMD_MISC_ACTION = $TXT_MENU_MISC_CUSTOM_CMDS
        if (-not $b) {
          $script:CMD_INPUT = ui_prompt $TXT_MENU_MISC_CUSTOM_CMDS_PROMPT
          if (-not $CMD_INPUT) { _app_usage 1 }
        } else { $script:CMD_INPUT = $b; $shift_count = 2 }
      }
      { @('-s', '--search') -ccontains $_ } {
        $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_SEARCH
        if (-not $b) {
          $script:CMD_INPUT = ui_prompt $TXT_MENU_MAIN_SEARCH_PROMPT
          if (-not $CMD_INPUT) { _app_usage 1 }
        } else { $script:CMD_INPUT = $b; $shift_count = 2 }
      }
      { @('-sp', '--search-playlist') -ccontains $_ } {
        $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC
        $script:CMD_MISC_ACTION = $TXT_MENU_MISC_EXPLORE_PLAYLISTS
        if (-not $b) {
          $script:CMD_INPUT = ui_prompt $TXT_MENU_MISC_EXPLORE_PLAYLISTS_PROMPT
          if (-not $CMD_INPUT) { _app_usage 1 }
        } else { $script:CMD_INPUT = $b; $shift_count = 2 }
      }
      { @('-sc', '--search-channel') -ccontains $_ } {
        $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC
        $script:CMD_MISC_ACTION = $TXT_MENU_MISC_EXPLORE_CHANNELS
        if (-not $b) {
          $script:CMD_INPUT = ui_prompt $TXT_MENU_MISC_EXPLORE_CHANNELS_PROMPT
          if (-not $CMD_INPUT) { _app_usage 1 }
        } else { $script:CMD_INPUT = $b; $shift_count = 2 }
      }
      { @('-ss', '--search-short') -ccontains $_ } {
        $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC
        $script:CMD_MISC_ACTION = $TXT_MENU_MISC_EXPLORE_SHORTS
        if (-not $b) {
          $script:CMD_INPUT = ui_prompt $TXT_MENU_MISC_EXPLORE_SHORTS_PROMPT
          if (-not $CMD_INPUT) { _app_usage 1 }
        } else { $script:CMD_INPUT = $b; $shift_count = 2 }
      }
      { @('-sm', '--search-movie') -ccontains $_ } {
        $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_MISC
        $script:CMD_MISC_ACTION = $TXT_MENU_MISC_EXPLORE_MOVIES
        if (-not $b) {
          $script:CMD_INPUT = ui_prompt $TXT_MENU_MISC_EXPLORE_MOVIES_PROMPT
          if (-not $CMD_INPUT) { _app_usage 1 }
        } else { $script:CMD_INPUT = $b; $shift_count = 2 }
      }
      { @('c', 'channels') -ccontains $_ } {
        $i++
        $script:CMD_MAIN_ACTION = $TXT_MENU_MAIN_CHANNELS
        while ($i -lt $argv.Count) {
          $cs = 1
          $ca = $argv[$i]
          $cb = if ($i + 1 -lt $argv.Count) { $argv[$i + 1] } else { '' }
          switch ($ca) {
            { @('-n', '--name') -ccontains $_ } {
              if (-not $cb) {
                $script:CMD_CHANNEL = ui_prompt $TXT_MENU_MAIN_CHANNELS_PROMPT
                if (-not $CMD_CHANNEL) { _app_usage_channels 1 }
              } else { $script:CMD_CHANNEL = $cb; $cs = 2 }
            }
            { @('-s', '--search') -ccontains $_ } {
              $script:CMD_CHANNEL_ACTION = $TXT_MENU_CHANNEL_ACTIONS_SEARCH
              if (-not $cb) {
                $script:CMD_INPUT = ui_prompt $TXT_MENU_CHANNEL_ACTIONS_SEARCH_PROMPT
                if (-not $CMD_INPUT) { _app_usage_channels 1 }
              } else { $script:CMD_INPUT = $cb; $cs = 2 }
            }
            { @('-v', '--videos') -ccontains $_ } { $script:CMD_CHANNEL_ACTION = $TXT_MENU_CHANNEL_ACTIONS_VIDEOS }
            { @('-f', '--featured') -ccontains $_ } { $script:CMD_CHANNEL_ACTION = $TXT_MENU_CHANNEL_ACTIONS_FEATURED }
            { @('-p', '--playlists') -ccontains $_ } { $script:CMD_CHANNEL_ACTION = $TXT_MENU_CHANNEL_ACTIONS_PLAYLISTS }
            { @('-sh', '--shorts') -ccontains $_ } { $script:CMD_CHANNEL_ACTION = $TXT_MENU_CHANNEL_ACTIONS_SHORTS }
            { @('-st', '--streams') -ccontains $_ } { $script:CMD_CHANNEL_ACTION = $TXT_MENU_CHANNEL_ACTIONS_STREAMS }
            { @('-po', '--podcasts') -ccontains $_ } { $script:CMD_CHANNEL_ACTION = $TXT_MENU_CHANNEL_ACTIONS_PODCASTS }
            { @('-h', '--help') -ccontains $_ } { _app_usage_channels }
            default { _app_usage_channels 1 }
          }
          $i += $cs
        }
        return
      }
      { $_ -ceq 'completions' } {
        if (-not $b) { _app_usage 1 }
        switch ($b) {
          { @('-f', '--fish') -ccontains $_ } { _app_completions_fish }
          { @('-b', '--bash') -ccontains $_ } { Write-Output "Contribute to $CLI_NAME by writing bash completions"; exit 1 }
          { @('-z', '--zsh') -ccontains $_ } { Write-Output "Contribute to $CLI_NAME by writing zsh completions"; exit 1 }
          { @('-h', '--help') -ccontains $_ } { _app_usage_completions }
          default { _app_usage_completions 1 }
        }
        $shift_count = 2
      }
      default { _app_usage 1 }
    }

    $i += $shift_count
  }
}

# ==============================================================================
# App
# ==============================================================================
function main {
  # bash uses `trap _app_runtime_clean_up EXIT INT TERM`; try/finally covers normal
  # return and terminating errors. The explicit-exit path (_util_byebye) runs the
  # same cleanup itself before exiting.
  try {
    _load_config
    _app_cmd_line_parser @args
    _app_auto_update
    _app_core_dep_ch
    menu_main
  } finally {
    _app_runtime_clean_up
  }
}

# Guarded so __run_disowned (which re-sources this script with $env:YTX_SOURCED=1
# to reuse its functions) does not re-enter the app.
if (-not $env:YTX_SOURCED) {
  main @args
}
