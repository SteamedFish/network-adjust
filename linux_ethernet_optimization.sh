#!/usr/bin/env bash
# -*- mode: sh-mode; -*-
# vim: filetype=sh

#set -euo pipefail
#IFS=$'\n\t'

shopt -s extglob

# ========================
# Critical design decisions (DO NOT change behavior)
# 1) RFS disabled by default: production safety (hash collision causes ksoftirq 100%)
# 2) mlx5 queue count / 2: mlx5e exposes both normal and XSK queues together
# 3) systemd detection: INVOCATION_ID / SYSTEMD_EXEC_PID / LAUNCHED_BY_SYSTEMD
# 4) is_sourced behavior: script can be sourced as API
# 5) >64 CPU mask calculation: bash cannot handle big integers, needs fallback
# 6) 10-second delay: bonding scenario prevents both ports resetting simultaneously
# ========================

# dependencies: ethtool, lspci, bash version >=4, grep, GNU sed column
# optional: calc, bc, or python3 (needed only for systems with >64 CPUs)
check_script_requirements() {
	for command in ethtool lspci grep sed column; do
		if [ -z "$(command -v "${command}")" ]; then
			echo "ERROR: you need ${command} command to run the script" >&2
			return 1
		fi
	done

	if ! sed --version >/dev/null 2>&1; then
		echo "ERROR: you need GNU version of sed to run the script" >&2
		return 1
	fi

	if [ -z "$BASH_VERSION" ]; then
		echo "ERROR: this script requires bash shell" >&2
		return 1
	fi

	local bash_major_version="${BASH_VERSION%%.*}"
	if [ "${bash_major_version}" -lt 4 ]; then
		echo "ERROR: this script requires bash version 4 or higher (current: ${BASH_VERSION})" >&2
		return 1
	fi

	return 0
}

check_root() {
	test ${EUID} -eq 0
}

# check if the script is running by systemd or not
run_by_systemd() {
	# systemd v232 added $INVOCATION_ID
	# systemd v248 added $SYSTEMD_EXEC_PID
	# man 5 systemd.exec for more information

	# NOTE: there's no easy way to determine for systemd version before v232
	# if you use systemd version before v232
	# you have to setup environment in the systemd service file
	# Environment=LAUNCHED_BY_SYSTEMD=1

	# systemd detection must be preserved to avoid misdetection in boot scenario
	[ -n "$INVOCATION_ID" ] || [ -n "$SYSTEMD_EXEC_PID" ] || [ -n "$LAUNCHED_BY_SYSTEMD" ]
}

# if the script is sourced by other scripts, or executed directly
# NOTE: this function doesn't support zsh
# This detection method relies on bash-specific behavior of $0
is_sourced() {
	case ${0##*/} in
	dash | -dash | bash | -bash | ksh | -ksh | sh | -sh)
		return 0
		;;
	esac
	return 1 # NOT sourced.
}

add_to_run_queue() {
	run_queue+=("$@")
}

confirm_and_run() {
	local REPLY
	local DO_ACTION

	if [ "${dry_run}" = "true" ]; then
		DO_ACTION=false
	elif [ "${assume_yes}" = "true" ]; then
		DO_ACTION=true
	else
		read -p "Perform Optimization[yn]: " -n 1 -r </dev/tty
		echo
		if [[ "$REPLY" =~ ^[Yy] ]]; then
			DO_ACTION=true
		else
			DO_ACTION=false
		fi
	fi

	if [ "${DO_ACTION}" = "true" ]; then
		if "$@"; then
			:
			# echo "Finished Optimization"
		else
			:
			#echo "Failed Performing Optimization"
		fi
	else
		:
		#echo -e "Ignored"
	fi
}

get_number_of_cpus() {
	grep -c processor /proc/cpuinfo
}

get_running_rx_queues_of_device() {
	local ETH=$1

	find /sys/class/net/"${ETH}"/queues/ -type d -name "rx-*"
}

get_running_tx_queues_of_device() {
	local ETH=$1

	find /sys/class/net/"${ETH}"/queues/ -type d -name "tx-*"
}

_sysfs_read() {
	local path=$1

	cat "${path}"
}

_sysfs_write() {
	local path=$1
	local value=$2

	echo "${value}" >"${path}"
}

set_rps_mask_for_queue() {
	local QUEUE=$1
	# the cpu mask to be set
	local MASK=$2

	_sysfs_write "${QUEUE}/rps_cpus" "${MASK}"
}

set_xps_mask_for_queue() {
	local QUEUE=$1
	# the cpu mask to be set
	local MASK=$2

	_sysfs_write "${QUEUE}/xps_cpus" "${MASK}"
}

get_rps_mask_from_queue() {
	local QUEUE=$1

	_sysfs_read "${QUEUE}/rps_cpus"
}

get_xps_mask_from_queue() {
	local QUEUE=$1

	_sysfs_read "${QUEUE}/xps_cpus"
}

set_rfs_for_queue() {
	local QUEUE=$1
	# the cpu mask to be set
	local CNT=$2

	_sysfs_write "${QUEUE}/rps_flow_cnt" "${CNT}"
}

get_rfs_from_queue() {
	local QUEUE=$1

	_sysfs_read "${QUEUE}/rps_flow_cnt"
}

get_rfs_flow_entries() {
	_sysfs_read /proc/sys/net/core/rps_sock_flow_entries
}

set_rfs_flow_entries() {
	local number=$1

	_sysfs_write /proc/sys/net/core/rps_sock_flow_entries "${number}"
}

