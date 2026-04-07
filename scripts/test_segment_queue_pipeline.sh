#!/bin/bash

set -euo pipefail

on_error() {
  local exit_code=$?
  echo "Error: command failed at line $1" >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/Back Channel.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/Backchannel"
FFMPEG_BIN="$APP_BUNDLE/Contents/Resources/bin/ffmpeg"

SOURCE_URL="${SOURCE_URL:-https://www.youtube.com/watch?v=x5vvRMWuWWw}"
TEST_SECONDS="${TEST_SECONDS:-240}"
BUFFER_SECONDS="${BUFFER_SECONDS:-15}"
APP_MODE="${APP_MODE:-compatible}"
INTERNAL_PIPELINE_MODE="${INTERNAL_PIPELINE_MODE:-segment-queue}"
MAX_STAGED_EXCESS_SECONDS="${MAX_STAGED_EXCESS_SECONDS:-8}"
SPEED_FLOOR="${SPEED_FLOOR:-0.995}"
SPEED_CEILING="${SPEED_CEILING:-1.005}"
SPEED_GRACE_OUTPUT_SECONDS="${SPEED_GRACE_OUTPUT_SECONDS:-20}"
SPEED_STARTUP_WINDOW_SECONDS="${SPEED_STARTUP_WINDOW_SECONDS:-20}"
MAX_SPEED_OUT_OF_BAND_SAMPLES="${MAX_SPEED_OUT_OF_BAND_SAMPLES:-3}"
MAX_PACKET_CORRUPT_LINES="${MAX_PACKET_CORRUPT_LINES:-0}"
RTMP_URL="${RTMP_URL:-rtmp://127.0.0.1:1935/live/test}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/dist/test-artifacts/segment-queue-$TIMESTAMP}"
APP_LOG="$ARTIFACT_DIR/app.log"
RECV_LOG="$ARTIFACT_DIR/receiver.log"
SUMMARY_FILE="$ARTIFACT_DIR/summary.txt"

APP_PID=""
RECV_PID=""

cleanup() {
  if [[ -n "${APP_PID}" ]]; then
    kill "${APP_PID}" 2>/dev/null || true
    wait "${APP_PID}" 2>/dev/null || true
  fi
  if [[ -n "${RECV_PID}" ]]; then
    kill "${RECV_PID}" 2>/dev/null || true
    wait "${RECV_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$ARTIFACT_DIR"

if [[ ! -x "$APP_BIN" ]]; then
  echo "Missing app binary: $APP_BIN" >&2
  exit 1
fi

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "Missing bundled ffmpeg: $FFMPEG_BIN" >&2
  exit 1
fi

echo "Artifacts: $ARTIFACT_DIR"
echo "Source: $SOURCE_URL"
echo "Duration: ${TEST_SECONDS}s"
echo "RTMP: $RTMP_URL"
echo "App mode: $APP_MODE"
echo "Pipeline mode: $INTERNAL_PIPELINE_MODE"

python3 -u - "$FFMPEG_BIN" "$RTMP_URL" >"$RECV_LOG" 2>&1 <<'PY' &
import subprocess
import sys
import time

ffmpeg_bin = sys.argv[1]
rtmp_url = sys.argv[2]

cmd = [
    ffmpeg_bin,
    "-hide_banner",
    "-loglevel", "info",
    "-listen", "1",
    "-timeout", "60",
    "-i", rtmp_url,
    "-c", "copy",
    "-f", "null", "-",
    "-progress", "pipe:2",
]

proc = subprocess.Popen(
    cmd,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    bufsize=1,
    errors="replace",
)

try:
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(f"{time.time():.6f} {line}")
        sys.stdout.flush()
finally:
    if proc.stdout is not None:
        proc.stdout.close()

sys.exit(proc.wait())
PY
RECV_PID=$!

sleep 1

BACKCHANNEL_INTERNAL_PIPELINE="$INTERNAL_PIPELINE_MODE" \
  "$APP_BIN" \
  --source-url "$SOURCE_URL" \
  --format rtmp \
  --rtmp-url "$RTMP_URL" \
  --mode "$APP_MODE" \
  --buffer-seconds "$BUFFER_SECONDS" \
  --disk-buffer true \
  --extended-logging false \
  --auto-start \
  >"$APP_LOG" 2>&1 &
APP_PID=$!

sleep "$TEST_SECONDS"

kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

kill "$RECV_PID" 2>/dev/null || true
wait "$RECV_PID" 2>/dev/null || true
RECV_PID=""

transient_stalls=$(grep -c "Short output stall recovered" "$APP_LOG" || true)
buffer_exhausted=$(grep -c "Buffer exhausted" "$APP_LOG" || true)
output_stall_restart=$(grep -c "Output appears stalled" "$APP_LOG" || true)
freeze_restart=$(grep -c "Visual freeze persisted" "$APP_LOG" || true)
queue_write_fail=$(grep -c "Queue publisher write failed" "$APP_LOG" || true)
prototype_enabled=$(grep -c "Experimental queue publisher enabled" "$APP_LOG" || true)
supervised_remux_enabled=$(grep -c "Streamlink supervisor remux active" "$APP_LOG" || true)
supervised_transcode_enabled=$(grep -c "Streamlink supervisor transcode active" "$APP_LOG" || true)
yt_eof=$(grep -c "IO error: End of file" "$APP_LOG" || true)
queue_trim_count=$(grep -c "Queued delay grew to" "$APP_LOG" || true)

receiver_connected=0
if grep -q "Input #0" "$RECV_LOG"; then
  receiver_connected=1
fi

max_stall_gap=$(awk '
  function to_secs(ts) {
    split(ts, parts, ":")
    return (parts[1] * 3600) + (parts[2] * 60) + parts[3]
  }
  /\[app\] Short output stall recovered after/ {
    if (match($0, /\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]/)) {
      ts = substr($0, RSTART + 1, 8)
      seconds = to_secs(ts)
      if (last > 0) {
        gap = seconds - last
        if (gap < 0) { gap += 86400 }
        if (gap > max_gap) { max_gap = gap }
      }
      last = seconds
    }
  }
  END {
    if (max_gap == "") { max_gap = 0 }
    print max_gap
  }
' "$APP_LOG")

progress_line_count=$(grep -c "\\[app\\] ffmpeg progress:" "$APP_LOG" || true)
packet_corrupt_lines=$(grep -c "Packet corrupt" "$APP_LOG" || true)
max_staged_seconds=$(python3 - "$APP_LOG" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="ignore")
values = [float(match) for match in re.findall(r"staged=([0-9]+(?:\.[0-9]+)?)s", text)]
print(max(values) if values else 0)
PY
)
allowed_max_staged=$(python3 - <<PY
buffer_seconds = float("${BUFFER_SECONDS}")
max_excess = float("${MAX_STAGED_EXCESS_SECONDS}")
print(buffer_seconds + max_excess)
PY
)
speed_metrics=$(python3 - "$RECV_LOG" "$SPEED_GRACE_OUTPUT_SECONDS" "$SPEED_STARTUP_WINDOW_SECONDS" "$SPEED_FLOOR" "$SPEED_CEILING" <<'PY'
import re
import sys
from pathlib import Path

grace_seconds = float(sys.argv[2])
startup_window_seconds = float(sys.argv[3])
speed_floor = float(sys.argv[4])
speed_ceiling = float(sys.argv[5])
line_pattern = re.compile(r"^([0-9]+(?:\.[0-9]+)?)\s+(.*)$")

def parse_out_time(value: str) -> float:
    hours, minutes, seconds = value.split(":")
    return (int(hours) * 3600) + (int(minutes) * 60) + float(seconds)

text = Path(sys.argv[1]).read_text(errors="ignore").splitlines()
samples = []
current_out_time = None
current_wall_time = None
previous_wall_time = None
overall_samples = []
startup_samples = []
steady_state_samples = []

for line in text:
    match = line_pattern.match(line)
    if not match:
        continue
    current_wall_time = float(match.group(1))
    body = match.group(2)

    if body.startswith("out_time="):
        try:
            next_out_time = parse_out_time(body.split("=", 1)[1].strip())
        except Exception:
            current_out_time = None
            continue
        if current_out_time is not None and previous_wall_time is not None:
            wall_delta = current_wall_time - previous_wall_time
            media_delta = next_out_time - current_out_time
            if wall_delta > 0 and next_out_time >= grace_seconds:
                speed = media_delta / wall_delta
                overall_samples.append(speed)
                if next_out_time < grace_seconds + startup_window_seconds:
                    startup_samples.append(speed)
                else:
                    steady_state_samples.append(speed)
        previous_wall_time = current_wall_time
        current_out_time = next_out_time

def summarize(samples):
    if not samples:
        return ("0", "0", "0", "0")
    out_of_band = sum(1 for sample in samples if sample < speed_floor or sample > speed_ceiling)
    return (f"{min(samples)}", f"{max(samples)}", f"{out_of_band}", f"{len(samples)}")

print(" ".join(summarize(overall_samples) + summarize(startup_samples) + summarize(steady_state_samples)))
PY
)
read -r \
  min_speed_after_grace max_speed_after_grace speed_out_of_band_samples speed_sample_count \
  startup_min_speed startup_max_speed startup_speed_out_of_band_samples startup_speed_sample_count \
  steady_min_speed steady_max_speed steady_speed_out_of_band_samples steady_speed_sample_count \
  <<< "$speed_metrics"

window_metrics=$(python3 - "$RECV_LOG" "$SPEED_GRACE_OUTPUT_SECONDS" <<'PY'
import re
import sys
from pathlib import Path

grace_seconds = float(sys.argv[2])
line_pattern = re.compile(r"^([0-9]+(?:\.[0-9]+)?)\s+(.*)$")

def parse_out_time(value: str) -> float:
    hours, minutes, seconds = value.split(":")
    return (int(hours) * 3600) + (int(minutes) * 60) + float(seconds)

def summarize_window(samples, window):
    if not samples:
        return ("0", "0", "0", "0", "0", "0")
    values = []
    for index, (start_wall, start_media) in enumerate(samples):
        end_index = index
        while end_index + 1 < len(samples) and samples[end_index + 1][0] - start_wall < window:
            end_index += 1
        end_wall, end_media = samples[end_index]
        wall_delta = end_wall - start_wall
        if wall_delta >= window * 0.7:
            values.append((end_media - start_media) / wall_delta)
    if not values:
        return ("0", "0", "0", "0", "0", "0")
    values.sort()
    def quantile(p):
        return values[min(len(values) - 1, max(0, int(len(values) * p)))]
    return (
        str(len(values)),
        f"{values[0]}",
        f"{quantile(0.10)}",
        f"{quantile(0.50)}",
        f"{quantile(0.90)}",
        f"{values[-1]}",
    )

text = Path(sys.argv[1]).read_text(errors="ignore").splitlines()
current_wall_time = None
monotonic_samples = []
last_out_time = None

for line in text:
    match = line_pattern.match(line)
    if not match:
        continue
    current_wall_time = float(match.group(1))
    body = match.group(2)
    if not body.startswith("out_time="):
        continue
    try:
        next_out_time = parse_out_time(body.split("=", 1)[1].strip())
    except Exception:
        continue
    if next_out_time < grace_seconds:
        continue
    if last_out_time is None or next_out_time > last_out_time:
        monotonic_samples.append((current_wall_time, next_out_time))
        last_out_time = next_out_time

end_media = monotonic_samples[-1][1] - 3.0 if monotonic_samples else 0.0
steady_samples = [sample for sample in monotonic_samples if sample[1] <= end_media]

results = []
for window in (5.0, 8.0, 10.0):
    results.extend(summarize_window(steady_samples, window))
print(" ".join(results))
PY
)
read -r \
  window5_count window5_min window5_p10 window5_median window5_p90 window5_max \
  window8_count window8_min window8_p10 window8_median window8_p90 window8_max \
  window10_count window10_min window10_p10 window10_median window10_p90 window10_max \
  <<< "$window_metrics"

{
  echo "prototype_enabled=$prototype_enabled"
  echo "supervised_remux_enabled=$supervised_remux_enabled"
  echo "supervised_transcode_enabled=$supervised_transcode_enabled"
  echo "receiver_connected=$receiver_connected"
  echo "progress_line_count=$progress_line_count"
  echo "transient_stalls=$transient_stalls"
  echo "buffer_exhausted=$buffer_exhausted"
  echo "output_stall_restart=$output_stall_restart"
  echo "freeze_restart=$freeze_restart"
  echo "queue_write_fail=$queue_write_fail"
  echo "queue_trim_count=$queue_trim_count"
  echo "yt_eof=$yt_eof"
  echo "packet_corrupt_lines=$packet_corrupt_lines"
  echo "max_gap_between_stall_logs=$max_stall_gap"
  echo "max_staged_seconds=$max_staged_seconds"
  echo "allowed_max_staged_seconds=$allowed_max_staged"
  echo "min_speed_after_grace=$min_speed_after_grace"
  echo "max_speed_after_grace=$max_speed_after_grace"
  echo "speed_out_of_band_samples=$speed_out_of_band_samples"
  echo "speed_sample_count=$speed_sample_count"
  echo "startup_window_seconds=$SPEED_STARTUP_WINDOW_SECONDS"
  echo "startup_min_speed=$startup_min_speed"
  echo "startup_max_speed=$startup_max_speed"
  echo "startup_speed_out_of_band_samples=$startup_speed_out_of_band_samples"
  echo "startup_speed_sample_count=$startup_speed_sample_count"
  echo "steady_min_speed=$steady_min_speed"
  echo "steady_max_speed=$steady_max_speed"
  echo "steady_speed_out_of_band_samples=$steady_speed_out_of_band_samples"
  echo "steady_speed_sample_count=$steady_speed_sample_count"
  echo "window5_count=$window5_count"
  echo "window5_min=$window5_min"
  echo "window5_p10=$window5_p10"
  echo "window5_median=$window5_median"
  echo "window5_p90=$window5_p90"
  echo "window5_max=$window5_max"
  echo "window8_count=$window8_count"
  echo "window8_min=$window8_min"
  echo "window8_p10=$window8_p10"
  echo "window8_median=$window8_median"
  echo "window8_p90=$window8_p90"
  echo "window8_max=$window8_max"
  echo "window10_count=$window10_count"
  echo "window10_min=$window10_min"
  echo "window10_p10=$window10_p10"
  echo "window10_median=$window10_median"
  echo "window10_p90=$window10_p90"
  echo "window10_max=$window10_max"
} | tee "$SUMMARY_FILE"

fail=0
if [[ "$prototype_enabled" -eq 0 && "$supervised_remux_enabled" -eq 0 && "$supervised_transcode_enabled" -eq 0 ]]; then
  echo "FAIL: rebroadcast pipeline did not activate" | tee -a "$SUMMARY_FILE"
  fail=1
fi
if [[ "$receiver_connected" -eq 0 ]]; then
  echo "FAIL: receiver never connected" | tee -a "$SUMMARY_FILE"
  fail=1
fi
if [[ "$queue_write_fail" -gt 0 ]]; then
  echo "FAIL: queue publisher write failed" | tee -a "$SUMMARY_FILE"
  fail=1
fi
if [[ "$packet_corrupt_lines" -gt "$MAX_PACKET_CORRUPT_LINES" ]]; then
  echo "FAIL: packet corruption warnings observed ($packet_corrupt_lines)" | tee -a "$SUMMARY_FILE"
  fail=1
fi
if [[ "$output_stall_restart" -gt 0 || "$freeze_restart" -gt 0 ]]; then
  echo "FAIL: hard output freeze recovery triggered" | tee -a "$SUMMARY_FILE"
  fail=1
fi
if [[ "$transient_stalls" -gt 3 ]]; then
  echo "FAIL: too many transient stalls ($transient_stalls)" | tee -a "$SUMMARY_FILE"
  fail=1
fi
if python3 - <<PY
max_staged = float("${max_staged_seconds}")
allowed = float("${allowed_max_staged}")
raise SystemExit(0 if max_staged <= allowed else 1)
PY
then
  :
else
  echo "FAIL: staged delay grew too far ($max_staged_seconds s > $allowed_max_staged s)" | tee -a "$SUMMARY_FILE"
  fail=1
fi
if [[ "$speed_sample_count" -eq 0 ]]; then
  echo "FAIL: no receiver speed samples collected after grace period" | tee -a "$SUMMARY_FILE"
  fail=1
elif [[ "$speed_out_of_band_samples" -gt "$MAX_SPEED_OUT_OF_BAND_SAMPLES" ]]; then
  echo "FAIL: output pace drifted outside ${SPEED_FLOOR}x-${SPEED_CEILING}x for $speed_out_of_band_samples samples" | tee -a "$SUMMARY_FILE"
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "PASS: queue prototype stayed within current thresholds" | tee -a "$SUMMARY_FILE"
