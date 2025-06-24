#!/bin/sh

# CPE状态监控脚本 - 开机启动守护进程版本
# 功能：每2秒检测CPE连接状态，CPE状态异常立即扫描频点并按PCI优先级锁频
#       在CPE状态恢复时发送钉钉通知消息
#       在指定时间点（6:50，16:30，18:30，20:30）检查并切换到PCI 141
# 兼容性：针对 OpenWrt busybox ash shell 优化

# 日志文件路径
LOG_FILE="/tmp/cpe_monitor.log"

# PID文件
PID_FILE="/tmp/cpe_monitor.pid"

# 全局变量：CPE状态异常时间记录（Unix时间戳|可读格式）
DISCONNECT_TIME=""

# 全局变量：上次日志检查时间（防止重复执行）
LAST_CHECK_TIME=""

# 全局变量：上次指定时间点检查时间（防止重复执行lock_cellular_141）
LAST_SPECIFIC_TIME_CHECK=""

# 全局变量：锁频开始时间记录（Unix时间戳|可读格式）
FREQUENCY_LOCK_TIME=""

# 获取文件大小
get_file_size() {
    local file="$1"
    local size=0

    if [ -f "$file" ]; then
        # 获取文件大小（字节）
        size=$(wc -c < "$file" 2>/dev/null || echo 0)
    fi

    echo "$size"
}

# 日志记录函数
# 参数1: 日志级别 (e.g., INFO, WARN, ERROR)
# 参数2: 日志消息
log_message() {
    local level="$1"
    local message="$2"

    # 如果日志文件不存在，创建并写入创建时间戳标记
    if [ ! -f "$LOG_FILE" ]; then
        local create_timestamp=$(date '+%s')
        echo "# LOG_CREATE_TIME=$create_timestamp" > "$LOG_FILE"
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" >> "$LOG_FILE"
}

# 发送钉钉消息的函数
send_dingtalk_message() {
    local message="$1"
    curl 'https://oapi.dingtalk.com/robot/send?access_token=028e1fd5646372f94b879538707c82d36965fbc767c22a605ead2254fe4a4905' \
    -H 'Content-Type: application/json' \
    -d "{\
        \"msgtype\": \"text\",\
        \"text\": {\
            \"content\": \"$message\"\
        },\
        \"at\": {\
            \"isAtAll\": false\
        }\
    }"
}

# 获取CPE信号强度（参考cpesel.sh的get_signal函数）
get_signal() {
    local _iface="cpe"
    local rsrp=""

    # 使用ubus获取CPE状态信息
    local cpe_status=$(ubus call infocd cpestatus 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$cpe_status" ]; then
        # 提取指定接口的状态信息
        local iface_info=$(echo "$cpe_status" | jsonfilter -e '@.*[@.status.name="'${_iface}'"]' 2>/dev/null)
        if [ -n "$iface_info" ]; then
            rsrp=$(echo "$iface_info" | jsonfilter -e '@.status.rsrp' 2>/dev/null)

            # 检查是否获取到有效的rsrp值
            if [ -n "$rsrp" ] && [ "$rsrp" != "null" ]; then
                echo "$rsrp"
                return 0
            fi
        fi
    fi

    # 如果获取失败，返回空值
    echo ""
    return 1
}

# 获取CPE状态
# 返回值：
#   0 - CPE状态正常，继续监控
#   1 - CPE状态异常，需要处理
#   2 - 跳过检测（非up状态但有信号）
get_cpe_status() {
    local _iface="cpe"
    local wan_status=""

    # 读取主状态文件
    wan_status=$(cat "/var/run/wanchk/iface_state/$_iface" 2>/dev/null)

    # 如果主状态为down，尝试读取IPv6状态
    if [ "$wan_status" = "down" ]; then
        wan_status=$(cat "/var/run/wanchk/iface_state/${_iface}_6" 2>/dev/null)
    fi

    # 根据状态判断处理方式
    case "$wan_status" in
        "up")
            return 0  # CPE状态正常
            ;;
        "down"|"block"|*)
            # 非up状态时检查信号强度
            local signal=$(get_signal)
            if [ $? -eq 0 ] && [ -n "$signal" ]; then
                # 有信号，清空锁频时间记录并跳过检测
                FREQUENCY_LOCK_TIME=""
                return 2
            else
                # 无信号，需要处理
                log_message "WARN" "CPE状态异常: $wan_status"
                return 1
            fi
            ;;
    esac
}

