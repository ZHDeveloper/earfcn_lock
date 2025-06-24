#!/bin/sh

# 卸载脚本 - 从OpenWrt系统中移除CPE状态监控脚本

# 停止并禁用服务
/etc/init.d/cpe_monitor stop
/etc/init.d/cpe_monitor disable

# 从crontab中移除
sed -i '/cpe_monitor.sh/d' /etc/crontabs/root
/etc/init.d/cron restart

# 删除文件
rm -f /etc/init.d/cpe_monitor
rmdir /etc/config/earfcn_lock 2>/dev/null || true

# 删除临时文件
rm -f /tmp/cpe_monitor.log
rm -f /tmp/cpe_monitor.pid

echo "CPE状态监控脚本已成功卸载。"