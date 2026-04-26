#!/bin/bash
#
# normy.sh — Batch EBU R128 loudness normalization for MP3 collections.
#
# Wraps FFmpeg's two-pass loudnorm filter with a single-pass fallback,
# preserves folder structure, source sample rates, and (by default) source
# bitrates so old low-bitrate archives don't get bloated 10x by a fixed
# 320k re-encode. Resumable on Ctrl+C — partially-encoded files are never
# left behind to confuse the skip-if-exists check on the next run.
#
# Usage:
#   ./normy.sh                                  # interactive prompts
#   ./normy.sh /path/to/mp3s                    # CLI: source only
#   ./normy.sh /path/to/mp3s /path/to/output    # CLI: source + output
#

# ── Tunables ──────────────────────────────────────────────────────────────────

TARGET_I=-16          # Target integrated loudness (LUFS) — good for spoken word
TARGET_TP=-1.5        # True peak ceiling (dBTP)
TARGET_LRA=11         # Loudness range target (LU)

# Encoding mode:
#   "preserve" — match each file's source bitrate, with $BITRATE_FLOOR floor.
#                Best for archive material where source bitrates vary widely
#                and you don't want to inflate small files.
#   "vbr"      — LAME VBR with quality $VBR_QUALITY (0=best, 9=worst).
#                Best for podcast/voice workflows on consistently-sourced material.
ENCODE_MODE="preserve"
BITRATE_FLOOR=96      # kbps — sources below this are bumped up (avoids
                      # generation-loss artifacts when re-encoding 32k/64k files)
VBR_QUALITY=4         # ~165k avg, good for spoken word

# Files exceeding this many decoder errors are flagged in the run summary —
# they encoded successfully but the output may have audible glitches.
DECODE_WARN_THRESHOLD=50

HISTORY_FILE="$HOME/.normy_history"

# ── Preflight ─────────────────────────────────────────────────────────────────

for cmd in ffmpeg ffprobe python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd not found." >&2
    case "$cmd" in
      ffmpeg|ffprobe) echo "Install via your package manager (e.g. 'brew install ffmpeg' or 'apt install ffmpeg')." >&2 ;;
      python3)        echo "python3 is required for parsing FFmpeg's loudnorm JSON output." >&2 ;;
    esac
    exit 1
  fi
done

# ── Helpers ───────────────────────────────────────────────────────────────────

# Expand a leading ~ to $HOME (read -p does not do this for us).
expand_tilde() {
  local p="$1"
  echo "${p/#\~/$HOME}"
}

# Format seconds as a compact human duration: 1h23m, 4m12s, 32s.
format_duration() {
  local s=$1
  if [ "$s" -lt 0 ]; then s=0; fi
  local h=$((s / 3600))
  local m=$(((s % 3600) / 60))
  local sec=$((s % 60))
  if [ $h -gt 0 ]; then
    printf "%dh%dm" $h $m
  elif [ $m -gt 0 ]; then
    printf "%dm%ds" $m $sec
  else
    printf "%ds" $sec
  fi
}

describe_encoding() {
  if [ "$ENCODE_MODE" = "vbr" ]; then
    echo "VBR -q:a ${VBR_QUALITY}"
  else
    echo "preserve source (floor ${BITRATE_FLOOR}k)"
  fi
}

