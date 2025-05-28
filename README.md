# EARFCN Lock 网络监控脚本

## 功能说明

此脚本用于监控网络连接状态，具有以下功能：
- 检测网络连接状态
- 在断网情况下，如果距离上次切换超过2分钟，自动切换PCI5值
- 在网络恢复时发送钉钉通知消息
- 在每天6:50-6:58时间段内，如果PCI5值为93，自动切换到141

## 脚本运行修复

```
sed -i 's/\r$//' ./network_monitor.sh
```

## 常用命令

### 打包命令
```
tar -zcvf new.tar.gz etc
```

### 查看IMEI命令
```
cpetools.sh -t 0 -c 'AT+SPIMEI?'
```

### 改IMEI命令
```
cpetools.sh -t 0 -c 'AT+SPIMEI=0,"需要改的串码"'
```

### 扫描频点
```
cpetools.sh -i cpe -c scan /var/cpescan_cache_last_cpe
```

## 管理界面地址

### 开启备份地址
`http://192.168.66.1/cgi-bin/luci/admin/system/flashops`

### 开启SSH地址
`http://192.168.66.1/cgi-bin/luci/admin/system/security`

## 开启SSH

恢复配置c8-601开启SSH

```
opkg update
opkg install openssh-sftp-server
```

## 强制降级

强制降级到1.9.2.n10.c2.bin，先将固件上传到/tmp目录下，然后执行以下命令：
```
sysupgrade -n -F /tmp/1.9.2.n10.c2.bin
```

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

## 手动运行

如需手动运行脚本，可执行：
```
/bin/sh /root/network_monitor.sh
```