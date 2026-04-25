# Claude Code API Key Auto-Switcher

Claude Code API Key 自动切换与监控工具（PowerShell）。支持查询额度、按余量排名、后台监控、额度不足时自动切换。

---

## 功能概述

- **额度查询**：单 key / 所有 key 的详细使用情况（状态、每日消费、总消费、Weekly Opus Cost、Token 统计、模型消费明细）
- **排名面板**：按剩余每日额度排序展示所有 key，标注当前 key 和最佳 key
- **消费概览**：Dashboard 模式按配置顺序展示所有 key 每日消费
- **自动切换**：当前 key 余量不足阈值时，切换到余量最多的 key
- **持续监控**：定时检测，支持前台 / 后台模式
- **GUI 选择**：后台模式下触发切换时弹出深色主题 GUI 窗口供选择（含进度条和颜色标识）
- **系统通知**：Windows Toast 提醒，用户不在终端也能感知
- **多 Key 兼容**：同时支持 `ANTHROPIC_AUTH_TOKEN` 和 `ANTHROPIC_API_KEY` 环境变量

---

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 / 11 |
| PowerShell | 5.1 及以上（已预装） |
| 执行策略 | `RemoteSigned` 或 `Bypass` |
| 网络 | 可访问 `https://osr.cc.sususu.cf`（TLS 1.2/1.3） |

如首次运行被策略拦截，在 PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## 配置文件 `api-keys.json`

脚本启动时会从**同目录**的 `api-keys.json` 读取 key 列表。文件不存在或格式错误时会直接报错退出。

### 字段说明

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `Name` | string | key 名称（显示和 `-Name` 查询时使用，必须唯一） |
| `Key` | string | 完整的 API Key（以 `sk-` 开头） |
| `Dept` | string | 所属部门（面板展示用） |
| `Admin` | string | 管理员姓名（面板展示用） |

### DEMO 示例

```json
[
  {
    "Name": "osr-demo_1",
    "Key":  "sk-0000000000000000000000000000000000000000000000000000000000000001",
    "Dept": "IP",
    "Admin": "张三"
  },
  {
    "Name": "osr-demo_2",
    "Key":  "sk-0000000000000000000000000000000000000000000000000000000000000002",
    "Dept": "SW",
    "Admin": "李四、王五"
  },
  {
    "Name": "osr-demo_3",
    "Key":  "sk-0000000000000000000000000000000000000000000000000000000000000003",
    "Dept": "QA",
    "Admin": "验证"
  }
]
```

> 配置多个 key 时，脚本会**并行查询**（最多 15 线程），刷新面板非常快。

### 安全建议

- `api-keys.json` 已加入 `.gitignore`，**不要提交到远程仓库**
- 不要将密钥贴到聊天群、截图、公网 Gist
- 如果密钥泄露，联系管理员立即禁用并重新下发

---

## 使用方式

### 查询类命令

| 命令 | 作用 |
| --- | --- |
| `.\auto-switch-key.ps1 -Current` | 查看当前 key 详细信息（名称、额度、Weekly Opus Cost、模型消费明细） |
| `.\auto-switch-key.ps1 -Name osr-demo_1` | 查询指定 key 详细信息 |
| `.\auto-switch-key.ps1 -Name -ALL` | 一次性查看所有 key 的完整详情（并行查询，含 Weekly Opus Cost 和模型明细） |
| `.\auto-switch-key.ps1 -Status` | 所有 key 按剩余额度**排名** |
| `.\auto-switch-key.ps1 -Dashboard` | 所有 key 按**配置顺序**的每日消费概览 |
| `.\auto-switch-key.ps1 -Help` | 显示完整帮助 |

### 切换类命令

| 命令 | 作用 |
| --- | --- |
| `.\auto-switch-key.ps1` | 一次性检测并切换（默认阈值 $5） |
| `.\auto-switch-key.ps1 -Threshold 10` | 余量低于 $10 时自动切换 |
| `.\auto-switch-key.ps1 -DryRun` | 模拟运行，只显示"会切换到谁"，不改环境变量 |
| `.\auto-switch-key.ps1 -DryRun -Threshold 999` | 强制触发切换逻辑，查看当前最优 key |

### 监控类命令

| 命令 | 作用 |
| --- | --- |
| `.\auto-switch-key.ps1 -Monitor` | 前台持续监控（默认 300 秒间隔，`Ctrl+C` 停止） |
| `.\auto-switch-key.ps1 -Monitor -Interval 60` | 自定义监控间隔（60 秒） |
| `.\auto-switch-key.ps1 -Monitor -Threshold 10` | 余量低于 $10 时自动弹窗切换 |
| `.\auto-switch-key.ps1 -Background` | **后台监控**（隐藏窗口，关终端不影响） |
| `.\auto-switch-key.ps1 -Background -Interval 60 -Threshold 10` | 后台组合参数 |
| `.\auto-switch-key.ps1 -Stop` | 停止后台监控进程 |

