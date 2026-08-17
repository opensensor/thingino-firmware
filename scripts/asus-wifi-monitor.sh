#!/bin/bash
# Host-side, read-only Broadcom wl monitor for Asuswrt-Merlin routers.
# shellcheck disable=SC2029  # Commands are intentionally executed on the router.

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: asus-wifi-monitor.sh [OPTIONS]

Capture channel occupancy and per-station Wi-Fi statistics from an
Asuswrt-Merlin router without changing radio configuration.

Options:
  --router USER@HOST       SSH destination (default: matteius@192.168.50.1)
  --radio IFACE            Physical wl interface (default: eth10)
  --bss IFACE              BSS interface to inspect; repeatable
                           (defaults: eth10 and wl3.1)
  --nvram-prefix PREFIX    Radio NVRAM prefix (default: wl3)
  --samples COUNT          Number of samples (default: 12)
  --interval SECONDS       Delay between samples (default: 5)
  --ping-target HOST       Ping target to correlate; repeatable
  --output-dir DIR         Output directory
  -h, --help               Show this help

The monitor does not run active scans, reset counters, or write NVRAM.
SSH key authentication must already work for the router.
EOF
}

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

valid_iface() {
	case "$1" in
		*[!A-Za-z0-9._-]* | "") return 1 ;;
		*) return 0 ;;
	esac
}

ROUTER="matteius@192.168.50.1"
RADIO="eth10"
NVRAM_PREFIX="wl3"
SAMPLES=12
INTERVAL=5
OUTPUT_DIR="./wifi-monitor-$(date +%Y%m%d-%H%M%S)"
BSS_INTERFACES=()
PING_TARGETS=()

while [ "$#" -gt 0 ]; do
	case "$1" in
		--router)
			ROUTER=${2:-}
			shift 2
			;;
		--radio)
			RADIO=${2:-}
			shift 2
			;;
		--bss)
			BSS_INTERFACES+=("${2:-}")
			shift 2
			;;
		--nvram-prefix)
			NVRAM_PREFIX=${2:-}
			shift 2
			;;
		--samples)
			SAMPLES=${2:-}
			shift 2
			;;
		--interval)
			INTERVAL=${2:-}
			shift 2
			;;
		--ping-target)
			PING_TARGETS+=("${2:-}")
			shift 2
			;;
		--output-dir)
			OUTPUT_DIR=${2:-}
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			fail "unknown argument: $1"
			;;
	esac
done

case "$SAMPLES" in
	"" | *[!0-9]* | 0) fail "--samples must be a positive integer" ;;
esac
case "$INTERVAL" in
	"" | *[!0-9]*) fail "--interval must be a non-negative integer" ;;
esac
valid_iface "$RADIO" || fail "invalid radio interface: $RADIO"
valid_iface "$NVRAM_PREFIX" || fail "invalid NVRAM prefix: $NVRAM_PREFIX"

if [ "${#BSS_INTERFACES[@]}" -eq 0 ]; then
	BSS_INTERFACES=("$RADIO" "wl3.1")
fi
for iface in "${BSS_INTERFACES[@]}"; do
	valid_iface "$iface" || fail "invalid BSS interface: $iface"
done

require_cmd awk
require_cmd ping
require_cmd ssh

SSH_OPTIONS=(
	-o BatchMode=yes
	-o ConnectTimeout=8
	-o ServerAliveInterval=10
	-o ServerAliveCountMax=2
)

umask 077
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

METADATA_FILE="$OUTPUT_DIR/metadata.txt"
RAW_FILE="$OUTPUT_DIR/raw-samples.log"
CHANIM_FILE="$OUTPUT_DIR/chanim.csv"
STATIONS_FILE="$OUTPUT_DIR/stations.csv"
PING_FILE="$OUTPUT_DIR/ping.csv"
STATION_SUMMARY_FILE="$OUTPUT_DIR/station-summary.csv"
RADIO_SUMMARY_FILE="$OUTPUT_DIR/radio-summary.txt"

printf 'epoch,utc,radio,channel,tx_pct,inbss_pct,obss_pct,nocat_pct,nopkt_pct,doze_pct,txop_pct,goodtx_pct,badtx_pct,glitch,badplcp,noise_dbm,idle_pct,busy_pct,driver_timestamp\n' >"$CHANIM_FILE"
printf 'epoch,utc,bss,mac,ip,hostname,rssi_dbm,rx_bytes,rx_packets,rx_retried,last_rx_kbps,tx_retries,tx_retry_exhausted\n' >"$STATIONS_FILE"
printf 'epoch,utc,target,status,rtt_ms\n' >"$PING_FILE"

