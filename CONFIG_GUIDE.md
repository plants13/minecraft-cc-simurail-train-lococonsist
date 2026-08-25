# 机车重联控制系统 —— 配置与部署说明

> 本说明对应**合并版**：单文件 `startup.lua`，换向拉杆选主从；驱动/制动走 **Simurail 物理转向架的 CC 外设**（`useBogeyPeripheral`），冒进防护走红石输入。
> 所有脚本/配置必须**纯 ASCII**——CC:Tweaked 加载不了中文注释（这份文档给人看，放本地，别复制进游戏电脑）。

---

## 0. 架构总览

每台机车电脑上放 3 个文件：

| 文件 | 作用 | 每车是否相同 |
| --- | --- | --- |
| `startup.lua` | 控制程序（主机+从机合一，拉杆决定角色） | 相同 |
| `config_locomodel.lua` | 本车硬件/PID/外设配置 | 每车一份，按接线可不同 |
| `mu_config.lua` | 重联配置（协议名 + 其他车相对本车方向） | 每车一份，视角不同 |

- 电脑身份用 `label set <名称>` 设置（大小写敏感，重启不丢）。
- **接线角色分工**：

| 功能 | 通道 |
| --- | --- |
| 驱动（油门） | Simurail 转向架 CC 外设 `setMaxStress`（±128，应力=网络消耗） |
| 制动 | Simurail 转向架 CC 外设 `setBrakeStrengthOverride`（0..1） |
| 换向 | 驱动应力符号（负 = 反向），不再用倒挡齿轮箱红石 |
| 红灯（冒进防护） | **红石输入 `sideRedSignal`**（不经过 CC 外设） |
| 重联通信 | 无线 modem（rednet） |

---

## 一、模式选择（换向拉杆）

`sideReverse` 接的拉杆是**模拟量**，三个区间决定角色与方向：

| 模拟值 | 角色 | 方向 |
| --- | --- | --- |
| 0-4 | 主机 | 前进 |
| 5-10 | 从机 | — |
| 11-15 | 主机 | 后退 |

- 拉杆运行中可实时切换；从机不读自己的拉杆方向，方向跟随主机（按 mu_config 取反）。
- **全网安全**：同一协议组内**恰好 1 台主机**才正常；0 台或多台主机 → 全列切断牵引 + EB（全制动）。

---

## 二、config_locomodel.lua —— 本车配置

```lua
return {
    maxSpeed = 50.0,               -- 最高速度 (m/s)，档位设定速度上限

    -- 红石 I/O 面（bogey 模式下只剩输入面 + 显示器/modem）
    sideSetSpeed  = "top",         -- 输入：RHI 手柄 0-15（档位）
    sideReverse   = "right",       -- 输入：模式拉杆 0-4前进 / 5-10中立 / 11-15后退
    sideRedSignal = "front",       -- 输入：前方红灯信号（0=无，1-15=红灯且越强越近）
    sideMonitor   = "left",        -- 输出：显示器（可无）
    sideModem     = "front",       -- 外设：无线调制解调器面（rednet）

    -- Simurail 转向架 CC 外设（驱动/制动/换向）
    useBogeyPeripheral = true,     -- false = 回退红石输出（需接回 sideBrake/sideThrottle/sideRevGearbox）
    bogeyDriveMax = 128.0,         -- 驱动应力范围：油门满档 → ±128（应力=动力网络消耗）

    visualMaxSpeed = 10.0,         -- 目视行车限速 (m/s = 36 km/h，运行中可开)

    -- 控制循环周期
    pidDt = 0.05,                  -- 循环节奏 20Hz（>红石刻 10Hz，利于平顺）

    -- PID 参数（统一 PID：输出 = 驱动应力 0..128 / 制动强度 0..1）
    pidKi = 4.3,                   -- 积分（0..128 刻度，原 0..15 刻度 0.5 ×8.53）
    pidKd = 4.3,                   -- 微分（同上换算）
    pidKpNear = 6.8, pidKpMid = 10.2, pidKpFar = 21.3,   -- 分段增益（0..128 刻度）
    nearThreshold = 0.8, farThreshold = 5.0,           -- 增益分段边界 (m/s)
    pidDeadband = 0.15,            -- 死区：设定点附近不动作
    noBrakeWindow = 0.5,           -- 略超速不制动（滑行窗口）
    maxOutputDelta = 17.0,         -- 输出斜坡（每 0.1s 参考应力变化，0..128 刻度）
    brakeScale = 0.2,              -- 制动强度上限：满驱动输出时制动 = 0.2
    emergencyBrakeKp = 0.1,        -- 急停：制动强度 = 速度(m/s) × 0.1 × brakeScale

    -- 性能标定参数（Calibrate 命令）
    calibAccelDur     = 3.0,       -- 全油门加速测量时长 (s)
    calibBrakeTarget  = 10.0,      -- 制动标定前的巡航速度 (m/s = 36 km/h)
    calibRunTimeout   = 20.0,      -- 爬到巡航速度的超时 (s)
    calibBrakeTimeout = 12.0,      -- 制动测量超时 (s)
    calibSettle       = 0.5,       -- 输出切换后的稳定时间 (s)
}
```

