#!/usr/bin/env bash
# Emits JSON for waybar with CPU usage %, temp, and a sparkline of recent
# samples. Run by waybar every interval; state files in /tmp persist history.
set -eu

HIST=/tmp/waybar-cpu-hist
LAST=/tmp/waybar-cpu-last
N=12   # sparkline length (samples)

# --- CPU usage from /proc/stat delta ---
read -r _ user nice sys idle iowait irq softirq _ < /proc/stat
cur_active=$((user + nice + sys + irq + softirq))
cur_total=$((user + nice + sys + idle + iowait + irq + softirq))

prev_active=0; prev_total=0
[[ -f "$LAST" ]] && read -r prev_active prev_total < "$LAST"
echo "$cur_active $cur_total" > "$LAST"

usage=0
if (( cur_total > prev_total )); then
    usage=$(( 100 * (cur_active - prev_active) / (cur_total - prev_total) ))
fi

# --- CPU temp from k10temp hwmon (AMD) or coretemp (Intel) ---
temp=0
for hw in /sys/class/hwmon/hwmon*; do
    name=$(cat "$hw/name" 2>/dev/null) || continue
    if [[ "$name" == "k10temp" || "$name" == "coretemp" || "$name" == "zenpower" ]]; then
        t=$(cat "$hw/temp1_input" 2>/dev/null) || continue
        temp=$((t / 1000))
        break
    fi
done

# --- Sparkline history ---
spark=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
hist=$(cat "$HIST" 2>/dev/null || true)
hist+=" $usage"
hist=$(echo "$hist" | awk -v n=$N '{
    for (i = NF - n + 1; i <= NF; i++) if (i > 0) printf "%s ", $i
}')
echo "$hist" > "$HIST"

graph=""
for v in $hist; do
    idx=$(( v * 8 / 100 ))
    (( idx > 7 )) && idx=7
    (( idx < 0 )) && idx=0
    graph+="${spark[$idx]}"
done

# --- Class for CSS coloring ---
class="cpu"
(( usage >= 80 || temp >= 80 )) && class="cpu warning"
(( usage >= 95 || temp >= 90 )) && class="cpu critical"

text=$(printf ' %s  %d%% %d°C' "$graph" "$usage" "$temp")
tooltip=$(printf 'CPU: %d%% usage\nTemp: %d°C\nLast %d samples' "$usage" "$temp" "$N")

jq -nc --arg text "$text" --arg tt "$tooltip" --arg cls "$class" \
    '{text: $text, tooltip: $tt, class: $cls}'