{
	printf 'capture_started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'router=%s\n' "$ROUTER"
	printf 'radio=%s\n' "$RADIO"
	printf 'nvram_prefix=%s\n' "$NVRAM_PREFIX"
	printf 'bss_interfaces=%s\n' "${BSS_INTERFACES[*]}"
	printf 'samples=%s\n' "$SAMPLES"
	printf 'interval_seconds=%s\n' "$INTERVAL"
	printf 'ping_targets=%s\n' "${PING_TARGETS[*]:-}"
} >"$METADATA_FILE"

ssh "${SSH_OPTIONS[@]}" "$ROUTER" sh -s -- "$RADIO" "$NVRAM_PREFIX" "${BSS_INTERFACES[@]}" >>"$METADATA_FILE" <<'REMOTE_METADATA'
set -eu

radio=$1
nvram_prefix=$2
shift 2

printf 'router_uname=%s\n' "$(uname -a)"
printf 'router_uptime=%s\n' "$(uptime)"
for key in productid buildno extendno firmver qos_enable runner_disable fc_disable "${nvram_prefix}_chanspec" "${nvram_prefix}_bw" "${nvram_prefix}_bw_cap" "${nvram_prefix}_nmode" "${nvram_prefix}_wme" "${nvram_prefix}_wme_no_ack" "${nvram_prefix}_atf" "${nvram_prefix}_ampdu" "${nvram_prefix}_amsdu" "${nvram_prefix}_reg_mode" "${nvram_prefix}_country_code"; do
	printf 'nvram_%s=%s\n' "$key" "$(nvram get "$key")"
done

printf '\nradio_status\n'
wl -i "$radio" status 2>&1 || true
printf '\nchannel_stats\n'
wl -i "$radio" chanim_stats 2>&1 || true

for iface in "$@"; do
	printf '\nassociations_%s\n' "$iface"
	wl -i "$iface" assoclist 2>&1 || true
done

if command -v wg >/dev/null 2>&1; then
	for wg_iface in wgs1 wg0; do
		if wg show "$wg_iface" >/dev/null 2>&1; then
			printf '\nwireguard_%s_latest_handshakes\n' "$wg_iface"
			wg show "$wg_iface" latest-handshakes 2>&1 || true
			printf 'wireguard_%s_transfer\n' "$wg_iface"
			wg show "$wg_iface" transfer 2>&1 || true
			printf 'wireguard_%s_endpoints\n' "$wg_iface"
			wg show "$wg_iface" endpoints 2>&1 || true
		fi
	done
fi
REMOTE_METADATA

sample_router() {
	ssh "${SSH_OPTIONS[@]}" "$ROUTER" sh -s -- "$RADIO" "${BSS_INTERFACES[@]}" <<'REMOTE_SAMPLE'
set -eu

radio=$1
shift
epoch=$(date +%s)
utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

wl -i "$radio" chanim_stats 2>/dev/null | awk -v epoch="$epoch" -v utc="$utc" -v radio="$radio" '
	NR > 2 && NF >= 16 {
		printf "CHANIM|%s|%s|%s", epoch, utc, radio
		for (field = 1; field <= 16; field++)
			printf "|%s", $field
		printf "\n"
		exit
	}'

for iface in "$@"; do
	wl -i "$iface" assoclist 2>/dev/null | awk '{print $2}' | while IFS= read -r mac; do
		[ -n "$mac" ] || continue
		info=$(wl -i "$iface" sta_info "$mac" 2>/dev/null || true)
		rssi=$(printf '%s\n' "$info" | awk '/smoothed rssi:/ {print $3; exit}')
		rx_bytes=$(printf '%s\n' "$info" | awk '/rx data bytes:/ {print $4; exit}')
		rx_packets=$(printf '%s\n' "$info" | awk '/rx data pkts:/ {print $4; exit}')
		rx_retried=$(printf '%s\n' "$info" | awk '/rx total pkts retried:/ {print $5; exit}')
		last_rx_kbps=$(printf '%s\n' "$info" | awk '/rate of last rx pkt:/ {print $6; exit}')
		tx_retries=$(printf '%s\n' "$info" | awk '/tx pkts retries:/ {print $4; exit}')
		tx_exhausted=$(printf '%s\n' "$info" | awk '/tx pkts retry exhausted:/ {print $5; exit}')
		ip=$(ip neigh show 2>/dev/null | awk -v wanted="$mac" 'tolower($0) ~ tolower(wanted) {print $1; exit}')
		hostname=
		if [ -r /var/lib/misc/dnsmasq.leases ]; then
			hostname=$(awk -v wanted="$mac" 'tolower($2) == tolower(wanted) {print $4; exit}' /var/lib/misc/dnsmasq.leases)
		fi
		hostname=$(printf '%s' "$hostname" | tr ',|' '__')
		printf 'STATION|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
			"$epoch" "$utc" "$iface" "$mac" "${ip:--}" "${hostname:--}" "${rssi:-0}" \
			"${rx_bytes:-0}" "${rx_packets:-0}" "${rx_retried:-0}" "${last_rx_kbps:-0}" \
			"${tx_retries:-0}" "${tx_exhausted:-0}"
	done

	wl -i "$iface" rx_report -noreset 2>/dev/null | while IFS= read -r line; do
		printf 'RXREPORT|%s|%s|%s|%s\n' "$epoch" "$utc" "$iface" "$line"
	done
done
REMOTE_SAMPLE
}

