# yt-x — Windows (git-bash/MSYS) preview debugging — session handoff

> Working notes for resuming the "previews break fzf navigation under git-bash" investigation
> **directly on the Windows machine**. Delete this file once the issue is resolved.

## The problem (user's report)
- `yt-x` works fine under git-bash **until previews are enabled** (even **text-only** previews).
- With previews on, moving the selection (Up/Down) misbehaves: arrow keys "seem to accept or
  exit fzf" instead of navigating.
- Without previews, navigation is perfectly fine.
- **Status: STILL REPRODUCES on Windows after the two fixes below.** The fixes were validated in
  WSL-against-git-bash via non-interactive probes, but the real interactive symptom persists on
  the Windows box, so the root cause is (at least partly) NOT what we fixed. Continue debugging
  natively.

## Environment (the user's machine)
- Editing happens in **WSL** at `/home/eduardo/projects/yt-x`.
- git-bash is reachable from WSL at `/mnt/c/Program Files/Git/usr/bin/bash.exe`.
- The actual run environment is **git-bash / MSYS** (`MSYSTEM=MSYS`, `uname` → `MSYS_NT-...`).
  In yt-x's platform detection this maps to `CLI_PLATFORM="windows"` (yt-x:62).
- **`fzf` is the NATIVE WINDOWS binary**, installed via scoop:
  `C:\Users\eduardo\scoop\shims\fzf` → `fzf.exe`, version **0.73.1 (ce4bef75)**.
  This native-fzf-inside-mintty combination is central to the whole issue.
- `jq` 1.8.1 (scoop), `stty`/`fold`/`sh`/`bash` all from MSYS `/usr/bin`.
- In a login git-bash shell, `SHELL=/usr/bin/bash`, `command -v sh` → `/usr/bin/sh`.

## Changes already made (committed by the user)
Two edits to `yt-x`, both syntax-checked with `bash -n`:

1. **`yt-x:82`** — was `export SHELL="sh"`, now:
   ```sh
   export SHELL="$(command -v sh || printf '%s' sh)"
   ```
   Rationale: native `fzf.exe` spawns preview/execute children via `$SHELL` and **silently fails
   to spawn the child when `$SHELL` is a bare name** (`sh`, `bash`) or unset — only an **absolute
   path** works. This was confirmed empirically (see "Probe technique" below).

2. **`yt-x:1505`** — added `[ "$CLI_PLATFORM" != "windows" ] &&` guard to the `fzf_preview`
   image-path line that ran `stty size </dev/tty` on every render. (`CLI_PLATFORM` is injected
   into the preview env at yt-x:1223.) The other `stty </dev/tty` at yt-x:1503 was left as-is
   (fallback only; runs only when fzf provides no dimensions).

   ⚠️ **CACHE CAVEAT** — this code lives in a shared preview script that yt-x writes **once** and
   never overwrites (`__preview_fzf_create_shared_script`, yt-x:~1481 only writes if missing).
   The change to the embedded heredoc does NOT take effect until the cached copy is regenerated:
   ```sh
   rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/yt-x/previews/text/fzf-preview.sh"
   ```
   **On Windows verify the real cache path** — print it from a yt-x context:
   `echo "$CLI_FZF_PREVIEW_SCRIPT"` (it is `$CLI_CACHE_DIR/previews/text/fzf-preview.sh`,
   `CLI_CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/yt-x`). The per-item generated scripts in
   `.../previews/text/*.sh` are also cached — **clear the whole `previews/text/` dir** to be safe.

## What was CONFIRMED empirically (in WSL driving git-bash)
Native `fzf.exe` cannot spawn the preview/execute child unless `$SHELL` is an absolute path:

| `$SHELL` value           | preview child runs? |
|--------------------------|---------------------|
| `sh`   (old yt-x:82)     | ❌ no                |
| `bash`                   | ❌ no                |
| unset                    | ❌ no                |
| `/usr/bin/sh`            | ✅ yes               |
| `/usr/bin/bash`          | ✅ yes               |

A multi-line preview that sources `{1}` (mirroring `__ui_fzf_launcher_with_preview`) ran fine
with `SHELL=/usr/bin/sh`. So the SHELL fix is necessary — but evidently **not sufficient**.

### Probe technique (works non-interactively — reuse it)
`--preview` only renders for the focused item in interactive mode, which is hard to script.
Trick: use `focus:execute-silent(...)` (same child-spawn path as `--preview`) then `accept`:
```sh
printf "alpha\nbravo\n" | fzf --sync \
  --bind "focus:execute-silent(echo RAN > /c/temp/out)+accept" >/dev/null 2>&1
# if /c/temp/out exists, the child spawned successfully
```
Note: `focus:accept` alone fires BEFORE the preview renders, so don't use it to test `--preview`
directly — use the `execute-silent` form above.

