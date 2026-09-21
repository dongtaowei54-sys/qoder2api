# 一键把 Qoder 免费 Qwen3.8-Flash 接到 Codex

> 三分钟搞定：下载 → 跑脚本 → 授权 → 用
>
> ⚠️ 本项目仅供**学习研究**，使用风险自负。详见文末免责声明。

---

## 这是什么

一个本地小网关，把 **Qoder 客户端里的免费 Qwen3.8-Flash** 转成 OpenAI 兼容接口，
让你的 **Codex CLI** 可以直接用上它。

**它不改动你的默认模型** —— 你原来的 `gpt-5.6-sol`（或任何默认配置）一行都不动，
两套并存，用 `--profile qoder` 切过来，敲 `codex` 就用回去。

---

## 支持平台

| 系统 | 架构 | 包名 |
|---|---|---|
| Windows | x64 | `qoder2api-windows-amd64.zip` |
| Windows | ARM64 | `qoder2api-windows-arm64.zip` |
| macOS | Apple 芯片 | `qoder2api-darwin-arm64.zip` |
| macOS | Intel | `qoder2api-darwin-amd64.zip` |
| Linux | x64 | `qoder2api-linux-amd64.zip` |
| Linux | ARM64 | `qoder2api-linux-arm64.zip` |

**不需要装 Go**，包里是编译好的可执行文件。

---

## Windows 三步

**前置**：已经装好 [Codex CLI](https://github.com/openai/codex)（终端里敲 `codex` 有反应）。

### 第 1 步：解压 + 一键配置

下载 `qoder2api-windows-amd64.zip`，解压到任意目录（比如 `D:\qoder2api`），
然后在这个目录打开 PowerShell，执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

脚本会自动：备份你的 `config.toml` → 写入 provider → 注册模型目录 → 建 profile → 设环境变量。

看到 `Setup complete.` 就成了。

> 脚本**可以重复跑**，已配过的项会自动跳过，不会重复写入。

### 第 2 步：授权 + 起网关（只需一次授权）

**开一个新的** PowerShell 窗口（让环境变量生效）：

```powershell
# 授权：会打开浏览器，登录 Qoder 账号后点确认
.\qoder2api-login.exe

# 起网关：这个窗口别关，关了 Codex 就用不了
.\qoder2api.exe
```

看到 `listening on http://127.0.0.1:8963` 就对了。

### 第 3 步：用 Codex

**再开一个**窗口：

```powershell
codex --profile qoder
```

搞定。想切回默认模型，敲 `codex`（不带 profile）就是。

---

## macOS / Linux 三步

```bash
# 解压后进入目录
cd qoder2api-darwin-arm64

# 1. 加执行权限 + 一键配置
chmod +x qoder2api qoder2api-login setup.sh
bash setup.sh

# 2. 开新终端，授权 + 起网关
./qoder2api-login      # 开浏览器授权，只需一次
./qoder2api            # 这个终端别关

# 3. 再开一个终端
codex --profile qoder
```

---

## 日常使用

```bash
# 交互模式
codex --profile qoder

# 非交互（跑单个任务）
codex exec --profile qoder "把这个函数重构成 async"
```

**每次开机后**，只要把网关起起来就行（授权不用重做）。

---

## 常见问题

### 1. 输出 `tokens used 0`，一个字都没有

两个可能，**都要检查**：

| 原因 | 检查方法 |
|---|---|
| 网关没起 | 另开窗口敲 `netstat -ano \| findstr :8963`，没输出就是没起 |
| 环境变量没生效 | 确认是**新开的**终端；或手动确认 `QODER_LOCAL_KEY` 和 `NO_PROXY` 存在 |

### 2. 报 `Reconnecting... waiting for network`

多半是**系统代理**把 `127.0.0.1` 也代理了。确认 `NO_PROXY` 里有 `127.0.0.1,localhost`。

### 3. Windows 提示「已保护你的电脑」/ 杀软报警

因为 exe **没有代码签名**。选择「更多信息 → 仍要运行」即可。
介意的话可以自行从源码编译。

### 4. 提示 `Model metadata for 'qfmodel' not found`

说明 `model_catalog_json` 没配上。如果你自己已经设过这个字段，脚本不会覆盖它，
需要手动把 `qoder-models.json` 里的内容合并进去。

### 5. 报错 `bind: Only one usage of each socket address`

已经有一个网关在跑了。先清掉再起：

```powershell
taskkill /F /IM qoder2api.exe
```

### 6. 授权过期了

重跑一次 `qoder2api-login.exe` 就行。

### 7. **Codex 桌面端能用吗？**

**不能。** 桌面端的模型选择器不识别 provider，选了 `qfmodel` 也还是走默认 provider。
这条链路**只支持 Codex CLI**。

---

## 卸载 / 回滚

```powershell
# 1. 还原配置（用 setup 时生成的备份）
Copy-Item "$env:USERPROFILE\.codex\config.toml.bak-qoder-*" "$env:USERPROFILE\.codex\config.toml"
Remove-Item "$env:USERPROFILE\.codex\qoder.config.toml"

# 2. 清环境变量
[Environment]::SetEnvironmentVariable('QODER_LOCAL_KEY', $null, 'User')
[Environment]::SetEnvironmentVariable('NO_PROXY', $null, 'User')
[Environment]::SetEnvironmentVariable('no_proxy', $null, 'User')
```

---

## 原理简述

```
Codex CLI
  │  POST http://127.0.0.1:8963/v1/responses
  ▼
qoder2api（本机网关，复刻 Qoder 客户端协议）
  │  鉴权：官方 OAuth 设备码拿到的 token
  ▼
Qoder 上游 → Qwen3.8-Flash
```

- 凭据保存在本机，**不会外传**
- 与 Qoder 服务端之间是复刻客户端私有协议，**官方更新后可能失效**

---

## 免责声明

本项目**仅供学习和研究目的**使用，使用者需自行承担风险。

作者不对因使用本软件产生的任何后果负责，包括但不限于**账号封禁、数据丢失或法律纠纷**。
请勿将本项目用于任何商业用途，或以违反 Qoder 服务条款的方式使用。

**请自行确认当地法律法规与你所用服务的条款。**

---

## 致谢与许可

本项目基于 **[jyao0708/qoder2api](https://github.com/jyao0708/qoder2api)**（MIT License，Copyright (c) 2026 wangjunyao）修改，
增加了 Codex 兼容性补丁（详见 `PATCH.md`）与一键安装脚本。

遵循 MIT License 分发，原版权声明完整保留于 `LICENSE` 文件。
