#!/bin/sh

# 安装脚本 - 将CPE状态监控脚本安装到OpenWrt系统

# 确保脚本有执行权限
chmod +x uninstall.sh
chmod +x cpe_monitor.sh
chmod +x cpe_monitor_init

# 复制启动脚本到init.d目录
cp cpe_monitor_init /etc/init.d/cpe_monitor
chmod +x /etc/init.d/cpe_monitor

# 启用并启动服务
/etc/init.d/cpe_monitor enable
/etc/init.d/cpe_monitor start

echo "CPE状态监控脚本已安装并启用。"
echo "守护进程已添加到开机启动项，将在系统启动时自动运行。"
echo "脚本路径: /etc/config/earfcn_lock/cpe_monitor.sh"
echo "日志文件: /tmp/cpe_monitor.log"
echo "使用 '/etc/init.d/cpe_monitor status' 查看运行状态"