**要点**：
- **删掉的红石输出面**：`sideBrake` / `sideThrottle` / `sideRevGearbox` 在 bogey 模式下不再需要（驱动/制动/换向走转向架外设）。⚠️ `sideThrottle` 原来是给变速箱供转速（驱动前提是转向架有转速 `getSpeed`）——删掉后**变速箱必须由常亮红石（红石火把/拉杆）直接供能**，否则车不动。
- **冒进防护（sideRedSignal）**：主机读前方红灯电平——`>0` 即红灯，**切断牵引 + 按接近程度制动**（电平越强制动越猛，制动强度 = 电平/15）；红灯清除自动恢复。**后退位（拉杆 11-15）完全不读红灯**（前方信号在行进方向后方，倒车靠司机目视，锁存也不触发）。**电平到 15（贴脸）触发锁存**：全制动 + 设定速度归零，**须把手柄拉到 EB（信号 0）确认后才能缓解**；目视行车豁免。**从机不读红灯**（跟随主机广播 ctrl，全列一起停）。未接线时读 0 = 无限制。显示器第 7 行 `RED`（防护）/ `LAT`（锁存）指示。
- **运行时指令**：终端输入命令 + 回车（大小写不敏感）：`VisualDriving`（或 `vd`）开关目视行车；`Calibrate`（或 `calib`）性能标定（两步确认，见下）；`help` 列出命令。
- **性能标定**：先把 RHI 手柄拉到 **EB 位**，输入 `calib` 进入待命（显示器 `ARM`；EB 位再输一次解除），再**拉到 N 位开始**。前置：主机位 + 停车 + 无红灯 + 有速度传感器。自动跑：全油门（±满应力）测加速 → 爬到 36 km/h → 全制动测减速 → 最小二乘拟合 m/s² → 存本机 `calib.json`（将来 LKJ 用 `fs.exists` + `textutils.unserializeJSON` 读取）。标定中故障自动中止并全制动；结束保持全制动到停稳（从机同步）。重联时从机跟随一起动，测的是**整列**性能。
- **K 档速率与 pidDt 解耦**：每拍实测 dt，设定速度按 `5/1 km/h/s × dt` 增减、PID 积分/微分、输出斜坡都按 dt 算。
- 文件头注释里的 `config_swd1p.lua / SWD1P` 是历史残留，不影响运行。

---

## 二·五、Simurail 转向架 CC 外设（驱动层）

- 外设类型：`Simurail_PhysicsBogey`（有线网络/贴面可达，`peripheral.getNames()` 可找）。
- **驱动**：`setMaxStress(±bogeyDriveMax)` —— 应力 = |maxStress| × |multiplier|，脚本启动时把 multiplier 锁 1，所以**应力 = maxStress 绝对值，直接反映动力网络消耗**；符号决定方向。
- **制动**：`setBrakeStrengthOverride(0..1)`，与红石/遥控/导航 4 路取 max，CC 覆盖直通不平方。
- **转速前提**：转向架必须有动力学转速（`getSpeed`）才出力——变速箱/动力网络负责，电脑不再管（见上"删掉的红石输出面"）。
- **外设调用节流**：驱动/制动只在数值变化时才调用外设（防 mainThread 任务拖垮主循环）；重启后外设数值复位，无需额外同步。
- 转向架 GUI 里的"应力"就是 maxStress 基数——CC 设置的倍率不显示在 GUI，用 `hasStressMultiplierOverride()`/`getStressMultiplier()` 判断。

