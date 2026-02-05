# Linux Ethernet Performance Optimization Script

[![GitHub Repository](https://img.shields.io/badge/GitHub-SteamedFish%2Fnetwork--adjust-blue?logo=github)](https://github.com/SteamedFish/network-adjust)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A powerful Bash script for optimizing Linux physical network card performance parameters, significantly improving network performance in high-throughput environments.

> ⚠️ **IMPORTANT: This script is designed ONLY for maximizing throughput in high-throughput network environments. It is NOT suitable for latency-sensitive scenarios (e.g., financial trading, real-time gaming, VoIP). The optimizations may actually INCREASE latency due to larger buffers and batch processing.**

> ⚠️ **DISCLAIMER: This script was originally written several years ago and included some non-universal logic specific to the original environment. AI has been used to remove these environment-specific portions, retain only the universal logic, optimize the code, and write documentation. However, due to changes in work circumstances, all logic in this script has not been fully verified in production. AI has analyzed the code logic for correctness (see [verification-report.md](verification-report.md)), but before executing this script, please carefully read the code to understand what it does to avoid unnecessary risks and losses.**

## Introduction

`linux_ethernet_optimization.sh` is a production-grade script that optimizes Linux network card performance by tuning the following key network parameters:

- **Queue Numbers**: Optimize parallel processing capability of multi-queue NICs
- **Ringbuffer**: Reduce packet drops under high traffic
- **IRQ Affinity**: Balance interrupt load across multiple CPU cores
- **RPS (Receive Packet Steering)**: Software-level receive packet distribution
- **XPS (Transmit Packet Steering)**: Software-level transmit packet distribution
- **RFS (Receive Flow Steering)**: Flow-level CPU affinity (disabled by default)

### Use Cases

- 🚀 High-throughput network environments (data centers, CDN, storage clusters)
- 📦 Bulk data transfer workloads
- 🔧 Multi-queue NIC performance tuning
- 🖥️ Multi-core server network optimization
- 🔄 systemd service integration

### NOT Suitable For

- ❌ Low-latency applications (financial trading, real-time communication)
- ❌ Latency-sensitive workloads (gaming servers, VoIP)
- ❌ Scenarios where response time is more important than throughput

## NUMA-Aware Variant (Experimental)

A NUMA-aware version is available as `linux_ethernet_optimization_numa.sh`.

**⚠️ WARNING: This variant is completely AI-generated and has NOT been tested in production.**

This variant automatically detects each NIC's NUMA node and binds IRQ/RPS/XPS only to CPUs local to that node, avoiding cross-NUMA memory access penalties.

**Key differences from original:**
- Auto-detects NIC's NUMA node from `/sys/class/net/<dev>/device/numa_node`
- Binds IRQ/RPS/XPS only to CPUs local to that NUMA node
- Falls back to original round-robin behavior if NUMA detection fails
- See script header for detailed warnings, testing recommendations, and known limitations

**Recommended for:**
- Multi-socket servers (2+ CPUs with separate NUMA domains)
- Systems where NIC NUMA locality matters for performance
- Users who can thoroughly test before production deployment

**NOT recommended for:**
- Single-socket systems (no NUMA benefit)
- Production use without extensive testing
- Users unfamiliar with NUMA topology

See the script header comments for comprehensive testing procedures and known limitations.

## Features

### 1. Queue Optimization

**Principle**: Multi-queue NICs support distributing network traffic to multiple hardware queues, each can be processed independently, fully utilizing multi-core CPUs.

**Target Value**: `min(CPU cores, max NIC queues)`

**Effects**:
- Improve concurrent processing capability
- Reduce single-core bottleneck
- Enhance overall throughput

```bash
# Example: 8-core CPU, NIC supports 16 queues → set to 8 queues
```

### 2. Ringbuffer Optimization

**Principle**: Ringbuffer is the data buffer between NIC and kernel. Larger buffers reduce packet drops during traffic bursts.

**Target Value**: Hardware maximum (for both RX and TX)

**Effects**:
- Lower packet drop rate (especially during traffic bursts)
- Improve stability
- Adapt to traffic fluctuations

### 3. IRQ Affinity Optimization

**Principle**: Distribute NIC interrupt requests (IRQ) to different CPU cores, avoiding single-core overload.

**Strategy**: Round-robin distribution

**Effects**:
- Balance CPU load
- Avoid interrupt handling bottleneck
- Improve interrupt response speed

**⚠️ NUMA Limitation**: See "Known Limitations" section - IRQ, RPS, and XPS optimizations do NOT consider NUMA topology.

### 4. RPS Optimization

**Principle**: Distribute received packets to multiple CPUs at the software level, compensating for insufficient hardware queues.

**Enable Conditions**:
- ✅ Queues < CPU cores → Enable RPS
- ❌ Queues ≥ CPU cores → Disable RPS (hardware already distributes enough)

**Effects**:
- Improve receive-side parallelism
- Fully utilize all CPU cores
- Reduce CPU idle waste

**⚠️ NUMA Limitation**: See "Important Notes" section - RPS uses all CPUs regardless of NUMA topology.

### 5. XPS Optimization

**Principle**: Similar to RPS but for the transmit side.

**Effects**:
- Improve transmit-side parallelism
- Optimize cache locality

**⚠️ NUMA Limitation**: See "Important Notes" section - XPS uses all CPUs regardless of NUMA topology.

### 6. RFS Optimization

**⚠️ Disabled by Default - Production Environment Risk**

**Reasons for Disabling**:
1. **Hash Collision Issues**: RFS uses hash tables; collisions cause `ksoftirq` CPU usage to spike to 100%
2. **Firmware Bugs**: Some NIC firmware has random RFS-related failures
3. **Latency Fluctuations**: May introduce unpredictable ping latency jitter

**Production Recommendation**: Keep disabled unless specifically needed and thoroughly tested.

```bash
# If you really need to enable (at your own risk)
./linux_ethernet_optimization.sh -y -a rfs
```

## System Requirements

### Dependencies

**Required Dependencies**:
```bash
# Check if installed
command -v ethtool lspci bash grep sed column

# Debian/Ubuntu installation
apt-get install ethtool pciutils bash grep sed coreutils

# CentOS/RHEL installation
yum install ethtool pciutils bash grep sed coreutils
```

**Optional Dependencies (only needed for CPU > 64 cores)**:
- `bc` (recommended, for math calculations)
- `python3` (fallback)
- `calc` (last fallback)

### Permission Requirements

- **Must run as root** (needs to modify `/sys` and `/proc` files)
- Requires physical NICs (virtual NICs and virtualization drivers are automatically excluded)

### Compatibility

- **Bash Version**: >= 4.0
- **Kernel Version**: >= 2.6.35 (supports RPS/RFS features)
- **GNU sed**: Required (BSD sed incompatible)

## Installation

### Download Script

```bash
# Method 1: Clone repository
git clone https://github.com/SteamedFish/network-adjust.git
cd network-adjust

# Method 2: Direct download single file
wget https://raw.githubusercontent.com/SteamedFish/network-adjust/master/linux_ethernet_optimization.sh
chmod +x linux_ethernet_optimization.sh
```

### Verify Dependencies

```bash
# Script automatically checks dependencies, or manually verify
./linux_ethernet_optimization.sh -n
```

## Usage

### Basic Usage

#### 1. Dry Run (Recommended for First Use)

```bash
# Only show operations to be performed, don't actually modify
sudo ./linux_ethernet_optimization.sh -n
```

#### 2. Interactive Optimization

```bash
# Show operations and ask for confirmation
sudo ./linux_ethernet_optimization.sh
```

#### 3. Automatic Optimization (Non-interactive)

```bash
# Automatically execute all optimizations without asking
sudo ./linux_ethernet_optimization.sh -y
```

### Command-Line Options

#### Execution Mode

| Option | Description | Example |
|--------|-------------|---------|
| `-n` | Dry-run mode (show only, don't execute) | `sudo ./script.sh -n` |
| `-y` | Auto-confirm mode (skip interactive prompts) | `sudo ./script.sh -y` |

#### Optimization Control

| Option | Description | Example |
|--------|-------------|---------|
| `-a <action>` | **Include** specified optimization | `-a queue -a ringbuffer` |
| `-A <action>` | **Exclude** specified optimization | `-A rfs` |

**Available action values**:
- `queue` - Queue number optimization
- `ringbuffer` - Ringbuffer optimization
- `irq` - IRQ affinity optimization
- `rps` - RPS optimization
- `xps` - XPS optimization
- `rfs` - RFS optimization (excluded by default)

#### NIC Filtering (by System Name)

| Option | Description | Match Rule | Example |
|--------|-------------|------------|---------|
| `-e <name>` | **Include** specified NIC | Exact match | `-e enp4s0` |
| `-E <name>` | **Exclude** specified NIC | Exact match | `-E enp4s0` |

#### NIC Filtering (by Hardware Device Name)

| Option | Description | Match Rule | Example |
|--------|-------------|------------|---------|
| `-i <device>` | **Include** device name | Partial match, case-insensitive | `-i X722` |
| `-I <device>` | **Exclude** device name | Partial match, case-insensitive | `-I X710` |

#### NIC Filtering (by Driver)

| Option | Description | Match Rule | Example |
|--------|-------------|------------|---------|
| `-d <driver>` | **Include** driver | Exact match | `-d i40e` |
| `-D <driver>` | **Exclude** driver | Exact match | `-D ixgbe` |

#### NIC Filtering (by Vendor)

| Option | Description | Match Rule | Example |
|--------|-------------|------------|---------|
| `-v <vendor>` | **Include** vendor | Partial match, case-insensitive | `-v Intel` |
| `-V <vendor>` | **Exclude** vendor | Partial match, case-insensitive | `-V Broadcom` |

### Usage Examples

#### Example 1: Optimize Only Queue and Ringbuffer

```bash
sudo ./linux_ethernet_optimization.sh -y -a queue -a ringbuffer
```

#### Example 2: Optimize All Intel NICs

```bash
sudo ./linux_ethernet_optimization.sh -y -v Intel
```

#### Example 3: Optimize All NICs Except i40e Driver

```bash
sudo ./linux_ethernet_optimization.sh -y -D i40e
```

#### Example 4: Optimize Only enp4s0, Exclude RFS

```bash
sudo ./linux_ethernet_optimization.sh -y -e enp4s0 -A rfs
```

#### Example 5: Optimize Intel and Broadcom NICs, Exclude ixgbe Driver

```bash
sudo ./linux_ethernet_optimization.sh -y -v Intel -v Broadcom -D ixgbe
```

## systemd Integration

### One-Time Run (Temporary Optimization)

```bash
# Use systemd-run to execute at boot
systemd-run --on-boot=5s /path/to/linux_ethernet_optimization.sh -y
```

### Persistent Configuration (Recommended)

Create systemd service file:

```bash
# Create service file
sudo nano /etc/systemd/system/network-optimization.service
```

```ini
[Unit]
Description=Optimize Ethernet Card Performance
After=network-pre.target
Before=network.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/linux_ethernet_optimization.sh -y
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

# Set environment variable to identify systemd launch (optional)
Environment="LAUNCHED_BY_SYSTEMD=1"

[Install]
WantedBy=multi-user.target
```

Enable service:

```bash
# Copy script to system path
sudo cp linux_ethernet_optimization.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/linux_ethernet_optimization.sh

# Reload systemd configuration
sudo systemctl daemon-reload

# Enable service (auto-start at boot)
sudo systemctl enable network-optimization.service

# Start immediately
sudo systemctl start network-optimization.service

# Check status
sudo systemctl status network-optimization.service
```

### systemd-networkd Alternative

For systems using systemd-networkd, you can persist some configurations via `.link` files:

```bash
# Create link file
sudo nano /etc/systemd/network/10-eth.link
```

```ini
[Match]
MACAddress=xx:xx:xx:xx:xx:xx

[Link]
# Set Ringbuffer size (systemd v246+)
RxBufferSize=max
TxBufferSize=max

# Set queue numbers to maximum (systemd v246+)
RxChannels=max
TxChannels=max
CombinedChannels=max
# OtherChannels=max  # Uncomment if needed
```

**Note**: `.link` files can only configure some parameters; IRQ/RPS/XPS still need script configuration.

## Use as Library (source)

The script can be sourced by other scripts to directly call internal functions:

### Available Functions

#### Optimization Functions

```bash
# RPS optimization
set_ethernet_rps_to_optimum <nic_name>

# XPS optimization
set_ethernet_xps_to_optimum <nic_name>

# Queue number optimization
set_ethernet_queue_to_optimum <nic_name>

# Ringbuffer optimization
set_ethernet_ringbuffer_to_optimum <nic_name>

# IRQ affinity optimization
set_ethernet_irq_affinity_to_optimum <nic_name>

# RFS optimization (use with caution)
set_ethernet_rfs_to_optimum <nic_name>
```

#### Check Functions

```bash
# Check RPS status
check_ethernet_rps <nic_name>

# Check XPS status
check_ethernet_xps <nic_name>

# Check queue configuration
check_ethernet_queue <nic_name>

# Check Ringbuffer configuration
check_ethernet_ringbuffer <nic_name>

# Check IRQ affinity
check_ethernet_irq_affinity <nic_name>

# Check RFS configuration
check_ethernet_rfs <nic_name>
```

#### Query Functions

```bash
# Get NIC hardware queue count
get_ethernet_hardware_queues_number <nic_name>

# Get NIC kernel queue count
get_ethernet_kernel_queues_number <nic_name>

# Get physical NIC list
get_physical_ethernet_card_list

# Generate CPU mask (all CPUs)
generate_cpus_mask <cpu_count>
```

### Usage Example

```bash
#!/bin/bash
# Custom optimization script

# Load function library
source /path/to/linux_ethernet_optimization.sh

# Optimize only eth0's RPS and XPS
set_ethernet_rps_to_optimum eth0
set_ethernet_xps_to_optimum eth0

# Check optimization results
check_ethernet_rps eth0
check_ethernet_xps eth0

echo "Optimization complete"
```

## Troubleshooting

### Common Errors

#### 1. "ERROR: you need root permission"

**Cause**: Script needs root permission to modify system files.

**Solution**:
```bash
sudo ./linux_ethernet_optimization.sh -y
```

#### 2. "ERROR: you need <command> command to run the script"

**Cause**: Missing required system commands.

**Solution**:
```bash
# Debian/Ubuntu
sudo apt-get install ethtool pciutils

# CentOS/RHEL
sudo yum install ethtool pciutils
```

#### 3. "ERROR: you need GNU version of sed"

**Cause**: System uses BSD sed (common on macOS).

**Solution**:
```bash
# macOS install GNU sed
brew install gnu-sed
# Use gsed instead of sed
```

#### 4. Brief Network Disconnection

**Cause**: Modifying NIC parameters requires NIC reset, causing 500ms-30s brief disconnection.

**Solution**:
- Normal behavior, just wait
- In bonding scenarios, script automatically delays 10 seconds to avoid resetting both NICs simultaneously
- Execute during maintenance window to avoid business impact

### Verify Optimization Results

#### 1. Check Queue Numbers

```bash
ethtool -l eth0
```

#### 2. Check Ringbuffer Size

```bash
ethtool -g eth0
```

#### 3. Check IRQ Affinity

```bash
grep eth0 /proc/interrupts
cat /proc/irq/*/smp_affinity_list
```

#### 4. Check RPS/XPS Configuration

```bash
cat /sys/class/net/eth0/queues/rx-0/rps_cpus
cat /sys/class/net/eth0/queues/tx-0/xps_cpus
```

#### 5. Performance Testing

```bash
# Test throughput with iperf3
iperf3 -c <server> -P 8

# Test latency with netperf
netperf -H <server> -t TCP_RR
```

### Rollback Configuration

Optimizations are **lost after reboot**. For immediate rollback:

```bash
# Method 1: Restart NIC
sudo ifdown eth0 && sudo ifup eth0

# Method 2: Reboot system
sudo reboot

# Method 3: Manually restore defaults
# Disable RPS
echo 0 | sudo tee /sys/class/net/eth0/queues/rx-*/rps_cpus

# Disable XPS
echo 0 | sudo tee /sys/class/net/eth0/queues/tx-*/xps_cpus

# Restore default queue count (needs ethtool)
sudo ethtool -L eth0 combined <original_queue_count>
```

## Important Notes

### ⚠️ Warnings

1. **NIC Reset Risk**
   - Modifying parameters causes NIC reset
   - Downtime: 500ms ~ 30 seconds (depends on NIC model)
   - Recommend executing during maintenance window

2. **Bonding Scenario Delay**
   - Script delays 10 seconds between NICs
   - Prevents longer downtime from resetting both ports simultaneously
   - systemd boot scenario skips delay (boot-time optimization)

3. **Configuration Persistence Issue**
   - **Optimizations do NOT persist after reboot**
   - Must use systemd service or cron for persistence
   - Or use systemd-networkd `.link` files (partial parameters)

4. **Virtual NIC Compatibility**
   - Script designed for physical NICs
   - Virtual NICs (veth, bridge, tun/tap) are automatically excluded
   - Virtualization drivers (virtio_net, vmxnet3, xen-netfront, hv_netvsc) are automatically excluded

5. **RFS Disabled by Default**
   - **Strongly recommended to keep disabled in production**
   - Must thoroughly test before enabling to confirm no hash collisions or firmware bugs
   - See "Features" section for detailed RFS explanation

6. **NUMA Affinity Not Considered** ⚠️
   - **Critical limitation on multi-socket servers**
   - **Affected optimizations**: IRQ affinity, RPS, XPS (all use round-robin across ALL CPUs)
   - Does NOT respect NUMA node boundaries
   - **Impact**: On NUMA systems, network processing may occur on remote CPUs, causing:
     - 2-3× memory access latency penalty
     - Reduced throughput due to cross-node traffic
     - Cache inefficiency and increased CPU overhead
   - **Affected systems**: Multi-socket servers (2+ CPUs), AMD EPYC, Intel Xeon multi-socket, any system with multiple NUMA nodes
   - **Workaround**: Manually check NIC's NUMA node and bind IRQ/RPS/XPS to local CPUs:
     ```bash
     # Check NIC's NUMA node
     cat /sys/class/net/eth0/device/numa_node
     # Get local CPUs
     cat /sys/devices/system/node/node0/cpulist
     # Bind IRQ/RPS/XPS to local CPUs only
     ```
   - **Recommendation**: For NUMA systems, use NUMA-aware tuning tools (e.g., `tuned`, `irqbalance --hintpolicy=subset`)

### 💡 Best Practices

1. **Dry-run First for Initial Use**
   ```bash
   sudo ./linux_ethernet_optimization.sh -n
   ```

2. **Verify in Test Environment**
   - Validate effects on test servers first
   - Apply to production only after confirming no issues

3. **Use systemd for Persistence**
   - Create systemd service
   - Set auto-start at boot

4. **Monitor Optimization Effects**
   - Use monitoring tools to observe CPU usage, network throughput
   - Record performance metrics before and after optimization

5. **Gradual Optimization**
   - Optimize single parameters first, observe effects
   - For example, optimize queue and ringbuffer first, then others after confirming stability

## Technical Details

### CPU Mask Calculation

**Challenge**: Bash cannot handle integer arithmetic over 64 bits.

**Solution**: Tiered fallback strategy
```bash
# CPU ≤ 64: Pure Bash bitwise operations
mask=$((2 ** cpus - 1))
printf "%x" "$mask"

# CPU > 64: Try in order
# 1) bc (most common, recommended)
echo "obase=16; 2^$cpus - 1" | bc

# 2) python3 (fallback)
python3 -c "print(hex((2**$cpus)-1)[2:])"

# 3) calc (original solution, last fallback)
calc "hex(2^$cpus - 1)"
```

**Formatting**: Insert comma every 8 hex characters
```
Example: 256 CPUs → ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
Formatted → ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff,ffffffff
```

### mlx5 NIC Special Handling

**Issue**: mlx5e driver reports normal and XSK queues together, doubling queue count.

**Solution**: Auto-detect and divide by 2
```bash
get_ethernet_kernel_queues_number() {
    local ETH=$1
    local queues=$(find /sys/class/net/"${ETH}"/queues/ -type d -name "rx-*" | wc -l)
    
    # mlx5 special handling
    local driver=$(basename "$(readlink /sys/class/net/"${ETH}"/device/driver)")
    if [[ "$driver" == "mlx5_core" ]]; then
        queues=$((queues / 2))
    fi
    
    echo "$queues"
}
```

### IRQ Queue Number Extraction Algorithm

**Most Drivers**: IRQ name format is `<prefix>-<queue>` or `<prefix>@<queue>`
```
Example: eth0-TxRx-0, i40e-eth0@0
Extract: Use sed 's/.*[-@]//'
```

**mlx5 Exception**: Format is `mlx5_comp<queue>@pci:<id>`
```
Example: mlx5_comp0@pci:0000:04:00.0
Extract: Use sed 's/mlx5_comp\([0-9]*\)@.*/\1/'
```

### Design Features

This script uses a modular design with the following characteristics:

1. **Clean Code Organization**
   - Unified sysfs operations via `_sysfs_read()` / `_sysfs_write()`
   - Unified ethtool parsing via `_ethtool_parse()`
   - Filter logic handled by `_filter_list()`
   - Clean main loop logic

2. **Minimal Dependencies**
   - No external tools needed for CPU ≤64 (pure Bash, covers 95% scenarios)
   - CPU >64 supports `bc` / `python3` / `calc` with automatic fallback

3. **Readability First**
   - Detailed comments for complex logic
   - Unified naming conventions
   - Clear constant definitions

4. **Performance Optimized**
   - Minimized subshell invocations
   - Maintains efficient execution speed

5. **Key Design Decisions**
   - RFS disabled by default (see comments for reasoning)
   - mlx5 queue count special handling (/2)
   - Automatic systemd environment detection
   - Sourceable as library
   - >64 CPU mask calculation support
   - 10-second delay for bonding scenarios

## Developer Notes

### Code Structure

```
linux_ethernet_optimization.sh
├── Core logic protection comments
├── Dependency check functions
│   ├── check_script_requirements()
│   ├── check_root()
│   └── run_by_systemd()
├── Utility functions
│   ├── _sysfs_read()
│   ├── _sysfs_write()
│   └── _ethtool_extract_value()
├── CPU Mask calculation
│   ├── generate_cpus_mask()      # supports bash/bc/python3/calc fallback
│   └── format_cpumask()
├── Hardware query functions
│   ├── get_ethernet_hardware_*()
│   └── get_ethernet_kernel_*()
├── Optimization functions (6 pairs)
│   ├── check_ethernet_{rps,xps,rfs,queue,ringbuffer,irq_affinity}()
│   └── set_ethernet_*_to_optimum()
├── Filtering and main loop
│   ├── get_filtered_ethernet_card_list()
│   └── main()
└── Script entry (is_sourced detection)
```

### How to Extend

#### Add New Optimization

1. Create `check_ethernet_<new_feature>()` function
2. Create `set_ethernet_<new_feature>_to_optimum()` function
3. Add new item to action list in `main()`
4. Add command-line option parsing

#### Add New Hardware Support

1. Add special handling logic in `get_ethernet_kernel_queues_number()`
2. Add new naming patterns in IRQ extraction logic
3. Test and verify

### Testing Recommendations

```bash
# 1. Syntax check
shellcheck linux_ethernet_optimization.sh

# 2. Dry-run test
sudo ./linux_ethernet_optimization.sh -n

# 3. Single-item test
sudo ./linux_ethernet_optimization.sh -y -a queue

# 4. Comparison test (record before/after states)
ethtool -l eth0 > before.txt
sudo ./linux_ethernet_optimization.sh -y
ethtool -l eth0 > after.txt
diff before.txt after.txt
```

## License

MIT License

Copyright (c) 2026 Network Optimization Project

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Contributing

Issues and Pull Requests are welcome.

## Related Links

- Kernel Documentation: `man 7 cpuset`
- systemd Documentation: `man 5 systemd.link`, `man 5 systemd.service`
- RPS/RFS Official Documentation: https://www.kernel.org/doc/Documentation/networking/scaling.txt

## Contact

For questions or suggestions, please provide feedback via Issues.