# 扫描附近频点
scan_frequencies() {
    local cache_file="/var/cpescan_cache_last_cpe"
    local current_time=$(date '+%s')
    local cache_valid_duration=600  # 10分钟 = 600秒

    # 检查缓存文件是否存在且有内容
    if [ -s "$cache_file" ]; then
        # 获取缓存文件的修改时间（针对OpenWrt优化）
        local cache_time=$(stat -c %Y "$cache_file" 2>/dev/null || echo "0")
        if [ "$cache_time" != "0" ]; then
            local time_diff=$((current_time - cache_time))

            # 如果缓存文件在10分钟内，直接返回缓存内容
            if [ $time_diff -lt $cache_valid_duration ]; then
                local scan_result=$(cat "$cache_file")
                echo "$scan_result"
                return 0
            fi
        fi
    fi

    # 执行新的扫描
    cpetools.sh -i cpe -c scan > "$cache_file"
    if [ $? -eq 0 ] && [ -s "$cache_file" ]; then
        local scan_result=$(cat "$cache_file")
        echo "$scan_result"
        return 0
    else
        log_message "ERROR" "频点扫描失败或结果为空"
        return 1
    fi
}

# 从扫描结果中提取可用的PCI、EARFCN和RSRP组合
parse_scan_result() {
    local scan_data="$1"
    local temp_file="/tmp/scan_result_$$"

    # 将扫描数据写入临时文件，避免管道子shell问题
    echo "$scan_data" > "$temp_file"

    # 使用jsonfilter解析JSON数据，提取NR模式的cell信息
    # 获取scanlist数组的长度
    local array_length=$(jsonfilter -i "$temp_file" -e '@.scanlist[#]' 2>/dev/null)

    if [ -z "$array_length" ] || [ "$array_length" = "0" ]; then
        log_message "WARN" "扫描结果为空或格式错误"
        rm -f "$temp_file"
        return 1
    fi

    # 遍历scanlist数组中的每个元素
    local i=0
    while [ $i -lt "$array_length" ]; do
        # 提取当前索引的cell信息
        local mode=$(jsonfilter -i "$temp_file" -e "@.scanlist[$i].MODE" 2>/dev/null)

        # 只处理NR模式的cell
        if [ "$mode" = "NR" ]; then
            local earfcn=$(jsonfilter -i "$temp_file" -e "@.scanlist[$i].EARFCN" 2>/dev/null)
            local pci=$(jsonfilter -i "$temp_file" -e "@.scanlist[$i].PCI" 2>/dev/null)
            local rsrp=$(jsonfilter -i "$temp_file" -e "@.scanlist[$i].RSRP" 2>/dev/null)

            # 验证提取的值是否有效
            if [ -n "$earfcn" ] && [ -n "$pci" ] && [ -n "$rsrp" ] && \
               [ "$earfcn" != "null" ] && [ "$pci" != "null" ] && [ "$rsrp" != "null" ]; then
                echo "$earfcn|$pci|$rsrp"
            fi
        fi

        i=$((i + 1))
    done

    # 清理临时文件
    rm -f "$temp_file"
}


