#!/bin/sh
# Runs a heavy job (the language model) with a watchdog, so it can never take the
# Kindle down with it:
#
#   ai-guard.sh <max seconds> <command...>
#
# - The kernel kills the job first if memory runs out (oom_score_adj 1000).
# - Its address space is capped (AI_MAX_MB, 450 MB by default), so a model too big
#   fails to load instead of squeezing everything else out. Mapped weights count
#   toward it, so a mapped model needs it raised.
# - Every second: if free memory drops under AI_MIN_FREE_MB (150), the chip passes
#   70 °C, the battery passes 42 °C, or the time is up, the job is killed outright.
#   SIGKILL, not SIGTERM: a process stuck in the memory squeeze never handles one.
# Each kill is logged to AI_LOG with why. Exit status: the job's, or 137 if killed.
max_s=$1
shift
min_free_kb=$((${AI_MIN_FREE_MB:-150} * 1024))
max_kb=$((${AI_MAX_MB:-450} * 1024))
log=${AI_LOG:-/mnt/us/noface/ai.log}

# In a process group of its own (setsid, same pid), so a kill takes everything it
# started too, not just a wrapping shell
(
    echo 1000 > /proc/self/oom_score_adj
    ulimit -v "$max_kb"
    exec setsid "$@"
) &
job=$!

reason=
t=0
while kill -0 "$job" 2>/dev/null; do
    free_kb=$(awk '/^MemAvailable/ {print $2}' /proc/meminfo)
    soc=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
    bat=$(cat /sys/class/thermal/thermal_zone1/temp 2>/dev/null || echo 0)
    if [ "$free_kb" -lt "$min_free_kb" ]; then reason="memory low: $((free_kb / 1024)) MB free"
    elif [ "$soc" -gt 70000 ]; then reason="chip hot: $((soc / 1000)) C"
    elif [ "$bat" -gt 42000 ]; then reason="battery hot: $((bat / 1000)) C"
    elif [ "$t" -ge "$max_s" ]; then reason="over time: ${max_s} s"
    fi
    if [ -n "$reason" ]; then
        kill -9 -"$job" 2>/dev/null || kill -9 "$job" 2>/dev/null
        echo "$(date '+%F %T') ai-guard killed $1: $reason" >> "$log"
        wait "$job" 2>/dev/null
        exit 137
    fi
    sleep 1
    t=$((t + 1))
done
wait "$job"