sample_ping() {
	local epoch utc target ping_output rtt
	epoch=$(date +%s)
	utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	target=$1
	if ping_output=$(ping -n -c 1 -W 1 "$target" 2>/dev/null); then
		rtt=$(printf '%s\n' "$ping_output" | awk -F'time=' '/time=/{split($2, value, " "); print value[1]; exit}')
		printf '%s,%s,%s,ok,%s\n' "$epoch" "$utc" "$target" "${rtt:-0}" >>"$PING_FILE"
	else
		printf '%s,%s,%s,timeout,\n' "$epoch" "$utc" "$target" >>"$PING_FILE"
	fi
}

for ((sample = 1; sample <= SAMPLES; sample++)); do
	printf 'sample %d/%d\n' "$sample" "$SAMPLES"
	snapshot=$(sample_router)
	printf '%s\n' "$snapshot" >>"$RAW_FILE"
	printf '%s\n' "$snapshot" | awk -F'|' '
		$1 == "CHANIM" {
			printf "%s,%s,%s", $2, $3, $4
			for (field = 5; field <= 20; field++)
				printf ",%s", $field
			printf "\n"
		}' >>"$CHANIM_FILE"
	printf '%s\n' "$snapshot" | awk -F'|' '
		$1 == "STATION" {
			printf "%s", $2
			for (field = 3; field <= 14; field++)
				printf ",%s", $field
			printf "\n"
		}' >>"$STATIONS_FILE"

	for target in "${PING_TARGETS[@]}"; do
		sample_ping "$target"
	done

	if [ "$sample" -lt "$SAMPLES" ]; then
		sleep "$INTERVAL"
	fi
done

awk -F',' '
	NR == 1 { next }
	{
		key = $3 SUBSEP $4
		if (!(key in first_epoch)) {
			first_epoch[key] = $1
			first_bytes[key] = $8
			first_retries[key] = $10
			bss[key] = $3
			mac[key] = $4
			ip[key] = $5
			hostname[key] = $6
			rssi_min[key] = $7
			rssi_max[key] = $7
		}
		last_epoch[key] = $1
		last_bytes[key] = $8
		last_retries[key] = $10
		last_phy[key] = $11
		rssi_sum[key] += $7
		rssi_count[key]++
		if ($7 < rssi_min[key]) rssi_min[key] = $7
		if ($7 > rssi_max[key]) rssi_max[key] = $7
	}
	END {
		print "bss,mac,ip,hostname,elapsed_seconds,upload_mbps,rssi_avg_dbm,rssi_min_dbm,rssi_max_dbm,last_rx_phy_mbps,rx_retry_delta"
		for (key in first_epoch) {
			elapsed = last_epoch[key] - first_epoch[key]
			mbps = elapsed > 0 ? (last_bytes[key] - first_bytes[key]) * 8 / elapsed / 1000000 : 0
			printf "%s,%s,%s,%s,%d,%.3f,%.1f,%d,%d,%.1f,%d\n", bss[key], mac[key], ip[key], hostname[key], elapsed, mbps, rssi_sum[key] / rssi_count[key], rssi_min[key], rssi_max[key], last_phy[key] / 1000, last_retries[key] - first_retries[key]
		}
	}' "$STATIONS_FILE" | sort >"$STATION_SUMMARY_FILE"

awk -F',' '
	NR == 1 { next }
	{
		count++
		tx += $5
		inbss += $6
		obss += $7
		idle += $17
		busy += $18
		if ($18 > busy_max) busy_max = $18
	}
	END {
		if (count == 0) {
			print "no channel samples captured"
			exit
		}
		printf "samples=%d\n", count
		printf "tx_avg_pct=%.1f\n", tx / count
		printf "inbss_avg_pct=%.1f\n", inbss / count
		printf "obss_avg_pct=%.1f\n", obss / count
		printf "idle_avg_pct=%.1f\n", idle / count
		printf "busy_avg_pct=%.1f\n", busy / count
		printf "busy_max_pct=%.1f\n", busy_max
	}' "$CHANIM_FILE" >"$RADIO_SUMMARY_FILE"

printf 'capture complete: %s\n' "$OUTPUT_DIR"
printf 'radio summary:\n'
cat "$RADIO_SUMMARY_FILE"