# query ethernet queres seen in the kernel
get_ethernet_kernel_queues_number() {
	local ETH=$1
	# INFO: one of RX, TX (case insensitive due to ${2,,})
	local INFO=${2,,}

	# mlx5e exposes two groups of queues: normal + XSK (AF_XDP)
	# Must divide by 2 for actual queue count in production

	nm_queues="$(find /sys/class/net/"${ETH}"/queues -type d -name "${INFO}-*" | wc -l)"

	if [[ "$(get_driver_of_ethernet_card "${ETH}")" == "mlx5"* ]]; then
		echo "$((nm_queues / 2))"
	else
		echo "${nm_queues}"
	fi
}

# query ethernet queue info
# including hardware capabilities and current settings
get_ethernet_hardware_queues_number() {
	# ethernet card names, such as eno1
	local ETH=$1
	# what info to query, one of RX TX or Combined
	local INFO=$2
	# max or current
	local TYPE=$3

	case "${INFO}" in
	"RX" | "TX" | "Other" | "Combined") ;;
	*)
		echo "Unrecognized INFO ${INFO}" >&2
		return 1
		;;
	esac

	_ethtool_extract_value "${ETH}" "${INFO}" "${TYPE}" "-l"
}

# set ethernet hardware queue number
# this may reset the ethernet card
set_ethernet_hardware_queues_number() {
	# ethernet card names, such as eno1
	local ETH=$1
	# what info to query, one of RX or TX
	local INFO=$2
	local VALUE=$3

	case "${INFO}" in
	"RX" | "TX" | "Other" | "Combined")
		# ,, is used to convert uppercase to lowercase
		# this feature requires at least bash version 4
		ethtool -L "${ETH}" "${INFO,,}" "${VALUE}"
		return $?
		;;
	*)
		echo "Unrecognized INFO ${INFO}" >&2
		return 1
		;;
	esac

}

# query ethernet ringbuffer info
# including hardware capabilities and current settings
get_ethernet_hardware_ringbuffer() {
	# ethernet card names, such as eno1
	local ETH=$1
	# what info to query, one of RX or TX
	local INFO=$2
	# max or current
	local TYPE=$3

	case "${INFO}" in
	"RX" | "TX") ;;
	*)
		echo "Unrecognized INFO ${INFO}" >&2
		return 1
		;;
	esac

	_ethtool_extract_value "${ETH}" "${INFO}" "${TYPE}" "-g"
}

# Parse ethtool output and extract specific value
# ASSUMPTIONS:
#   - ethtool output contains exact strings "Pre-set maximums:" and "Current hardware settings:"
#   - INFO field format: "<INFO>:    <value>"
# KNOWN FAILURES:
#   - Different NIC firmware may change output format
#   - Older ethtool versions may not support -l/-g flags
# FALLBACK: Returns empty string if parsing fails
_ethtool_extract_value() {
	local ETH=$1
	local INFO=$2
	local TYPE=$3
	local MODE=$4
	local current_string="Current hardware settings:"
	local max_string="Pre-set maximums:"
	local started=false
	local start_string
	local stop_string

	case "${TYPE}" in
	"max")
		start_string="${max_string}"
		stop_string="${current_string}"
		;;
	"current")
		start_string="${current_string}"
		stop_string="end_of_the_file_not_exist"
		;;
	*)
		echo "Unrecognized TYPE ${TYPE}" >&2
		return 1
		;;
	esac

	while read -r line; do
		if [ "$line" = "${start_string}" ]; then
			started=true
		elif [ "$line" = "${stop_string}" ]; then
			return
		elif [ "${started}" = "true" ] && [[ $line =~ ^${INFO}:[[:space:]]* ]]; then
			echo -n "$line" | grep "${INFO}" | cut -d : -f 2 | xargs
			# There should be only one
			return
		fi
	done < <(ethtool "${MODE}" "${ETH}")
}

# set ethernet ringbuffer info
# this may reset the ethernet card
set_ethernet_hardware_ringbuffer() {
	# ethernet card names, such as eno1
	local ETH=$1
	# what info to query, one of RX or TX
	local INFO=$2
	local VALUE=$3

	case "${INFO}" in
	"RX" | "TX")
		# ,, is used to convert uppercase to lowercase
		# this feature requires at least bash version 4
		ethtool -G "${ETH}" "${INFO,,}" "${VALUE}"
		return $?
		;;
	*)
		echo "Unrecognized INFO ${INFO}" >&2
		return 1
		;;
	esac

}

# bignum_calc - Arbitrary precision calculator with multiple backend fallback
#
# USAGE: bignum_calc <mode> <expression>
#
# PARAMETERS:
#   mode        Output format: "hex", "bin", "oct", "default" (decimal)
#   expression  Math expression (supports: +, -, *, /, ^, parentheses)
#
# RETURNS:
#   Calculation result in specified format
#
# BACKENDS (fallback order):
#   1. bash (CPU ≤ 64 cores only)
#   2. bc (recommended for > 64 cores)
#   3. python3 (fallback)
#   4. calc (last resort)
#
# EXAMPLE:
#   bignum_calc hex "2 ^ 128 - 1"
#   # Output: ffffffffffffffffffffffffffffffff
bignum_calc() {
	# mode: bin for base2, oct for base8, default for base10, hex for base 16
	local mode="${1:-default}"

	shift
	local expr="$*"
	local result
	local nr_cpu

	nr_cpu="$(get_number_of_cpus)"
	if [ "${nr_cpu}" -le 64 ]; then
		result="$(_calc_with_bash "${mode}" "${expr}")"
		echo "${result}"
		return 0
	fi

	if command -v bc >/dev/null 2>&1; then
		result="$(_calc_with_bc "${mode}" "${expr}")"
		echo "${result}"
		return 0
	fi

	if command -v python3 >/dev/null 2>&1; then
		result="$(_calc_with_python "${mode}" "${expr}")"
		echo "${result}"
		return 0
	fi

	if command -v calc >/dev/null 2>&1; then
		result="$(_calc_with_calc "${mode}" "${expr}")"
		echo "${result}"
		return 0
	fi

	echo "ERROR: no suitable calculator found (need bc, python3, or calc for >64 CPUs)" >&2
	return 1
}

