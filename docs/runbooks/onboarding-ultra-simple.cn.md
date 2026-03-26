# 超简上手指南（简体中文）- DGX Agentic Stack

适用对象：完全非技术用户。  
目标：快速理解平台做什么，并安全地完成最基本的操作。

## 1）一句话说明

这个平台运行本地 AI、Web 界面和监控工具，并默认采用更安全的方式：只监听本机地址，外部访问受控。

本快速指南默认使用当前日常开发模式：`rootless-dev`。

## 2）记住 6 个部分

1. `core` = 技术核心（AI + DNS + 代理 + OpenClaw / `gate-mcp` 等内部控制服务）。
2. `agents` = 在隔离工作区中运行的助手。
3. `ui` = 你会打开的网页界面。
4. `obs` = 监控面板（健康、日志、指标）。
5. `rag` = 文档记忆与语义检索。
6. `optional` = 只有在需要时才启用的额外模块。

## 3）主要网页地址

- OpenWebUI: `http://127.0.0.1:8080`
- OpenHands: `http://127.0.0.1:3000`
- ComfyUI: `http://127.0.0.1:8188`
- Grafana: `http://127.0.0.1:13000`

重要：这些都是本机地址。  
如果你从另一台电脑访问，需要使用 SSH / Tailscale 隧道。

## 4）最少命令

```bash
export AGENTIC_PROFILE=rootless-dev
./agent profile
./agent first-up
./agent ps
./agent doctor
```

如果你想按步骤启动：

```bash
./agent up core
./agent up agents,ui,obs,rag
```

干净停止：

```bash
./agent stack stop all
```

## 5）怎么判断运行正常

简单规则：
- `./agent ps` 应该看到服务状态为 `Up`
- `./agent doctor` 应该没有阻塞性错误

如果某个服务失败：

```bash
./agent logs <service>
```

例如：

```bash
./agent logs openwebui
```

## 6）简单安全规则

- 不要把服务暴露到 `0.0.0.0`
- 不要在应用容器里挂载 `docker.sock`
- 不要把密钥提交到 git
- 远程访问只通过 Tailscale / SSH

## 7）更新与回滚

更新：

```bash
./agent update
```

回滚：

```bash
./agent rollback all <release_id>
```

## 8）下一步阅读

- 法语详细初学者指南：`docs/runbooks/services-expliques-debutants.md`
- 英文详细初学者指南：`docs/runbooks/services-explained-beginners.en.md`
- 完整首次部署说明：`docs/runbooks/first-time-setup.md`
- 印地语版本：`docs/runbooks/onboarding-ultra-simple.hi.md`
