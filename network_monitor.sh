#!/bin/sh

# 网络监控脚本
# 功能：检测网络连接状态，在断网时按间隔切换PCI5值（距离上次切换超过50秒）
#       在网络恢复时发送钉钉通知消息
#       在指定时间范围内（6:50-6:58，8:50-8:58，...，20:50-20:58）自动切换到earfcn5=633984,pci5=141

# 日志文件路径
LOG_FILE="/tmp/network_monitor.log"

# 断网时间记录文件
DISCONNECT_TIME_FILE="/tmp/network_disconnect_time"

# 断网时间的可读格式记录文件
DISCONNECT_READABLE_TIME_FILE="/tmp/network_disconnect_readable_time"

# 上次切换PCI5值的时间记录文件
LAST_SWITCH_TIME_FILE="/tmp/last_pci5_switch_time"

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
    
    if ping -c 1 8.8.8.8 > /dev/null 2>&1; then
        log_message "INFO" "网络检测：ping 8.8.8.8 成功"
        ping_result=0
    elif ping -c 1 114.114.114.114 > /dev/null 2>&1; then
        log_message "INFO" "网络检测：ping 114.114.114.114 成功"
        ping_result=0
    elif ping -c 1 www.baidu.com > /dev/null 2>&1; then
        log_message "INFO" "网络检测：ping www.baidu.com 成功"
        ping_result=0
    else
        log_message "WARN" "网络检测：所有ping目标均失败"
    fi
    
    return $ping_result
}

# 顺序切换earfcn5和pci5值（用于断网时）
lock_cellular_sequence() {
    local current_pci5=$(uci -q get cpecfg.cpesim1.pci5)
    local current_earfcn5=$(uci -q get cpecfg.cpesim1.earfcn5)
    
    # 根据当前组合确定下一个组合
    if [ "$current_earfcn5" = "633984" ] && [ "$current_pci5" = "141" ]; then
        new_pci5="296"
        new_earfcn5="627264"
    elif [ "$current_earfcn5" = "627264" ] && [ "$current_pci5" = "296" ]; then
        new_pci5="189"
        new_earfcn5="633984"
    elif [ "$current_earfcn5" = "633984" ] && [ "$current_pci5" = "189" ]; then
        new_pci5="739"
        new_earfcn5="633984"
    elif [ "$current_earfcn5" = "633984" ] && [ "$current_pci5" = "739" ]; then
        new_pci5="141"
        new_earfcn5="633984"
    else
        # 如果当前组合不在预期范围内，重置为第一个组合
        new_pci5="141"
        new_earfcn5="633984"
    fi
        
    # 使用uci设置earfcn5和pci5值
    uci set cpecfg.cpesim1.pci5="$new_pci5"
    uci set cpecfg.cpesim1.earfcn5="$new_earfcn5"
    uci commit cpecfg
    
    if [ $? -eq 0 ]; then
        log_message "INFO" "参数已从 earfcn5=$current_earfcn5,pci5=$current_pci5 切换到 earfcn5=$new_earfcn5,pci5=$new_pci5"
        # 执行更新命令
        log_message "INFO" "开始执行更新命令: cpetools.sh -u"
        cpetools.sh -u
        local update_result=$?
        if [ $update_result -eq 0 ]; then
            log_message "INFO" "更新命令执行成功"
        else
            log_message "WARN" "更新命令执行失败，退出码: $update_result"
        fi
        # 记录切换时间
        date '+%s' > $LAST_SWITCH_TIME_FILE
        return 0
    else
        log_message "ERROR" "参数切换失败 (uci commit 失败)"
        return 1
    fi
    
}

# 直接切换到earfcn5=633984,pci5=141（用于有网络时）
lock_cellular_141() {
    local current_pci5=$(uci -q get cpecfg.cpesim1.pci5)
    local current_earfcn5=$(uci -q get cpecfg.cpesim1.earfcn5)

    # 如果当前参数已经是目标组合，则无需切换
    if [ "$current_earfcn5" = "633984" ] && [ "$current_pci5" = "141" ]; then
        log_message "INFO" "当前参数已经是 earfcn5=633984,pci5=141，无需切换"
        return 0
    fi
    
    new_pci5="141"
    new_earfcn5="633984"
    
    # 使用uci设置earfcn5和pci5值
    uci set cpecfg.cpesim1.pci5="$new_pci5"
    uci set cpecfg.cpesim1.earfcn5="$new_earfcn5"
    uci commit cpecfg

    if [ $? -eq 0 ]; then
        log_message "INFO" "参数已从 earfcn5=$current_earfcn5,pci5=$current_pci5 切换到 earfcn5=$new_earfcn5,pci5=$new_pci5"
        # 执行更新命令
        log_message "INFO" "开始执行更新命令: cpetools.sh -u"
        cpetools.sh -u
        local update_result=$?
        if [ $update_result -eq 0 ]; then
            log_message "INFO" "更新命令执行成功"
        else
            log_message "WARN" "更新命令执行失败，退出码: $update_result"
        fi
        # 记录切换时间
        date '+%s' > $LAST_SWITCH_TIME_FILE
        return 0
    else
        log_message "ERROR" "参数切换失败 (uci commit 失败)"
        return 1
    fi
    
}