read_history() {
  LAST_SRC=""
  LAST_OUT=""
  if [ -f "$HISTORY_FILE" ]; then
    LAST_SRC=$(grep "^src=" "$HISTORY_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    LAST_OUT=$(grep "^out=" "$HISTORY_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
  fi
}

write_history() {
  {
    echo "src=$SRC_DIR_ABS"
    echo "out=$OUT_DIR_ABS"
  } > "$HISTORY_FILE" 2>/dev/null || true
}

prompt_for_dirs() {
  read_history

  local input default_out

  while true; do
    if [ -n "$LAST_SRC" ]; then
      read -p "Source dir [$LAST_SRC]: " input
      SRC_DIR="${input:-$LAST_SRC}"
    else
      read -p "Source dir: " input
      SRC_DIR="$input"
    fi
    SRC_DIR=$(expand_tilde "$SRC_DIR")
    if [ -z "$SRC_DIR" ]; then
      echo "  Source is required."
      continue
    fi
    if [ ! -d "$SRC_DIR" ]; then
      echo "  Not a directory: $SRC_DIR"
      LAST_SRC=""
      continue
    fi
    break
  done

  if [ -n "$LAST_OUT" ]; then
    default_out="$LAST_OUT"
  else
    default_out="${SRC_DIR%/}/normalized"
  fi
  read -p "Output dir [$default_out]: " input
  OUT_DIR=$(expand_tilde "${input:-$default_out}")
}

# Robust loudnorm JSON parser. Reads ffmpeg stderr from stdin, prints
# "input_i input_tp input_lra input_thresh target_offset" or exits non-zero.
parse_loudnorm_json() {
  python3 -c "
import sys, json, re
text = sys.stdin.read()
match = re.search(r'\{[^}]*\"input_i\"[^}]*\}', text, re.DOTALL)
if not match:
    sys.exit(1)
try:
    data = json.loads(match.group())
    vals = [data.get('input_i', ''), data.get('input_tp', ''),
            data.get('input_lra', ''), data.get('input_thresh', ''),
            data.get('target_offset', '')]
    if all(v != '' for v in vals):
        print(' '.join(str(v) for v in vals))
    else:
        sys.exit(1)
except (json.JSONDecodeError, KeyError):
    sys.exit(1)
" 2>/dev/null
}

# Source bitrate in kbps. Tries stream-level, falls back to format-level.
# Echoes empty string if undetectable.
detect_bitrate_kbps() {
  local f="$1"
  local br
  br=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate \
       -of csv=p=0 "$f" 2>/dev/null)
  if [ -z "$br" ] || [ "$br" = "N/A" ]; then
    br=$(ffprobe -v error -show_entries format=bit_rate \
         -of csv=p=0 "$f" 2>/dev/null)
  fi
  if [[ ! "$br" =~ ^[0-9]+$ ]]; then
    echo ""
    return 1
  fi
  echo $(( (br + 500) / 1000 ))
}

detect_sample_rate() {
  local f="$1"
  local rate
  rate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate \
         -of csv=p=0 "$f" 2>/dev/null)
  if [[ ! "$rate" =~ ^[0-9]+$ ]]; then
    rate="44100"
  fi
  echo "$rate"
}

# ── Resolve source/output paths ───────────────────────────────────────────────

SRC_DIR=""
OUT_DIR=""

if [ "$#" -ge 1 ]; then
  SRC_DIR=$(expand_tilde "$1")
  if [ "$#" -ge 2 ]; then
    OUT_DIR=$(expand_tilde "$2")
  fi
elif [ -t 0 ]; then
  prompt_for_dirs
else
  echo "Usage: $0 [SRC_DIR] [OUT_DIR]" >&2
  echo "Run interactively (no args, attached terminal) for prompts." >&2
  exit 1
fi

SRC_DIR="${SRC_DIR%/}"
if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: Source directory does not exist: $SRC_DIR" >&2
  exit 1
fi

OUT_DIR="${OUT_DIR:-${SRC_DIR}/normalized}"
OUT_DIR="${OUT_DIR%/}"
mkdir -p "$OUT_DIR" || { echo "ERROR: Cannot create output directory: $OUT_DIR" >&2; exit 1; }

SRC_DIR_ABS=$(cd "$SRC_DIR" && pwd)
OUT_DIR_ABS=$(cd "$OUT_DIR" && pwd)

# Per-run timestamped logs in $OUT_DIR/logs/, with $OUT_DIR/normalize.log
# kept as a symlink to the current run's log. Previous runs' logs are
# preserved so you can review history after a long batch.
LOG_DIR="${OUT_DIR_ABS}/logs"
mkdir -p "$LOG_DIR" || { echo "ERROR: Cannot create log directory: $LOG_DIR" >&2; exit 1; }
RUN_TS=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/normalize-${RUN_TS}.log"
ln -sf "logs/normalize-${RUN_TS}.log" "${OUT_DIR_ABS}/normalize.log" 2>/dev/null

write_history

# ── Sweep stale .tmp files left from prior interrupted/crashed runs ───────────
# Recorded silently here; surfaced to console + log after the run header below.

STALE_COUNT=$(find "$OUT_DIR_ABS" -type f -iname "*.mp3.tmp" 2>/dev/null | wc -l | tr -d ' ')
if [ "$STALE_COUNT" -gt 0 ]; then
  find "$OUT_DIR_ABS" -type f -iname "*.mp3.tmp" -delete 2>/dev/null
fi

# ── Build file list ───────────────────────────────────────────────────────────

FILE_LIST=$(mktemp)
ERR_TMP=$(mktemp)
trap 'rm -f "$FILE_LIST" "$ERR_TMP"' EXIT

