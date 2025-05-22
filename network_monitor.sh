#!/bin/sh

# 网络监控脚本
# 功能：检测网络连接状态，在断网超过3分钟时切换PCI5值
#       在网络恢复时发送钉钉通知消息

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
    ping -c 1 8.8.8.8 > /dev/null 2>&1 || \
    ping -c 1 114.114.114.114 > /dev/null 2>&1 || \
    ping -c 1 www.baidu.com > /dev/null 2>&1
    
    return $?
}

# 获取当前PCI5值
get_pci5_value() {
    grep -A 10 "cpesim 'cpesim1'" /etc/config/cpecfg | grep "option pci5" | cut -d "'" -f 2
}

# 切换PCI5值
switch_pci5_value() {
    current_pci5=$1
    new_pci5="141"
    
    if [ "$current_pci5" = "141" ]; then
        new_pci5="93"
    fi
    
    # 使用sed替换PCI5值
    sed -i "s/option pci5 '$current_pci5'/option pci5 '$new_pci5'/" /etc/config/cpecfg
    
    if [ $? -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') PCI5值已从 $current_pci5 切换到 $new_pci5" >> $LOG_FILE
        # 执行更新命令
        cpetools.sh -u
        echo "$(date '+%Y-%m-%d %H:%M:%S') 执行更新命令: cpetools.sh -u" >> $LOG_FILE
        # 记录切换时间
        date '+%s' > $LAST_SWITCH_TIME_FILE
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误：PCI5值切换失败" >> $LOG_FILE
        return 1
    fi
}

# 检查是否在指定时间范围内（6:50-6:58）
check_time_range() {
    # 获取当前小时和分钟
    current_hour=$(date '+%H')
    current_minute=$(date '+%M')
    
    # 检查是否在6:50-6:58之间
    if [ "$current_hour" = "06" ] && [ "$current_minute" -ge "50" ] && [ "$current_minute" -le "58" ]; then
        return 0  # 在时间范围内
    else
        return 1  # 不在时间范围内
    fi
}

# 主程序
main() {
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
            # 如果上次切换时间文件不存在，或者距离上次切换已超过2分钟（120秒）
            can_switch=0
            
            if [ ! -f $LAST_SWITCH_TIME_FILE ]; then
                can_switch=1
                echo "$(date '+%Y-%m-%d %H:%M:%S') 没有找到上次切换记录，准备切换PCI5值" >> $LOG_FILE
            else
                # 计算距离上次切换的时间（秒）
                last_switch_time=$(cat $LAST_SWITCH_TIME_FILE)
                current_time=$(date '+%s')
                time_since_last_switch=$((current_time - last_switch_time))
                
                if [ $time_since_last_switch -ge 120 ]; then
                    can_switch=1
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 距离上次切换已超过2分钟，准备切换PCI5值" >> $LOG_FILE
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 距离上次切换不足2分钟，暂不切换" >> $LOG_FILE
                fi
            fi
            
            # 如果可以切换，则执行切换
            if [ $can_switch -eq 1 ]; then
                # 获取当前PCI5值
                current_pci5=$(get_pci5_value)
                
                # 切换PCI5值
                switch_pci5_value "$current_pci5"
            fi
        fi
    else
        # 网络已连接
        
        # 检查是否在指定时间范围内（6:50-6:58）
        if check_time_range; then
            # 获取当前PCI5值
            current_pci5=$(get_pci5_value)
            
            # 如果当前PCI5值为93，则切换到141
            if [ "$current_pci5" = "93" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 在指定时间范围内(6:50-6:58)，当前PCI5值为93，准备切换到141" >> $LOG_FILE
                switch_pci5_value "$current_pci5"
            fi
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
            send_dingtalk_message "$message"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 网络已恢复连接，已发送钉钉通知" >> $LOG_FILE
            
            # 删除断网时间记录文件
            rm -f $DISCONNECT_TIME_FILE
            rm -f $DISCONNECT_READABLE_TIME_FILE
        fi

        # 删除上次切换时间记录文件
        rm -f $LAST_SWITCH_TIME_FILE

    fi
}

# 执行主程序
main