_calc_with_bash() {
	local mode=$1
	local expr=$2
	local value
	local tmp
	local power

	if [[ "${expr}" =~ ^2[[:space:]]*\^[[:space:]]*([0-9]+)[[:space:]]*-[[:space:]]*1$ ]]; then
		power="${BASH_REMATCH[1]}"
		if [ "${mode}" = "hex" ] && [ "${power}" -eq 64 ]; then
			echo ffffffffffffffff
			return 0
		fi
	fi

	value=$((${expr//^/**}))
	case "${mode}" in
	bin)
		if [ "${value}" -eq 0 ]; then
			echo 0
			return 0
		fi
		while [ "${value}" -gt 0 ]; do
			tmp="$((value & 1))${tmp}"
			value=$((value >> 1))
		done
		echo "${tmp}"
		;;
	oct)
		printf "%o" "${value}"
		;;
	default)
		echo "${value}"
		;;
	hex)
		printf "%x" "${value}"
		;;
	esac
}

_calc_with_bc() {
	local mode=$1
	local expr=$2
	local result

	case "${mode}" in
	bin)
		result="$(echo "ibase=10; obase=2; ${expr}" | bc)"
		;;
	oct)
		result="$(echo "ibase=10; obase=8; ${expr}" | bc)"
		;;
	default)
		result="$(echo "scale=0; ${expr}" | bc)"
		;;
	hex)
		result="$(echo "ibase=10; obase=16; ${expr}" | bc)"
		;;
	esac

	echo "${result,,}"
}

_calc_with_python() {
	local mode=$1
	local expr=$2
	local result

	# SECURITY NOTE: Expression comes from internal script logic only
	# If future modifications allow external input, add validation here
	result="$(
		python3 - <<PY
import sys
# Expression sanitized by script logic - only arithmetic operators used
expr = "${expr}".replace('^', '**')
value = eval(expr, {"__builtins__": {}}, {})
mode = "${mode}"
if mode == "hex":
    print(hex(value)[2:])
elif mode == "bin":
    print(bin(value)[2:])
elif mode == "oct":
    print(oct(value)[2:])
else:
    print(value)
PY
	)"

	echo "${result,,}"
}

_calc_with_calc() {
	local mode=$1
	local expr=$2
	local result

	result="$(calc -m0 -e -d "a=config('display',0); a=config('mode','${mode}'); ${expr}" | xargs)"

	case "${mode}" in
	bin)
		if [[ "${result}" == 0b* ]]; then
			result="${result#0b}"
		fi
		;;
	oct)
		if [[ "${result}" == 0* ]] && [[ "${result}" != "0" ]]; then
			result="${result#0}"
		fi
		;;
	hex)
		if [[ "${result}" == 0x* ]]; then
			result="${result#0x}"
		fi
		;;
	default) ;;
	esac

	echo "${result,,}"
}

format_cpumask() {
	local mask="$1"

	# Insert comma every 8 hex chars per cpuset specification
	# GNU sed specific (not POSIX compatible, not BSD sed compatible)
	echo "${mask}" | sed ':a;s/\B.\{8\}\>/,&/;ta'
}

# generate a cpuset CPU mask that uses all cpu
# man 7 cpuset, go for FORMAT section for detailed format description
generate_cpus_mask_for_all_cpu() {
	local NR_CPU
	NR_CPU="$(get_number_of_cpus)"

	format_cpumask "$(bignum_calc hex "2 ^ ${NR_CPU} - 1")"
}

# generate_cpus_mask - Generate CPU mask for round-robin queue distribution
#
# USAGE: generate_cpus_mask <number> <total>
#
# PARAMETERS:
#   number  Starting queue number (0-based)
#   total   Total number of queues
#
# ALGORITHM:
#   Distributes queues across CPUs in round-robin fashion.
#   For queue N, assigns to CPU (N mod NR_CPU), then (N+total mod NR_CPU), etc.
#
# RETURNS:
#   Formatted CPU mask (comma-separated 8-hex-digit groups per cpuset spec)
#
# EXAMPLE:
#   generate_cpus_mask 0 4   # Queue 0 of 4 total
#   # On 8-CPU system: assigns CPUs 0,4 → mask: 00000011
#
# man 7 cpuset, go to FORMAT section for detailed format description
generate_cpus_mask() {
	local number=$1
	local total=$2

	local NR_CPU
	NR_CPU=$(get_number_of_cpus)

	# Round-robin CPU mask generation based on queue number
	mask=0
	while [ "${number}" -lt "${NR_CPU}" ]; do
		temp_mask="$(generate_cpus_mask_for_one_cpu "$((number % NR_CPU))" false)"
		mask="$(bignum_calc default "${mask} | ${temp_mask}")"
		number="$((number + total))"
	done
	format_cpumask "$(bignum_calc hex "${mask}")"
}