---

## 三、mu_config.lua —— 重联配置（最容易写错）

```lua
return {
    protocol = "loco-mu",         -- 协议名：同一组内的车必须逐字符一致
    others = {
        -- 键 = 其他车的电脑 label，值 = 该车相对【本车】的方向
        ["对方车label"] = { reverse = true },   -- true = 对方与本车反向（车头对车头）
        ["另一台车label"] = { reverse = false }, -- false = 同向
    },
}
```

**铁律**：
1. **自己不出现在自己的表里**——`others` 只列"除自己外"的车。
2. **键必须是"对方"的 label**——从机靠 `others[主机label].reverse` 决定是否取反；查不到就不换向（默认同向）。
3. **reverse 是"对方相对我"**：对方车头对着我 → `true`；同向 → `false`。
4. **protocol 组内保持一致、组间必须不同**——protocol 是隔离手段，一组（如两台）共用一个名字；不同组的车互不干扰。

**双机示例**（车头对车头，两台一组）：

9001 电脑的 mu_config.lua：
```lua
return {
    protocol = "grp-a",
    others = { ["YL56U2_9002"] = { reverse = true } },
}
```

9002 电脑的 mu_config.lua：
```lua
return {
    protocol = "grp-a",
    others = { ["YL56U2_9001"] = { reverse = true } },
}
```

> 两台内容**不一样是正常的**（视角不同）。把同一份复制给两台是典型错误——从机会查不到主机的键 → 不换向。

四台车 = 两个重联组：组 A（9001/9002）protocol 用 `grp-a`，组 B（9003/9004）用 `grp-b`，各组 others 只列同组另一台。

---

## 四、部署步骤

1. 每台车 `label set <自己的名字>`（与 mu_config 里 others 的键对应）。
2. 复制 3 个文件到每台车：`startup.lua`、`config_locomodel.lua`、`mu_config.lua`。
3. 每台车按自己视角改 `mu_config.lua` 和 `config_locomodel.lua`（接线面）。
4. **接线**：`sideSetSpeed`/`sideReverse`/`sideRedSignal` 三个输入面 + 显示器 + 无线 modem；转向架外设有线网络可达；变速箱用常亮红石供转速。
5. 把想当主机的车拉杆扳到前进/后退，其余中立。开机即运行。

---

## 五、改机车配置文件名

`config_locomodel.lua` 的名字在脚本里写死，改名要同步改脚本。合并版只有**一处**：

| 文件 | 位置 | 代码 |
| --- | --- | --- |
| `startup.lua` | 第 0 节 | `local cfg = dofile("config_locomodel.lua")` |

`mu_config.lua` 同理，`startup.lua` 里 `pcall(dofile, "mu_config.lua")` 一处。

---

## 七、常见问题速查

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 从机不自动换向 | mu_config 的 `others` 键写错/复制了主机那份 | 从机那份的键改成**主机的 label**，reverse 按实车朝向 |
| 收不到对方（无 Heard / RX 不涨） | 组内 protocol 不一致 | 两台 `protocol` 逐字符对比；控制台 `Foreign protocol` 会指出差异 |
| 全列 EB（FAULT） | 组内主机数 ≠ 1（都中立/多台非中立） | 确认恰好一台拉杆在前进/后退 |
| 车完全不动（bogey 模式） | ① 变速箱没转速（常亮红石缺失）② 转向架 maxStress 为 0 | ① 变速箱接常亮红石 ② `bogey_probe.lua` 查 `getMaxStress` |
| 显示器 `T:` 无变化 | 驱动应力未变或外设失联 | 控制台 `BOGEY CALL FAILED` 提示；`bogey_probe.lua` 单测 |
| 倒车被红灯挡住 | （已修复）锁存曾缺倒车豁免 | 确认拉杆 11-15 时 `RED` 不亮 |
| B1-B9 无制动 | B 档制动 = (10-sig)/15 强度 | 信号 1→强度1.0 … 信号9→0.067，逐级 |
| 20Hz 下油门高频抖动 | 微分项噪声放大 | pidKd 从 4.3 降到 2~3（0..128 刻度） |
| 控制台 `BROADCAST FAILED` | 广播失败（少见） | 查看原因，多为 modem 被移除 |
| 脚本加载报错 | 文件里有中文/非 ASCII | 注释一律英文 |