# 按PCI优先级选择最佳频点组合
select_best_frequency() {
    local scan_data="$1"
    local available_combinations=$(parse_scan_result "$scan_data")

    # PCI优先级列表
    local priority_pcis="141 189 296 93"

    # 按优先级查找可用的PCI
    for priority_pci in $priority_pcis; do
        local match=$(echo "$available_combinations" | grep "|$priority_pci|" | head -1)
        if [ -n "$match" ]; then
            local earfcn=$(echo "$match" | cut -d'|' -f1)
            local pci=$(echo "$match" | cut -d'|' -f2)
            local rsrp=$(echo "$match" | cut -d'|' -f3)
            log_message "INFO" "选择频点组合: EARFCN=$earfcn, PCI=$pci, RSRP=$rsrp (优先级: $priority_pci)"
            echo "$earfcn|$pci"
            return 0
        fi
    done
    
    log_message "WARN" "未找到优先级PCI，根据RSRP最大值选择"
    # 根据RSRP最大值选择（RSRP值越大越好，即越接近0）
    # RSRP通常是负数，如-80dBm，值越大（越接近0）信号越好

    # 使用awk进行RSRP比较，避免shell循环中的变量作用域问题
    local best_match=$(echo "$available_combinations" | awk -F'|' '
    BEGIN {
        best_rsrp = ""
        best_line = ""
        combination_count = 0
    }
    {
        earfcn = $1
        pci = $2
        rsrp = $3

        if (earfcn != "" && pci != "" && rsrp != "") {
            combination_count++

            # 验证RSRP是否为有效整数
            if (rsrp ~ /^-?[0-9]+$/) {
                if (best_rsrp == "" || rsrp > best_rsrp) {
                    best_rsrp = rsrp
                    best_line = $0
                }
            }
        }
    }
    END {
        if (best_line != "") {
            print best_line "|" combination_count
        }
    }')

    if [ -n "$best_match" ]; then
        local earfcn=$(echo "$best_match" | cut -d'|' -f1)
        local pci=$(echo "$best_match" | cut -d'|' -f2)
        local rsrp=$(echo "$best_match" | cut -d'|' -f3)
        local combination_count=$(echo "$best_match" | cut -d'|' -f4)
        log_message "INFO" "选择RSRP最佳频点组合: EARFCN=$earfcn, PCI=$pci, RSRP=${rsrp}dBm (共检查${combination_count}个组合)"
        echo "$earfcn|$pci"
        return 0
    else
        log_message "ERROR" "未找到任何有效的频点组合"
        return 1
    fi
}

# 锁定到指定频点
lock_to_frequency() {
    local earfcn="$1"
    local pci="$2"
    
    if [ -z "$earfcn" ] || [ -z "$pci" ]; then
        log_message "ERROR" "锁频参数无效: EARFCN=$earfcn, PCI=$pci"
        return 1
    fi
    
    local current_pci5=$(uci -q get cpecfg.cpesim1.pci5)
    local current_earfcn5=$(uci -q get cpecfg.cpesim1.earfcn5)
    
    # 如果当前参数已经是目标组合，则无需切换
    if [ "$current_earfcn5" = "$earfcn" ] && [ "$current_pci5" = "$pci" ]; then
        log_message "INFO" "当前已是目标频点组合 EARFCN=$earfcn, PCI=$pci，无需切换"
        return 0
    fi
    
    # 使用uci设置earfcn5和pci5值
    uci set cpecfg.cpesim1.pci5="$pci"
    uci set cpecfg.cpesim1.earfcn5="$earfcn"
    uci commit cpecfg
    
    if [ $? -eq 0 ]; then
        log_message "INFO" "参数已从 earfcn5=$current_earfcn5,pci5=$current_pci5 切换到 earfcn5=$earfcn,pci5=$pci"

        # 记录锁频开始时间
        local timestamp=$(date '+%s')
        local readable_time=$(date '+%Y-%m-%d %H:%M:%S')
        FREQUENCY_LOCK_TIME="${timestamp}|${readable_time}"

        # 执行更新命令
        cpetools.sh -u
        if [ $? -eq 0 ]; then
            return 0
        else
            log_message "WARN" "更新命令执行失败"
            return 1
        fi
    else
        log_message "ERROR" "参数切换失败 (uci commit 失败)"
        return 1
    fi
}

# 智能锁频处理 - 检查锁频超时并切换频点
handle_frequency_lock() {
    # 检查是否有锁频时间记录
    if [ -z "$FREQUENCY_LOCK_TIME" ]; then
        log_message "INFO" "无锁频时间记录，立即尝试锁频"
        # 按默认顺序依次切换频点
        try_default_frequencies
        return 0
    fi

    # 从变量中提取时间戳和可读时间
    local lock_start_timestamp=$(echo "$FREQUENCY_LOCK_TIME" | cut -d'|' -f1)
    local lock_start_readable=$(echo "$FREQUENCY_LOCK_TIME" | cut -d'|' -f2)

    # 计算锁频持续时间
    local current_timestamp=$(date '+%s')
    local lock_duration=$((current_timestamp - lock_start_timestamp))


    # 如果锁频超过30秒，开始按默认顺序切换频点
    if [ $lock_duration -gt 30 ]; then
        log_message "INFO" "锁频超过30秒，开始按默认顺序切换频点"

        # 清空锁频时间记录，避免重复触发
        FREQUENCY_LOCK_TIME=""

        # 按默认顺序依次切换频点
        try_default_frequencies
    fi
}

# 尝试默认频点配置
try_default_frequencies() {
    log_message "INFO" "开始尝试默认频点配置策略"

    # 默认频点配置列表（按优先级排序）
    local default_frequencies="627264|296 633984|189 633984|93 633984|141"

    # 获取当前配置
    local current_pci5=$(uci -q get cpecfg.cpesim1.pci5)
    local current_earfcn5=$(uci -q get cpecfg.cpesim1.earfcn5)
    local current_combination="${current_earfcn5}|${current_pci5}"

    # 遍历默认频点配置
    for freq_combination in $default_frequencies; do
        local earfcn=$(echo "$freq_combination" | cut -d'|' -f1)
        local pci=$(echo "$freq_combination" | cut -d'|' -f2)

        # 跳过当前已经配置的组合
        if [ "$freq_combination" = "$current_combination" ]; then
            continue
        fi

        log_message "INFO" "尝试默认频点配置: EARFCN=$earfcn, PCI=$pci"
        if lock_to_frequency "$earfcn" "$pci"; then
            log_message "INFO" "成功切换到默认频点配置: EARFCN=$earfcn, PCI=$pci"
            return 0
        else
            log_message "WARN" "默认频点配置切换失败: EARFCN=$earfcn, PCI=$pci，尝试下一个"
        fi
    done

    log_message "ERROR" "所有默认频点配置尝试失败"
    return 1
}

# 直接切换到earfcn5=633984,pci5=141（用于特定时间点检查）
lock_cellular_141() {
    local current_pci5=$(uci -q get cpecfg.cpesim1.pci5)

    # 如果当前PCI已经是141，则无需处理
    if [ "$current_pci5" = "141" ]; then
        return 0
    fi

    log_message "INFO" "当前PCI不是141，开始扫描频点查找PCI 141"

    local scan_result=$(scan_frequencies)
    if [ $? -eq 0 ] && [ -n "$scan_result" ]; then
        # 查找PCI 141的频点组合
        local pci_141_combination=$(parse_scan_result "$scan_result" | grep "|141|")
        if [ -n "$pci_141_combination" ]; then
            local earfcn=$(echo "$pci_141_combination" | cut -d'|' -f1)
            log_message "INFO" "找到PCI 141，EARFCN=$earfcn，开始切换"
            lock_to_frequency "$earfcn" "141"
        else
            log_message "WARN" "扫描结果中未找到PCI 141"
        fi
    else
        log_message "ERROR" "频点扫描失败，无法检查PCI 141"
    fi
}

# 处理CPE状态恢复的函数
handle_status_recovery() {
    # 清空锁频时间记录（CPE状态恢复时）
    if [ -n "$FREQUENCY_LOCK_TIME" ]; then
        FREQUENCY_LOCK_TIME=""
    fi

    # 如果存在CPE状态异常记录则发送钉钉消息并清空记录变量
    if [ -n "$DISCONNECT_TIME" ]; then
        # 获取当前时间
        local current_time=$(date '+%Y-%m-%d %H:%M:%S')

        # 从变量中分别提取时间戳和可读时间
        local disconnect_time=$(echo "$DISCONNECT_TIME" | cut -d'|' -f1)
        local disconnect_readable_time=$(echo "$DISCONNECT_TIME" | cut -d'|' -f2)

        # 计算CPE状态异常持续时间（秒）
        local current_timestamp=$(date '+%s')
        local duration=$((current_timestamp - disconnect_time))

        # 转换为可读格式（小时:分钟:秒）
        local hours=$((duration / 3600))
        local minutes=$(((duration % 3600) / 60))
        local seconds=$((duration % 60))
        local duration_readable="${hours}小时${minutes}分钟${seconds}秒"

        # 获取当前PCI5值
        local current_pci5=$(uci -q get cpecfg.cpesim1.pci5)

        # 构建消息内容
        local message="CPE状态通知:\n- CPE异常时间: ${disconnect_readable_time}\n- 恢复时间: ${current_time}\n- 异常持续: ${duration_readable}\n- 当前PCI5值: ${current_pci5}"

        # 延迟10秒后发送钉钉消息
        log_message "INFO" "准备发送钉钉通知消息（10秒后发送）"
        sleep 10
        send_dingtalk_message "$message"
        local dingtalk_result=$?
        if [ $dingtalk_result -eq 0 ]; then
            log_message "INFO" "CPE状态已恢复正常，钉钉通知发送成功"
        else
            log_message "WARN" "CPE状态已恢复正常，钉钉通知发送失败，退出码: $dingtalk_result"
        fi

        # 清空CPE状态异常时间记录变量
        DISCONNECT_TIME=""
    fi
}

# 检查是否在指定时间点（6:50，16:30，18:30，20:30）
check_specific_time() {
    # 获取当前小时和分钟
    local current_hour=$(date '+%H')
    local current_minute=$(date '+%M')
    local current_time="${current_hour}:${current_minute}"

    # 检查是否为指定的时间点
    case "$current_time" in
        "06:50"|"16:30"|"18:30"|"20:30")
            # 添加防重复执行机制
            local current_time_key="$(date '+%Y-%m-%d-%H-%M')"
            if [ "$LAST_SPECIFIC_TIME_CHECK" = "$current_time_key" ]; then
                return 1  # 同一分钟内已执行过，跳过
            fi
            LAST_SPECIFIC_TIME_CHECK="$current_time_key"
            return 0  # 是指定时间点且未重复执行
            ;;
        *)
            return 1  # 不是指定时间点
            ;;
    esac
}

