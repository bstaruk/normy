# normy — working notes

Single-file bash script that batch-normalizes MP3 loudness via FFmpeg's `loudnorm`. Open source. Architecture and design rationale live in [README.md](README.md) — this file is for working conventions and active context.

## Conventions

- Bash, target macOS + Linux. Preflight messages should mention both `brew` and `apt` install paths.
- 2-space indent, LF line endings, final newline (enforced via `.editorconfig`).
- No formatter wired up yet. Prettier and `shfmt` were considered and deferred — don't add them without checking with the user.
- `chmod +x` on `normy.sh` is tracked in git (mode `100755`); preserve it on edits.
- Comments lean toward explaining *why*, since this is a public tool. Don't strip the rationale comments at the top of `normy.sh` or in section headers.

## Working decisions (don't relitigate without asking)

- **Stay in bash.** Node was considered and rejected — the script is a thin wrapper around FFmpeg/ffprobe and rewriting would only add deps without adding capability.
- **`python3` is an acceptable hard dep** (parses FFmpeg's loudnorm JSON). Don't try to "simplify" it away with grep/awk — the embedded JSON is too fragile for that.

## Open threads

- The `WARNED_FILES` list (files with many decoder errors) is informational — the user spot-checks by ear. A potential follow-up: a separate helper that diffs source/output durations or scans for long silences to flag glitches automatically.
- Single-threaded; ~921 files in the user's collection takes hours per run. Parallelization (e.g. `xargs -P`) would complicate progress/ETA and interrupt handling — defer until proven necessary.
- The end-of-run summary distinguishes failed files from files-with-warnings; if we add new categories (e.g. "skipped silently" or "fallback used") keep them as separate sections rather than collapsing.

## Things to remember when editing

- The skip-if-exists check (`[ -f "$OUTFILE" ]`) is what makes resume work. Don't break it. The atomic `.tmp` → `mv` pattern is what makes it safe — keep them coupled.
- `ENCODE_MODE` is `"preserve"` by default for a reason (see README design notes). If a user complains about size or quality, check their source bitrates first before changing defaults.
- Interrupt handling: single Ctrl+C sets `INTERRUPTED=1` and finishes gracefully; double Ctrl+C force-quits. Don't add a "quit immediately" first-press path without discussing — the graceful default is intentional.
