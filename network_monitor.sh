#!/bin/sh

# 网络监控脚本 - 开机启动守护进程版本
# 功能：每5秒检测网络连接状态，断网50秒后扫描频点并按PCI优先级锁频
#       在网络恢复时发送钉钉通知消息
#       在指定时间点（6:50，8:50，12:50，14:50，16:50，18:50，20:50）检查是否需要切换到PCI 141

# 日志文件路径
LOG_FILE="/tmp/network_monitor.log"

# PID文件
PID_FILE="/tmp/network_monitor.pid"

# 全局变量：断网时间记录（Unix时间戳|可读格式）
DISCONNECT_TIME=""

# 全局变量：锁频时间记录（Unix时间戳）
LOCK_TIME=""

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

# 检测网络连接
check_network() {
    # 尝试ping多个目标以确保可靠性
    local ping_result=1
    
    if ping -c 1 -W 1 8.8.8.8 > /dev/null 2>&1; then
        ping_result=0
    elif ping -c 1 -W 1 114.114.114.114 > /dev/null 2>&1; then
        ping_result=0
    elif ping -c 1 -W 1 www.baidu.com > /dev/null 2>&1; then
        ping_result=0
    else
        log_message "WARN" "网络检测：所有ping目标均失败"
    fi
    
    return $ping_result
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
    # 使用更简单的方法：直接用grep和sed提取每个cell的信息
    # 先分割成单独的cell记录，然后逐个解析
    echo "$scan_data" | sed 's/}, {/}\n{/g' | sed 's/\[{/{/g' | sed 's/}\]/}/g' | \
    while IFS= read -r cell_data; do
        if echo "$cell_data" | grep -q '"MODE":[ ]*"NR"'; then
            # 先移除lockneed部分，避免干扰
            clean_data=$(echo "$cell_data" | sed 's/"lockneed".*$//')

            # 提取EARFCN (确保不是lockneed中的EARFCN)
            earfcn=$(echo "$clean_data" | sed -n 's/.*"EARFCN":[ ]*"\([^"]*\)".*/\1/p' | head -1)
            # 提取PCI (确保不是lockneed中的PCI)
            pci=$(echo "$clean_data" | sed -n 's/.*"PCI":[ ]*"\([^"]*\)".*/\1/p' | head -1)
            # 提取RSRP
            rsrp=$(echo "$clean_data" | sed -n 's/.*"RSRP":[ ]*"\([^"]*\)".*/\1/p' | head -1)

            # 如果三个值都提取到了，输出结果
            if [ -n "$earfcn" ] && [ -n "$pci" ] && [ -n "$rsrp" ]; then
                echo "$earfcn|$pci|$rsrp"
            fi
        fi
    done
}

# 按PCI优先级选择最佳频点组合
select_best_frequency() {
    local scan_data="$1"
    local available_combinations=$(parse_scan_result "$scan_data")
    
    # PCI优先级列表
    local priority_pcis="141 296 189 93"
    
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
            # 记录锁频时间，60秒内不检测网络
            LOCK_TIME="$(date '+%s')"
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

# 检查是否在锁频等待期内（锁频后50秒内不检测网络，50秒后恢复检测）
is_in_lock_wait_period() {
    if [ -z "$LOCK_TIME" ]; then
        return 1 # 没有锁频记录，不在等待期
    fi
    
    local current_time=$(date '+%s')
    local elapsed_time=$((current_time - LOCK_TIME))
    
    if [ $elapsed_time -lt 50 ]; then
        return 0 # 在等待期内
    else
        # 超过50秒，清空锁频记录变量
        LOCK_TIME=""
        return 1 # 不在等待期
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
        local pci_141_combination=$(parse_scan_result "$scan_result" | grep "|141$")
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
        # 计算断网持续时间（秒）
        local disconnect_time=$(echo "$DISCONNECT_TIME" | cut -d'|' -f1)
        local current_time=$(date '+%s')
        local disconnect_duration=$((current_time - disconnect_time))
        
        if [ $disconnect_duration -ge 50 ]; then
            return 0 # 断网时间超过50秒，需要智能锁频
        else
            return 1 # 断网时间不足50秒，不需要锁频
        fi
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
        "06:50"|"08:50"|"12:50"|"14:50"|"16:50"|"18:50"|"20:50")
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
    # 检查是否在锁频等待期内
    if is_in_lock_wait_period; then
        log_message "DEBUG" "在锁频等待期内，跳过网络检测"
        return 1  # 返回1表示跳过检测
    fi
    
    # 检查网络连接
    if ! check_network; then
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
                # 断网超过50秒，进行智能锁频
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
            # 正常执行，等待5秒后继续下一次检测
            sleep 5
        else
            # 跳过检测（如在锁频等待期），等待5秒后继续
            sleep 5
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
    "")
        echo "默认启动守护进程模式"
        start_daemon
        ;;
    *)
        echo "用法: $0 [start|stop|restart|status|-c|-s|-r]"
        echo "  start:    启动守护进程（默认）"
        echo "  stop:     停止守护进程"
        echo "  restart:  重启守护进程"
        echo "  status:   查看守护进程状态"
        echo "  -c:       执行单次网络检测"
        echo "  -s:       执行频点扫描测试"
        echo "  -r:       执行锁定到PCI 141"
        echo ""
        echo "守护进程功能:"
        echo "  - 每5秒检测网络连接状态"
        echo "  - 断网50秒后扫描频点并按PCI优先级锁频"
        echo "  - 锁频后50秒内不检测网络，50秒后恢复检测"
        echo "  - 在6:50,8:50,12:50,14:50,16:50,18:50,20:50检查PCI 141"
        echo "  - 网络恢复时发送钉钉通知"
        exit 1
        ;;
esac