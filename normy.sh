#!/bin/bash
#
# normalize.sh — Batch EBU R128 loudness normalization for mp3 collections
# Two-pass FFmpeg loudnorm for best results, single-pass fallback
#
# Usage: ./normalize.sh /path/to/your/mp3s [/path/to/output]
#
# If no output path given, creates a "normalized" subfolder in the source dir.
# Recursively finds mp3s and preserves subfolder structure in the output.
#

# ── Preflight checks ──────────────────────────────────────────────────────────

if ! command -v ffmpeg &>/dev/null; then
  echo "ERROR: ffmpeg not found. Install with: brew install ffmpeg"
  exit 1
fi

if ! command -v ffprobe &>/dev/null; then
  echo "ERROR: ffprobe not found. Install with: brew install ffmpeg"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 not found (needed for JSON parsing)"
  exit 1
fi

SRC_DIR="${1:-.}"

# Strip trailing slashes so path math works
SRC_DIR="${SRC_DIR%/}"

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: Source directory does not exist: $SRC_DIR"
  exit 1
fi

OUT_DIR="${2:-${SRC_DIR}/normalized}"
OUT_DIR="${OUT_DIR%/}"

# Create and resolve output dir to an absolute path
mkdir -p "$OUT_DIR" || { echo "ERROR: Cannot create output directory: $OUT_DIR"; exit 1; }
OUT_DIR_ABS=$(cd "$OUT_DIR" && pwd)

# Also resolve source dir to absolute so prefix stripping always works
SRC_DIR_ABS=$(cd "$SRC_DIR" && pwd)

LOG_FILE="${OUT_DIR_ABS}/normalize.log"

# ── Normalization settings ────────────────────────────────────────────────────

TARGET_I=-16      # Target integrated loudness (LUFS) — good for spoken word
TARGET_TP=-1.5    # True peak ceiling (dBTP)
TARGET_LRA=11     # Loudness range target (LU)
BITRATE="320k"    # Output bitrate

# ── Build file list ───────────────────────────────────────────────────────────

# Use a temp file for the file list so nothing can eat it from stdin
FILE_LIST=$(mktemp)
trap 'rm -f "$FILE_LIST"' EXIT

find "$SRC_DIR_ABS" -type f -iname "*.mp3" -not -path "${OUT_DIR_ABS}/*" | sort > "$FILE_LIST"

TOTAL=$(wc -l < "$FILE_LIST" | tr -d ' ')
if [ "$TOTAL" -eq 0 ]; then
  echo "No mp3 files found in: $SRC_DIR_ABS"
  exit 1
fi

# ── JSON parser (avoids fragile grep chains) ──────────────────────────────────

parse_loudnorm_json() {
  # Extracts loudnorm JSON values robustly using python3
  # Reads from stdin, outputs space-separated: input_i input_tp input_lra input_thresh target_offset
  python3 -c "
import sys, json, re

text = sys.stdin.read()

# Find the JSON object in ffmpeg's output
match = re.search(r'\{[^}]*\"input_i\"[^}]*\}', text, re.DOTALL)
if not match:
    sys.exit(1)

try:
    data = json.loads(match.group())
    vals = [
        data.get('input_i', ''),
        data.get('input_tp', ''),
        data.get('input_lra', ''),
        data.get('input_thresh', ''),
        data.get('target_offset', '')
    ]
    if all(v != '' for v in vals):
        print(' '.join(str(v) for v in vals))
    else:
        sys.exit(1)
except (json.JSONDecodeError, KeyError):
    sys.exit(1)
" 2>/dev/null
}

# ── Main loop ─────────────────────────────────────────────────────────────────

echo "=== Art Bell Normalizer ===" | tee "$LOG_FILE"
echo "Source:  $SRC_DIR_ABS" | tee -a "$LOG_FILE"
echo "Output:  $OUT_DIR_ABS" | tee -a "$LOG_FILE"
echo "Files:   $TOTAL" | tee -a "$LOG_FILE"
echo "Target:  ${TARGET_I} LUFS @ ${BITRATE}" | tee -a "$LOG_FILE"
echo "Started: $(date)" | tee -a "$LOG_FILE"
echo "=========================" | tee -a "$LOG_FILE"

COUNT=0
FAILED=0
SKIPPED=0

