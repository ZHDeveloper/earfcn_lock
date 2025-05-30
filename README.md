# EARFCN Lock 网络监控脚本

## 功能说明

此脚本用于监控网络连接状态，具有以下功能：
- 检测网络连接状态（支持多目标ping检测）
- 在断网情况下，如果断网时间超过90秒，自动按序切换PCI5值
- 在网络恢复时发送钉钉通知消息，包含详细的断网统计信息
- 在指定时间范围内（6:50-6:58，8:50-8:58，...，20:50-20:58）自动切换到earfcn5=633984,pci5=141
- 优化的文件管理：使用单个文件记录断网时间信息

## 安装说明

### 方法一：使用安装脚本（推荐）

1. 将所有文件上传到OpenWrt设备
2. 给安装脚本添加执行权限：
   ```
   chmod +x install.sh
   ```
3. 运行安装脚本：
   ```
   ./install.sh
   ```

### 方法二：手动安装

1. 将网络监控脚本复制到设备：
   ```
   cp network_monitor.sh /root/
   chmod +x /root/network_monitor.sh
   ```

2. 将启动脚本复制到init.d目录：
   ```
   cp network_monitor_init /etc/init.d/network_monitor
   chmod +x /etc/init.d/network_monitor
   ```

3. 启用并启动服务：
   ```
   /etc/init.d/network_monitor enable
   /etc/init.d/network_monitor start
   ```

## 验证安装

安装完成后，可以通过以下命令验证：

1. 检查服务是否已启用：
   ```
   /etc/init.d/network_monitor enabled
   ```

2. 检查服务是否正在运行：
   ```
   ps | grep network_monitor
   ```

3. 检查crontab是否已设置：
   ```
   cat /etc/crontabs/root | grep network_monitor
   ```

## 日志查看

脚本运行日志保存在：
```
/tmp/network_monitor.log
```

## 临时文件

脚本运行时会创建以下临时文件：
- `/tmp/network_disconnect_time` - 断网时间记录文件（包含Unix时间戳和可读格式）

## 卸载说明

如需卸载脚本，可以运行：
```
chmod +x uninstall.sh
./uninstall.sh
```

卸载脚本会自动：
- 停止并禁用服务
- 从crontab中移除定时任务
- 删除所有相关文件和临时文件

## 手动运行

如需手动运行脚本，可执行：
```
/bin/sh /root/network_monitor.sh
```