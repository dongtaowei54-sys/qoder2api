# Codex CLI 一键接入版

在上游 [jyao0708/qoder2api](https://github.com/jyao0708/qoder2api) 基础上增加了 **Codex CLI 兼容性补丁**与**一键安装脚本**。

## 这个版本解决了什么

上游原版直连 Codex 会连续撞两个 400 错误：

| 错误 | 原因 |
|---|---|
| `developer is not one of ['system','assistant',...]` | Codex 用 `developer` role 传系统提示，Qoder 上游只认 5 种 role |
| `'function' is a required property - 'tools.7'` | Codex 的 `custom` / `local_shell` 等工具类型上游不认 |

本版本修复了这两处并配好一键脚本，详见 [PATCH.md](./PATCH.md)。

## 下载

| 系统 | 架构 | 文件 |
|---|---|---|
| Windows | x64 | `qoder2api-windows-amd64.zip` |
| Windows | ARM64 | `qoder2api-windows-arm64.zip` |
| macOS | Apple 芯片 | `qoder2api-darwin-arm64.zip` |
| macOS | Intel | `qoder2api-darwin-amd64.zip` |
| Linux | x64 | `qoder2api-linux-amd64.zip` |
| Linux | ARM64 | `qoder2api-linux-arm64.zip` |

**不需要装 Go**，包内是编译好的可执行文件。校验和见 `SHA256SUMS.txt`。

## 三步用起来

**Windows**

```powershell
# 1. 解压后在目录内执行，自动配置 Codex
powershell -ExecutionPolicy Bypass -File .\setup.ps1

# 2. 开新窗口：授权（只做一次，会开浏览器），然后起网关（窗口别关）
.\qoder2api-login.exe
.\qoder2api.exe

# 3. 再开一个窗口
codex --profile qoder
```

**macOS / Linux**

```bash
chmod +x qoder2api qoder2api-login setup.sh
bash setup.sh

./qoder2api-login      # 授权，只做一次
./qoder2api            # 网关，窗口别关

codex --profile qoder  # 另开终端
```

## 特性

- **不动你的默认配置** —— 原来的默认模型照常可用，敲 `codex` 就是它
- **幂等安装** —— setup 脚本可重复执行，已配好的项自动跳过
- **自动备份** —— 改配置前备份为 `config.toml.bak-qoder-<时间戳>`
- **不覆盖你已有的 `model_catalog_json`**

## 已知限制

- **仅支持 Codex CLI**。Codex 桌面端的模型选择器不识别 provider，用不了
- 与 Qoder 服务端之间是复刻客户端私有协议，**官方更新后可能失效**
- Windows 可执行文件**未签名**，首次运行可能被 SmartScreen 拦截，选「仍要运行」即可

## 免责声明

本项目**仅供学习和研究目的**使用，使用者需自行承担风险。

作者不对因使用本软件产生的任何后果负责，包括但不限于**账号封禁、数据丢失或法律纠纷**。
请勿用于任何商业用途，或以违反 Qoder 服务条款的方式使用。

## 许可证

基于上游 MIT License（Copyright (c) 2026 wangjunyao）分发，原版权声明完整保留于 [LICENSE](./LICENSE)。
本版本的修改说明见 [PATCH.md](./PATCH.md)。
