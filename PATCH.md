# Codex 兼容性补丁说明

本仓库基于上游 **[jyao0708/qoder2api](https://github.com/jyao0708/qoder2api)** 的 `0b17d78`
（`feat: qoder2api - Qoder 协议桥`）修改，新增以下 **2 处功能性补丁**（另含 1 处可选调试开关）。

上游原版**无法直接用于 Codex CLI**，会连续撞两个 400 错误。这就是本 fork 存在的理由。

---

## 补丁 1：`developer` role 归一化

**文件**：`internal/qoder/legacy.go` → `legacyMessages()`

**现象**（上游原版直连 Codex 时）：

```json
{
  "code": "invalid_parameter_error",
  "message": "developer is not one of ['system', 'assistant', 'user', 'tool', 'function']",
  "type": "invalid_request_error"
}
```

**原因**：Codex 用的是 **Responses API** 规范，它使用 `role: "developer"` 来承载系统提示词。
而 Qoder 上游只接受 `system / assistant / user / tool / function` 五种 role。

**改动**：

```go
role := firstNonBlank(message.Role, "user")
// Qoder 上游只接受 system/assistant/user/tool/function 五种 role；
// Codex（Responses API）使用 developer 承载系统提示，这里归一化为 system。
if role == "developer" {
    role = "system"
}
switch role {
```

---

## 补丁 2：非 function 类型的工具过滤

**文件**：`internal/bridge/util.go` → `normalizeToolDefinitions()`

**现象**：

```json
{
  "code": "invalid_parameter_error",
  "message": "'function' is a required property, expected an object - 'tools.7'",
  "type": "invalid_request_error"
}
```

**原因**：Codex 会发送若干**非 `function` 类型**的工具定义，例如：

| Codex 工具类型 | 说明 |
|---|---|
| `type: "custom"` | freeform 工具（如 `apply_patch`），入参是一段自由文本而非 JSON Schema |
| `type: "local_shell"` | 内置 shell 工具 |
| `type: "web_search"` | 内置联网搜索 |

上游网关只认 `{type:"function", function:{name, description, parameters}}` 这一种形状，
其余类型**原样透传就会触发 400**。

**改动**：

- `custom` 类型 → 包装成 `function`，用单个 `input` 字符串参数承载自由文本
- 其他非 function 类型 → **直接丢弃**
- 删掉循环末尾的 `out = append(out, item)` 兜底（原版会把非法项原样带出去）

```go
case "custom":
    // Codex 的 apply_patch 等 freeform 工具（type=custom）。
    // 上游只认 {type:"function", function:{...}}，这里用单字符串入参包装。
    if name := stringValue(item["name"]); name != "" {
        out = append(out, map[string]any{
            "type": "function",
            "function": map[string]any{
                "name":        name,
                "description": firstNonBlank(stringValue(item["description"]),
                    "Freeform tool. Pass the complete raw input as the `input` string."),
                "parameters": map[string]any{
                    "type": "object",
                    "properties": map[string]any{
                        "input": map[string]any{
                            "type":        "string",
                            "description": "Complete raw input for this tool.",
                        },
                    },
                    "required": []any{"input"},
                },
            },
        })
        continue
    }
default:
    // 上游只接受 function 类型；local_shell / web_search 等内置类型必须丢弃，
    // 否则报 "'function' is a required property, expected an object"。
    continue
}
```

> **副作用说明**：`local_shell` / `web_search` 被丢弃后，Codex 只能使用 `function` 类的工具。
> 实测 shell 执行、文件读写、多轮 tool loop 均正常工作。

---

## 补丁 3（可选，不影响功能）：调试日志开关

**文件**：`internal/qoder/legacy.go`

设置 `QODER_DEBUG=1` 启动网关后，会打印：

- 发往上游的完整请求头
- 请求体（前 400 / 700 字符）
- 上游响应状态与头
- 上游 SSE 原始数据行（前 2500 字符）

并且会把**完整请求体** dump 到 `%TEMP%\qoder2api-last-request.json`，排查格式问题非常有用。

```go
var legacyDebug = strings.TrimSpace(os.Getenv("QODER_DEBUG")) != ""
```

> ⚠️ 调试模式会把完整请求体（含你的对话内容）写入临时文件。
> **排查完请关掉 `QODER_DEBUG` 并删除该文件。**

---

## 对应的 Codex 侧配置

补丁只解决"上游能接受 Codex 的请求"。除此之外还需要两个 Codex 侧的设置，
这两个由 `setup.ps1` / `setup.sh` 自动完成，原理见下。

### 1. 模型 key 必须是 `qfmodel`

Qoder 内部对 Qwen3.8-Flash 的 key 是 **`qfmodel`**，不是对外的 `qwen3.8-flash`。

用错 key 时的现象**极具迷惑性**：HTTP 状态码是 **200**，但 SSE 数据里包着一个 403：

```json
{
  "code": "112",
  "message": "{\"pricingUrl\":\"https://qoder.com/pricing?client=qoder\"}",
  "statusCodeValue": 403,
  "statusCode": "FORBIDDEN"
}
```

看起来像"账号没权限"，实际是**模型名不认识**。
所以 profile 里写的是 `model = "qfmodel"`。

### 2. 两个必需的环境变量

| 变量 | 不设的后果 | 原理 |
|---|---|---|
| `QODER_LOCAL_KEY` | Codex **静默不发请求**，`tokens used 0` | provider 定义了 `env_key`，Codex 在启动预热阶段就检查，缺失则放弃。值本身任意（本地网关不校验） |
| `NO_PROXY` | 同上 | 机器上若有 `HTTP_PROXY`，Codex 会把 `127.0.0.1:8963` 也当外网走代理，请求直接丢失 |

**这两个坑的症状一模一样**（都是 `tokens used 0`、网关收不到请求），排查时**两个都要查**。

---

## 验证补丁是否生效

```bash
cd qoder2api
grep -n 'role == "developer"' internal/qoder/legacy.go   # 应有输出
grep -n 'case "custom":'        internal/bridge/util.go  # 应有输出
```

两条都有输出 = 补丁已应用。

---

## 上游更新后如何同步

本补丁针对 `0b17d78`。如果上游有了新提交：

```bash
git fetch origin
git rebase origin/main      # 或 origin/master
```

若 `legacy.go` / `util.go` 冲突，参考本文档的两段代码手工合并。
补丁逻辑很简单，定位函数名（`legacyMessages` / `normalizeToolDefinitions`）即可。
