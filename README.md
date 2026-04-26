# normy

Batch loudness normalization for MP3 collections. Wraps FFmpeg's two-pass `loudnorm` filter (EBU R128) with a single-pass fallback, preserves your folder structure, and skips files that already exist in the output directory so reruns are safe.

Built for normalizing variable-quality archive material — old radio recordings, podcasts, audiobooks — where source bitrates, sample rates, and volumes are all over the map.

## Requirements

- `ffmpeg` and `ffprobe` (`brew install ffmpeg`)
- `python3` (used for parsing FFmpeg's loudnorm JSON output)

## Usage

```sh
./normy.sh /path/to/mp3s [/path/to/output]
```

If you omit the output path, normy writes to a `normalized/` subfolder inside the source directory.

## Defaults

| Setting           | Value      | Notes                                  |
| ----------------- | ---------- | -------------------------------------- |
| Target loudness   | `-16 LUFS` | Spoken-word friendly (R128 broadcast)  |
| True peak ceiling | `-1.5 dBTP`|                                        |
| Loudness range    | `11 LU`    |                                        |
| Bitrate           | `320k`     |                                        |
| Sample rate       | source     | Preserved per-file from the input      |

Edit the `TARGET_*` and `BITRATE` variables near the top of `normy.sh` to change.

## Output

- Files mirror the source directory structure under the output dir.
- `normalize.log` is written to the output dir with per-file results and FFmpeg warnings.
- Existing output files are skipped (safe to rerun after interruption).