find "$SRC_DIR_ABS" -type f -iname "*.mp3" -not -path "${OUT_DIR_ABS}/*" -print0 | sort -z > "$FILE_LIST"

TOTAL=$(LC_ALL=C tr -dc '\000' < "$FILE_LIST" | wc -c | tr -d ' ')
if [ "$TOTAL" -eq 0 ]; then
  echo "No mp3 files found in: $SRC_DIR_ABS" >&2
  exit 1
fi

# ── Header ────────────────────────────────────────────────────────────────────

echo "=== normy ===" | tee "$LOG_FILE"
echo "Source:   $SRC_DIR_ABS" | tee -a "$LOG_FILE"
echo "Output:   $OUT_DIR_ABS" | tee -a "$LOG_FILE"
echo "Files:    $TOTAL" | tee -a "$LOG_FILE"
echo "Target:   ${TARGET_I} LUFS" | tee -a "$LOG_FILE"
echo "Encoding: $(describe_encoding)" | tee -a "$LOG_FILE"
echo "Started:  $(date)" | tee -a "$LOG_FILE"
echo "=============" | tee -a "$LOG_FILE"

if [ "$STALE_COUNT" -gt 0 ]; then
  echo "Cleaned up $STALE_COUNT stale temp file(s) from a previous run." | tee -a "$LOG_FILE"
fi

# ── Interrupt handling ────────────────────────────────────────────────────────
#
# Single Ctrl+C: finish gracefully — break out of the loop, clean up the
# in-progress .tmp, write the summary so the user knows where to resume.
# Double Ctrl+C: force quit immediately.

INTERRUPTED=0
on_interrupt() {
  if [ "$INTERRUPTED" -eq 1 ]; then
    echo ""
    echo "Force quitting."
    exit 130
  fi
  INTERRUPTED=1
  echo ""
  echo "Stopping after current file (Ctrl+C again to force quit)..."
}
trap on_interrupt INT TERM

# ── Main loop ─────────────────────────────────────────────────────────────────

COUNT=0
SUCCESS=0
WARNED=0          # successful encodes that hit DECODE_WARN_THRESHOLD
FAILED=0
SKIPPED=0
ATTEMPTED=0       # files we actually ran ffmpeg on (used for ETA averaging)
TIME_PROCESSING=0 # cumulative seconds spent on attempted encodes

declare -a FAILED_FILES=()
declare -a WARNED_FILES=()

RUN_START=$(date +%s)