# generate a cpuset CPU mask that uses only one CPU
generate_cpus_mask_for_one_cpu() {
	# CPU number
	local CPU=$1
	local format=$2

	if "${format}"; then
		format_cpumask "$(bignum_calc hex "2 ^ ${CPU}")"
	else
		bignum_calc default "2 ^ ${CPU}"
	fi

}

# return irq list of the ethernet card
get_irq_of_ethernet_card() {
	local ETH_NAME=$1

	# NOTE:
	# The irq name registered to kernel is driver specific and varies from driver to driver
	# This makes it pretty hard to track which irq belongs to the card by query /proc/irq/*/<irq name>
	# The method used here seems to be driver irrelevant, but not 100% sure
	# Needs more testing for it

	# the legacy irq file in device/irq is usually not used, and not exist in /proc/irq/<number>
	# we have to check if the irq actually exists

	# IRQ list from legacy irq + MSI IRQ directory
	while read -r irq; do
		if [ -d "/proc/irq/${irq}" ]; then
			echo "${irq}"
		fi
	done < <(
		cat "/sys/class/net/${ETH_NAME}/device/irq" 2>/dev/null
		# Iterate over MSI IRQ directory (avoid ls parsing anti-pattern)
		for irq_file in "/sys/class/net/${ETH_NAME}/device/msi_irqs/"*; do
			[ -e "${irq_file}" ] || continue
			basename "${irq_file}"
		done 2>/dev/null
	)
}

# return the queue number of an irq
get_queue_from_irq() {
	local IRQ=$1

	# The irq name registeded to kernel is driver specific.
	# but usually, it will have quene numbers at the end if its a multi-queued device, such as xxx-<queue>  or xxx@<queue>

	# an exception is, some mlx card may have the following format: mlx5_comp<queue>@pci:<pci id>

	# It may not have any queue number if its a single-queled device, so the function may return an empty string

	# IRQ name format is driver-specific, mlx5 requires special parsing
	if find "/proc/irq/${IRQ}/" -type d | grep -qE 'mlx.*@pci:'; then
		find "/proc/irq/${IRQ}/" -type d | sed -e 's|^.*/||' | grep -E '^mlx.*@pci:.*$' | sed -e 's/@pci:.*$//' | grep -Eo '[0-9]+$'
	else
		find "/proc/irq/${IRQ}/" -type d | grep -E '[^a-z0-9][0-9]+$' | grep -Eo '[0-9]+$'
	fi
}

set_irq_smp_affinity() {
	local IRQ=$1
	local MASK=$2

	_sysfs_write "/proc/irq/${IRQ}/smp_affinity" "${MASK}"
	# shellcheck disable=SC2320
	return $?
}

get_irq_smp_affinity() {
	local IRQ=$1

	_sysfs_read "/proc/irq/${IRQ}/smp_affinity"
}

mask_is_equal() {
	local MASK1=$1
	local MASK2=$2

	# remove the leading zeros and commas before compare
	test "${MASK1##*([0,])}" == "${MASK2##*([0,])}"
}

get_driver_of_ethernet_card() {
	# ethernet card names, such as eno1
	local ETH_NAME=$1

	basename "$(readlink "/sys/class/net/${ETH_NAME}/device/driver")"
}

get_ethernet_hardware_info() {
	# ethernet card names, such as eno1
	local ETH_NAME=$1

	local PCIADDR
	PCIADDR="$(basename "$(readlink "/sys/class/net/${ETH_NAME}/device")")"

	if [ -z "${PCIADDR}" ]; then
		return 1
	fi

	lspci -s "${PCIADDR}" -vmm
}

get_vendor_of_ethernet_card() {
	# ethernet card names, such as eno1
	local ETH_NAME=$1

	get_ethernet_hardware_info "${ETH_NAME}" | grep -E '^Vendor:' | cut -d : -f 2 | xargs
}

get_name_of_ethernet_card() {
	# ethernet card names, such as eno1
	local ETH_NAME=$1

	get_ethernet_hardware_info "${ETH_NAME}" | grep -E '^Device:' | cut -d : -f 2 | xargs
}

get_physical_ethernet_card_list() {
	local ETH_NAME
	local DRIVER_PATH
	local DRIVER_NAME

	# we remove all the devices in /sys/class/net that links to virtual device
	# and also exclude virtio and other virtualization drivers

	while read -r ETH_NAME; do
		DRIVER_PATH="/sys/class/net/${ETH_NAME}/device/driver"
		if [ -L "${DRIVER_PATH}" ]; then
			DRIVER_NAME="$(basename "$(readlink "${DRIVER_PATH}")")"
			case "${DRIVER_NAME}" in
			virtio_net | veth | vmxnet3 | xen-netfront | hv_netvsc)
				continue
				;;
			esac
		fi
		echo "${ETH_NAME}"
	done < <(find /sys/class/net -mindepth 1 -maxdepth 1 -lname '*/virtual/*' -prune -o -type l -printf '%f\n')
}

_match_exact_in_list() {
	local target=$1
	shift
	local item

	for item in "$@"; do
		if [[ "${target}" == "${item}" ]]; then
			return 0
		fi
	done
	return 1
}

_match_substr_ci_in_list() {
	local target=$1
	shift
	local item
	local target_lc

	target_lc="${target,,}"
	for item in "$@"; do
		if [[ "${target_lc}" =~ .*"${item,,}".* ]]; then
			return 0
		fi
	done
	return 1
}