> `-Interval` 必须配合 `-Monitor` 使用，不能单独出现。

---

## 参数速查

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `-Current` | switch | — | 查看当前 key |
| `-Name` | string | — | 指定 key 名称；传 `-ALL` 查看全部 |
| `-Status` | switch | — | 按余量排名 |
| `-Dashboard` | switch | — | 按配置顺序展示 |
| `-Threshold` | double | `5.0` | 自动切换的余量阈值（美元） |
| `-Monitor` | switch | — | 前台持续监控 |
| `-Interval` | int | `300` | 监控间隔（秒） |
| `-Background` | switch | — | 后台监控（隐藏窗口） |
| `-Stop` | switch | — | 停止后台监控 |
| `-DryRun` | switch | — | 模拟运行，不实际切换 |
| `-Help` | switch | — | 显示帮助 |

---

## 工作原理

1. 读取 `api-keys.json` 的 key 列表
2. 并行调用 `https://osr.cc.sususu.cf` 接口获取每个 key 的当日已用额度和限额
3. 识别当前环境变量对应的 key（优先 `ANTHROPIC_AUTH_TOKEN`，回退 `ANTHROPIC_API_KEY`；先查进程级，再查 User 级）
4. 若当前 key 剩余 `<=` 阈值 **或** 未设置 **或** 已失效，进入切换流程
5. 前台模式下终端选择（回车=自动），后台模式下弹出 GUI 窗口选择
6. 切换时设置 `User` 级环境变量 `ANTHROPIC_AUTH_TOKEN`（同时持久化 `ANTHROPIC_BASE_URL`）
7. 提示用户重启 Claude Code 使新 Key 生效

---

## 切换后如何让 Claude Code 生效

环境变量是在新进程启动时读取的，因此**必须重启** Claude Code：

- **VS Code**：关闭并重新打开窗口，在 Claude Code 面板输入 `/resume`
- **CLI**：打开新终端，`cd` 到项目目录，运行 `claude --resume`

---

## 常见场景示例

### 场景 1：每天早上检查一下哪个 key 余量最多

```powershell
.\auto-switch-key.ps1 -Status
```

### 场景 2：不想手动盯着，额度快用完自动切换

```powershell
.\auto-switch-key.ps1 -Background -Interval 120 -Threshold 10
```

窗口隐藏后台运行，每 120 秒检测一次，余量低于 $10 时弹窗提醒。

### 场景 3：验证自动切换逻辑是否正确（不真切）

```powershell
.\auto-switch-key.ps1 -DryRun -Threshold 999
```

强制触发切换流程，打印会切到哪个 key，但不改环境变量。

### 场景 4：部门审计，一次性导出所有 key 的详细消费

```powershell
.\auto-switch-key.ps1 -Name -ALL
```

---

## 文件说明

| 文件 | 作用 | 是否进 git |
| --- | --- | --- |
| `auto-switch-key.ps1` | 主脚本 | ✅ |
| `api-keys.json` | 密钥配置（敏感） | ❌（已在 `.gitignore`） |
| `switch-key.log` | 切换日志 | ❌（已在 `.gitignore`） |
| `monitor.pid` | 后台监控进程 PID | ❌（运行时生成） |

---

## 注意事项

- 所有 key 每日限额 **$100**（含 p4 和 v2 系列）
- 每日限额在 **UTC 00:00** 重置
- 后台监控启动后可关闭终端，进程独立运行
- `-Stop` 通过读取 `monitor.pid` 终止后台进程；若 PID 文件残留但进程已不存在，`-Stop` 会清理 PID 文件

---

## 详情查询输出说明

`-Current` / `-Name` / `-Name -ALL` 查询的详情包含以下板块：

| 板块 | 内容 |
| --- | --- |
| Status | Key 名称、部门、管理员、激活状态、创建/过期时间、并发数 |
| Daily Cost Limit | 当日已用 / 每日限额 + 进度条 |
| Total Cost | 累计总消费 |
| Weekly Opus Cost | 本周 Opus 模型消费 / 周限额（仅在有限额时显示） |
| Token Usage | 全时段 Requests / Input / Output / Cache Write / Cache Read / Total |
| Today's Model Breakdown | 按模型拆分的当日消费明细（请求数、Token、费用） |