while IFS= read -r f; do
  COUNT=$((COUNT + 1))

  # Compute relative path for output mirroring
  REL_PATH="${f#${SRC_DIR_ABS}/}"
  REL_DIR=$(dirname "$REL_PATH")
  BASENAME=$(basename "$f")
  OUTDIR_FULL="${OUT_DIR_ABS}/${REL_DIR}"
  OUTFILE="${OUTDIR_FULL}/${BASENAME}"

  mkdir -p "$OUTDIR_FULL"

  # Skip if already processed
  if [ -f "$OUTFILE" ]; then
    echo "[${COUNT}/${TOTAL}] SKIP: $REL_PATH" | tee -a "$LOG_FILE"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "[${COUNT}/${TOTAL}] Processing: $REL_PATH" | tee -a "$LOG_FILE"

  # ── Validate the file ────────────────────────────────────────────────────
  # Check ffprobe can read it at all
  if ! ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
    -of csv=p=0 "$f" 2>/dev/null | grep -q "audio"; then
    echo "  FAILED (no audio stream or unreadable): $REL_PATH" | tee -a "$LOG_FILE"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Get source sample rate, default to 44100 if detection fails
  SRC_RATE=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=sample_rate -of csv=p=0 "$f" 2>/dev/null)
  SRC_RATE="${SRC_RATE:-44100}"
  # Sanity check: if it's garbage, default
  if ! [[ "$SRC_RATE" =~ ^[0-9]+$ ]]; then
    SRC_RATE="44100"
  fi

  # ── Pass 1: measure loudness ─────────────────────────────────────────────
  MEASURE=$(ffmpeg -nostdin -hide_banner -i "$f" \
    -vn -af loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:print_format=json \
    -f null /dev/null 2>&1)

  PARSED=$(echo "$MEASURE" | parse_loudnorm_json)

  if [ -n "$PARSED" ]; then
    # Two-pass: apply with measured values
    INPUT_I=$(echo "$PARSED" | cut -d' ' -f1)
    INPUT_TP=$(echo "$PARSED" | cut -d' ' -f2)
    INPUT_LRA=$(echo "$PARSED" | cut -d' ' -f3)
    INPUT_THRESH=$(echo "$PARSED" | cut -d' ' -f4)
    TARGET_OFFSET=$(echo "$PARSED" | cut -d' ' -f5)

    if ffmpeg -nostdin -hide_banner -loglevel warning -i "$f" \
      -vn -af loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:measured_I=${INPUT_I}:measured_TP=${INPUT_TP}:measured_LRA=${INPUT_LRA}:measured_thresh=${INPUT_THRESH}:offset=${TARGET_OFFSET}:linear=true \
      -ar "${SRC_RATE}" -ab "$BITRATE" -map_metadata 0 -id3v2_version 3 \
      "$OUTFILE" 2>>"$LOG_FILE"; then
      echo "  OK (${INPUT_I} -> ${TARGET_I} LUFS @ ${SRC_RATE}Hz)" | tee -a "$LOG_FILE"
    else
      echo "  FAILED (encoding error): $REL_PATH" | tee -a "$LOG_FILE"
      rm -f "$OUTFILE"  # Clean up partial output
      FAILED=$((FAILED + 1))
    fi
  else
    # Measurement failed — try single-pass as fallback
    echo "  WARN: Measurement failed, trying single-pass" | tee -a "$LOG_FILE"
    if ffmpeg -nostdin -hide_banner -loglevel warning -i "$f" \
      -vn -af loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA} \
      -ar "${SRC_RATE}" -ab "$BITRATE" -map_metadata 0 -id3v2_version 3 \
      "$OUTFILE" 2>>"$LOG_FILE"; then
      echo "  OK (single-pass @ ${SRC_RATE}Hz)" | tee -a "$LOG_FILE"
    else
      echo "  FAILED (single-pass also failed): $REL_PATH" | tee -a "$LOG_FILE"
      rm -f "$OUTFILE"  # Clean up partial output
      FAILED=$((FAILED + 1))
    fi
  fi

done < "$FILE_LIST"

# ── Summary ───────────────────────────────────────────────────────────────────

SUCCESS=$((COUNT - FAILED - SKIPPED))
echo "" | tee -a "$LOG_FILE"
echo "=== Done ===" | tee -a "$LOG_FILE"
echo "Finished: $(date)" | tee -a "$LOG_FILE"
echo "Total:     ${TOTAL}" | tee -a "$LOG_FILE"
echo "Success:   ${SUCCESS}" | tee -a "$LOG_FILE"
echo "Skipped:   ${SKIPPED}" | tee -a "$LOG_FILE"
echo "Failed:    ${FAILED}" | tee -a "$LOG_FILE"
echo "Output:    ${OUT_DIR_ABS}" | tee -a "$LOG_FILE"

if [ "$FAILED" -gt 0 ]; then
  echo "" | tee -a "$LOG_FILE"
  echo "Failed files:" | tee -a "$LOG_FILE"
  grep "FAILED" "$LOG_FILE" | grep -v "^Failed:" | tee -a /dev/null
fi
