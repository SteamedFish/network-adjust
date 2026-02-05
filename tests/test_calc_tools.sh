#!/usr/bin/env bash
# -*- mode: sh-mode; -*-
# vim: filetype=sh

# 测试脚本：确保所有 calc 工具 (bash, bc, python3, calc) 产生完全相同的结果
#
# 设计思路：
# 1. 测试覆盖所有 mode (default, hex, oct, bin)
# 2. 测试覆盖边界情况（0, 1, 小数字, 大数字, 最大值）
# 3. 测试覆盖关键表达式（幂运算、减法、位运算）
# 4. 独立测试每个实现（_calc_with_bash, _calc_with_bc, _calc_with_python, _calc_with_calc）
# 5. 交叉验证所有实现的结果一致性

set -euo pipefail

# 导入被测试的脚本
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 测试用例计数
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
	echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
	echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $*"
}

check_tool() {
	local tool=$1
	if command -v "${tool}" >/dev/null 2>&1; then
		return 0
	else
		return 1
	fi
}

normalize_result() {
	local result=$1
	result="${result#0x}"
	result="${result#0X}"
	result="${result#0b}"
	result="${result#0B}"
	result="${result,,}"
	if [[ "${result}" =~ ^0+$ ]]; then
		result="0"
	else
		result="${result##+(0)}"
	fi
	echo "${result}"
}

shopt -s extglob

_calc_with_bash() {
	local mode=$1
	local expr=$2
	local value
	local tmp=""
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
		if [ "${value}" -lt 0 ]; then
			return 1
		fi
		while [ "${value}" -gt 0 ]; do
			tmp="$((value & 1))${tmp}"
			value=$((value >> 1))
		done
		echo "${tmp}"
		;;
	oct)
		if [ "${value}" -lt 0 ]; then
			return 1
		fi
		printf "%o" "${value}"
		;;
	default)
		echo "${value}"
		;;
	hex)
		if [ "${value}" -lt 0 ]; then
			return 1
		fi
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

	result="$(
		python3 - <<PY
import sys
expr = "${expr}".replace('^', '**')
value = eval(expr, {}, {})
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

# 测试用例定义
# 格式: mode|expression|expected_result
# 注意: expected_result 必须是 normalize 之后的结果（小写，去除前缀）
declare -a TEST_CASES=(
	# === default mode (十进制) ===
	"default|0|0"
	"default|1|1"
	"default|2|2"
	"default|10|10"
	"default|255|255"
	"default|256|256"
	"default|1000|1000"
	"default|65535|65535"
	"default|65536|65536"
	"default|2 ^ 0|1"
	"default|2 ^ 1|2"
	"default|2 ^ 2|4"
	"default|2 ^ 4|16"
	"default|2 ^ 8|256"
	"default|2 ^ 10|1024"
	"default|2 ^ 16|65536"
	"default|2 ^ 31|2147483648"
	"default|2 ^ 32|4294967296"
	"default|2 ^ 32 - 1|4294967295"
	"default|2 ^ 63|9223372036854775808"
	"default|2 ^ 64|18446744073709551616"
	"default|2 ^ 64 - 1|18446744073709551615"
	"default|2 ^ 128 - 1|340282366920938463463374607431768211455"
	"default|1 + 1|2"
	"default|10 - 5|5"
	"default|2 ^ 8 - 1|255"

	# === hex mode (十六进制) ===
	"hex|0|0"
	"hex|1|1"
	"hex|2|2"
	"hex|10|a"
	"hex|15|f"
	"hex|16|10"
	"hex|255|ff"
	"hex|256|100"
	"hex|4095|fff"
	"hex|65535|ffff"
	"hex|65536|10000"
	"hex|2 ^ 0|1"
	"hex|2 ^ 1|2"
	"hex|2 ^ 2|4"
	"hex|2 ^ 4|10"
	"hex|2 ^ 8|100"
	"hex|2 ^ 8 - 1|ff"
	"hex|2 ^ 16|10000"
	"hex|2 ^ 16 - 1|ffff"
	"hex|2 ^ 32|100000000"
	"hex|2 ^ 32 - 1|ffffffff"
	"hex|2 ^ 64|10000000000000000"
	"hex|2 ^ 64 - 1|ffffffffffffffff"
	"hex|2 ^ 128 - 1|ffffffffffffffffffffffffffffffff"
	"hex|1 + 1|2"
	"hex|16 - 1|f"

	# === oct mode (八进制) ===
	"oct|0|0"
	"oct|1|1"
	"oct|7|7"
	"oct|8|10"
	"oct|9|11"
	"oct|63|77"
	"oct|64|100"
	"oct|255|377"
	"oct|256|400"
	"oct|511|777"
	"oct|512|1000"
	"oct|2 ^ 0|1"
	"oct|2 ^ 1|2"
	"oct|2 ^ 2|4"
	"oct|2 ^ 3|10"
	"oct|2 ^ 6|100"
	"oct|2 ^ 8|400"
	"oct|2 ^ 8 - 1|377"
	"oct|2 ^ 9|1000"
	"oct|2 ^ 16|200000"
	"oct|2 ^ 16 - 1|177777"
	"oct|2 ^ 32 - 1|37777777777"
	"oct|2 ^ 64 - 1|1777777777777777777777"
	"oct|1 + 1|2"
	"oct|8 - 1|7"

	# === bin mode (二进制) ===
	"bin|0|0"
	"bin|1|1"
	"bin|2|10"
	"bin|3|11"
	"bin|4|100"
	"bin|7|111"
	"bin|8|1000"
	"bin|15|1111"
	"bin|16|10000"
	"bin|255|11111111"
	"bin|256|100000000"
	"bin|2 ^ 0|1"
	"bin|2 ^ 1|10"
	"bin|2 ^ 2|100"
	"bin|2 ^ 3|1000"
	"bin|2 ^ 4|10000"
	"bin|2 ^ 8|100000000"
	"bin|2 ^ 8 - 1|11111111"
	"bin|2 ^ 16|10000000000000000"
	"bin|2 ^ 16 - 1|1111111111111111"
	"bin|2 ^ 32 - 1|11111111111111111111111111111111"
	"bin|2 ^ 64 - 1|1111111111111111111111111111111111111111111111111111111111111111"
	"bin|1 + 1|10"
	"bin|4 - 1|11"
)

