# 网络监控脚本

## 功能说明

此脚本是一个功能完整的网络监控守护进程，具有以下核心功能：

### 网络监控与智能锁频
- **多目标网络检测**：支持ping多个目标（8.8.8.8、114.114.114.114、www.baidu.com）确保检测可靠性
- **智能锁频机制**：断网超过50秒后自动扫描附近频点，按PCI优先级（141 > 296 > 189 > 93）智能选择最佳频点组合
- **锁频保护期**：锁频后50秒内暂停网络检测，避免频繁切换
- **频点扫描**：使用cpetools.sh扫描附近可用频点，解析PCI和EARFCN组合

### 定时任务与自动切换
- **指定时间检查**：在每天6:50、8:50、12:50、14:50、16:50、18:50、20:50自动检查并切换到PCI 141
- **智能判断**：仅在当前PCI不是141时才执行扫描和切换操作

### 通知与日志系统
- **钉钉通知**：网络恢复时自动发送详细通知，包含断网时间、恢复时间、持续时长和当前PCI值
- **完整日志记录**：记录所有操作和状态变化到 `/tmp/network_monitor.log`
- **智能日志管理**：
  - 每天凌晨0:00自动清空日志文件
  - 日志文件超过10MB时自动清空
  - 清空前备份最后5行重要状态信息

### 守护进程模式
- **后台运行**：支持守护进程模式，开机自启动
- **进程管理**：支持start、stop、restart、status等标准服务操作
- **内存优化**：使用变量记录状态信息，避免频繁文件I/O操作
- **单例保护**：防止重复启动多个守护进程实例

## 安装说明

### 方法一：使用安装脚本（推荐）

1. 将所有文件上传到OpenWrt设备
2. 给安装脚本添加执行权限：
   ```bash
   chmod +x install.sh
   ```
3. 运行安装脚本：
   ```bash
   ./install.sh
   ```

### 方法二：手动安装

1. 将网络监控脚本复制到设备：
   ```bash
   cp network_monitor.sh /etc/config/earfcn_lock/
   chmod +x /etc/config/earfcn_lock/network_monitor.sh
   ```

2. 将启动脚本复制到init.d目录：
   ```bash
   cp network_monitor_init /etc/init.d/network_monitor
   chmod +x /etc/init.d/network_monitor
   ```

3. 启用并启动服务：
   ```bash
   /etc/init.d/network_monitor enable
   /etc/init.d/network_monitor start
   ```

## 使用说明

### 守护进程模式（推荐）

脚本支持标准的守护进程操作：

```bash
# 启动守护进程
/etc/config/earfcn_lock/network_monitor.sh start

# 停止守护进程
/etc/config/earfcn_lock/network_monitor.sh stop

# 重启守护进程
/etc/config/earfcn_lock/network_monitor.sh restart

# 查看守护进程状态
/etc/config/earfcn_lock/network_monitor.sh status
```

### 测试和调试模式

```bash
# 执行单次网络检测
/etc/config/earfcn_lock/network_monitor.sh -c

# 执行频点扫描测试
/etc/config/earfcn_lock/network_monitor.sh -s

# 执行锁定到PCI 141测试
/etc/config/earfcn_lock/network_monitor.sh -r
```

### 默认行为

直接运行脚本（无参数）将启动守护进程模式：
```bash
/etc/config/earfcn_lock/network_monitor.sh
```

## 验证安装

安装完成后，可以通过以下命令验证：

1. 检查服务是否已启用：
   ```bash
   /etc/init.d/network_monitor enabled
   ```

2. 检查守护进程是否正在运行：
   ```bash
   /etc/config/earfcn_lock/network_monitor.sh status
   ```
   或者：
   ```bash
   ps | grep network_monitor
   ```

3. 检查PID文件：
   ```bash
   cat /tmp/network_monitor.pid
   ```

## 日志系统

### 日志文件位置
脚本运行日志保存在：
```
/tmp/network_monitor.log
```

### 日志自动管理
- **每日清理**：每天凌晨0:00自动清空日志文件
- **大小限制**：日志文件超过10MB时自动清空
- **状态保护**：清空前自动备份最后5行重要状态信息
- **详细记录**：记录清理原因、时间和清理前状态

### 日志查看命令
```bash
# 查看完整日志
cat /tmp/network_monitor.log

# 实时监控日志
tail -f /tmp/network_monitor.log

# 查看最近的日志
tail -n 50 /tmp/network_monitor.log
```

## 运行时文件

脚本运行时会创建以下文件：
- `/tmp/network_monitor.pid` - 守护进程PID文件
- `/tmp/network_monitor.log` - 运行日志文件

**注意**：脚本已优化为使用内存变量记录状态，不再依赖临时状态文件，提升了性能和可靠性。

## 技术特性

### 性能优化
- **内存变量存储**：使用全局变量记录断网时间和锁频时间，避免频繁文件I/O
- **智能检测间隔**：每5秒检测一次网络状态，锁频后50秒内暂停检测
- **高效日志管理**：自动清理机制防止日志文件无限增长

### 可靠性保障
- **多目标检测**：ping多个不同的服务器确保网络状态判断准确
- **单例模式**：防止多个守护进程同时运行造成冲突
- **异常恢复**：自动处理各种异常情况，确保服务稳定运行
- **状态保护**：重要状态信息在日志清理时得到保护

### 智能算法
- **PCI优先级**：按照预设优先级（141 > 296 > 189 > 93）选择最佳频点
- **时间窗口检测**：精确的时间点检测，确保在指定时间执行特定操作
- **断网时长判断**：只有断网超过50秒才触发锁频，避免网络抖动误操作

## 卸载说明

如需卸载脚本，可以运行：
```bash
chmod +x uninstall.sh
./uninstall.sh
```

卸载脚本会自动：
- 停止并禁用守护进程服务
- 从系统启动项中移除
- 删除所有相关文件和运行时文件
- 清理日志和PID文件

## 故障排除

### 常见问题

1. **守护进程无法启动**
   ```bash
   # 检查脚本权限
   ls -l /etc/config/earfcn_lock/network_monitor.sh
   
   # 手动启动查看错误信息
   /etc/config/earfcn_lock/network_monitor.sh start
   ```

2. **网络检测不工作**
   ```bash
   # 测试网络连接
   ping -c 1 8.8.8.8
   
   # 执行单次检测
   /etc/config/earfcn_lock/network_monitor.sh -c
   ```

3. **频点扫描失败**
   ```bash
   # 测试频点扫描
   /etc/config/earfcn_lock/network_monitor.sh -s
   
   # 检查cpetools.sh是否可用
   which cpetools.sh
   ```

4. **钉钉通知不发送**
   - 检查网络连接是否正常
   - 验证钉钉机器人token是否正确
   - 查看日志中的错误信息

### 日志分析

查看日志了解脚本运行状态：
```bash
# 查看错误信息
grep "ERROR" /tmp/network_monitor.log

# 查看警告信息
grep "WARN" /tmp/network_monitor.log

# 查看锁频操作
grep "锁频\|切换" /tmp/network_monitor.log
```