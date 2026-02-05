# NETWORK-ADJUST PROJECT KNOWLEDGE BASE

**Generated:** 2026-02-05 18:03:33  
**Commit:** 2abecd8  
**Branch:** master  
**Type:** Single-file Bash script (1375 lines, 68 functions)

## OVERVIEW

Optimizes Linux ethernet card settings for maximum throughput by tuning queues, ringbuffers, IRQ affinity, RPS/XPS/RFS.

## STRUCTURE

```
network-adjust/
├── linux_ethernet_optimization.sh    # Main script (executable + sourceable)
├── verification-report.md            # AI code logic analysis
├── tests/                            # Test tools and reports
│   ├── test_calc_tools.sh            # Calculator implementation tests
│   ├── verify_functions.sh           # Function verification tool
│   └── *.md                          # Test reports (FINAL_REPORT, etc.)
└── README.md / README.zh-CN.md       # Documentation (bilingual)
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| **Entry point** | `linux_ethernet_optimization.sh` | Both executable and sourceable |
| **Core optimizations** | Functions: `set_ethernet_*_to_optimum` | queue, ringbuffer, irq, rps, xps, rfs |
| **Hardware queries** | Functions: `get_ethernet_*` | ethtool wrappers |
| **CPU mask generation** | `generate_cpus_mask*` | Handles >64 CPU using `calc`/`bc`/`python3` |
| **Filtering logic** | `get_filtered_ethernet_card_list` | Include/exclude by vendor/driver/device/osname |
| **Validation** | Functions: `check_ethernet_*` | Pre-flight checks before optimization |
| **Testing** | `tests/test_calc_tools.sh` | 517 tests for calculator implementations |

## KEY CONVENTIONS

### Design Patterns

- **Check-then-set**: Every `set_*` has matching `check_*` function
- **Sourceable**: Script skips `main` if sourced (`is_sourced()`)
- **Systemd-aware**: Detects systemd context via `$INVOCATION_ID`, `$SYSTEMD_EXEC_PID`, `$LAUNCHED_BY_SYSTEMD`
- **Dry-run first**: Shows changes → asks confirmation → applies

### CPU Mask Handling

- **Problem**: Bash can't handle numbers >64 CPUs with `printf "%x"`
- **Solution**: Uses `calc`/`bc`/`python3` with automatic fallback
- **Format**: Comma every 8 hex chars (`format_cpumask`)
- **Fallback chain**: bash (≤64 CPU) → bc → python3 → calc

### Hardware-Specific Quirks

- **mlx5 cards**: Report 2× queues (normal + XSK). Script divides by 2 in `get_ethernet_kernel_queues_number`
- **mlx5 IRQ format**: `mlx5_comp<queue>@pci:<id>` requires special parsing
- **Most drivers**: IRQ name ends with `-<queue>` or `@<queue>`

## ANTI-PATTERNS (THIS PROJECT)

1. **RFS disabled by default** (line 756-834)
   - **Reason**: Hash collisions cause `ksoftirq` CPU 100%, random FW bugs, ping jitter
   - **Never enable** unless specifically demanded
   - Comment block at line 804-815 explains production risk

2. **Don't use `-i` flag in `ethtool`**
   - Interactive mode not supported in script context

3. **Don't optimize virtual devices**
   - `get_physical_ethernet_card_list` filters `/sys/class/net/*/virtual/*`
   - Also excludes virtualization drivers: `virtio_net`, `veth`, `vmxnet3`, `xen-netfront`, `hv_netvsc`

4. **Bash version >=4 required**
   - Uses `${VAR,,}` lowercase conversion (line 171, 246, 321)
   - Uses `extglob` pattern `##*([0,])` (line 476)

5. **DO NOT change critical design decisions**
   - Line 11-14: 6 design decisions marked "DO NOT change behavior"
   - Changing these will break production deployments

## DEPENDENCIES

**Hard requirements** (checked by `check_script_requrements`):
- `ethtool` - NIC configuration tool
- `lspci` - PCI device lister
- `grep`, `sed` (GNU version), `column` - Text processing

**Optional requirements**:
- `calc`, `bc`, or `python3` - Arbitrary precision calculator
  - **Only needed** for systems with >64 CPUs
  - Fallback chain: `bc` → `python3` → `calc`
  - ≤64 CPUs: bash built-in arithmetic is sufficient

**Runtime requirements**:
- Root permission (`check_root`)
- Physical ethernet cards with `/sys/class/net/<dev>/device/` entries

## COMMANDS

```bash
# Check current status (dry-run)
./linux_ethernet_optimization.sh -n

# Apply all optimizations without asking
./linux_ethernet_optimization.sh -y

# Optimize only Intel and Broadcom cards, exclude i40e driver
./linux_ethernet_optimization.sh -v Intel -v Broadcom -D i40e

# Include/exclude specific actions
./linux_ethernet_optimization.sh -y -a queue -a ringbuffer -A rfs

# Source for function reuse
source ./linux_ethernet_optimization.sh
set_ethernet_rps_to_optimum eth0
```

## OPTIONS SUMMARY

| Flag | Purpose | Example |
|------|---------|---------|
| `-n` | Dry-run (show changes, don't apply) | `-n` |
| `-y` | Assume yes (no confirmation prompts) | `-y` |
| `-a <action>` | Include action (queue/ringbuffer/irq/rps/xps/rfs) | `-a queue` |
| `-A <action>` | Exclude action | `-A rfs` |
| `-e <name>` | Include ethernet by OS name (exact match) | `-e enp4s0` |
| `-E <name>` | Exclude ethernet by OS name | `-E enp4s0` |
| `-i <device>` | Include by device name (partial, case-insensitive) | `-i X722` |
| `-I <device>` | Exclude by device name | `-I X710` |
| `-d <driver>` | Include by driver (exact match) | `-d i40e` |
| `-D <driver>` | Exclude by driver | `-D ixgbe` |
| `-v <vendor>` | Include by vendor (partial, case-insensitive) | `-v Intel` |
| `-V <vendor>` | Exclude by vendor | `-V Broadcom` |

## OPTIMIZATION LOGIC

### Queue (`-a queue`)

**Target**: `min(CPU cores, max hardware queues)`  
**Why**: More queues = better parallelism, but >CPU cores wastes resources

### Ringbuffer (`-a ringbuffer`)

**Target**: Hardware max for RX and TX  
**Why**: Larger buffer reduces packet drops under burst

### IRQ Affinity (`-a irq`)

**Target**: Spread IRQs across CPUs (round-robin)  
**Why**: Avoid single-CPU bottleneck for interrupt handling

### RPS (Receive Packet Steering) (`-a rps`)

**Logic**:
- Queues < CPUs → Enable (spread load)
- Queues >= CPUs → Disable (hardware already spreads)

### XPS (Transmit Packet Steering) (`-a xps`)

**Same as RPS** for TX queues

### RFS (Receive Flow Steering) (`-a rfs`)

**ALWAYS DISABLED** (see Anti-patterns #1)

## GOTCHAS

1. **Optimization resets NIC** (500ms-30s disconnect)
   - Script sleeps 10s between cards to avoid dual-reset in bonding setup (line 1338)
   - Skip sleep if run by systemd (boot-time)

2. **HIGH-THROUGHPUT focus**
   - **WARNING** (line 1046): Designed ONLY for high-throughput environments
   - **WARNING** (line 1053): Maximum throughput = more CPU usage + INCREASED latency
   - Not suitable for low-latency requirements

3. **`calc` mode syntax**
   - `run_calc hex "2 ^ 64 - 1"` → hex output
   - Prefix removed by `${result##"${prefix}"}` (line 360)

4. **Mask comparison strips leading zeros**
   - `mask_is_equal` uses `##*([0,])` to ignore `0,0,0,0,ffff` vs `ffff` (line 476)

5. **Exit code propagation in subshell**
   - Line 1271: `kill $$` instead of `exit 0` because subshell exit doesn't affect parent

6. **`ethtool -l` parsing fragility**
   - Relies on exact strings "Pre-set maximums:" and "Current hardware settings:"
   - Different NIC firmware may break this (lines 204-232)

## USAGE NOTES

- **Idempotent**: Re-running won't harm if already optimized
- **Persistent across reboots?** **NO** - add to systemd service for persistence
- **systemd-networkd alternative**: Modern systemd (v248+) supports `RxBufferSize=max`, `TxBufferSize=max`, `RxChannels=max`, `TxChannels=max`, `CombinedChannels=max`, `OtherChannels=max` in `.link` files (line 933-936)
- **Virtual NICs**: Script excludes virtual and virtualization drivers

## TESTING

- **Calculator tests**: `tests/test_calc_tools.sh` - 517 tests, 97.5% pass rate
- **Function verification**: `tests/verify_functions.sh`
- **Test reports**: See `tests/FINAL_REPORT.md` for comprehensive results

## RELATED DOCS

- **Verification report**: `verification-report.md` - AI code logic analysis
- **Kernel docs**: `man 7 cpuset` (CPU mask format)
- **systemd**: `man 5 systemd.link` (networkd config)