while IFS= read -r -d '' f; do
  if [ "$INTERRUPTED" -eq 1 ]; then
    break
  fi

  COUNT=$((COUNT + 1))

  REL_PATH="${f#${SRC_DIR_ABS}/}"
  OUTFILE="${OUT_DIR_ABS}/${REL_PATH}"
  OUTDIR_FULL=$(dirname "$OUTFILE")
  OUTFILE_TMP="${OUTFILE}.tmp"

  mkdir -p "$OUTDIR_FULL"

  # Build a running-totals fragment for the line prefix. Counters reflect
  # state BEFORE this file is handled (incremented after the work below).
  # Zeros are omitted so the prefix stays tight on a clean run.
  TOTALS=""
  [ "$SUCCESS" -gt 0 ] && TOTALS+="✓${SUCCESS} "
  [ "$WARNED"  -gt 0 ] && TOTALS+="⚠${WARNED} "
  [ "$FAILED"  -gt 0 ] && TOTALS+="✗${FAILED} "
  [ "$SKIPPED" -gt 0 ] && TOTALS+="⊘${SKIPPED} "
  [ -n "$TOTALS" ] && TOTALS="[${TOTALS% }] "

  if [ -f "$OUTFILE" ]; then
    echo "[${COUNT}/${TOTAL}] ${TOTALS}SKIP: $REL_PATH" | tee -a "$LOG_FILE"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Progress / ETA prefix. Project from time-per-handled-file (attempted +
  # skipped) rather than time-per-attempt, so a heavy resume where most
  # remaining files will skip instantly doesn't get an inflated estimate.
  if [ "$ATTEMPTED" -gt 0 ]; then
    REMAINING=$((TOTAL - COUNT + 1))
    HANDLED=$((ATTEMPTED + SKIPPED))
    ETA_SECONDS=$((TIME_PROCESSING * REMAINING / HANDLED))
    PREFIX="[${COUNT}/${TOTAL}] ${TOTALS}[ETA $(format_duration $ETA_SECONDS)]"
  else
    PREFIX="[${COUNT}/${TOTAL}] ${TOTALS}[ETA --]"
  fi
  echo "$PREFIX $REL_PATH" | tee -a "$LOG_FILE"

  # Validate: must have a readable audio stream
  if ! ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
    -of csv=p=0 "$f" 2>/dev/null | grep -q "audio"; then
    echo "  FAILED (no audio stream): $REL_PATH" | tee -a "$LOG_FILE"
    FAILED=$((FAILED + 1))
    FAILED_FILES+=("$REL_PATH")
    continue
  fi

  SRC_RATE=$(detect_sample_rate "$f")

  # Decide encoding args & description
  if [ "$ENCODE_MODE" = "vbr" ]; then
    ENC_ARGS=(-q:a "$VBR_QUALITY")
    BR_DESC="VBR q=${VBR_QUALITY}"
  else
    SRC_BR=$(detect_bitrate_kbps "$f")
    if [ -z "$SRC_BR" ]; then
      OUT_BR=$BITRATE_FLOOR
      BR_DESC="?k -> ${OUT_BR}k"
    elif [ "$SRC_BR" -lt "$BITRATE_FLOOR" ]; then
      OUT_BR=$BITRATE_FLOOR
      BR_DESC="${SRC_BR}k -> ${OUT_BR}k"
    else
      OUT_BR=$SRC_BR
      BR_DESC="${OUT_BR}k"
    fi
    ENC_ARGS=(-b:a "${OUT_BR}k")
  fi

  FILE_START=$(date +%s)

  # Pass 1 — measure
  MEASURE=$(ffmpeg -nostdin -hide_banner -i "$f" \
    -vn -af "loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:print_format=json" \
    -f null /dev/null 2>&1)

  if [ "$INTERRUPTED" -eq 1 ]; then
    rm -f "$OUTFILE_TMP"
    break
  fi

  PARSED=$(echo "$MEASURE" | parse_loudnorm_json)

  > "$ERR_TMP"
  ENCODE_OK=0
  ENCODE_DESC=""

  if [ -n "$PARSED" ]; then
    INPUT_I=$(echo "$PARSED" | cut -d' ' -f1)
    INPUT_TP=$(echo "$PARSED" | cut -d' ' -f2)
    INPUT_LRA=$(echo "$PARSED" | cut -d' ' -f3)
    INPUT_THRESH=$(echo "$PARSED" | cut -d' ' -f4)
    TARGET_OFFSET=$(echo "$PARSED" | cut -d' ' -f5)

    if ffmpeg -nostdin -hide_banner -loglevel warning -i "$f" \
      -vn -af "loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:measured_I=${INPUT_I}:measured_TP=${INPUT_TP}:measured_LRA=${INPUT_LRA}:measured_thresh=${INPUT_THRESH}:offset=${TARGET_OFFSET}:linear=true" \
      -ar "${SRC_RATE}" "${ENC_ARGS[@]}" -map_metadata 0 -id3v2_version 3 \
      -f mp3 "$OUTFILE_TMP" 2>"$ERR_TMP"; then
      ENCODE_OK=1
      ENCODE_DESC="${INPUT_I} -> ${TARGET_I} LUFS"
    fi
  else
    # Single-pass fallback when measurement fails
    if ffmpeg -nostdin -hide_banner -loglevel warning -i "$f" \
      -vn -af "loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA}" \
      -ar "${SRC_RATE}" "${ENC_ARGS[@]}" -map_metadata 0 -id3v2_version 3 \
      -f mp3 "$OUTFILE_TMP" 2>"$ERR_TMP"; then
      ENCODE_OK=1
      ENCODE_DESC="single-pass -> ${TARGET_I} LUFS"
    fi
  fi

  FILE_ELAPSED=$(($(date +%s) - FILE_START))
  ATTEMPTED=$((ATTEMPTED + 1))
  TIME_PROCESSING=$((TIME_PROCESSING + FILE_ELAPSED))

  # Tally noisy decoder warnings (these flood the log on bad source frames)
  HEADER_MISSING=$(grep -c "Header missing" "$ERR_TMP" 2>/dev/null | tr -d '\n')
  HEADER_MISSING=${HEADER_MISSING:-0}
  INVALID_DATA=$(grep -c "Invalid data found" "$ERR_TMP" 2>/dev/null | tr -d '\n')
  INVALID_DATA=${INVALID_DATA:-0}
  TOTAL_DECODE_ERRS=$((HEADER_MISSING + INVALID_DATA))

  if [ "$ENCODE_OK" -eq 1 ]; then
    # Log a one-line summary of decoder noise instead of dumping the flood,
    # but keep any non-flood lines verbatim (those may indicate real problems).
    {
      if [ "$TOTAL_DECODE_ERRS" -gt 0 ]; then
        echo "  [decode warnings: ${HEADER_MISSING} header missing, ${INVALID_DATA} invalid data]"
      fi
      grep -v -E "Header missing|Invalid data found|Estimating duration|Trying to remove|Error submitting packet" "$ERR_TMP" 2>/dev/null
    } >> "$LOG_FILE"

    mv "$OUTFILE_TMP" "$OUTFILE"
    SUCCESS=$((SUCCESS + 1))

    WARN_TAG=""
    if [ "$TOTAL_DECODE_ERRS" -ge "$DECODE_WARN_THRESHOLD" ]; then
      WARN_TAG=" [! ${TOTAL_DECODE_ERRS} decode warnings]"
      WARNED_FILES+=("$REL_PATH (${TOTAL_DECODE_ERRS} warnings)")
      WARNED=$((WARNED + 1))
    fi

    echo "  OK (${ENCODE_DESC}, ${BR_DESC} @ ${SRC_RATE}Hz) in $(format_duration $FILE_ELAPSED)${WARN_TAG}" | tee -a "$LOG_FILE"
  else
    rm -f "$OUTFILE_TMP"
    if [ "$INTERRUPTED" -eq 1 ]; then
      echo "  Interrupted before completion." | tee -a "$LOG_FILE"
      break
    fi
    # Same flood-suppression as the success path: tally decoder noise as a
    # one-liner, but keep non-flood lines verbatim so the actual failure
    # reason is preserved in the log.
    {
      if [ "$TOTAL_DECODE_ERRS" -gt 0 ]; then
        echo "  [decode warnings: ${HEADER_MISSING} header missing, ${INVALID_DATA} invalid data]"
      fi
      grep -v -E "Header missing|Invalid data found|Estimating duration|Trying to remove|Error submitting packet" "$ERR_TMP" 2>/dev/null
    } >> "$LOG_FILE"
    echo "  FAILED (encoding error): $REL_PATH" | tee -a "$LOG_FILE"
    FAILED=$((FAILED + 1))
    FAILED_FILES+=("$REL_PATH")
  fi

done < "$FILE_LIST"

# Defensive sweep: catch any .tmp the loop didn't get to clean up itself.
find "$OUT_DIR_ABS" -type f -iname "*.mp3.tmp" -delete 2>/dev/null

# ── Summary ───────────────────────────────────────────────────────────────────

TOTAL_ELAPSED=$(($(date +%s) - RUN_START))

echo "" | tee -a "$LOG_FILE"
if [ "$INTERRUPTED" -eq 1 ]; then
  echo "=== Interrupted ===" | tee -a "$LOG_FILE"
  echo "Stopped at file ${COUNT}/${TOTAL}." | tee -a "$LOG_FILE"
  echo "Re-run with the same paths to resume — partially-encoded file was discarded." | tee -a "$LOG_FILE"
else
  echo "=== Done ===" | tee -a "$LOG_FILE"
fi
echo "Finished:  $(date)" | tee -a "$LOG_FILE"
echo "Elapsed:   $(format_duration $TOTAL_ELAPSED)" | tee -a "$LOG_FILE"
echo "Total:     ${TOTAL}" | tee -a "$LOG_FILE"
echo "Success:   ${SUCCESS}" | tee -a "$LOG_FILE"
echo "Skipped:   ${SKIPPED}" | tee -a "$LOG_FILE"
echo "Failed:    ${FAILED}" | tee -a "$LOG_FILE"
echo "Output:    ${OUT_DIR_ABS}" | tee -a "$LOG_FILE"

if [ ${#FAILED_FILES[@]} -gt 0 ]; then
  echo "" | tee -a "$LOG_FILE"
  echo "Failed files:" | tee -a "$LOG_FILE"
  for ff in "${FAILED_FILES[@]}"; do
    echo "  - $ff" | tee -a "$LOG_FILE"
  done
fi

if [ ${#WARNED_FILES[@]} -gt 0 ]; then
  echo "" | tee -a "$LOG_FILE"
  echo "Files with significant decode warnings (output may have audible glitches):" | tee -a "$LOG_FILE"
  for wf in "${WARNED_FILES[@]}"; do
    echo "  - $wf" | tee -a "$LOG_FILE"
  done
fi

if [ "$INTERRUPTED" -eq 1 ]; then
  exit 130
fi
