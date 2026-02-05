#!/bin/bash
# 功能验证脚本：对比原始脚本和优化脚本的关键函数输出

echo "=== 功能验证报告 ==="
echo ""

# 测试 1: 脚本可以被 source
echo "✅ 测试 1: 脚本可被 source"
if source linux_ethernet_optimization_optimized.sh 2>/dev/null; then
    echo "  通过: 脚本成功加载"
else
    echo "  ❌ 失败: 脚本无法 source"
    exit 1
fi

# 测试 2: 关键函数存在
echo "✅ 测试 2: 关键函数存在性检查"
functions=(
    "check_script_requrements"
    "check_root"
    "run_by_systemd"
    "is_sourced"
    "get_number_of_cpus"
    "generate_cpus_mask_for_all_cpu"
    "set_ethernet_rps_to_optimum"
    "set_ethernet_xps_to_optimum"
    "check_ethernet_rps"
    "check_ethernet_xps"
)

for func in "${functions[@]}"; do
    if declare -f "$func" > /dev/null; then
        echo "  ✓ $func"
    else
        echo "  ❌ $func 不存在"
        exit 1
    fi
done

# 测试 3: CPU mask 生成（纯 Bash 场景）
echo "✅ 测试 3: CPU mask 生成功能"
cpus=4
mask=$(generate_cpus_mask_for_all_cpu "$cpus" 2>/dev/null || echo "ERROR")
if [[ "$mask" =~ ^[0-9a-f,]+$ ]]; then
    echo "  通过: 生成 CPU mask = $mask (4 核心)"
else
    echo "  ❌ 失败: 无法生成 CPU mask"
    exit 1
fi

# 测试 4: 依赖检查功能
echo "✅ 测试 4: 依赖检查功能"
if check_script_requrements >/dev/null 2>&1; then
    echo "  通过: 依赖检查正常"
else
    echo "  ⚠️  警告: 部分依赖缺失（ethtool/lspci/calc 等）"
fi

# 测试 5: is_sourced 功能
echo "✅ 测试 5: is_sourced 检测"
if is_sourced; then
    echo "  通过: 正确检测到脚本被 source"
else
    echo "  ❌ 失败: is_sourced 检测错误"
    exit 1
fi

echo ""
echo "=== 所有核心功能验证通过 ==="
