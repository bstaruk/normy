# normy

Batch loudness normalization for MP3 collections. Wraps FFmpeg's two-pass `loudnorm` filter (EBU R128) with a single-pass fallback. Built for normalizing variable-quality archive material — old radio recordings, podcasts, audiobooks — where source bitrates, sample rates, and volumes are all over the map.

**Highlights**

- Two-pass loudnorm with single-pass fallback
- Preserves source bitrate by default (with a sensible floor) — won't bloat 1GB of low-bitrate archives into 30GB
- Preserves source sample rate per-file
- Mirrors source folder structure to the output directory
- Resumable: safe to interrupt with Ctrl+C; partial files are cleaned up; rerun picks up where it left off
- Interactive prompts (with last-used paths remembered) or CLI args
- Per-file progress + running ETA
- Decoder-warning summarization so the log doesn't drown in repeated errors from corrupt source frames

## Requirements

- `ffmpeg` and `ffprobe`
- `python3` (used for parsing FFmpeg's loudnorm JSON output)

```sh
brew install ffmpeg          # macOS
sudo apt install ffmpeg      # Debian/Ubuntu
```

## Usage

```sh
./normy.sh                                  # interactive prompts
./normy.sh /path/to/mp3s                    # CLI: source only
./normy.sh /path/to/mp3s /path/to/output    # CLI: source + output
```

If you omit the output path, normy writes to a `normalized/` subfolder inside the source directory.

Last-used source/output paths are remembered in `~/.normy_history` and offered as defaults on the next interactive run.

### Resuming

If you Ctrl+C mid-run, normy finishes the current file's cleanup and exits. The partially-encoded file is removed. Rerun with the same paths and it skips everything already done. Press Ctrl+C twice to force-quit.

## Defaults

| Setting           | Value                   | Notes                                  |
| ----------------- | ----------------------- | -------------------------------------- |
| Target loudness   | `-16 LUFS`              | Spoken-word friendly (R128 broadcast)  |
| True peak ceiling | `-1.5 dBTP`             |                                        |
| Loudness range    | `11 LU`                 |                                        |
| Encoding          | preserve source bitrate | Floor at 96 kbps; sample rate preserved|

Edit the constants at the top of `normy.sh` to change.

### Encoding modes

Two modes, set via `ENCODE_MODE` near the top of the script:

- **`preserve`** (default) — match each file's source bitrate, with a `BITRATE_FLOOR` (default 96 kbps) for sources below that. Best for archive material with mixed source quality. Won't inflate small files.
- **`vbr`** — LAME VBR with `VBR_QUALITY` (default 4, ~165 kbps avg). Best for podcast/voice workflows where source material is consistent.

## Output

- Files mirror the source directory structure under the output dir.
- `normalize.log` is written to the output dir with per-file results.
- Existing output files are skipped (safe to rerun).
- The end-of-run summary lists any failed files and any files with significant decode warnings — those encoded successfully but the output may have audible glitches from corrupt source frames; worth spot-checking.

## How it works

Per file, normy:

1. **Validates** that there's a readable audio stream (`ffprobe`).
2. **Detects** source sample rate and bitrate (used for output settings).
3. **Pass 1 — measure.** Runs `loudnorm` against `/dev/null` with `print_format=json`, parses the embedded JSON out of FFmpeg's noisy stderr.
4. **Pass 2 — apply.** Runs `loudnorm` again with the measured values for accurate two-pass normalization, encoding to `OUTFILE.tmp`.
5. **Atomic finalize.** On success, `mv` the `.tmp` to its final name. On failure or interrupt, the `.tmp` is removed.
6. **Fallback.** If pass 1 measurement fails (some malformed inputs make this happen), normy retries as a single-pass normalization — less accurate but better than nothing.

Output mirrors the source folder structure. Files already present at the destination are skipped, which is what makes resume work.

## Design notes

A few non-obvious choices worth understanding:

- **Atomic writes (`.tmp` then `mv`)** mean a Ctrl+C never leaves a half-encoded file at the final path. Without this, the skip-if-exists check would falsely treat partial files as "already done" on the next run. Stale `.tmp` files are also swept on startup so you recover cleanly from crashes.
- **Source-bitrate preservation, not a fixed bitrate.** A fixed 320k re-encode bloats low-bitrate archive material ~10× for zero quality gain (you can't recover detail that wasn't there in the source). The 96k floor exists because re-encoding ultra-low-bitrate sources at the same bitrate produces noticeable generation-loss artifacts — bumping the floor gives the new encoder a little headroom.
- **Decoder warnings are summarized, not dumped.** Old MP3s with corrupted frames produce hundreds of identical "Header missing" / "Invalid data found" lines per file. The log gets a one-line tally instead, while preserving any non-flood stderr verbatim. Files exceeding the warning threshold are surfaced in the final summary so you can spot-check them.
- **`python3` for JSON parsing.** FFmpeg's loudnorm JSON is embedded in noisy stderr; a regex-based extraction is fragile. Could move to `jq` if we want one less interpreter dep.

## License

MIT (or specify your preference)
