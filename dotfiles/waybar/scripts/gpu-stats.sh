#!/usr/bin/env bash
# Emits JSON for waybar with AMD GPU usage %, temp, and a sparkline.
# Auto-picks the dGPU (largest VRAM) if more than one amdgpu card is present.
set -eu

HIST=/tmp/waybar-gpu-hist
N=12

# --- Find the discrete AMD GPU (largest VRAM) ---
GPU_DIR=""
best_vram=0
for d in /sys/class/drm/card*/device; do
    drv=$(readlink -f "$d/driver" 2>/dev/null | xargs basename 2>/dev/null) || continue
    [[ "$drv" == "amdgpu" ]] || continue
    [[ -f "$d/gpu_busy_percent" ]] || continue
    vram=$(cat "$d/mem_info_vram_total" 2>/dev/null || echo 0)
    if (( vram > best_vram )); then
        best_vram=$vram
        GPU_DIR=$d
    fi
done

if [[ -z "$GPU_DIR" ]]; then
    jq -nc '{text: "󰢮 n/a", tooltip: "no amdgpu device found", class: "gpu"}'
    exit 0
fi

usage=$(cat "$GPU_DIR/gpu_busy_percent" 2>/dev/null || echo 0)

# Temp from hwmon under the device.
temp=0
for hw in "$GPU_DIR/hwmon/"hwmon*; do
    [[ -f "$hw/temp1_input" ]] || continue
    t=$(cat "$hw/temp1_input")
    temp=$((t / 1000))
    break
done

# VRAM use for the tooltip.
vram_used=$(cat "$GPU_DIR/mem_info_vram_used" 2>/dev/null || echo 0)
vram_pct=0
(( best_vram > 0 )) && vram_pct=$(( vram_used * 100 / best_vram ))
vram_gb=$(awk -v b="$best_vram" 'BEGIN { printf "%.1f", b / 1073741824 }')

# --- Sparkline ---
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

class="gpu"
(( usage >= 80 || temp >= 80 )) && class="gpu warning"
(( usage >= 95 || temp >= 90 )) && class="gpu critical"

text=$(printf '󰢮 %s  %d%% %d°C' "$graph" "$usage" "$temp")
tooltip=$(printf 'GPU: %d%% busy\nTemp: %d°C\nVRAM: %d%% of %s GB\nDevice: %s' \
    "$usage" "$temp" "$vram_pct" "$vram_gb" "$(basename "$(dirname "$GPU_DIR")")")

jq -nc --arg text "$text" --arg tt "$tooltip" --arg cls "$class" \
    '{text: $text, tooltip: $tt, class: $cls}'