# 检查并清空日志文件的函数
# 日志文件缓存36小时，或日志文件大于8MB时清空
check_and_clear_log() {
    # 添加分钟级别的防重复机制
    local current_time_key="$(date '+%Y-%m-%d-%H-%M')"
    if [ "$LAST_CHECK_TIME" = "$current_time_key" ]; then
        return 0  # 同一分钟内已检查过，跳过
    fi
    LAST_CHECK_TIME="$current_time_key"

    local should_clear=false
    local clear_reason=""

    # 检查日志文件是否存在
    if [ ! -f "$LOG_FILE" ]; then
        return 0  # 日志文件不存在，无需处理
    fi

    # 检查日志文件大小是否超过8MB
    local file_size=$(get_file_size "$LOG_FILE")
    # 8MB = 8388608 字节
    if [ "$file_size" -gt 8388608 ]; then
        should_clear=true
        clear_reason="文件大小超过8MB"
    else
        # 检查日志文件是否超过36小时（使用文件中记录的创建时间戳）
        local current_timestamp=$(date '+%s')
        local create_timestamp=""

        # 从日志文件第一行读取创建时间戳
        if [ -f "$LOG_FILE" ]; then
            local first_line=$(head -1 "$LOG_FILE" 2>/dev/null)
            if echo "$first_line" | grep -q "^# LOG_CREATE_TIME="; then
                create_timestamp=$(echo "$first_line" | sed 's/^# LOG_CREATE_TIME=//')
            fi
        fi

        # 如果找到创建时间戳，检查是否超过36小时
        if [ -n "$create_timestamp" ] && [ "$create_timestamp" -gt 0 ]; then
            local time_diff=$((current_timestamp - create_timestamp))
            # 36小时 = 129600秒
            if [ "$time_diff" -gt 129600 ]; then
                should_clear=true
                clear_reason="日志文件超过36小时缓存期"
            fi
        fi
    fi

    # 执行清空操作
    if [ "$should_clear" = true ]; then
        # 清空日志文件并重新写入创建时间戳
        local new_create_timestamp=$(date '+%s')
        echo "# LOG_CREATE_TIME=$new_create_timestamp" > "$LOG_FILE"

        # 记录清理操作
        log_message "INFO" "日志文件已清空 - 原因: $clear_reason"
        log_message "INFO" "清理时间: $(date '+%Y-%m-%d %H:%M:%S')"
    fi
}