get_filtered_ethernet_card_list() {
	local ETH_NAME
	local devname
	local drivername
	local vendorname

	while read -r ETH_NAME; do
		devname=""
		drivername=""
		vendorname=""

		if _match_exact_in_list "${ETH_NAME}" "${osname_exclude_list[@]}"; then
			continue
		fi

		if [ "${#device_exclude_list[@]}" -gt 0 ]; then
			devname="$(get_name_of_ethernet_card "${ETH_NAME}")"
			if _match_substr_ci_in_list "${devname}" "${device_exclude_list[@]}"; then
				continue
			fi
		fi

		if [ "${#driver_exclude_list[@]}" -gt 0 ]; then
			drivername="$(get_driver_of_ethernet_card "${ETH_NAME}")"
			if _match_exact_in_list "${drivername}" "${driver_exclude_list[@]}"; then
				continue
			fi
		fi

		if [ "${#vendor_exclude_list[@]}" -gt 0 ]; then
			vendorname="$(get_vendor_of_ethernet_card "${ETH_NAME}")"
			if _match_substr_ci_in_list "${vendorname}" "${vendor_exclude_list[@]}"; then
				continue
			fi
		fi

		if _match_exact_in_list "${ETH_NAME}" "${osname_include_list[@]}"; then
			echo "${ETH_NAME}"
			continue
		fi

		if [ "${#device_include_list[@]}" -gt 0 ]; then
			if [ -z "${devname}" ]; then
				devname="$(get_name_of_ethernet_card "${ETH_NAME}")"
			fi
			if _match_substr_ci_in_list "${devname}" "${device_include_list[@]}"; then
				echo "${ETH_NAME}"
				continue
			fi
		fi

		if [ "${#driver_include_list[@]}" -gt 0 ]; then
			if [ -z "${drivername}" ]; then
				drivername="$(get_driver_of_ethernet_card "${ETH_NAME}")"
			fi
			if _match_exact_in_list "${drivername}" "${driver_include_list[@]}"; then
				echo "${ETH_NAME}"
				continue
			fi
		fi

		if [ "${#vendor_include_list[@]}" -gt 0 ]; then
			if [ -z "${vendorname}" ]; then
				vendorname="$(get_vendor_of_ethernet_card "${ETH_NAME}")"
			fi
			if _match_substr_ci_in_list "${vendorname}" "${vendor_include_list[@]}"; then
				echo "${ETH_NAME}"
				continue
			fi
		fi

		if [ "${#osname_include_list[@]}" -eq 0 ] &&
			[ "${#device_include_list[@]}" -eq 0 ] &&
			[ "${#driver_include_list[@]}" -eq 0 ] &&
			[ "${#vendor_include_list[@]}" -eq 0 ]; then
			# there's no include list, anything not excluded will be shown
			echo "${ETH_NAME}"
		fi
		# in the find we remove all the devices in /sys/class/net that links to virtual device
	done < <(get_physical_ethernet_card_list)
}