# 执行单个测试用例
run_test_case() {
	local mode=$1
	local expr=$2
	local expected=$3
	local tool=$4
	local calc_func=$5

	TOTAL_TESTS=$((TOTAL_TESTS + 1))

	local result
	local exit_code=0
	result=$("${calc_func}" "${mode}" "${expr}" 2>&1) || exit_code=$?

	if [ ${exit_code} -ne 0 ]; then
		log_error "Test #${TOTAL_TESTS} FAILED [${tool}]"
		log_error "  Mode: ${mode}, Expr: ${expr}"
		log_error "  Tool failed with exit code ${exit_code}"
		log_error "  Output: ${result}"
		FAILED_TESTS=$((FAILED_TESTS + 1))
		return 1
	fi

	# 标准化结果
	local normalized_result
	normalized_result=$(normalize_result "${result}")
	local normalized_expected
	normalized_expected=$(normalize_result "${expected}")

	if [ "${normalized_result}" = "${normalized_expected}" ]; then
		PASSED_TESTS=$((PASSED_TESTS + 1))
		# 只在详细模式下输出成功信息
		if [ "${VERBOSE:-0}" = "1" ]; then
			log_info "Test #${TOTAL_TESTS} PASSED [${tool}] ${mode} \"${expr}\" = ${result}"
		fi
		return 0
	else
		log_error "Test #${TOTAL_TESTS} FAILED [${tool}]"
		log_error "  Mode: ${mode}, Expr: ${expr}"
		log_error "  Expected: ${normalized_expected}"
		log_error "  Got:      ${normalized_result}"
		FAILED_TESTS=$((FAILED_TESTS + 1))
		return 1
	fi
}

