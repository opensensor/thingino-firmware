# Asus Wi-Fi monitoring

`scripts/asus-wifi-monitor.sh` is a host-side, read-only monitor for the
Broadcom `wl` driver shipped by Asuswrt-Merlin. It is intended to distinguish
router or tunnel failures from Wi-Fi airtime congestion affecting Thingino
cameras.

The monitor deliberately does not run `wl scan`, reset driver counters, write
NVRAM, or change an interface. It requires SSH key access to the router.

## Example

```bash
scripts/asus-wifi-monitor.sh \
  --router matteius@192.168.50.1 \
  --radio eth10 \
  --bss eth10 \
  --bss wl3.1 \
  --samples 60 \
  --interval 5 \
  --ping-target 192.168.52.1 \
  --ping-target 192.168.52.170
```

The output directory contains:

- `metadata.txt`: firmware, radio configuration, associations, and safe
  WireGuard status fields.
- `chanim.csv`: physical-channel transmit, in-BSS, neighboring-BSS, idle, and
  busy percentages.
- `stations.csv`: station RSSI, receive byte counters, PHY rate, and retries.
- `raw-samples.log`: raw `wl rx_report -noreset` output for detailed airtime
  and MCS analysis.
- `ping.csv`: optional latency probes correlated to the samples.
- `station-summary.csv`: computed upload rates and RSSI/retry deltas.
- `radio-summary.txt`: average and peak channel occupancy.

VLANs and virtual BSS interfaces on one physical radio share the same airtime.
Pass every BSS on the radio so the report accounts for all stations. For
example, `eth10` and `wl3.1` are separate BSS interfaces but share the same
2.4 GHz channel on the GT-AXE16000.