# CPE状态监控核心逻辑（通用函数）
perform_network_monitoring() {
    # 获取CPE状态（合并了锁定检查和CPE状态检查）
    get_cpe_status
    local status_result=$?

    case $status_result in
        0)
            # CPE状态正常
            # 检查是否在指定时间点
            if check_specific_time; then
                # 在指定时间点，检查是否需要切换到PCI 141
                log_message "INFO" "到达指定时间点，检查PCI 141状态"
                lock_cellular_141
            fi

            # 处理CPE状态恢复
            handle_status_recovery
            ;;
        1)
            # CPE状态异常
            if [ -z "$DISCONNECT_TIME" ]; then
                # 记录CPE状态异常时间（Unix时间戳和可读格式，用|分隔）
                local timestamp=$(date '+%s')
                local readable_time=$(date '+%Y-%m-%d %H:%M:%S')
                DISCONNECT_TIME="${timestamp}|${readable_time}"
                log_message "INFO" "CPE状态异常，开始记录异常时间: $readable_time"
            fi

            # CPE状态异常立即进行智能锁频
            handle_frequency_lock
            ;;
        2)
            # 跳过检测（非up状态但有信号）
            return 1  # 返回1表示跳过检测
            ;;
    esac

    return 0  # 返回0表示正常执行
}

