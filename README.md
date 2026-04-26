# normy

Batch loudness normalization for MP3 collections, built for variable-quality archive material — old radio recordings, podcasts, audiobooks. Wraps FFmpeg's two-pass `loudnorm` filter (EBU R128) with a single-pass fallback, preserves source bitrates and sample rates per-file (so a 1 GB low-bitrate archive doesn't bloat into 30 GB), and resumes safely after Ctrl+C.

## What it looks like

```
=== normy ===
Source:   /Volumes/Wolfpack/Media/Radio/Art Bell
Output:   /Volumes/Wolfpack/Media/Radio/Art Bell Normalized
Files:    921
Target:   -16 LUFS
Encoding: preserve source (floor 96k)
Started:  Sun Apr 26 16:52:45 EDT 2026
=============
[1/921] [ETA --] 1992-12-12 - Area 51 - John Lear - Bob Lazar.mp3
  OK ▲5.8dB (-21.79 → -16 LUFS, 96k @ 22050Hz) in 25s
[2/921] [✓1] [ETA 6h21m] 1993-06-20 - Al Bielek - Philadelphia Experiment.mp3
  OK ▲8.2dB (-24.20 → -16 LUFS, 64k → 96k @ 44100Hz) in 18s
[3/921] [✓2] [ETA 5h47m] 1993-09-03 - John Lear - UFOs.mp3
  OK ≈ (-16.30 → -16 LUFS, 96k @ 22050Hz) in 21s
[4/921] [✓3] [ETA 5h33m] 1993-10-30 - Ghost to Ghost 1993.mp3
  Encoding  ████████████░░░░░░░░  62% │ 01:12 / 01:56 │ 9.2x
...
[30/921] [✓27 ✗1 ⊘1] [ETA 4h12m] 1994-10-30 - Ghost To Ghost 1994.mp3
  OK ▼0.1dB (-16.12 → -16 LUFS, 96k @ 22050Hz) in 19s [! 87 decode warnings]
...

=== Done ===
Finished:  Sun Apr 26 22:14:09 EDT 2026
Elapsed:   5h21m
Total:     921
Success:   905
Skipped:   10
Failed:    6

Files with significant decode warnings (output may have audible glitches):
  - 1994-10-30 - Ghost To Ghost 1994.mp3 (87 warnings)
  - 1995-03-19 - Linda Moulton Howe.mp3 (102 warnings)

Bitrate distribution:
    32k: 47 files
    64k: 312 files
    96k: 245 files
   128k: 198 files
   192k: 87 files
   256k: 16 files
```

## Requirements

- `ffmpeg` and `ffprobe`
- `python3`

```sh
brew install ffmpeg          # macOS
sudo apt install ffmpeg      # Debian/Ubuntu
```

## Usage

```sh
./normy.sh                                  # interactive prompts
./normy.sh /path/to/mp3s                    # source only
./normy.sh /path/to/mp3s /path/to/output    # source + output
```

If you omit the output path, normy writes to a `normalized/` subfolder inside the source. Last-used paths are remembered in `~/.normy_history` and offered as defaults the next time you run it interactively.

### Resuming

Press Ctrl+C anytime. normy finishes cleanup on the in-progress file, discards any partial output, and exits. Re-run with the same paths and it picks up where it left off. Press Ctrl+C twice to force quit.

## Configuration

The defaults are tuned for spoken-word archive material. To change them, edit the constants near the top of `normy.sh`.

| Setting           | Default      | Notes                                  |
| ----------------- | ------------ | -------------------------------------- |
| Target loudness   | `-16 LUFS`   | Podcast / spoken-word standard         |
| True peak ceiling | `-1.5 dBTP`  |                                        |
| Loudness range    | `11 LU`      |                                        |
| Encoding mode     | `preserve`   | Match source bitrate, with floor       |
| Bitrate floor     | `96 kbps`    | Bumps up ultra-low-bitrate sources     |
| Sample rate       | source       | Preserved per-file from the input      |

### Encoding modes

- **`preserve`** *(default)* — match each file's source bitrate, with the floor for very low ones. Best for archive material with mixed source quality; won't inflate small files.
- **`vbr`** — LAME VBR (`-q:a 4` ≈ 165 kbps avg). Best for podcast/voice workflows where source quality is consistent.

## Output

- Files mirror the source folder structure under the output directory.
- Each run writes a timestamped log to `<output>/logs/normalize-YYYYMMDD-HHMMSS.log`.
- `<output>/normalize.log` is a symlink to the current run's log, so `tail -f normalize.log` always tracks the active run.
- Existing output files are skipped, which is what makes Ctrl+C / rerun cheap.

## License

[The Unlicense](LICENSE) — public domain. Do anything you want with this; no attribution required.