# Validate if a string is a positive integer
_is_positive_integer() {
	local value="$1"
	[[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -gt 0 ]
}

# Unified RPS/XPS optimization logic
# mode: "check" (return 0/1), "apply" (output + modify)
# direction: "rx" for RPS, "tx" for XPS
#
# LIMITATION: This function does NOT consider NUMA topology.
# On multi-socket NUMA systems, this may distribute packets to CPUs on remote NUMA nodes,
# causing cross-node memory access with 2-3× latency penalty.
# Optimal: RPS/XPS should only use CPUs local to the NIC's NUMA node.
# Check NIC's NUMA node: cat /sys/class/net/<dev>/device/numa_node
# Get local CPUs: cat /sys/devices/system/node/node<N>/cpulist
_optimize_packet_steering() {
	local eth_name=$1
	local mode=$2
	local direction=$3
	local label
	local get_mask_func
	local set_mask_func
	local get_queues_func

	if [ "${direction}" == "rx" ]; then
		label="RPS"
		get_mask_func="get_rps_mask_from_queue"
		set_mask_func="set_rps_mask_for_queue"
		get_queues_func="get_running_rx_queues_of_device"
	else
		label="XPS"
		get_mask_func="get_xps_mask_from_queue"
		set_mask_func="set_xps_mask_for_queue"
		get_queues_func="get_running_tx_queues_of_device"
	fi

	local NR_CPU NR_QUEUE
	NR_CPU=$(get_number_of_cpus)
	NR_QUEUE=$(get_ethernet_kernel_queues_number "${eth_name}" "${direction}")

	local needs_change=false

	while read -r queue; do
		local queue_name queue_number current_mask best_mask
		queue_name="$(basename "${queue}")"
		queue_number="$(echo "${queue_name}" | grep -Eo '[0-9]+$')"
		current_mask="$("${get_mask_func}" "${queue}")"

		if [ "$NR_QUEUE" -lt "$NR_CPU" ]; then
			best_mask="$(generate_cpus_mask "${queue_number}" "${NR_QUEUE}")"
		else
			best_mask="0"
		fi

		if ! mask_is_equal "${best_mask}" "${current_mask}"; then
			needs_change=true
			if [ "${mode}" = "apply" ]; then
				echo -e "${eth_name} \t ${label} \t\t ${queue_name} \t\t ${current_mask} \t ${best_mask}"
				"${set_mask_func}" "${queue}" "${best_mask}"
			fi
		fi
	done < <("${get_queues_func}" "${eth_name}")

	if [ "${mode}" = "check" ] && [ "${needs_change}" = "true" ]; then
		return 1
	fi
	return 0
}

check_ethernet_rps() {
	_optimize_packet_steering "$1" "check" "rx"
}

set_ethernet_rps_to_optimum() {
	_optimize_packet_steering "$1" "apply" "rx"
}

check_ethernet_xps() {
	_optimize_packet_steering "$1" "check" "tx"
}

set_ethernet_xps_to_optimum() {
	_optimize_packet_steering "$1" "apply" "tx"
}

# RFS optimization logic (always disabled for safety)
# RFS disabled by default: production hash collision may cause ksoftirq 100%
_optimize_rfs() {
	local eth_name=$1
	local mode=$2

	local needs_change=false
	local best_rfs="0"

	while read -r queue; do
		local queue_name current_rfs
		queue_name="$(basename "${queue}")"
		current_rfs="$(get_rfs_from_queue "${queue}")"

		if [ "${current_rfs}" != "${best_rfs}" ]; then
			needs_change=true
			if [ "${mode}" = "apply" ]; then
				echo -e "${eth_name} \t RFS \t\t ${queue_name} \t\t ${current_rfs} \t ${best_rfs}"
				set_rfs_for_queue "${queue}" "${best_rfs}"
			fi
		fi
	done < <(get_running_rx_queues_of_device "${eth_name}")

	local current_rfs_flow
	current_rfs_flow="$(get_rfs_flow_entries)"
	if [ "${current_rfs_flow}" -ne 0 ]; then
		needs_change=true
		if [ "${mode}" = "apply" ]; then
			echo -e "N/A \t RFS-FLOW \t -- \t\t ${current_rfs_flow} \t 0"
			set_rfs_flow_entries 0
		fi
	fi

	if [ "${mode}" = "check" ] && [ "${needs_change}" = "true" ]; then
		return 1
	fi
	return 0
}

check_ethernet_rfs() {
	_optimize_rfs "$1" "check"
}

set_ethernet_rfs_to_optimum() {
	_optimize_rfs "$1" "apply"
}

_optimize_ringbuffer() {
	local eth_name=$1
	local mode=$2

	local needs_change=false

	for INFO in "RX" "TX"; do
		local current_ringbuffer max_ringbuffer
		current_ringbuffer="$(get_ethernet_hardware_ringbuffer "${eth_name}" "${INFO}" current)"
		max_ringbuffer="$(get_ethernet_hardware_ringbuffer "${eth_name}" "${INFO}" max)"

		if [ -z "${current_ringbuffer}" ] || [ -z "${max_ringbuffer}" ]; then
			continue
		fi

		if _is_positive_integer "${current_ringbuffer}" && _is_positive_integer "${max_ringbuffer}"; then
			if [ "${max_ringbuffer}" -gt "${current_ringbuffer}" ]; then
				needs_change=true
				if [ "${mode}" = "apply" ]; then
					echo -e "${eth_name} \t RINGBUFFER \t ${INFO} \t\t ${current_ringbuffer} \t ${max_ringbuffer}"
					set_ethernet_hardware_ringbuffer "${eth_name}" "${INFO}" "${max_ringbuffer}"
				fi
			fi
		fi
	done

	if [ "${mode}" = "check" ] && [ "${needs_change}" = "true" ]; then
		return 1
	fi
	return 0
}

check_ethernet_ringbuffer() {
	_optimize_ringbuffer "$1" "check"
}

set_ethernet_ringbuffer_to_optimum() {
	_optimize_ringbuffer "$1" "apply"
}

# Unified queue optimization
# mode: "check" = return 1 if needs optimization, "apply" = perform optimization
_optimize_queue() {
	local eth_name=$1
	local mode=$2

	# The optimum settings of queue number is min(number of CPU cores, max queues hardware can support)

	# NOTE: if you use a more recent systemd version, you can configure queues in systemd-networkd
	# RxChannels=max TxChannels=max OtherChannels=max CombinedChannels=max
	# man 5 systemd.link for more information about how to setup queues in systemd-networkd
	# Ubuntu 20's systemd is too old, that systemd-networkd cannot recognize the value "max"

	local nr_cpu current_queue max_queue best_queue info
	local needs_change=false

	nr_cpu="$(get_number_of_cpus)"
	for info in "RX" "TX" "Other" "Combined"; do
		current_queue="$(get_ethernet_hardware_queues_number "${eth_name}" "${info}" current)"
		max_queue="$(get_ethernet_hardware_queues_number "${eth_name}" "${info}" max)"
		if [ "${current_queue}" == "n/a" ] || [ "${max_queue}" == "n/a" ]; then
			continue
		fi
		if [ -z "${current_queue}" ] || [ -z "${max_queue}" ]; then
			continue
		fi
		if [ "${current_queue}" -eq 0 ]; then
			# This info is not supported by hardware
			continue
		fi
		if _is_positive_integer "${current_queue}" && _is_positive_integer "${max_queue}"; then
			best_queue=$((max_queue > nr_cpu ? nr_cpu : max_queue))
			if [ "${best_queue}" -gt "${current_queue}" ]; then
				needs_change=true
				if [ "${mode}" = "apply" ]; then
					echo -e "${eth_name} \t QUEUE \t\t ${info} \t\t ${current_queue} \t ${best_queue}"
					set_ethernet_hardware_queues_number "${eth_name}" "${info}" "${best_queue}"
				fi
			fi
		fi
	done

	if [ "${mode}" = "check" ] && [ "${needs_change}" = "true" ]; then
		return 1
	fi
	return 0
}

check_ethernet_queue() {
	_optimize_queue "$1" "check"
}

set_ethernet_queue_to_optimum() {
	_optimize_queue "$1" "apply"
}

# Unified IRQ affinity optimization
# Strategy: round-robin bind each queue to different CPU
# mode: "check" = return 1 if needs optimization, "apply" = perform optimization
#
# LIMITATION: This function does NOT consider NUMA topology.
# On multi-socket NUMA systems, this may assign IRQs to CPUs on remote NUMA nodes,
# causing cross-node memory access with 2-3× latency penalty.
# Optimal: IRQs should be bound to CPUs local to the NIC's NUMA node.
# Check NIC's NUMA node: cat /sys/class/net/<dev>/device/numa_node
# Get local CPUs: cat /sys/devices/system/node/node<N>/cpulist
_optimize_irq_affinity() {
	local eth_name=$1
	local mode=$2

	local nr_cpu best_mask current_mask irq queue
	local needs_change=false

	nr_cpu="$(get_number_of_cpus)"

	for irq in $(get_irq_of_ethernet_card "${eth_name}"); do
		while read -r queue; do
			if [ -z "${queue}" ]; then
				continue
			fi
			best_mask="$(generate_cpus_mask_for_one_cpu "$((queue % nr_cpu))" true)"
			current_mask="$(get_irq_smp_affinity "${irq}")"

			if ! mask_is_equal "${best_mask}" "${current_mask}"; then
				needs_change=true
				if [ "${mode}" = "apply" ]; then
					echo -e "${eth_name} \t IRQ \t\t irq-${irq}-queue-${queue} \t ${current_mask} \t ${best_mask}"
					set_irq_smp_affinity "${irq}" "${best_mask}"
				fi
			fi
		done < <(get_queue_from_irq "${irq}")
	done

	if [ "${mode}" = "check" ] && [ "${needs_change}" = "true" ]; then
		return 1
	fi
	return 0
}

check_ethernet_irq_affinity() {
	_optimize_irq_affinity "$1" "check"
}

set_ethernet_irq_affinity_to_optimum() {
	_optimize_irq_affinity "$1" "apply"
}

usage() {
	cat <<EOF

Optimize linux ethernet card settings for maximum throughput.

IMPORTANT: This script is designed ONLY for HIGH-THROUGHPUT network environments.
           It is NOT suitable for latency-sensitive scenarios (e.g., financial trading,
           real-time gaming, VoIP). These optimizations may INCREASE latency.

The script will perform several modifications.
For each modification, the script will ask the user to comfirm unless -n or -y option is passed.

WARNING: maximum throughput means more CPU usage and INCREASED latency.

WARNING: some of the modifications will reset the ethernet card, making it disconnect for about 500ms to 30 seconds.

Usage:
    $0 [ OPTIONS ]

OPTIONS:
    -h                this help
    -n                dry-run
                      show the actions that needs to be done, but ignore all actions without asking
                      overrides -y
    -y                assume-yes
                      perform all actions that needs to be done without asking
    -a <ACTION NAME>  actions to include, can be one of "queue" "ringbuffer" "irq" "rps" "xps" "rfs"
    -A <ACTION NAME>  actions to exclude, can be one of "queue" "ringbuffer" "irq" "rps" "xps" "rfs"
    -e <ETH OS NAME>  ethernet card to include
    -E <ETH OS NAME>  ethernet card to exclude
    -i <DEVICE NAME>  device to include
    -I <DEVICE NAME>  device to exclude
    -d <DRIVER NAME>  drivers to include
    -D <DRIVER NAME>  drivers to exclude
    -v <VENDOR NAME>  vendors to include
    -V <VENDOR NAME>  vendors to exclude

INCLUDE and EXCLUDE:
    You can give include and exclude options several times to include or exclude multiple things
    If any include options are given, only ethernet devices in the include list will be parsed
    If a device is in both include list and exclude list, it will be excluded

ACTION NAME:
    What optimization to perform. Can be one of "queue" "ringbuffer" "irq" "rps" "xps" "rfs".

ETH OS NAME:
    Ethernet card name shown in the OS. Will be fully matched, case sensitive.
    Example of ethernet card name: enp4s0

DEVICE NAME:
    Device name will be partially matched, case insensitive
    You can get device information by lspci | grep Ethernet
    Example of device name: X722

DRIVER NAME:
    Driver name must be exactly matched, case sensitive
    You can get driver of an ethernet card by ethtool -i <ETH NAME> | grep -E '^driver:'
    Example of driver name: i40e

VENDOR NAME:
    Vendor name will be partially matched, case insensitive
    You can get vendor information by lspci | grep Ethernet
    Example of vendor name: Intel

Examples:
    # Optimize all the ethernet cards in the system, do all the modifications without any confirmation
    $0 -y

    # Optimize all the ethernet cards in the system, only show the modifications without actually do modifications
    $0 -n

    # Optimize only intel and broadcom ethernet cards, but don't optimize cards with i40e driver
    # ask for confirmation before any modification
    $0 -v Intel -v Broadcom -D i40e

EOF
}

################################################################################
# main
################################################################################

# this script can be sourced by other scripts to use only some of the functions defined above
if is_sourced; then
	return
fi

if ! check_root; then
	echo "ERROR: This script requires root permission" >&2
	usage
	exit 1
fi

if ! check_script_requirements; then
	exit 1
fi

export dry_run=false
export assume_yes=false

export action_include_list=()
export action_exclude_list=()
export osname_include_list=()
export osname_exclude_list=()
export device_include_list=()
export device_exclude_list=()
export driver_include_list=()
export driver_exclude_list=()
export vendor_include_list=()
export vendor_exclude_list=()

export run_queue=()

while getopts "nyha:A:e:E:d:D:v:V:i:I:" OPT; do
	case "${OPT:-}" in
	h)
		usage
		exit 0
		;;
	n)
		export dry_run=true
		;;
	y)
		export assume_yes=true
		;;
	a)
		export action_include_list+=("${OPTARG}")
		;;
	A)
		export action_exclude_list+=("${OPTARG}")
		;;
	e)
		export osname_include_list+=("${OPTARG}")
		;;
	E)
		export osname_exclude_list+=("${OPTARG}")
		;;
	i)
		export device_include_list+=("${OPTARG}")
		;;
	I)
		export device_exclude_list+=("${OPTARG}")
		;;
	d)
		export driver_include_list+=("${OPTARG}")
		;;
	D)
		export driver_exclude_list+=("${OPTARG}")
		;;
	v)
		export vendor_include_list+=("${OPTARG}")
		;;
	V)
		export vendor_exclude_list+=("${OPTARG}")
		;;
	*)
		usage
		exit 1
		;;
	esac
