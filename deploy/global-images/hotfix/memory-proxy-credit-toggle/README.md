# memory-proxy hotfix: `creditReport.enabled` 开关

## 为什么需要它

proxy 每完成一次 LLM 应答都会把用量 POST 到外部计费服务（TencentDB MemoryPlus /
TokenHub），端点由 `creditReport.url` 指定。而这个配置项的内置默认值是**占位域名**：

```
http://gateway.example.com:8000/UpdateMemoryPlusUsage
```

本地自建部署没有这个服务（已实测：memory-core:8420 / memory-hub:8424 / 8125 都没有
该路由），DNS 必然解析失败。于是每轮请求都留下一条：

```
ERROR pipeline.error {"stage":"CREDIT_REPORT","error":"[stream] spaceId=default error=fetch failed resp=null"}
10-09 00:24:56.595 [01a11e0c]   ✗ CREDIT_REPORT [stream] spaceId=default error=fetch failed resp=null
```

实测 2 小时内：CommandCode 线（8100）98 条、主线（8096）58 条。上报本身是
best-effort（失败不影响转发，`← FORWARD status=200` 照旧），所以这不是功能故障，
是纯噪音 + 每次请求一次注定失败的 DNS 查询。

上游源码里 `CreditReportConfig` **只有 `url` / `timeoutMs`，没有关闭开关**
（`src/types.ts`、`src/config.ts`，`tryReportCreditFromPath()` 也没有 disabled 短路），
所以配置层关不掉——只能补一个开关。

## 改了什么（只加开关，不动其它行为）

| 文件 | 改动 |
| --- | --- |
| `src/types.ts` | `CreditReportConfig` 新增 `enabled: boolean` |
| `src/config.ts` | `DEFAULT_CONFIG.creditReport.enabled = true`；YAML 解析读 `creditReport.enabled`（缺省 true） |
| `src/credit-reporter.ts` | `tryReportCreditFromPath()` 在 `enabled === false` 时立即 `return {attempted:false}`，**不发任何网络请求** |

默认值刻意保持 `true`：老配置行为逐位不变，关闭是**显式**的部署决策。

## 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -All
```

`-All` 会建两个 tag（两条线的这三个文件 md5 完全相同，只有 `handler.ts` 有差异）：

| tag | 基线 | 用于 |
| --- | --- | --- |
| `agentmemory/memory-proxy:0.2.0-credit-toggle-zensession` | `...:0.2.0-opencode-binding-zensession` | CommandCode 线 8100 |
| `agentmemory/memory-proxy:0.2.0-credit-toggle` | `...:0.2.0-opencode-binding` | 主线 8096 |

构建是纯 `COPY`（约 1 秒，无需 npm/tsc），随后自动跑 `verify.mjs`（9 条断言，
stub 掉 `fetch`，无 LLM 调用、无网络）。**自测不过就不构建**。

## 部署（需要重启 proxy 容器，config.yaml 只在容器启动时读）

两条线的 `config.yaml` 都是启动脚本渲染的，脚本模板已同步加上：

```yaml
creditReport:
  enabled: false
```

- CommandCode 线（8100）：`pwsh -File start-proxy-cc.ps1`（`$Image` 默认值已指向新 tag）
- 主线（8096）：`.env` 的 `PROXY_IMAGE` 已钉到 `agentmemory/memory-proxy:0.2.0-credit-toggle`，
  再跑 `./start-proxy.sh`

> ⚠️ 重启 8100 等于切断 DSH 飞书当前会话的 LLM 网关，**会打断在飞的那一轮**。
> 按 DSH 重启纪律，选一个没有问答/回执在飞的时刻再做。

`bash -n` 之类没法直接验证这两个脚本：工作区里所有 `.sh` 都是 CRLF
（`core.autocrlf=true` 的 checkout 结果，整个目录一致），逐行 shell 解析会
"unexpected end of file"。做 LF 归一化后再 `bash -n` 即可通过——本次改动已验证。

## 回滚

把镜像指回旧 tag 并重建容器即可，无需改回配置（旧镜像会忽略 `creditReport.enabled`
这个未知键，行为回到"照旧报错"、不会崩）：

- 8100：`pwsh -File start-proxy-cc.ps1 -Image agentmemory/memory-proxy:0.2.0-opencode-binding-zensession`
- 8096：`.env` 的 `PROXY_IMAGE` 改回 `agentmemory/memory-proxy:0.2.0-opencode-binding`

## 踩过的坑（下次改 proxy 镜像别再踩）

1. **`docker run` 必须带 `--entrypoint node`**。镜像 ENTRYPOINT 已经写死
   `tini -- node --import tsx/esm src/index.ts`，你传的命令会被**追加成 index.ts 的参数**：
   容器不会跑你的脚本，而是把 proxy 服务起起来监听 8096，`docker run` 永不返回
   （本次因此泄漏了 3 个容器）。
2. **stderr 会让 Windows PowerShell 判整个构建失败**。模块加载时若 cwd 没有
   `config.yaml`，proxy 源码会往 stderr 打 `[config] config.yaml not found`；
   PS 5.1 把 native stderr 变成 `NativeCommandError`，配上
   `$ErrorActionPreference='Stop'` 就在判定断言之前直接终止。
   现在 verify 挂 `config.verify.yaml` 到 `/app/config.yaml`，并在调用前后临时降级
   `ErrorActionPreference`。
3. **不要用 `COPY src /app/src` 整树覆盖**——镜像里带着仓库没有的本地改动（同
   `../memory-core-l2-throttle` 的规则：只拷本次真正改的文件，且每个文件都从镜像版本出发）。
4. 本目录 `build.ps1` 是 ASCII-only：Windows PowerShell 5.1 会按 ANSI 读无 BOM 的
   `.ps1`，非 ASCII 会直接解析失败。中文说明放这个 README。