# 检查是否需要切换PCI5值
# 返回值: 0 表示需要切换, 1 表示不需要切换
should_switch_pci() {
    if [ ! -f $LAST_SWITCH_TIME_FILE ]; then
        return 0 # 需要切换
    else
        # 计算距离上次切换的时间（秒）
        local last_switch_time=$(cat $LAST_SWITCH_TIME_FILE)
        local current_time=$(date '+%s')
        local time_since_last_switch=$((current_time - last_switch_time))
        
        if [ $time_since_last_switch -ge 50 ]; then
            return 0 # 需要切换
        else
            return 1 # 不需要切换
        fi
    fi
}

# 处理网络恢复的函数
handle_network_recovery() {
    # 如果存在断网记录则发送钉钉消息并删除记录文件
    if [ -f $DISCONNECT_TIME_FILE ]; then
        # 获取当前时间
        local current_time=$(date '+%Y-%m-%d %H:%M:%S')
        
        # 获取断网时间（Unix时间戳）
        local disconnect_time=$(cat $DISCONNECT_TIME_FILE)
        
        # 获取可读的断网时间
        local disconnect_readable_time="未知"
        if [ -f $DISCONNECT_READABLE_TIME_FILE ]; then
            disconnect_readable_time=$(cat $DISCONNECT_READABLE_TIME_FILE)
        fi
        
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
        
        # 删除断网时间记录文件
        rm -f $DISCONNECT_TIME_FILE
        rm -f $DISCONNECT_READABLE_TIME_FILE
    fi
}

# 检查是否在指定时间范围内（例如6:50-6:58，8:50-8:58，...，20:50-20:58）
check_time_range() {
    # 获取当前小时和分钟
    local current_hour=$(date '+%H')
    local current_minute=$(date '+%M')
    local current_time="${current_hour}:${current_minute}"

    # 检查分钟是否在50-58之间
    if [ "$current_minute" -ge "50" ] && [ "$current_minute" -le "58" ]; then
        # 检查小时是否为6, 8, 10, 12, 14, 16, 18, 20
        case "$current_hour" in
            "06"|"08"|"10"|"12"|"14"|"16"|"18"|"20")
                return 0  # 在时间范围内
                ;;
            *)
                return 1  # 不在时间范围内 (小时不匹配)
                ;;
        esac
    else
        return 1  # 不在时间范围内 (分钟不匹配)
    fi
    
}

# 主程序
main() {
    log_message "INFO" "========== 开始执行网络监控检查 =========="
    
    # 检查网络连接
    if ! check_network; then
        # 网络断开
        if [ ! -f $DISCONNECT_TIME_FILE ]; then
            # 记录断网时间（Unix时间戳和可读格式）
            date '+%s' > $DISCONNECT_TIME_FILE
            local readable_time=$(date '+%Y-%m-%d %H:%M:%S')
            echo "$readable_time" > $DISCONNECT_READABLE_TIME_FILE
            log_message "INFO" "网络断开，开始记录断网时间"
        else
            # 检查是否需要切换PCI5值
            if should_switch_pci; then
                # 断网时按顺序切换PCI5值
                lock_cellular_sequence
            fi
        fi
    else
        # 网络已连接
        
        # 检查是否在指定时间范围内
        if check_time_range; then
            # 在指定时间范围内，切换到141（函数内部会自动判断是否需要切换）
            lock_cellular_141
        fi

        # 处理网络恢复
        handle_network_recovery
    fi
    
    log_message "INFO" "========== 网络监控检查完成 =========="
}

# 命令行参数处理
case "$1" in
    "-c")
        echo "执行主程序 (main)"
        main
        ;;
    "-l")
        echo "执行顺序切换 (lock_cellular_sequence)"
        lock_cellular_sequence
        ;;
    "-r")
        echo "执行锁定到141 (lock_cellular_141)"
        lock_cellular_141
        ;;
    "")
        echo "默认执行主程序 (main)"
        main
        ;;
    *)
        echo "用法: $0 [-c|-l|-r]"
        echo "  -c: 执行主程序 (main)"
        echo "  -l: 执行顺序切换 (lock_cellular_sequence)"
        echo "  -r: 执行锁定到141 (lock_cellular_141)"
        echo "  无参数: 默认执行主程序 (main)"
        exit 1
        ;;
esac