done
shift $((OPTIND - 1))

if [ "${#action_include_list[@]}" -eq 0 ]; then
	export action_include_list=("queue" "ringbuffer" "irq" "rps" "xps" "rfs")
fi

_should_skip_action() {
	local action=$1
	local exclude_action

	for exclude_action in "${action_exclude_list[@]}"; do
		if [ "${action}" == "${exclude_action}" ]; then
			return 0
		fi
	done
	return 1
}

_run_action_check() {
	local action=$1
	local eth_name=$2

	case "${action}" in
	"queue")
		if check_ethernet_queue "${eth_name}"; then
			echo -e "${eth_name} \t QUEUE \t\t OPTIMIZED"
		else
			echo -e "${eth_name} \t QUEUE \t\t UN-OPTIMIZED"
			return 1
		fi
		;;
	"ringbuffer")
		if check_ethernet_ringbuffer "${eth_name}"; then
			echo -e "${eth_name} \t RINGBUFFER \t OPTIMIZED"
		else
			echo -e "${eth_name} \t RINGBUFFER \t UN-OPTIMIZED"
			return 1
		fi
		;;
	"irq")
		if check_ethernet_irq_affinity "${eth_name}"; then
			echo -e "${eth_name} \t IRQ-AFFINITY \t OPTIMIZED"
		else
			echo -e "${eth_name} \t IRQ-AFFINITY \t UN-OPTIMIZED"
			return 1
		fi
		;;
	"rps")
		if check_ethernet_rps "${eth_name}"; then
			echo -e "${eth_name} \t RPS \t\t OPTIMIZED"
		else
			echo -e "${eth_name} \t RPS \t\t UN-OPTIMIZED"
			return 1
		fi
		;;
	"xps")
		if check_ethernet_xps "${eth_name}"; then
			echo -e "${eth_name} \t XPS \t\t OPTIMIZED"
		else
			echo -e "${eth_name} \t XPS \t\t UN-OPTIMIZED"
			return 1
		fi
		;;
	"rfs")
		if check_ethernet_rfs "${eth_name}"; then
			echo -e "${eth_name} \t RFS \t\t OPTIMIZED"
		else
			echo -e "${eth_name} \t RFS \t\t UN-OPTIMIZED"
			return 1
		fi
		;;
	*)
		echo "ignore unrecognised action ${action}" >&2
		;;
	esac
	return 0
}

