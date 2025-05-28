#!/bin/sh

# 网络监控脚本
# 功能：检测网络连接状态，在断网时按间隔切换PCI5值（距离上次切换超过1分钟）
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
        echo "$(date '+%Y-%m-%d %H:%M:%S') 网络检测：ping 8.8.8.8 成功" >> $LOG_FILE
        ping_result=0
    elif ping -c 1 114.114.114.114 > /dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 网络检测：ping 114.114.114.114 成功" >> $LOG_FILE
        ping_result=0
    elif ping -c 1 www.baidu.com > /dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 网络检测：ping www.baidu.com 成功" >> $LOG_FILE
        ping_result=0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 网络检测：所有ping目标均失败" >> $LOG_FILE
    fi
    
    return $ping_result
}

# 获取当前pci5值
get_pci5_value() {
    local pci5_value=$(grep -A 10 "cpesim 'cpesim1'" /etc/config/cpecfg | grep "option pci5" | cut -d "'" -f 2)
    if [ -z "$pci5_value" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：无法从配置文件读取pci5值" >> $LOG_FILE
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置读取：当前pci5值为 $pci5_value" >> $LOG_FILE
    fi
    echo "$pci5_value"
}

# 获取当前earfcn5值
get_earfcn5_value() {
    local earfcn5_value=$(grep -A 10 "cpesim 'cpesim1'" /etc/config/cpecfg | grep "option earfcn5" | cut -d "'" -f 2)
    if [ -z "$earfcn5_value" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：无法从配置文件读取earfcn5值" >> $LOG_FILE
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置读取：当前earfcn5值为 $earfcn5_value" >> $LOG_FILE
    fi
    echo "$earfcn5_value"
}

# 顺序切换earfcn5和pci5值（用于断网时）
lock_cellular_sequence() {
    current_pci5=$(get_pci5_value)
    current_earfcn5=$(get_earfcn5_value)
    
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
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') 开始执行参数切换：earfcn5=$current_earfcn5,pci5=$current_pci5 -> earfcn5=$new_earfcn5,pci5=$new_pci5" >> $LOG_FILE
    
    # 使用sed替换earfcn5和pci5值
    sed -i "s/option pci5 '$current_pci5'/option pci5 '$new_pci5'/" /etc/config/cpecfg
    local sed_result1=$?
    sed -i "s/option earfcn5 '$current_earfcn5'/option earfcn5 '$new_earfcn5'/" /etc/config/cpecfg
    local sed_result2=$?
    
    if [ $sed_result1 -eq 0 ] && [ $sed_result2 -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 参数已从 earfcn5=$current_earfcn5,pci5=$current_pci5 切换到 earfcn5=$new_earfcn5,pci5=$new_pci5" >> $LOG_FILE
        # 执行更新命令
        echo "$(date '+%Y-%m-%d %H:%M:%S') 开始执行更新命令: cpetools.sh -u" >> $LOG_FILE
        cpetools.sh -u
        local update_result=$?
        if [ $update_result -eq 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 更新命令执行成功" >> $LOG_FILE
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：更新命令执行失败，退出码: $update_result" >> $LOG_FILE
        fi
        # 记录切换时间
        date '+%s' > $LAST_SWITCH_TIME_FILE
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误：参数切换失败 (sed结果: pci5=$sed_result1, earfcn5=$sed_result2)" >> $LOG_FILE
        return 1
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') ========== 网络监控检查完成 ==========" >> $LOG_FILE
}

# 直接切换到earfcn5=633984,pci5=141（用于有网络时）
lock_cellular_141() {
    current_pci5=$(get_pci5_value)
    current_earfcn5=$(get_earfcn5_value)

    # 如果当前参数已经是目标组合，则无需切换
    if [ "$current_earfcn5" = "633984" ] && [ "$current_pci5" = "141" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 当前参数已经是 earfcn5=633984,pci5=141，无需切换" >> $LOG_FILE
        return 0
    fi
    
    new_pci5="141"
    new_earfcn5="633984"

    echo "$(date '+%Y-%m-%d %H:%M:%S') 在指定时间范围内，当前参数为 earfcn5=$current_earfcn5,pci5=$current_pci5，准备切换到 earfcn5=$new_earfcn5,pci5=$new_pci5" >> $LOG_FILE
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') 开始执行参数切换：earfcn5=$current_earfcn5,pci5=$current_pci5 -> earfcn5=$new_earfcn5,pci5=$new_pci5" >> $LOG_FILE
    
    # 使用sed替换earfcn5和pci5值
    sed -i "s/option earfcn5 '$current_earfcn5'/option earfcn5 '$new_earfcn5'/" /etc/config/cpecfg
    local sed_result1=$?
    sed -i "s/option pci5 '$current_pci5'/option pci5 '$new_pci5'/" /etc/config/cpecfg
    local sed_result2=$?
    
    if [ $sed_result1 -eq 0 ] && [ $sed_result2 -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 参数已从 earfcn5=$current_earfcn5,pci5=$current_pci5 切换到 earfcn5=$new_earfcn5,pci5=$new_pci5" >> $LOG_FILE
        # 执行更新命令
        echo "$(date '+%Y-%m-%d %H:%M:%S') 开始执行更新命令: cpetools.sh -u" >> $LOG_FILE
        cpetools.sh -u
        local update_result=$?
        if [ $update_result -eq 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 更新命令执行成功" >> $LOG_FILE
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：更新命令执行失败，退出码: $update_result" >> $LOG_FILE
        fi
        # 记录切换时间
        date '+%s' > $LAST_SWITCH_TIME_FILE
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误：参数切换失败 (sed结果: earfcn5=$sed_result1, pci5=$sed_result2)" >> $LOG_FILE
        return 1
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') ========== 网络监控检查完成 ==========" >> $LOG_FILE
}

# 检查是否在指定时间范围内（例如6:50-6:58，8:50-8:58，...，20:50-20:58）
check_time_range() {
    # 获取当前小时和分钟
    current_hour=$(date '+%H')
    current_minute=$(date '+%M')
    current_time="${current_hour}:${current_minute}"

    echo "$(date '+%Y-%m-%d %H:%M:%S') 时间检查：当前时间 $current_time" >> $LOG_FILE

    # 检查分钟是否在50-58之间
    if [ "$current_minute" -ge "50" ] && [ "$current_minute" -le "58" ]; then
        # 检查小时是否为6, 8, 10, 12, 14, 16, 18, 20
        case "$current_hour" in
            "06"|"08"|"10"|"12"|"14"|"16"|"18"|"20")
                echo "$(date '+%Y-%m-%d %H:%M:%S') 时间检查：在指定时间范围内 (${current_hour}:50-${current_hour}:58)" >> $LOG_FILE
                return 0  # 在时间范围内
                ;;
            *)
                echo "$(date '+%Y-%m-%d %H:%M:%S') 时间检查：不在指定时间范围内 (小时 $current_hour 不匹配)" >> $LOG_FILE
                return 1  # 不在时间范围内 (小时不匹配)
                ;;
        esac
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 时间检查：不在指定时间范围内 (分钟 $current_minute 不在50-58之间)" >> $LOG_FILE
        return 1  # 不在时间范围内 (分钟不匹配)
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') ========== 网络监控检查完成 ==========" >> $LOG_FILE
}

# 主程序
main() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ========== 开始执行网络监控检查 ==========" >> $LOG_FILE
    
    # 检查网络连接
    if ! check_network; then
        # 网络断开
        if [ ! -f $DISCONNECT_TIME_FILE ]; then
            # 记录断网时间（Unix时间戳和可读格式）
            date '+%s' > $DISCONNECT_TIME_FILE
            readable_time=$(date '+%Y-%m-%d %H:%M:%S')
            echo "$readable_time" > $DISCONNECT_READABLE_TIME_FILE
            echo "$(date '+%Y-%m-%d %H:%M:%S') 网络断开，开始记录断网时间" >> $LOG_FILE
        else
            # 计算断网时长（秒）
            disconnect_time=$(cat $DISCONNECT_TIME_FILE)
            current_time=$(date '+%s')
            elapsed_time=$((current_time - disconnect_time))
            
            # 检查是否可以切换PCI5值
            # 如果上次切换时间文件不存在，或者距离上次切换已超过1分钟（60秒）
            can_switch=0
            
            if [ ! -f $LAST_SWITCH_TIME_FILE ]; then
                can_switch=1
                echo "$(date '+%Y-%m-%d %H:%M:%S') 没有找到上次切换记录，准备切换PCI5值" >> $LOG_FILE
            else
                # 计算距离上次切换的时间（秒）
                last_switch_time=$(cat $LAST_SWITCH_TIME_FILE)
                current_time=$(date '+%s')
                time_since_last_switch=$((current_time - last_switch_time))
                
                if [ $time_since_last_switch -ge 60 ]; then
                    can_switch=1
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 距离上次切换已超过1分钟，准备切换PCI5值" >> $LOG_FILE
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 距离上次切换不足1分钟，暂不切换" >> $LOG_FILE
                fi
            fi
            
            # 如果可以切换，则执行切换
            if [ $can_switch -eq 1 ]; then
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

        # 如果存在断网记录则发送钉钉消息并删除记录文件
        if [ -f $DISCONNECT_TIME_FILE ]; then
            # 获取当前时间
            current_time=$(date '+%Y-%m-%d %H:%M:%S')
            
            # 获取断网时间（Unix时间戳）
            disconnect_time=$(cat $DISCONNECT_TIME_FILE)
            
            # 获取可读的断网时间
            disconnect_readable_time="未知"
            if [ -f $DISCONNECT_READABLE_TIME_FILE ]; then
                disconnect_readable_time=$(cat $DISCONNECT_READABLE_TIME_FILE)
            fi
            
            # 计算断网持续时间（秒）
            current_timestamp=$(date '+%s')
            duration=$((current_timestamp - disconnect_time))
            
            # 转换为可读格式（小时:分钟:秒）
            hours=$((duration / 3600))
            minutes=$(((duration % 3600) / 60))
            seconds=$((duration % 60))
            duration_readable="${hours}小时${minutes}分钟${seconds}秒"
            
            # 获取当前PCI5值
            current_pci5=$(get_pci5_value)
            
            # 构建消息内容
            message="网络状态通知:\n- 断网时间: ${disconnect_readable_time}\n- 恢复时间: ${current_time}\n- 断网持续: ${duration_readable}\n- 当前PCI5值: ${current_pci5}"
            
            # 发送钉钉消息
            echo "$(date '+%Y-%m-%d %H:%M:%S') 准备发送钉钉通知消息" >> $LOG_FILE
            send_dingtalk_message "$message"
            local dingtalk_result=$?
            if [ $dingtalk_result -eq 0 ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 网络已恢复连接，钉钉通知发送成功" >> $LOG_FILE
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 网络已恢复连接，钉钉通知发送失败，退出码: $dingtalk_result" >> $LOG_FILE
            fi
            
            # 删除断网时间记录文件
            rm -f $DISCONNECT_TIME_FILE
            rm -f $DISCONNECT_READABLE_TIME_FILE
        fi

    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') ========== 网络监控检查完成 ==========" >> $LOG_FILE
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