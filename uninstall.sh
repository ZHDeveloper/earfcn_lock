#!/bin/sh

# 卸载脚本 - 从OpenWrt系统中移除网络监控脚本

# 停止并禁用服务
/etc/init.d/network_monitor stop
/etc/init.d/network_monitor disable

# 从crontab中移除
sed -i '/network_monitor.sh/d' /etc/crontabs/root
/etc/init.d/cron restart

# 删除文件
rm -f /etc/init.d/network_monitor

# 删除临时文件
rm -f /tmp/network_monitor.log
rm -f /tmp/network_disconnect_time

echo "网络监控脚本已成功卸载。"