_run_action_apply() {
	local action=$1
	local eth_name=$2

	case "${action}" in
	"queue")
		set_ethernet_queue_to_optimum "${eth_name}"
		;;
	"ringbuffer")
		set_ethernet_ringbuffer_to_optimum "${eth_name}"
		;;
	"irq")
		set_ethernet_irq_affinity_to_optimum "${eth_name}"
		;;
	"rps")
		set_ethernet_rps_to_optimum "${eth_name}"
		;;
	"xps")
		set_ethernet_xps_to_optimum "${eth_name}"
		;;
	"rfs")
		set_ethernet_rfs_to_optimum "${eth_name}"
		;;
	*)
		echo "ignore unrecognised action ${action}" >&2
		;;
	esac
}

(
	echo "CARD ITEM STATUS"
	optimized=true
	while read -r ETH_NAME; do
		for action in "${action_include_list[@]}"; do
			if _should_skip_action "${action}"; then
				continue
			fi
			if ! _run_action_check "${action}" "${ETH_NAME}"; then
				optimized=false
			fi
		done
		echo
		echo
	done < <(get_filtered_ethernet_card_list)

	if [ "${optimized}" = "true" ]; then
		# All already optimized, exit early
		exit 0
	fi
) | column -t

if [ "${dry_run}" = "true" ]; then
	exit 1
fi

echo
echo

if [ "${assume_yes}" != "true" ]; then
	read -p "Perform all optimizations[yn]: " -n 1 -r </dev/tty
	echo
	if [[ "$REPLY" =~ ^[Yy] ]]; then
		:
	else
		exit 1
	fi
fi
export dry_run=true
export assume_yes=true

(
	echo "CARD    TYPE  ITEM             ORIGINAL-VALUE  OPTIMIZED-VALUE"
	while read -r ETH_NAME; do
		for action in "${action_include_list[@]}"; do
			if _should_skip_action "${action}"; then
				continue
			fi
			_run_action_apply "${action}" "${ETH_NAME}"
		done

		echo
		echo

		if ! (run_by_systemd || [ "${dry_run}" = "true" ]); then
			# executed by user instead of by systemd during boot process
			# wait for the device to finish resetting, before perform the next card
			# to avoid both cards in bonding device being resetting at the same time,
			# making the whole bonding device unavaliable
			sleep 10
		fi
	done < <(get_filtered_ethernet_card_list)
) | column -t

echo "All optimizations above has been completed."
exit 0