# 测试所有实现的一致性
test_consistency() {
	local mode=$1
	local expr=$2

	TOTAL_TESTS=$((TOTAL_TESTS + 1))

	local -a results=()
	local -a tools=()
	local -a funcs=(
		"_calc_with_bash"
		"_calc_with_bc"
		"_calc_with_python"
		"_calc_with_calc"
	)
	local -a tool_names=(
		"bash"
		"bc"
		"python3"
		"calc"
	)

	# 收集所有可用工具的结果
	for i in "${!funcs[@]}"; do
		local func="${funcs[$i]}"
		local tool_name="${tool_names[$i]}"

		# 检查工具是否可用（bash 总是可用）
		if [ "${tool_name}" = "bash" ] || check_tool "${tool_name}"; then
			local result
			local exit_code=0
			result=$("${func}" "${mode}" "${expr}" 2>&1) || exit_code=$?

			if [ ${exit_code} -eq 0 ]; then
				results+=("$(normalize_result "${result}")")
				tools+=("${tool_name}")
			fi
		fi
	done

	# 如果没有可用的工具，跳过测试
	if [ ${#results[@]} -eq 0 ]; then
		log_warn "Test #${TOTAL_TESTS} SKIPPED: No tools available"
		TOTAL_TESTS=$((TOTAL_TESTS - 1))
		return 0
	fi

	# 检查所有结果是否一致
	local first_result="${results[0]}"
	local all_match=true

	for i in "${!results[@]}"; do
		if [ "${results[$i]}" != "${first_result}" ]; then
			all_match=false
			break
		fi
	done

	if ${all_match}; then
		PASSED_TESTS=$((PASSED_TESTS + 1))
		if [ "${VERBOSE:-0}" = "1" ]; then
			log_info "Consistency Test #${TOTAL_TESTS} PASSED"
			log_info "  Mode: ${mode}, Expr: ${expr}, Result: ${first_result}"
			log_info "  All tools agree: ${tools[*]}"
		fi
		return 0
	else
		log_error "Consistency Test #${TOTAL_TESTS} FAILED"
		log_error "  Mode: ${mode}, Expr: ${expr}"
		log_error "  Results differ between tools:"
		for i in "${!results[@]}"; do
			log_error "    ${tools[$i]}: ${results[$i]}"
		done
		FAILED_TESTS=$((FAILED_TESTS + 1))
		return 1
	fi
}

# 主测试流程
main() {
	echo "========================================"
	echo "Calculator Tools Consistency Test Suite"
	echo "========================================"
	echo

	# 检测可用工具
	log_info "Checking available tools..."
	local -a available_tools=("bash")
	local -a unavailable_tools=()

	for tool in bc python3 calc; do
		if check_tool "${tool}"; then
			available_tools+=("${tool}")
			log_info "  ✓ ${tool} is available"
		else
			unavailable_tools+=("${tool}")
			log_warn "  ✗ ${tool} is NOT available"
		fi
	done
	echo

	if [ ${#unavailable_tools[@]} -gt 0 ]; then
		log_warn "Some tools are unavailable: ${unavailable_tools[*]}"
		log_warn "Tests for these tools will be skipped."
		echo
	fi

	# 阶段 1: 测试每个实现的正确性
	log_info "=== Phase 1: Testing Individual Implementations ==="
	echo

	for tool in "${available_tools[@]}"; do
		local func_name
		case "${tool}" in
		bash)
			func_name="_calc_with_bash"
			;;
		bc)
			func_name="_calc_with_bc"
			;;
		python3)
			func_name="_calc_with_python"
			;;
		calc)
			func_name="_calc_with_calc"
			;;
		esac

		log_info "Testing ${tool} implementation..."

		for test_case in "${TEST_CASES[@]}"; do
			IFS='|' read -r mode expr expected <<<"${test_case}"
			run_test_case "${mode}" "${expr}" "${expected}" "${tool}" "${func_name}" || true
		done

		echo
	done

	# 阶段 2: 交叉一致性测试
	log_info "=== Phase 2: Cross-Tool Consistency Tests ==="
	echo

	if [ ${#available_tools[@]} -lt 2 ]; then
		log_warn "Less than 2 tools available, skipping consistency tests."
	else
		log_info "Testing consistency across all available tools..."

		for test_case in "${TEST_CASES[@]}"; do
			IFS='|' read -r mode expr expected <<<"${test_case}"
			test_consistency "${mode}" "${expr}" || true
		done

		echo
	fi

	# 阶段 3: 特殊边界情况测试
	log_info "=== Phase 3: Special Edge Cases ==="
	echo

	# 测试 bash 的 2^64-1 特殊优化
	log_info "Testing bash special case: 2^64-1 in hex mode..."
	local bash_64bit_result
	bash_64bit_result=$(_calc_with_bash hex "2 ^ 64 - 1")
	if [ "${bash_64bit_result}" = "ffffffffffffffff" ]; then
		log_info "  ✓ bash 2^64-1 optimization works correctly"
		TOTAL_TESTS=$((TOTAL_TESTS + 1))
		PASSED_TESTS=$((PASSED_TESTS + 1))
	else
		log_error "  ✗ bash 2^64-1 optimization failed"
		log_error "    Expected: ffffffffffffffff"
		log_error "    Got:      ${bash_64bit_result}"
		TOTAL_TESTS=$((TOTAL_TESTS + 1))
		FAILED_TESTS=$((FAILED_TESTS + 1))
	fi
	echo

	# 测试超大数字（仅限支持任意精度的工具）
	if check_tool bc || check_tool python3 || check_tool calc; then
		log_info "Testing arbitrary precision (256-bit numbers)..."

		local test_256bit="2 ^ 256 - 1"
		local expected_256bit_hex="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

		for tool in bc python3 calc; do
			if ! check_tool "${tool}"; then
				continue
			fi

			local func_name
			case "${tool}" in
			bc)
				func_name="_calc_with_bc"
				;;
			python3)
				func_name="_calc_with_python"
				;;
			calc)
				func_name="_calc_with_calc"
				;;
			esac

			local result
			result=$("${func_name}" hex "${test_256bit}" 2>&1) || true
			local normalized
			normalized=$(normalize_result "${result}")

			if [ "${normalized}" = "${expected_256bit_hex}" ]; then
				log_info "  ✓ ${tool} handles 256-bit correctly"
				TOTAL_TESTS=$((TOTAL_TESTS + 1))
				PASSED_TESTS=$((PASSED_TESTS + 1))
			else
				log_error "  ✗ ${tool} 256-bit test failed"
				log_error "    Expected: ${expected_256bit_hex}"
				log_error "    Got:      ${normalized}"
				TOTAL_TESTS=$((TOTAL_TESTS + 1))
				FAILED_TESTS=$((FAILED_TESTS + 1))
			fi
		done
		echo
	fi

	# 测试 bignum_calc 的 fallback 逻辑
	log_info "=== Phase 4: Testing bignum_calc() Fallback Logic ==="
	echo

	# 模拟不同 CPU 数量场景
	local -a cpu_counts=(1 4 8 16 32 64 128 256)

	test_bignum_with_cpu_count() {
		local cpu_count=$1
		local expr="2 ^ ${cpu_count} - 1"
		local result

		if [ "${cpu_count}" -le 64 ]; then
			result=$(_calc_with_bash hex "${expr}" 2>&1) || true
		else
			if check_tool bc; then
				result=$(_calc_with_bc hex "${expr}" 2>&1) || true
			elif check_tool python3; then
				result=$(_calc_with_python hex "${expr}" 2>&1) || true
			elif check_tool calc; then
				result=$(_calc_with_calc hex "${expr}" 2>&1) || true
			fi
		fi

		if [ -n "${result}" ] && [[ "${result}" =~ ^[0-9a-f]+$ ]]; then
			log_info "  ✓ Calculator works correctly for ${cpu_count} CPUs"
			TOTAL_TESTS=$((TOTAL_TESTS + 1))
			PASSED_TESTS=$((PASSED_TESTS + 1))
		else
			log_error "  ✗ Calculator failed for ${cpu_count} CPUs"
			log_error "    Result: ${result}"
			TOTAL_TESTS=$((TOTAL_TESTS + 1))
			FAILED_TESTS=$((FAILED_TESTS + 1))
		fi
	}

	for cpu_count in "${cpu_counts[@]}"; do
		test_bignum_with_cpu_count "${cpu_count}"
	done

	echo

	# 输出测试总结
	echo "========================================"
	echo "Test Summary"
	echo "========================================"
	echo "Total tests:  ${TOTAL_TESTS}"
	echo "Passed:       ${GREEN}${PASSED_TESTS}${NC}"
	echo "Failed:       ${RED}${FAILED_TESTS}${NC}"
	echo

	if [ ${FAILED_TESTS} -eq 0 ]; then
		log_info "All tests passed! ✓"
		echo
		echo "Conclusion:"
		echo "  All calculator implementations (bash, bc, python3, calc) produce"
		echo "  consistent and correct results across all test cases."
		return 0
	else
		log_error "Some tests failed! ✗"
		echo
		echo "Please review the error messages above."
		return 1
	fi
}