# 守护进程主循环
daemon_loop() {
    log_message "INFO" "CPE状态监控守护进程启动"

    while true; do
        # 检查并清空日志文件（36小时缓存期或文件大于8MB时）
        check_and_clear_log

        # 执行CPE状态监控核心逻辑
        if perform_network_monitoring; then
            # 正常执行，等待2秒后继续下一次检测
            sleep 2
        else
            # 跳过检测（如在锁频等待期），等待2秒后继续
            sleep 2
        fi
    done
}

# 启动守护进程
start_daemon() {
    # 检查是否已经在运行
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "CPE状态监控守护进程已在运行 (PID: $old_pid)"
            exit 1
        else
            # PID文件存在但进程不存在，删除旧的PID文件
            rm -f "$PID_FILE"
        fi
    fi

    # 记录当前进程PID
    echo $$ > "$PID_FILE"

    # 启动守护进程循环
    daemon_loop
}

# 停止守护进程
stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$PID_FILE"
            echo "CPE状态监控守护进程已停止 (PID: $pid)"
        else
            echo "守护进程未运行"
            rm -f "$PID_FILE"
        fi
    else
        echo "守护进程未运行"
    fi
}

# 检查守护进程状态
status_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "CPE状态监控守护进程正在运行 (PID: $pid)"
        else
            echo "守护进程未运行（PID文件存在但进程不存在）"
            rm -f "$PID_FILE"
        fi
    else
        echo "守护进程未运行"
    fi
}

# 命令行参数处理
case "$1" in
    "start")
        echo "启动CPE状态监控守护进程"
        start_daemon
        ;;
    "stop")
        echo "停止CPE状态监控守护进程"
        stop_daemon
        ;;
    "restart")
        echo "重启CPE状态监控守护进程"
        stop_daemon
        sleep 2
        start_daemon
        ;;
    "status")
        status_daemon
        ;;
    "-c")
        echo "执行单次检测 (perform_network_monitoring)"
        perform_network_monitoring
        ;;
    "-s")
        echo "执行频点扫描测试"
        scan_result=$(scan_frequencies)
        if [ $? -eq 0 ]; then
            echo "扫描成功，结果:"
            echo "$scan_result"
            echo ""
            echo "解析结果:"
            parse_scan_result "$scan_result"
        else
            echo "扫描失败"
        fi
        ;;
    "-r")
        echo "执行锁定到141 (lock_cellular_141)"
        lock_cellular_141
        ;;
    "-g")
        echo "获取CPE信号强度 (get_signal)"
        signal=$(get_signal)
        if [ $? -eq 0 ] && [ -n "$signal" ]; then
            echo "信号强度 (RSRP): $signal dBm"
        else
            echo "无法获取信号强度"
            exit 1
        fi
        ;;
    "-n")
        echo "执行CPE状态检测 (get_cpe_status)"
        get_cpe_status
        status_result=$?
        case $status_result in
            0) echo "CPE状态正常" ;;
            1) echo "CPE状态异常"; exit 1 ;;
            2) echo "跳过检测 - 非up状态但有信号"; exit 2 ;;
        esac
        ;;
    "")
        echo "默认启动守护进程模式"
        start_daemon
        ;;
    *)
        echo "用法: $0 [start|stop|restart|status|-c|-s|-r|-g|-n|-l]"
        echo "  start:    启动守护进程（默认）"
        echo "  stop:     停止守护进程"
        echo "  restart:  重启守护进程"
        echo "  status:   查看守护进程状态"
        echo "  -c:       执行单次CPE状态检测"
        echo "  -s:       执行频点扫描测试"
        echo "  -r:       执行锁定到PCI 141"
        echo "  -g:       获取CPE信号强度"
        echo "  -n:       执行CPE状态检测"
        echo ""
        echo "测试命令:"
        echo "  -g:       显示当前CPE信号强度 (RSRP值)"
        echo "  -n:       测试CPE状态是否正常"
        echo ""
        echo "守护进程功能:"
        echo "  - 每2秒检测CPE连接状态"
        echo "  - CPE状态异常立即按默认顺序切换频点"
        echo "  - 锁频超过30秒时按默认顺序依次切换频点"
        echo "  - 在6:50,16:30,18:30,20:30检查PCI 141"
        echo "  - CPE状态恢复时发送钉钉通知"
        echo ""
        exit 1
        ;;
esac