## Key code map (line numbers as of the committed changes)
- `yt-x:58-64`   — platform detection (`uname` → `CLI_PLATFORM`).
- `yt-x:82`      — `export SHELL=...` (fix #1).
- `yt-x:183-220` — `CONFIG_FZF_OPTS` default. Note it already has `--wrap`,
  `--preview-window=border-rounded,left,35%,wrap`, and
  `--bind=ctrl-/:toggle-preview,ctrl-space:...`.
- `yt-x:804`     — `export FZF_DEFAULT_OPTS="$CONFIG_FZF_OPTS"`.
- `yt-x:1162-1179` — `__ui_fzf_launcher` (no preview).
- `yt-x:1215-1242` — `__ui_fzf_launcher_with_preview`. Builds the multi-line `--preview` string
  (defines a few vars, sets `preview_script_path='{1}'`, sources it) and calls:
  `fzf --prompt=... --delimiter '|' --with-nth "{2..}" --accept-nth "{2..}" --preview="$preview_script" $custom_opts`
- `yt-x:1480-1541` — `__preview_fzf_create_shared_script` (writes cached `fzf-preview.sh`;
  contains `fzf_preview()` image renderer + `draw_divider`). **Fix #2 is at 1505.**
- `yt-x:1543-1722` — `__preview_fzf_generate_script_for_item` (jq builds per-item vars; writes
  per-item `<hash>.sh` that sources the shared script, optionally renders image, then prints
  fields with `fold` + `draw_divider`).
- `yt-x:1772-1794` — `_preview_fzf` / `preview_fzf`: turns each list line into
  `"<scripts_dir>/<hash>.sh|<line>"` and kicks off script/image generation in the background.
- Callers of `ui_launcher_with_preview`: yt-x:3061, 3131, 3376, 3948, 4049, 4103.

## Leading hypotheses still open (investigate on Windows, in order)
1. **The SHELL fix isn't actually reaching fzf at runtime.** Confirm inside a running yt-x that
   `$SHELL` is absolute when fzf launches (the fix uses `command -v sh` at yt-x:82 — verify it
   resolved and that nothing later re-sets SHELL; `grep -n "SHELL=" yt-x`). Also confirm fzf is
   the scoop native build, not some other fzf on PATH at run time (`command -v fzf`).
2. **Stale cache** still serving the pre-fix shared/per-item scripts → clear `previews/text/`
   (see cache caveat) and retest. Easy to overlook; check first.
3. **Native fzf.exe + mintty input handling.** Even with previews working, the act of fzf
   repeatedly spawning a Windows child process per focus-change may be corrupting console input
   under mintty. Tests to run natively:
   - Does the problem persist under **Windows Terminal / conhost / wezterm** instead of mintty?
   - Does launching via **winpty** (`winpty yt-x ...`) change behavior?
   - Set `FZF_DEFAULT_OPTS` minimal and reproduce with a tiny standalone fzf + a trivial
     `--preview "echo hi"` to see if ANY preview breaks arrows, or only the heavy yt-x one.
   - Try `--preview "echo hi"` vs the full yt-x preview to separate "spawning a child at all"
     from "the specific heavy script".
4. **ESC-sequence timing.** Arrow keys are multi-byte ESC sequences; if per-render child-spawn
   latency makes fzf read a lone ESC, it aborts. If a trivial `echo hi` preview is fine but the
   heavy script breaks arrows, this (latency) is implicated → pursue the perf refactor below.
5. **`--accept-nth`/`--with-nth`/delimiter `|`** interaction on native fzf 0.73.1 — try removing
   preview-only options one at a time to bisect which option flips the behavior.

### Concrete first commands to run on Windows (in git-bash)
```sh
command -v fzf; fzf --version          # confirm scoop native fzf 0.73.1
echo "$SHELL"                          # in a yt-x context, must be ABSOLUTE
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/yt-x/previews/text"   # nuke stale cache
# minimal repro to bisect: does a trivial preview break arrows?
printf "a\nb\nc\n" | fzf --preview "echo hi"
# then with yt-x's heavy options layered on, one at a time.
```

## Performance issue (already explained to user; relevant if hypothesis #4 holds)
Per preview render on MSYS, the generated script: forks a child shell, sources 2 files, calls
`draw_divider` up to ~4× (per-character `printf` with truecolor escapes, ~70 cols), and runs
**~7-8 `fold` subprocesses**. MSYS has no real `fork()` (CreateProcess per external cmd,
**~66 ms each measured**), so a render is **~0.5-0.8 s** on Windows vs ~10 ms on Linux.

Proposed perf refactor (NOT yet implemented — offered, awaiting go-ahead):
1. **Drop `fold` entirely** — fzf already soft-wraps (`--wrap` + `--preview-window …,wrap`),
   so the manual word-wrap is redundant. Biggest single Windows win (~460 ms → 0).
2. **Pre-render text previews to `<hash>.txt` at list-build time**; make the preview command a
   plain `cat {1}` for text-only mode (no child shell logic, no sourcing, no fold, no divider
   loop at render). For image mode keep a tiny per-item script that renders the image (must stay
   at render time) then `cat`s the precomputed text.
3. **One-`printf` divider** instead of the per-char loop (also reduces ANSI volume mintty must
   process):
   ```sh
   draw_divider() { printf "%s%*s%s\n" "$THEME_FZF_PREVIEW_DIVIDER" "$FZF_PREVIEW_COLUMNS" "" "$THEME_RESET" | tr ' ' '-'; }
   ```
Files this refactor touches: `__preview_fzf_generate_script_for_item`, the shared script in
`__preview_fzf_create_shared_script`, and `__ui_fzf_launcher_with_preview`.

## Definition of done
- With previews enabled under git-bash, Up/Down navigate normally (no accept/exit).
- Verified interactively on the Windows box (not just via the non-interactive probe).
- Both text and image previews render correctly.
- Cache regenerated/confirmed so fixes are actually in effect.
