#!/bin/sh

# 安装脚本 - 将网络监控脚本安装到OpenWrt系统

# 确保脚本有执行权限
chmod +x network_monitor.sh
chmod +x network_monitor_init

# 复制网络监控脚本到根目录
cp network_monitor.sh /root/

# 复制启动脚本到init.d目录
cp network_monitor_init /etc/init.d/network_monitor
chmod +x /etc/init.d/network_monitor

# 启用并启动服务
/etc/init.d/network_monitor enable
/etc/init.d/network_monitor start

echo "网络监控脚本已安装并启用。"
echo "服务已添加到开机启动项，并设置为每分钟执行一次。"