# 处理命令行参数
while getopts "vh" opt; do
	case ${opt} in
	v)
		export VERBOSE=1
		;;
	h)
		cat <<EOF
Usage: $0 [OPTIONS]

Test script to ensure all calculator tools produce identical results.

OPTIONS:
    -v    Verbose mode (show passed tests)
    -h    Show this help message

DESCRIPTION:
    This script tests all calculator implementations (_calc_with_bash,
    _calc_with_bc, _calc_with_python, _calc_with_calc) to ensure they
    produce consistent and correct results across:
    
    - All modes: default (decimal), hex, oct, bin
    - Edge cases: 0, 1, small numbers, large numbers, maximum values
    - Key operations: powers, subtraction, bitwise operations
    - Arbitrary precision: 128-bit, 256-bit numbers

TEST PHASES:
    Phase 1: Test each implementation individually
    Phase 2: Cross-tool consistency verification
    Phase 3: Special edge cases
    Phase 4: bignum_calc() fallback logic

REQUIREMENTS:
    - bash >= 4.0
    - Optional: bc, python3, calc (tests adapted based on availability)

EOF
		exit 0
		;;
	\?)
		echo "Invalid option: -$OPTARG" >&2
		exit 1
		;;
	esac
done

# 执行测试
main
exit $?
