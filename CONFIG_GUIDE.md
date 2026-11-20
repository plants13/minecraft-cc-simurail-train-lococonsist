# 机车重联控制系统 —— 配置与部署

本文面向**部署者**：怎么接线、怎么改配置、怎么开车、出问题怎么查。
工作原理综述见 [`系统工作原理.txt`](系统工作原理.txt)，功能概览见 [`README.md`](README.md)。

> **纯 ASCII 铁律**：所有 `.lua` 与游戏内配置文件必须是纯 ASCII。CC:Tweaked 加载不了含非 ASCII 字符的脚本，开机直接报错。中文只写在这类 `.md` / `.txt` 里，**不要复制进游戏电脑**。

## 目录

1. [系统组成](#一系统组成)
2. [硬件接线](#二硬件接线)
3. [`config_locomodel.lua` 参考](#三config_locomodellua-参考)
4. [`mu_config.lua` 重联配置](#四mu_configlua-重联配置)
5. [部署步骤（按角色）](#五部署步骤按角色)
6. [日常操作](#六日常操作)
7. [安全与故障语义](#七安全与故障语义)
8. [排障](#八排障)
9. [附录：外设与探针事实](#九附录外设与探针事实)

---

## 一、系统组成

一台车至少一台电脑跑 `startup.lua`。同一份脚本有四种运行形态，由配置里的 `displayMode` / 运行时命令决定：

| 角色 | 跑什么 | 需要什么硬件 | 说哪个协议 |
| --- | --- | --- | --- |
| **运控车**（主机/从机） | `startup.lua` | 转向架外设、手柄、模式拉杆、显示器（可无）、速度传感器（可无）、无线 modem、可选应力表 | 控制 `<协议>`、遥显 `<协议>-disp`、手动台 `<协议>-manual` |
| **驾驶台遥显终端** | 同一份 `startup.lua`，`displayMode = true` | 电脑 + 显示器 + 无线 modem（**不需要**转向架/传感器/手柄/拉杆） | 只听 `<协议>-disp` |
| **手动驾驶台** | 同上（`displayMode = true`）+ 打字机 | 再看：`linked_typewriter` 贴在终端旁 | 发 `<协议>-manual` |
| **车门集控** | `door_ctrl.lua` | 左右门脉冲输入 + 两路常电平输出 + 无线 modem | `loco-door` |

```
                  无线 modem（rednet）
   运控车 A  ⇄⇄⇄  运控车 B      （<协议>：状态 + 控制数据，10 Hz）
      ⇢ 驾驶台终端              （<协议>-disp：主机快照，4 Hz）
      ⇠ 手动驾驶台               （<协议>-manual：档位 + 转向 + 警惕确认，10 Hz）
      ⇢ 车门电脑 ×N             （loco-door：开关命令 + 0.5 s 状态心跳）
```

**角色与方向由模式拉杆（`sideReverse` 模拟红石量）实时决定**，运行中可切：

| 模拟值 | 角色 | 方向 |
| --- | --- | --- |
| 0-4 | 主机 | 前进 |
| 5-10 | 从机 | 跟随主机（按 `mu_config` 取反） |
| 11-15 | 主机 | 后退 |

**全网安全**：同一协议组内恰好 1 台主机。0 台或多台 → 全列切牵引 + EB。

---

## 二、硬件接线

### 运控车（每台机车）

| 接口 | 方式 | 必需 | 说明 |
| --- | --- | --- | --- |
| 手柄（`sideSetSpeed`） | 模拟红石输入 0-15 | ✅ | 档位；也可由红石链接/遥控器无线传进来 |
| 模式拉杆（`sideReverse`） | 模拟红石输入 0-15 | ✅ | 决定主从与方向 |
| 转向架外设 | **贴面或同一有线网络** | ✅ | 驱动/制动/换向/转向/探针全走它，**无红石回退** |
| 显示器（`sideMonitor`） | 外设（可缺） | — | 缺了只是不画 |
| 无线 modem（`sideModem`） | 外设 | — | 缺了重联/遥显/手动台全停（单机仍可开） |
| 速度传感器 | `velocity_sensor`（贴面/有线） | — | 缺了实际速度显示 `N/A`，PID 无速度反馈（**不可用**） |
| 应力表（可选） | `Create_Stressometer` | — | 接在**被这些转向架消耗的同一条动力网络**上 |
| 变速箱 | 常亮红石（火把/拉杆） | ✅ | 转向架必须有转速 `getSpeed` 才出力 |

### 驾驶台遥显终端 / 手动台

| 接口 | 说明 |
| --- | --- |
| 显示器（`sideMonitor`） | 必需 |
| 无线 modem（`sideModem`） | 必需 |
| `linked_typewriter` | 手动台必需，**贴终端或同有线网络**，键位在打字机自己的界面里绑 |

### 车门电脑（每车一台，独立）

接线面写在 `door_ctrl.lua` 顶部常量里（不走 `config_locomodel.lua`）：

| 常量 | 默认面 | 作用 |
| --- | --- | --- |
| `SIDE_IN_L` / `SIDE_IN_R` | right / left | 左右门按钮脉冲输入（上升沿翻转） |
| `SIDE_OUT_L` / `SIDE_OUT_R` | front / back | 左右门常电平输出（开门期间为高） |
| `SIDE_MODEM` | top | 无线 modem |

---

## 三、`config_locomodel.lua` 参考

每台电脑一份，按本机接线与角色改。文件内已带英文注释，下面是分组速查（默认值即仓库版本）：

### 基本

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `maxSpeed` | `50.0` | 最高速度 m/s，设定速度上限 |
| `pidDt` | `0.05` | 控制循环周期 s（20 Hz）。K 档速率、PID、斜坡都按实测 dt 缩放，改它只影响响应度 |
| `visualMaxSpeed` | `10.0` | 目视行车限速 m/s（36 km/h） |

### 面位（红石输入 / 外设侧）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `sideSetSpeed` | `"top"` | RHI 手柄模拟输入面 |
| `sideReverse` | `"right"` | 模式拉杆模拟输入面 |
| `sideMonitor` | `"left"` | 显示器外设面 |
| `sideModem` | `"front"` | 无线 modem 面 |

> **红石输出面已移除**：老配置里的 `sideBrake` / `sideThrottle` / `sideRevGearbox` 三个键不再读取，留着无害但无效。

### 驱动

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `bogeyDriveMax` | `128.0` | 驱动应力范围：PID 输出 0..128 → `setMaxStress(±128)`；应力 = 动力网络消耗 |

### PID（统一控制器：正输出 = 驱动应力，负输出 = 制动强度）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `pidKpNear` / `pidKpMid` / `pidKpFar` | `6.8` / `10.2` / `21.3` | 分段比例增益（0..128 刻度），误差越大越激进 |
| `nearThreshold` / `farThreshold` | `0.8` / `5.0` | 增益分段边界 m/s |
| `pidKi` / `pidKd` | `4.3` / `4.3` | 积分 / 微分（0..128 刻度） |
| `pidDeadband` | `0.15` | 死区 m/s：误差在此内不动作、冻结积分 |
| `noBrakeWindow` | `0.5` | 略超速时不制动而是惰行（避免反复点刹） |
| `maxOutputDelta` | `17.0` | 输出斜坡：每 0.1 s 允许的应力变化（EB/B/N 不斜坡） |
| `brakeScale` | `0.2` | 制动强度上限系数：满驱动输出 → 0.2 制动 |
| `emergencyBrakeKp` | `0.1` | 设定速度为 0 时的制动强度 = 速度 × 该系数 × `brakeScale` |

> ⚠️ **不要出现两行 `pidKpFar`**。历史上有一份配置里 `21.3` 后面跟了一行 `2.5`（旧 0..15 刻度的残留），Lua 表构造后值覆盖前者，表现为"远区无力、误差大反而更软"。

### 冒进防护（转向架探针）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `redProbeFront` | `true` | 读哪根轴的探针：`true` 前端轴 / `false` 后端轴。**必须指向行驶方向**，反了就对后方红灯制动 |
| `redProbeWindow` | `128.0` | 探针扫描长度（格），启动时写入每个转向架（模组默认 0 = 不扫描） |
| `redEbDistance` | `4.0` | 红灯进入这个距离内 → EB 锁存（视为已到信号机，不做接近减速） |

### 性能标定

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `calibAccelDur` | `3.0` | 全牵引加速测量窗口 s |
| `calibBrakeStrength` | `0.5` | 制动段使用的制动强度（0.5 = 50%） |
| `calibPlateauTime` / `calibPlateauEps` | `2.0` / `0.1` | 速度这么久没涨超过 eps 就认为到顶 |
| `calibMinTopSpeed` | `5.0` | 顶速低于此判定标定失败 m/s |
| `calibStartClearance` | `64.0` | 开始标定所需的前方无红灯距离（格） |
| `calibRunTimeout` / `calibBrakeTimeout` | `120.0` / `60.0` | 爬升/制动段兜底超时 s |
| `calibSettle` | `0.5` | 输出切换后的稳定时间 s |

### 过应力保护（可选，需 `Create_Stressometer`）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `stressGuardMargin` | `0.95` | 超载时把驱动上限压到 `当前值 × capacity/used × 该系数` |
| `stressGuardReleaseRatio` | `0.85` | 仅在 `used/capacity` 低于此值时才放回上限（宽回差，防自泵） |
| `stressGuardRelease` | `8.0` | 上限恢复速率（0..128 刻度每秒） |
| `stressGuardCalibAbort` | `true` | 标定中触发保护则中止（此时不是全牵引，曲线不可信） |

### 空转防护（可选，默认关）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `slipGuardEnabled` | `false` | 总开关。**只在固定编组、或每次改编组后重标定后打开** |
| `slipGuardRatio` | `0.45` | `实测加速度/标定预期` 低于此判为打滑 |
| `slipGuardMinSpeed` / `slipGuardMinStress` | `2.0` / `24.0` | 低于这些速度/应力不下结论（噪声大） |
| `slipGuardCut` / `slipGuardFloor` | `0.55` / `32.0` | 每次判定乘性削减驱动上限，且不低于下限 |
| `slipGuardRelease` / `slipGuardHold` | `10.0` / `0.4` | 恢复速率与削减后冻结时间 |
| `slipGuardFilter` | `0.30` | 加速度平滑窗口 s |

> 为什么不默认开：预期加速度来自**某一固定编组**标定的曲线，机辆模式频繁摘挂车，真实质量变了曲线没变，这个偏差会被当成打滑 → 正常轮子被砍牵引。

### 驾驶台遥显（`displayMode`）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `displayMode` | `false` | `true` = 本机是**只读显示终端**，不再控车 |
| `displayProtocol` | `nil` | `nil` = `"<协议>-disp"`；手填则两端一致 |
| `displayInterval` | `0.25` | 主机快照周期 s；`false` = 主机不发布（省无线流量） |
| `displayStale` | `2.0` | 超过这么久没快照 → `LINK LOST` |

### 手动驾驶台

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `manualProtocol` | `nil` | `nil` = `"<协议>-manual"`；手填则两端一致 |
| `manualTimeout` | `2.5` | 主机超过这么久没收到驾驶台包 → 制动（见下条） |
| `manualHoldSpeedOnLoss` | `true` | 丢包时**保留设定速度**只制动；`false` = 连设定速度一起清零（旧行为） |
| `manualDefault` | `false` | 开机默认是否进手动模式；**`manual.json` 存在时以文件为准** |

### 警惕键（仅手动模式）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `vigilanceEnabled` | `false` | 开启后必须周期按 `Space` |
| `vigilancePeriod` | `30.0` | 多久要确认一次 s |
| `vigilanceGrace` | `15.0` | 到期前多久开始闪 `VIG?` |
| `vigilanceBrake` | `0.5` | 超时后施加的**常用制动**强度（不是 EB） |

### 文件名

配置文件名写死在脚本里，改名要同步改：

| 被加载的文件 | 在 `startup.lua` 里的位置 |
| --- | --- |
| `config_locomodel.lua` | 第 0 节 `local cfg = dofile("config_locomodel.lua")` |
| `mu_config.lua` | `local muOK, muCfg = pcall(dofile, "mu_config.lua")` |

---

## 四、`mu_config.lua` 重联配置

```lua
return {
    protocol = "loco-mu",      -- 同一组内逐字符一致
    others = {
        -- 键 = 【对方】电脑的 label；值 = 对方相对【本车】的方向
        ["YL56U2_9002"] = { reverse = true },   -- 车头对车头
        ["YL56U2_9003"] = { reverse = false },  -- 同向
    },
}
```

**四条铁律**：

1. **自己不出现在自己的 `others` 里**——只列"除自己外"的车。
2. **键必须是对方的 label**——从机靠 `others[主机label].reverse` 决定是否取反；查不到就按同向（典型错误是把主机那份复制给从机）。
3. **`reverse` 是"对方相对我"**：对方车头朝我 → `true`；同向 → `false`。
4. **`protocol` 组内一致、组间必须不同**——这是隔离手段。

**双机示例**（车头对车头）：

```lua
-- 9001 那台
return { protocol = "grp-a", others = { ["YL56U2_9002"] = { reverse = true } } }

-- 9002 那台
return { protocol = "grp-a", others = { ["YL56U2_9001"] = { reverse = true } } }
```

两台内容**不一样是正常的**。四个车 = 两个组：组 A 用 `grp-a`，组 B 用 `grp-b`，各组 `others` 只列同组另一台。

---

## 五、部署步骤（按角色）

### A. 运控车（最少一台）

1. `label set <名称>`（与 `mu_config` 的键一致）
2. 放三个文件：`startup.lua`、`config_locomodel.lua`、`mu_config.lua`
3. 改 `config_locomodel.lua` 的面位（手柄/拉杆/显示器/modem 接在哪些面）
4. 改 `mu_config.lua`：协议名 + 对方 label 与相对方向
5. 接线：见[第二节](#二硬件接线)；转向架**必须有线/贴面可达**，变速箱**必须常亮红石**
6. 开机。看启动横幅逐条确认：

```
Bogey peripherals found: 1              <- 转向架找到几个
Stress gauge found: N - overstress ...  <- 应力表（可选）
Performance curve: none - run Calibrate <- 标定曲线是否已加载
Network up on protocol 'loco-mu'        <- 无线网络
Red protection: probe front axle, window 128 blocks, EB inside 4 blocks
```

7. 拉杆扳到前进/后退 → 控制台打印 `Lever: 0 -> master`，随后 `OK: 1 master on network`

### B. 驾驶台遥显终端

1. 放 `startup.lua` + `config_locomodel.lua` + `mu_config.lua`（**`mu_config` 只用来推协议名**）
2. `config_locomodel.lua` 里设 `displayMode = true`，`sideMonitor` / `sideModem` 按实际面
3. 接显示器 + 无线 modem，开机看到 `Display terminal started: protocol '<协议>-disp'`
4. 终端**不进控制环**，也不会被算作主机；放几台都行

### C. 手动驾驶台（可选，在 B 基础上）

1. 终端旁（贴面或同一有线网络）放 `simulated:linked_typewriter`
2. 在打字机界面里给 `W` `S` `A` `D` `左Shift` `Space` **各绑一个频率**（不用接接收器；没绑频率的键不会被上报）
3. 开机确认 `Desk: linked_typewriter on '<外设名>'`
4. **到运控车终端输 `Manual` 才进入手动模式**（驾驶台单方面抢不走控制）；模式会写 `manual.json` 持久化

### D. 车门电脑（可选，每车一台）

放 `door_ctrl.lua`，改脚本顶部 5 个面常量，`label set <车号>_door`。行为见 `door_ctrl.lua` 顶部注释。

---

## 六、日常操作

### 6.1 开车

1. 拉杆扳到前进/后退（主机位）
2. 手柄从 **EB** 拨到 **N**（此时设定速度取当前实际速度，即 0）
3. 逐档拨上 `K3` / `K4` 加速，**回到 `C`（13 挡）保持速度**——K 档是"一直变"，不是"定速"
4. 减速用 `K1` / `K2`，停车用 `B9..B1`（直接制动）或 `EB`
5. 冒进锁存（`LAT`）后必须把手柄**扳回 EB** 才能解除

### 6.2 运行时命令

| 命令 | 作用 |
| --- | --- |
| `VisualDriving` / `vd` | 开关目视行车：设定速度封顶 36 km/h，且忽略红灯 |
| `Calibrate` / `calib` | 性能标定（见 6.3） |
| `Manual` / `man` | 开关手动驾驶台模式，并写盘持久化 |
| `help` | 列出命令 |

### 6.3 性能标定流程

1. **前置**：主机位、停车、有速度传感器、前方 ≥ `calibStartClearance` 无红灯
2. 手柄拉到 **EB**，输入 `calib`（显示器出现 `ARM`；EB 位再输一次解除）
3. 手柄拉到 **N** 启动
4. 程序自动：全牵引爬到顶速（或撞上 `maxSpeed`）→ 惰行 `calibSettle` → 按 `calibBrakeStrength` 制动到停 → 全制动保持到停稳
5. 结果写本机 `calib.json`（v3）：`accel.a0/a1/vmax`、`brake.d0/d1/mps2/mps2Full`、拟合质量 `rms/r2`、顶速 `topMps`、以及每 2 m/s 的 `profile` 采样表
6. 重联时从机跟随一起动，测的是**整列**性能

冒进防护不需要速度传感器即可工作；标定和空转防护需要。

### 6.4 手动驾驶台操作

| 键 | 作用 |
| --- | --- |
| `W` / `S` | 档位 +1 / −1（一次一格，16 挡与手柄同一套映射） |
| `A` / `D` | 按住：向左 / 右选边（岔口方向） |
| `左Shift` | 拍 EB（档位归 0） |
| `Space` | 警惕确认（若开启了 `vigilanceEnabled`） |

- 档位是**锁存**的：`C`(13) 保持速度，`K1..K4` 会持续变速
- **方向仍由模式拉杆决定**，`A/D` 只管岔口选边
- 打字机与电脑终端**互斥**：打开任何界面（含电脑 GUI）时打字机会断开，这是模组行为

---

## 七、安全与故障语义

### 7.1 什么情况会切牵引 / 制动

| 情况 | 行为 | 在哪一侧判定 |
| --- | --- | --- |
| 组内主机数 ≠ 1 | 全列切牵引 + EB | 每台车自己算 |
| 从机收不到主机控制数据 > 1.5 s | 切牵引 + EB | 从机 |
| 发送者状态过期 > 2.5 s | 从 `seen` 剔除（计入主机数判断） | 每台车 |
| 冒进防护：红灯 ≤ `redEbDistance` | EB 锁存（全制动 + 设定归零），须扳回 EB 解除 | 主机 |
| 外设调用失败 | 打印一次 `BOGEY CALL FAILED`，保持无输出 | 每台车 |
| 手动模式：驾驶台包超时 > `manualTimeout` | 切牵引 + 全制动；`manualHoldSpeedOnLoss = true` 时**保留设定速度** | 主机 |
| 手动模式：警惕超时 | 切牵引 + `vigilanceBrake` 常用制动，锁存到 `Space` 确认 | 主机 |
| 过应力（有应力表时） | 压低驱动上限，不切牵引 | 每台车 |
| 空转判定（开启时） | 压低驱动上限，只影响牵引 | 每台车 |

### 7.2 手动模式的持久化规则

`Manual` 是**模式**不是一次性开关，切换后写本机 `manual.json`：

```
manual.json（命令写下的）  >  manualDefault（配置默认）
```

- 恢复到手动但**还没收到驾驶台包时保持 EB**（比落到一个没人握着、可能停在驱动挡的物理手柄安全）
- 恢复时**没有 modem** → 忽略手动并打印提示（否则永远收不到包），文件保留
- 想彻底回手柄：主机敲一次 `Manual`（写回 `false`），或删本机 `manual.json`

### 7.3 三个协议的隔离保证

| 协议 | 谁发 | 谁听 | 为什么单独开 |
| --- | --- | --- | --- |
| `<协议>` | 每台运控车 | 每台运控车 | 控制数据与主机计数 |
| `<协议>-disp` | 只有主机 | 任何遥显终端 | 终端不能被算成主机；显示流量不进控制环 |
| `<协议>-manual` | 只有驾驶台 | 运控车 | 驾驶台不能单方面接管；手动台消息不影响自动驾驶 |

控车电脑收到 `-disp` / `-manual` 之外的外来协议只警告一次。

---

## 八、排障

### 8.1 通信与角色

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 收不到对方（无 `Heard` / `RX` 不涨） | 组内 `protocol` 不一致 | 两台逐字符对比；控制台 `Foreign protocol` 会指出差异 |
| 全列 EB（`FAULT`） | 组内主机数 ≠ 1 | 确认恰好一台拉杆在前进/后退位 |
| 从机不自动换向 | `mu_config.others` 键写错，或复制了主机那份 | 从机那份的键改成**主机 label**，`reverse` 按实车朝向 |
| 单机也想开，但一直 FAULT | 模式拉杆不在主机位（模拟量落在 5-10） | 拉杆扳到 0-4 或 11-15 |

### 8.2 驱动与制动

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 车完全不动 | ① 变速箱没转速 ② `maxStress` 为 0 ③ 转向架外设没找到 | ① 常亮红石 ② `bogey_probe.lua` 查 `getMaxStress` ③ 看启动横幅 / `ERROR: no Simurail_PhysicsBogey peripheral` |
| 启动横幅报找不到转向架 | 外设不在贴面/有线网络内，或转向架区块未加载 | 加有线 modem + 网线；确认区块加载 |
| `T:` 有数值但车不动 / 一顿一顿 | 动力网络 overstressed：`getSpeed()` 被清零，牵引力整体为 0 | 接应力表看 `used/capacity`；控制台 `STRESS GUARD:` 表示保护在介入；调小 `bogeyDriveMax` 或加产能 |
| `T:` 不变 | 驱动应力未变（缓存生效）或外设失联 | `BOGEY CALL FAILED` 提示；`bogey_probe.lua` 单测 |
| 加速度无力、误差大反而更软 | 配置里 `pidKpFar` 被重复定义（旧 0..15 刻度残留） | 确认只有一处 `pidKpFar = 21.3` |
| 20 Hz 下油门高频抖动 | 微分项噪声放大 | `pidKd` 从 4.3 降到 2~3 |
| B 档几乎不制动 | B 段制动强度 = `(10-sig)/15`：B9=60%，B1≈6.7% | 要更强用 EB；B 段本来就是逐级轻制动 |

### 8.3 冒进防护

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 前方红灯不动作 | 探针窗口为 0（模组默认），或信号在我们这侧没装信号方块（`aligned=false` 被忽略） | 看启动横幅的 `window` 值；`bogey_probe.lua` 查 `getProbeDistance` / `occupiedSignalAligned` |
| 对后方红灯制动 / 前方红灯漏判 | `redProbeFront` 与行驶方向相反 | 取反 `redProbeFront`；用 `bogey_probe.lua` 对比两轴 `trackDir` 与行驶方向 |
| 红灯不触发 EB / 触发太早 | `redEbDistance` 不合适 | 调 `redEbDistance`（默认 4 格） |
| 倒车被红灯挡住 | 探针轴固定，倒车时朝车尾 | 拉杆 11-15 时保护整体豁免（靠目视） |
| 信号明明是红的却不触发 | 该边界被**本组**占用（按设计不算红灯），或强制红标记不在我们这一侧 | 换到对方的进路或看 `getProbeOccupiedSignalForced` |

### 8.4 遥显终端

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| `LINK LOST` | 主机没发布：主机死机 / 无线出范围 / 全列无主机 / `displayInterval = false` | 看主机侧 `Display terminal started`；核对协议一致；确认有一台在主机位 |
| `STALE x.xs` | 快照变老（主机停顿或链路抖动） | 偶发忽略，持续按上一行查 |
| 面板有值但看不到 `R:` | 前方无红灯（正常）或探针未启用 | 见 8.3 |

### 8.5 手动驾驶台

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 打字机按了没反应 | 该键**没绑频率**；或打字机不在终端相邻/有线网络内 | 在打字机界面绑频率（不用接接收器）；终端侧应打印 `Desk: linked_typewriter on '...'` |
| 主机提示 `MANUAL: no desk packet` | 驾驶台没发包：打字机没连、开过电脑界面（会断开）、出范围、协议不一致 | 关界面；核对 `manualProtocol` 两端一致 |
| 进了手动模式但车不动 | 档位在 `N`(10)，或没按到 `K` 档 | 按 `W` 到 `K1..K4`；到 `C`(13) 保持 |
| 设定速度突然归零 | 看控制台 `SETSPD->0 by <原因>` | `EB(sig=0)` 档位到 EB；`B-notch` 落到 B 区；`handover/PID` 进档时实际速度为 0（查速度传感器）；`redLatch` 探针误报；`desk-lost` 驾驶台包超时 |
| 显示 `VIG?` 闪烁后切了牵引 | 警惕超时（`vigilancePeriod` 内没按 `Space`） | 按一次 `Space`；不用就 `vigilanceEnabled = false` |
| 重启后自动进了手动模式 | `manual.json` 生效（设计如此） | 敲一次 `Manual` 写回 `false`，或删本机 `manual.json` |
| 重启后手动模式没了 | 恢复时**没有 modem** 被忽略；或 `manual.json` 被删/损坏 | 看 `MANUAL:` 提示；文件损坏会静默回落到 `manualDefault` |

### 8.6 标定

| 提示 | 原因 | 处理 |
| --- | --- | --- |
| `top speed only X km/h` | 全牵引也爬不到 `calibMinTopSpeed` | 查常亮红石、转向架 `getSpeed`、是否有制动残留 |
| `no stable top speed within 120s` | 速度一直缓慢爬升 | 加大 `calibRunTimeout` 或缩小 `calibPlateauTime` |
| `speed rose during the brake run` | 制动没起作用（被别处覆盖 / 没转速 / 下坡） | 查常亮红石与 `brakeStrength`；标定时手柄要在 N 位 |
| `brake fit invalid` | 制动样本不足或斜率异常 | 确认制动段真的减速；加大 `calibBrakeTimeout` |
| 标定中途 `CALIB ABORTED` | 触发冒进锁存 / 过应力保护 / 拉杆离开主机位 | 分别处理：清前方红灯、放宽 `stressGuardMargin`、保持主机位 |

### 8.7 其他

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 脚本加载报错 | 文件里有中文/非 ASCII | 注释一律英文；`tools/lua_balance_check.py` + luaparse 检查 |
| `BROADCAST FAILED` | 广播失败（少见） | 多为 modem 被移除 |
| 显示器矮，看不到时钟 | 显示器高度 < 9 | 正常：时钟会挤到第 7 行 |

---

## 九、附录：外设与探针事实

以下均从模组源码核对，改脚本前可直接引用。

### 9.1 用到的外设

| 类型 | 来源 | 用途 |
| --- | --- | --- |
| `Simurail_PhysicsBogey` | Simurail | 驱动/制动/换向/转向/探针（唯一输出通道） |
| `Create_Stressometer` | Create | 过应力保护（可选） |
| `velocity_sensor` | Simulated | 实际速度（`getVelocity` / `getAdjustedVelocity`） |
| `linked_typewriter` | Simulated | 手动台按键（`key` / `key_up` 事件、`getPressedKeyCodes`） |
| 显示器 / 无线 modem | CC:T | 面板与通信 |

无线 modem **不能**访问外设；转向架/传感器/应力表必须是贴面或同一**有线**网络（贴面、有线 modem + 网线都行）。

### 9.2 转向架外设里与本项目相关的调用

```lua
setMaxStress(±128)                 -- 驱动应力（= 动力网络消耗，符号 = 方向）
setStressMultiplierOverride(1)     -- 启动时锁定倍率，保证应力 = |maxStress|
setBrakeStrengthOverride(0..1)     -- 制动强度
setSteerValueOverride(-1..1)       -- 岔口选边：负 = 左，正 = 右，0 = 尽量取直
disableSteerValueOverride()        -- 交还给红石/遥控（过岔后必须调用）
getProbeOccupiedSignalDistance(front)  -- 冒进防护数据源
setProbeDistance(blocks)           -- 启动时把 redProbeWindow 写入转向架
```

### 9.3 转向架探针（冒进防护数据源）

| 事实 | 说明 |
| --- | --- |
| 扫描长度 | `getProbeDistance()` 是配置项，**默认 0 = 不扫描**；脚本启动时写入 `redProbeWindow` |
| 刷新频率 | 服务端每 `bogeyProbeInterval` tick 扫一次（默认 5 tick = 0.25 s）；CC 读的是缓存 |
| 距离单位 | 沿轨道的**弧长（格）**；`-1` = 窗口内无目标 |
| 轴 | `getProbe*(true)` = 前端轴，`false` = 后端轴；每根轴朝**自己那一端**看，与换向无关 |
| 只报最近一个 | 窗口内**第一个**符合条件的边界才被记录 |
| 朝向过滤 | `getProbeOccupiedSignalAligned()` 为 `false` 时脚本忽略（不是给我们看的信号），也因此看不到它后面的信号 |
| 红灯判定 | 只有当信号被**强制红**或闭塞分区被**别的重联组**占用时才有值（本组占用不算） |
| 站台 | `getProbeStationDistance/Name/Id/Pos`，`-1`/`nil` 表示无 |
| 已知瑕疵 | 模组 `reset()` 不清 `stationId`，可能出现距离 −1 但 `stationId` 残留；用前先判 `stationDistance >= 0` |

诊断脚本：`lua bogey_probe.lua`，打印两个轴的完整探针快照与轨道方向向量。

### 9.4 校验工具

```bash
# 1) 纯 ASCII + Lua 5.1 语法（luaparse 装在游戏外的工作区）
node <luacheck.js> locos/startup.lua locos/config_locomodel.lua

# 2) 块配平（仓库自带）
python tools/lua_balance_check.py locos/startup.lua

# 3) mock 回归测试（lupa 提供嵌入式 Lua 5.1，无需进游戏）
python -m pip install --only-binary :all: lupa
python tools/sim_display_test.py
```
