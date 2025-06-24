#!/bin/sh

# 网络监控脚本 - 开机启动守护进程版本
# 功能：每1秒检测网络连接状态，断网立即扫描频点并按PCI优先级锁频
#       在网络恢复时发送钉钉通知消息
#       在指定时间点（6:50，8:50，14:50，16:50，18:50，20:50）检查是否需要切换到PCI 141

# 日志文件路径
LOG_FILE="/tmp/network_monitor.log"

# PID文件
PID_FILE="/tmp/network_monitor.pid"

# 全局变量：断网时间记录（Unix时间戳|可读格式）
DISCONNECT_TIME=""

# 全局变量：上次日志清理日期
LAST_LOG_CLEAR_DATE=""

# 全局变量：上次日志检查时间（防止重复执行）
LAST_CHECK_TIME=""

# 全局变量：上次指定时间点检查时间（防止重复执行lock_cellular_141）
LAST_SPECIFIC_TIME_CHECK=""

# 日志记录函数
# 参数1: 日志级别 (e.g., INFO, WARN, ERROR)
# 参数2: 日志消息
log_message() {
    local level="$1"
    local message="$2"
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
    local up=""
    local uptime=""

    # 使用ubus获取CPE状态信息
    local cpe_status=$(ubus call infocd cpestatus 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$cpe_status" ]; then
        # 提取指定接口的状态信息
        local iface_info=$(echo "$cpe_status" | jsonfilter -e '@.*[@.status.name="'${_iface}'"]' 2>/dev/null)
        if [ -n "$iface_info" ]; then
            up=$(echo "$iface_info" | jsonfilter -e '@.up' 2>/dev/null)
            uptime=$(echo "$iface_info" | jsonfilter -e '@.uptime' 2>/dev/null)
            rsrp=$(echo "$iface_info" | jsonfilter -e '@.status.rsrp' 2>/dev/null)

            # 检查接口状态：up=0且uptime>0表示连接正常
            if [ "$up" = "0" ] && [ -n "$uptime" ] && [ "$uptime" -gt 0 ]; then
                echo "$rsrp"
                return 0
            fi
        fi
    fi

    # 如果获取失败，返回空值
    echo ""
    return 1
}

# 获取WAN连接状态（参考cpesel.sh的get_wanchk_state函数）
get_wanchk_state() {
    local _iface_name="cpe"
    local _iface=""
    local status=""

    # 获取网络接口名称
    _iface=$(uci -q get "network.$_iface_name.network_ifname")
    [ -z "$_iface" ] && _iface="$_iface_name"

    # 读取接口状态文件
    status=$(cat "/var/run/wanchk/iface_state/$_iface" 2>/dev/null)

    # 如果状态为down，尝试读取IPv6状态
    if [ "$status" = "down" ]; then
        status=$(cat "/var/run/wanchk/iface_state/${_iface}_6" 2>/dev/null)
    fi

    echo "$status"
}

# 检测网络连接（基于wanchk状态）
check_cpe_status() {
    local wan_status=$(get_wanchk_state)

    if [ "$wan_status" = "up" ]; then
        log_message "DEBUG" "网络状态正常: $wan_status"
        return 0  # 网络正常
    elif [ "$wan_status" = "down" ]; then
        log_message "WARN" "网络状态异常: $wan_status"
        return 1  # 网络异常
    elif [ "$wan_status" = "block" ]; then
        log_message "INFO" "网络状态被阻塞: $wan_status (CPE可能处于锁定或暂停状态)"
        return 1  # 网络被阻塞，视为异常
    else
        # 如果无法获取状态或状态为空，记录详细信息
        log_message "WARN" "无法获取网络状态或状态未知: '$wan_status'"

        # 检查状态文件是否存在
        if [ ! -d "/var/run/wanchk/iface_state" ]; then
            log_message "WARN" "wanchk状态目录不存在: /var/run/wanchk/iface_state"
        fi

        return 1  # 网络异常
    fi
}

# 扫描附近频点
scan_frequencies() {
    log_message "INFO" "开始扫描附近频点"
    cpetools.sh -i cpe -c scan > /var/cpescan_cache_last_cpe
    if [ $? -eq 0 ] && [ -s "/var/cpescan_cache_last_cpe" ]; then
        log_message "INFO" "频点扫描成功，结果已保存到 /var/cpescan_cache_last_cpe"
        local scan_result=$(cat /var/cpescan_cache_last_cpe)
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
    
    log_message "INFO" "可用频点组合: $available_combinations"
    
    # 按优先级查找可用的PCI
    for priority_pci in $priority_pcis; do
        local match=$(echo "$available_combinations" | grep "|$priority_pci|" | head -1)
        if [ -n "$match" ]; then
            local earfcn=$(echo "$match" | cut -d'|' -f1)
            local pci=$(echo "$match" | cut -d'|' -f2)
            log_message "INFO" "选择频点组合: EARFCN=$earfcn, PCI=$pci (优先级: $priority_pci)"
            echo "$earfcn|$pci"
            return 0
        fi
    done
    
    log_message "WARN" "未找到优先级PCI，根据RSRP最大值选择"
    # 根据RSRP最大值选择（RSRP值越大越好，即越接近0）
    local best_match=$(echo "$available_combinations" | awk -F'|' '{
        rsrp = $3
        gsub(/^-/, "", rsrp)  # 移除负号进行数值比较
        if (NR == 1 || rsrp < min_rsrp) {
            min_rsrp = rsrp
            best_line = $0
        }
    } END { print best_line }')
    
    if [ -n "$best_match" ]; then
        local earfcn=$(echo "$best_match" | cut -d'|' -f1)
        local pci=$(echo "$best_match" | cut -d'|' -f2)
        local rsrp=$(echo "$best_match" | cut -d'|' -f3)
        log_message "INFO" "选择RSRP最佳频点组合: EARFCN=$earfcn, PCI=$pci, RSRP=$rsrp"
        echo "$earfcn|$pci"
        return 0
    else
        log_message "ERROR" "未找到任何可用的频点组合"
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
        # 执行更新命令
        log_message "INFO" "开始执行更新命令: cpetools.sh -u"
        cpetools.sh -u
        if [ $? -eq 0 ]; then
            log_message "INFO" "更新命令执行成功"

            # 15秒后再次执行锁频（后台执行）
            (
                sleep 15
                log_message "INFO" "15秒后再次执行锁频更新命令"

                # 再次执行更新命令
                cpetools.sh -u
                if [ $? -eq 0 ]; then
                    log_message "INFO" "15秒后锁频更新命令执行成功"
                else
                    log_message "WARN" "15秒后锁频更新命令执行失败"
                fi
            ) &

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

# 断网时的智能锁频处理
handle_network_disconnect() {
    log_message "INFO" "开始处理断网情况，扫描并锁定最佳频点"
    
    local scan_result=$(scan_frequencies)
    if [ $? -eq 0 ] && [ -n "$scan_result" ]; then
        local best_combination=$(select_best_frequency "$scan_result")
        if [ -n "$best_combination" ]; then
            local earfcn=$(echo "$best_combination" | cut -d'|' -f1)
            local pci=$(echo "$best_combination" | cut -d'|' -f2)
            lock_to_frequency "$earfcn" "$pci"
        else
            log_message "ERROR" "无法选择最佳频点组合"
        fi
    else
        log_message "ERROR" "频点扫描失败，无法进行智能锁频"
    fi
}

# 检查CPE是否处于锁定状态（基于wanchk状态文件）
is_cpe_locked() {
    local cpe_lock_status=""
    local cpe_state_name="cpe"

    # 检查CPE锁定状态文件
    cpe_lock_status=$(cat "/var/run/wanchk/iface_state/${cpe_state_name}_lock" 2>/dev/null)

    if [ "$cpe_lock_status" = "lock" ]; then
        log_message "DEBUG" "CPE处于锁定状态，跳过网络检测"
        return 0  # CPE被锁定
    elif [ "$cpe_lock_status" = "unlock" ]; then
        log_message "DEBUG" "CPE解锁状态，继续网络检测"
        return 1  # CPE未被锁定
    else
        # 如果锁定状态文件不存在或状态未知，检查CPE状态是否为block
        local cpe_status=$(cat "/var/run/wanchk/iface_state/${cpe_state_name}" 2>/dev/null)
        if [ "$cpe_status" = "block" ]; then
            log_message "DEBUG" "CPE状态为block，跳过网络检测"
            return 0  # CPE被阻塞
        else
            # 如果没有锁定状态且不是block状态，检查是否有cpetools进程在运行
            local cpetools_running=$(pgrep -f "cpetools" 2>/dev/null)
            if [ -n "$cpetools_running" ]; then
                log_message "DEBUG" "检测到cpetools进程正在运行，可能正在锁频操作"
                return 0  # 可能正在进行锁频操作
            else
                log_message "DEBUG" "CPE未处于锁定状态，继续网络检测"
                return 1  # CPE未被锁定
            fi
        fi
    fi
}

# 获取限速信息（参考get_speedlimit_info）
get_speedlimit_info() {
    local support_status=$(uci -q get cloudd.limit.support)
    local has_enabled_rules=0
    local enabled_rules=""

    # 检查是否支持限速
    if [ "$support_status" != "1" ]; then
        echo "support=0"
        return 1
    fi

    # 检查是否有启用的限速规则
    uci -q foreach cloudd speedlimit '
        local rule_name="$1"
        local rule_enabled=$(uci -q get cloudd.$rule_name.enabled)
        if [ "$rule_enabled" = "1" ]; then
            has_enabled_rules=1
            if [ -z "$enabled_rules" ]; then
                enabled_rules="$rule_name"
            else
                enabled_rules="$enabled_rules,$rule_name"
            fi
        fi
    '

    if [ $has_enabled_rules -eq 1 ]; then
        echo "support=1,enabled_rules=$enabled_rules"
        return 0
    else
        echo "support=1,enabled_rules=none"
        return 1
    fi
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

# 检查是否需要进行智能锁频
# 返回值: 0 表示需要锁频, 1 表示不需要锁频
should_do_smart_lock() {
    if [ -z "$DISCONNECT_TIME" ]; then
        return 1 # 没有断网记录，不需要锁频
    else
        # 断网立即进行智能锁频
        return 0 # 有断网记录，立即进行智能锁频
    fi
}

# 处理网络恢复的函数
handle_network_recovery() {
    # 如果存在断网记录则发送钉钉消息并清空记录变量
    if [ -n "$DISCONNECT_TIME" ]; then
        # 获取当前时间
        local current_time=$(date '+%Y-%m-%d %H:%M:%S')
        
        # 从变量中分别提取时间戳和可读时间
        local disconnect_time=$(echo "$DISCONNECT_TIME" | cut -d'|' -f1)
        local disconnect_readable_time=$(echo "$DISCONNECT_TIME" | cut -d'|' -f2)
        
        # 计算断网持续时间（秒）
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
        local message="网络状态通知:\n- 断网时间: ${disconnect_readable_time}\n- 恢复时间: ${current_time}\n- 断网持续: ${duration_readable}\n- 当前PCI5值: ${current_pci5}"
        
        # 发送钉钉消息
        log_message "INFO" "准备发送钉钉通知消息"
        send_dingtalk_message "$message"
        local dingtalk_result=$?
        if [ $dingtalk_result -eq 0 ]; then
            log_message "INFO" "网络已恢复连接，钉钉通知发送成功"
        else
            log_message "WARN" "网络已恢复连接，钉钉通知发送失败，退出码: $dingtalk_result"
        fi
        
        # 清空断网时间记录变量
        DISCONNECT_TIME=""
    fi
}

# 检查是否在指定时间点（6:50，8:50，12:50，14:50，16:50，18:50，20:50）
check_specific_time() {
    # 获取当前小时和分钟
    local current_hour=$(date '+%H')
    local current_minute=$(date '+%M')
    local current_time="${current_hour}:${current_minute}"

    # 检查是否为指定的时间点
    case "$current_time" in
        "06:50"|"08:50"|"14:50"|"16:50"|"18:50"|"20:50")
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
# 每天0:00清空日志文件，或者当日志文件大于10MB时清空
check_and_clear_log() {
    # 添加分钟级别的防重复机制
    local current_time_key="$(date '+%Y-%m-%d-%H-%M')"
    if [ "$LAST_CHECK_TIME" = "$current_time_key" ]; then
        return 0  # 同一分钟内已检查过，跳过
    fi
    LAST_CHECK_TIME="$current_time_key"
    
    local current_date=$(date '+%Y-%m-%d')
    local current_hour=$(date '+%H')
    local current_minute=$(date '+%M')
    local should_clear=false
    local clear_reason=""
    
    # 检查是否为每天0:00
    if [ "$current_hour" = "00" ] && [ "$current_minute" = "00" ]; then
        if [ "$LAST_LOG_CLEAR_DATE" != "$current_date" ]; then
            should_clear=true
            clear_reason="每日定时清理"
            LAST_LOG_CLEAR_DATE="$current_date"
        fi
    fi
    
    # 检查日志文件大小是否超过10MB
    if [ -f "$LOG_FILE" ]; then
        # 获取文件大小（字节）
        local file_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        # 10MB = 10485760 字节
        if [ "$file_size" -gt 10485760 ]; then
            should_clear=true
            clear_reason="文件大小超过10MB"
        fi
    fi
    
    # 执行清空操作
    if [ "$should_clear" = true ]; then
        # 备份最后几行日志信息
        local backup_info=""
        if [ -f "$LOG_FILE" ]; then
            backup_info=$(tail -n 5 "$LOG_FILE" 2>/dev/null || echo "")
        fi
        
        # 清空日志文件
        > "$LOG_FILE"
        
        # 记录清理操作
        log_message "INFO" "日志文件已清空 - 原因: $clear_reason"
        log_message "INFO" "清理时间: $(date '+%Y-%m-%d %H:%M:%S')"
        
        # 如果有备份信息，记录最后的状态
        if [ -n "$backup_info" ]; then
            log_message "INFO" "清理前最后状态:"
            echo "$backup_info" | while IFS= read -r line; do
                if [ -n "$line" ]; then
                    log_message "INFO" "  $line"
                fi
            done
        fi
    fi
}

# 网络监控核心逻辑（通用函数）
perform_network_monitoring() {
    # 检查CPE是否处于锁定状态
    if is_cpe_locked; then
        return 1  # 返回1表示跳过检测
    fi

    # 检查网络连接
    if ! check_cpe_status; then
        # 网络断开
        if [ -z "$DISCONNECT_TIME" ]; then
            # 记录断网时间（Unix时间戳和可读格式，用|分隔）
            local timestamp=$(date '+%s')
            local readable_time=$(date '+%Y-%m-%d %H:%M:%S')
            DISCONNECT_TIME="${timestamp}|${readable_time}"
            log_message "INFO" "网络断开，开始记录断网时间: $readable_time"
        else
            # 检查是否需要进行智能锁频
            if should_do_smart_lock; then
                # 断网立即进行智能锁频
                handle_network_disconnect
            fi
        fi
    else
        # 网络已连接
        
        # 检查是否在指定时间点
        if check_specific_time; then
            # 在指定时间点，检查是否需要切换到PCI 141
            log_message "INFO" "到达指定时间点，检查PCI 141状态"
            lock_cellular_141
        fi

        # 处理网络恢复
        handle_network_recovery
    fi
    
    return 0  # 返回0表示正常执行
}

# 守护进程主循环
daemon_loop() {
    log_message "INFO" "网络监控守护进程启动"
    
    while true; do
        # 检查并清空日志文件（每天0:00或文件大于10MB时）
        check_and_clear_log
        
        # 执行网络监控核心逻辑
        if perform_network_monitoring; then
            # 正常执行，等待1秒后继续下一次检测
            sleep 1
        else
            # 跳过检测（如在锁频等待期），等待1秒后继续
            sleep 1
        fi
    done
}

# 启动守护进程
start_daemon() {
    # 检查是否已经在运行
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "网络监控守护进程已在运行 (PID: $old_pid)"
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
            echo "网络监控守护进程已停止 (PID: $pid)"
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
            echo "网络监控守护进程正在运行 (PID: $pid)"
        else
            echo "守护进程未运行（PID文件存在但进程不存在）"
            rm -f "$PID_FILE"
        fi
    else
        echo "守护进程未运行"
    fi
}

# 单次执行主程序（兼容旧版本）
main() {
    # 执行网络监控核心逻辑
    perform_network_monitoring
}

# 命令行参数处理
case "$1" in
    "start")
        echo "启动网络监控守护进程"
        start_daemon
        ;;
    "stop")
        echo "停止网络监控守护进程"
        stop_daemon
        ;;
    "restart")
        echo "重启网络监控守护进程"
        stop_daemon
        sleep 2
        start_daemon
        ;;
    "status")
        status_daemon
        ;;
    "-c")
        echo "执行单次检测 (main)"
        main
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
    "-w")
        echo "获取WAN连接状态 (get_wanchk_state)"
        wan_status=$(get_wanchk_state)
        if [ -n "$wan_status" ]; then
            echo "WAN状态: $wan_status"
        else
            echo "无法获取WAN状态"
            exit 1
        fi
        ;;
    "-n")
        echo "执行网络连接检测 (check_cpe_status)"
        if check_cpe_status; then
            echo "网络连接正常"
        else
            echo "网络连接异常"
            exit 1
        fi
        ;;

    "-l")
        echo "查看限速状态 (get_speedlimit_info)"
        speedlimit_info=$(get_speedlimit_info)
        support_status=$(echo "$speedlimit_info" | cut -d',' -f1 | cut -d'=' -f2)
        enabled_rules=$(echo "$speedlimit_info" | cut -d',' -f2 | cut -d'=' -f2 2>/dev/null)

        echo "限速支持状态: $support_status"
        if [ "$support_status" = "1" ]; then
            echo "启用的限速规则: $enabled_rules"
            if [ "$enabled_rules" != "none" ] && [ -n "$enabled_rules" ]; then
                echo "⚠️  警告: 检测到启用的限速规则，可能影响网络速度"
            else
                echo "✅ 当前无启用的限速规则"
            fi
        else
            echo "✅ 限速功能已被禁用"
        fi
        ;;
    "-k")
        echo "检查CPE锁定状态 (is_cpe_locked)"
        if is_cpe_locked; then
            echo "🔒 CPE当前处于锁定状态，网络检测已暂停"

            # 显示详细的锁定状态信息
            local cpe_lock_status=$(cat "/var/run/wanchk/iface_state/cpe_lock" 2>/dev/null)
            local cpe_status=$(cat "/var/run/wanchk/iface_state/cpe" 2>/dev/null)
            local cpetools_running=$(pgrep -f "cpetools" 2>/dev/null)

            echo "详细状态信息:"
            echo "  - 锁定状态文件: ${cpe_lock_status:-'不存在'}"
            echo "  - CPE状态文件: ${cpe_status:-'不存在'}"
            if [ -n "$cpetools_running" ]; then
                echo "  - cpetools进程: 正在运行 (PID: $cpetools_running)"
            else
                echo "  - cpetools进程: 未运行"
            fi
        else
            echo "🔓 CPE当前未被锁定，网络检测正常进行"
        fi
        ;;
    "")
        echo "默认启动守护进程模式"
        start_daemon
        ;;
    *)
        echo "用法: $0 [start|stop|restart|status|-c|-s|-r|-g|-w|-n|-l|-k]"
        echo "  start:    启动守护进程（默认）"
        echo "  stop:     停止守护进程"
        echo "  restart:  重启守护进程"
        echo "  status:   查看守护进程状态"
        echo "  -c:       执行单次网络检测"
        echo "  -s:       执行频点扫描测试"
        echo "  -r:       执行锁定到PCI 141"
        echo "  -g:       获取CPE信号强度"
        echo "  -w:       获取WAN连接状态"
        echo "  -n:       执行网络连接检测"
        echo "  -l:       查看限速状态"
        echo "  -k:       检查CPE锁定状态"
        echo ""
        echo "守护进程功能:"
        echo "  - 每1秒检测网络连接状态"
        echo "  - 断网立即扫描频点并按PCI优先级锁频"
        echo "  - CPE锁定状态时跳过网络检测，解锁后恢复检测"
        echo "  - 在6:50,8:50,14:50,16:50,18:50,20:50检查PCI 141"
        echo "  - 网络恢复时发送钉钉通知"
        echo ""
        echo "测试命令:"
        echo "  -g:       显示当前CPE信号强度 (RSRP值)"
        echo "  -w:       显示当前WAN连接状态 (up/down)"
        echo "  -n:       测试网络连接是否正常"
        echo "  -l:       查看当前限速状态和规则"
        echo "  -k:       检查CPE锁定状态，显示详细锁定信息"
        exit 1
        ;;
esac