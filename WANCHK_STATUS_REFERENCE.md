# wanchk 状态参考文档

## 概述
`wanchk.sh` 是网络连接检查守护进程，负责监控CPE网络状态并设置相应的状态文件。

## 状态文件位置
- **主状态文件**: `/var/run/wanchk/iface_state/cpe`
- **锁定状态文件**: `/var/run/wanchk/iface_state/cpe_lock`
- **IPv6状态文件**: `/var/run/wanchk/iface_state/cpe_6`
- **电源控制文件**: `/var/run/wanchk/iface_state/cpe_power`

## 主要状态值

### 1. 网络连接状态 (主状态文件)
存储在 `/var/run/wanchk/iface_state/cpe` 中：

#### `up`
- **含义**: 网络连接正常
- **设置条件**: 
  - DNS检查通过 或
  - Ping检查通过 或
  - 网络流量检测正常
- **代码位置**: `check_main()` 函数中 `_Nstatus="up"`

#### `down`
- **含义**: 网络连接异常
- **设置条件**:
  - DNS检查失败 且
  - Ping检查失败 且
  - 网络流量检测异常
- **代码位置**: `check_main()` 函数中 `_Nstatus="down"`

#### `block`
- **含义**: 网络被阻塞/暂停
- **设置条件**:
  - `loopCheckMode = "pause"` 或
  - 锁定状态文件内容为 `"lock"`
- **代码位置**: `check_one_protocal()` 函数中 `set_wanchk_state "$state_name" "block"`

### 2. 锁定控制状态 (锁定状态文件)
存储在 `/var/run/wanchk/iface_state/cpe_lock` 中：

#### `lock`
- **含义**: CPE被锁定，暂停网络检测
- **效果**: 主状态会被设置为 `block`
- **用途**: 外部工具可以通过设置此文件来暂停wanchk的检测

#### `unlock`
- **含义**: CPE解锁，恢复网络检测
- **效果**: 清除锁定状态，恢复正常检测流程
- **用途**: 外部工具可以通过设置此文件来恢复wanchk的检测

### 3. 循环检查模式 (loopCheckMode)
这是 `wanchk.sh` 内部的控制变量：

#### `normal`
- **含义**: 正常检测模式
- **行为**: 执行完整的网络检测流程

#### `pause`
- **含义**: 暂停模式
- **触发**: 接收到 `USR2` 信号
- **效果**: 设置状态为 `block`，跳过网络检测

#### `recovery`
- **含义**: 恢复模式  
- **触发**: 接收到 `USR1` 信号
- **效果**: 清理状态文件，重新开始检测

### 4. 电源控制状态
存储在 `/var/run/wanchk/iface_state/cpe_power` 中：

#### `1`
- **含义**: 忽略电源重启
- **效果**: 当网络检测失败次数达到阈值时，不执行电源重启

#### 其他值或不存在
- **含义**: 允许电源重启
- **效果**: 网络检测失败时可以执行电源重启

## 状态检测优先级

### network_monitor.sh 中的检测逻辑：

1. **is_cpe_locked() 函数检测顺序**:
   ```
   1. 检查 /var/run/wanchk/iface_state/cpe_lock
      - "lock" → 跳过网络检测
      - "unlock" → 继续网络检测
   
   2. 检查 /var/run/wanchk/iface_state/cpe  
      - "block" → 跳过网络检测
   
   3. 检查 cpetools 进程
      - 有进程运行 → 跳过网络检测
      - 无进程运行 → 继续网络检测
   ```

2. **check_cpe_status() 函数检测顺序**:
   ```
   1. 检查主状态文件内容
      - "up" → 网络正常
      - "down" → 网络异常  
      - "block" → 网络被阻塞(视为异常)
      - 其他/空 → 网络异常
   ```

## 状态转换流程

```
正常流程:
[启动] → normal → [检测] → up/down → [继续检测]

暂停流程:  
[USR2信号] → pause → block → [跳过检测]

恢复流程:
[USR1信号] → recovery → [清理状态] → normal → [恢复检测]

锁定流程:
[外部设置lock] → block → [跳过检测]
[外部设置unlock] → [恢复检测]
```

## 实际使用场景

### 1. 正常网络监控
- 状态文件: `up` 或 `down`
- 锁定文件: 不存在或 `unlock`
- 行为: 正常执行网络检测和故障处理

### 2. 锁频操作期间
- 状态文件: `block`
- 锁定文件: `lock`
- 行为: 暂停网络检测，避免干扰锁频过程

### 3. 维护模式
- 通过信号控制: `kill -USR2 <wanchk_pid>` (暂停)
- 通过信号恢复: `kill -USR1 <wanchk_pid>` (恢复)
- 行为: 临时暂停或恢复网络检测

### 4. 外部工具控制
- 设置锁定: `echo "lock" > /var/run/wanchk/iface_state/cpe_lock`
- 解除锁定: `echo "unlock" > /var/run/wanchk/iface_state/cpe_lock`
- 删除锁定: `rm /var/run/wanchk/iface_state/cpe_lock`

## 调试命令

```bash
# 查看当前状态
cat /var/run/wanchk/iface_state/cpe

# 查看锁定状态  
cat /var/run/wanchk/iface_state/cpe_lock

# 查看所有状态文件
ls -la /var/run/wanchk/iface_state/

# 使用network_monitor.sh检查状态
./network_monitor.sh -k

# 查看wanchk进程
ps | grep wanchk

# 发送控制信号
kill -USR2 <wanchk_pid>  # 暂停
kill -USR1 <wanchk_pid>  # 恢复
```
