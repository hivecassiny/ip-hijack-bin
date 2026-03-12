# IP Hijack Manager — 预编译发行版

路由器级 IP 流量劫持管理系统。通过在路由器上部署 **Agent**，远程实时监控所有外部网络连接，选中目标 IP 一键劫持（DNAT 转发），所有操作均通过 **Server** 的 Web 管理面板完成。

> 源码仓库：[hivecassiny/ip-hijack](https://github.com/hivecassiny/ip-hijack)

---

## 架构概览

```
┌──────────────┐       ┌──────────────────┐       ┌──────────────┐
│   路由器 A    │       │  Management      │       │   路由器 B    │
│  (Agent)     │◄─────►│  Server          │◄─────►│  (Agent)     │
│  linux/mips  │  TCP  │  + Web UI (:8080)│  TCP  │  linux/arm64 │
└──────────────┘ 加密   │  + TCP   (:9000) │ 加密   └──────────────┘
                       └──────────────────┘
                              ▲
                              │ HTTP
                       ┌──────┴──────┐
                       │  管理员浏览器  │
                       │  Web 管理面板  │
                       └─────────────┘
```

**Agent** — 部署在路由器（Linux）上，负责：
- 通过 `conntrack` 实时采集所有网络连接
- 执行 `iptables` DNAT 规则（IP 劫持/解除）
- 通过加密通道上报数据到 Server

**Server** — 部署在有公网 IP 的服务器上，负责：
- 接收并管理多个 Agent 的连接
- 提供 Web 管理界面（查看连接、执行劫持、管理用户）
- SQLite 持久化所有数据

---

## 特性

| 特性 | 说明 |
|------|------|
| **端到端加密** | Agent 与 Server 之间使用 [umbra](https://github.com/hivecassiny/umbra) 加密（ECDH + ChaCha20-Poly1305） |
| **前向保密** | 每次连接使用临时密钥（Ephemeral Key），即使长期密钥泄露也无法解密历史通信 |
| **Zstd 压缩** | 默认开启 Zstd 压缩，节省带宽（适合低带宽路由器环境） |
| **断线自动重连** | 指数退避策略（3s → 60s），心跳检测半死连接，永不停止重试 |
| **多平台支持** | 支持 amd64 / arm64 / arm / mips / mipsle 等主流路由器架构 |
| **多用户权限** | 管理员 / 控制 / 只读三级权限，支持子账号分配 Agent |
| **离线持久化** | 劫持规则、用户数据、Agent 注册信息全部持久化，重启自动恢复 |
| **一键安装** | 交互式安装脚本，自动检测架构、下载、配置 systemd 服务 |

---

## 预编译二进制文件

### Agent

| 平台 | 文件 | 适用设备 |
|------|------|---------|
| linux/amd64 | `agent-linux-amd64` | x86 软路由、服务器 |
| linux/arm64 | `agent-linux-arm64` | 树莓派 4/5、ARM 路由器 |
| linux/arm | `agent-linux-arm` | 树莓派 2/3、旧 ARM 设备 |
| linux/mips | `agent-linux-mips` | OpenWrt (大端 MIPS) |
| linux/mipsle | `agent-linux-mipsle` | OpenWrt (小端 MIPS) |
| darwin/amd64 | `agent-darwin-amd64` | macOS Intel（调试用） |
| darwin/arm64 | `agent-darwin-arm64` | macOS Apple Silicon（调试用） |

### Server

| 平台 | 文件 |
|------|------|
| linux/amd64 | `server-linux-amd64` |
| linux/arm64 | `server-linux-arm64` |
| linux/arm | `server-linux-arm` |
| darwin/amd64 | `server-darwin-amd64` |
| darwin/arm64 | `server-darwin-arm64` |

> Server 不提供 mips/mipsle 版本（SQLite 依赖限制）

---

## 一键安装

使用交互式安装脚本，自动检测系统架构、下载二进制文件、配置 systemd 服务：

```bash
curl -fsSL https://raw.githubusercontent.com/hivecassiny/ip-hijack-bin/main/install.sh | sudo bash
```

脚本会显示如下菜单：

```
  ╔══════════════════════════════════════════╗
  ║       IP Hijack Manager Installer        ║
  ║                  v1.0.0                   ║
  ╚══════════════════════════════════════════╝

  [✓] Detected platform: linux-amd64

  Select an option:

    1)  Install Agent
    2)  Install Server
    3)  Install Both (Agent + Server)
    4)  Update installed components
    5)  Uninstall
    6)  Show Status
    0)  Exit
```

### 安装 Agent（选择 1）

脚本会交互式询问：

1. **Server address** — 管理服务器的地址和端口（如 `1.2.3.4:9000`）
2. **Username** — 登录用户名（默认 `admin`）
3. **Compression** — 是否开启压缩（默认 `Y`）

安装完成后自动创建 systemd 服务并启动。

### 安装 Server（选择 2）

脚本会交互式询问：

1. **TCP listen address** — Agent 连入端口（默认 `:9000`）
2. **HTTP listen address** — Web UI 端口（默认 `:8080`）
3. **Admin password** — 管理员密码（默认 `admin`）
4. **Database path** — 数据库文件路径（默认 `/var/lib/ip-hijack/hijack.db`）

### 直接命令（非交互式）

```bash
# 只安装 Agent
sudo ./install.sh install-agent

# 只安装 Server
sudo ./install.sh install-server

# 更新已安装组件
sudo ./install.sh update

# 卸载
sudo ./install.sh uninstall

# 查看状态
./install.sh status
```

---

## 手动安装

如果不想使用安装脚本，也可以手动操作。

### 1. 下载二进制文件

```bash
# 以 linux/amd64 为例
wget https://raw.githubusercontent.com/hivecassiny/ip-hijack-bin/main/bin/agent-linux-amd64
chmod +x agent-linux-amd64
sudo mv agent-linux-amd64 /usr/local/bin/ip-hijack-agent
```

### 2. 运行 Agent

```bash
# 前台运行（测试用）
ip-hijack-agent -server 1.2.3.4:9000 -user admin

# 可选参数
ip-hijack-agent \
  -server 1.2.3.4:9000 \
  -user admin \
  -uuid "custom-uuid-if-needed" \
  -compress=true
```

### 3. 配置 systemd 服务（推荐）

```bash
sudo tee /etc/systemd/system/ip-hijack-agent.service > /dev/null <<EOF
[Unit]
Description=IP Hijack Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ip-hijack-agent -server 1.2.3.4:9000 -user admin
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ip-hijack-agent
```

### 4. 管理服务

```bash
# 查看状态
sudo systemctl status ip-hijack-agent

# 查看实时日志
sudo journalctl -u ip-hijack-agent -f

# 重启
sudo systemctl restart ip-hijack-agent

# 停止
sudo systemctl stop ip-hijack-agent
```

---

## Agent 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-server` | `127.0.0.1:9000` | 管理服务器地址 |
| `-user` | `admin` | 认证用户名 |
| `-uuid` | 自动生成 | 设备 UUID（首次运行自动生成并持久化到 `/var/lib/ip-hijack/uuid`） |
| `-compress` | `true` | 是否启用 Zstd 压缩 |

## Server 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-tcp` | `:9000` | Agent TCP 监听地址 |
| `-http` | `:8080` | Web UI HTTP 监听地址 |
| `-db` | `hijack.db` | SQLite 数据库路径 |
| `-admin-pass` | `admin` | 管理员密码（首次运行时设置） |
| `-compress` | `true` | 是否启用 Zstd 压缩 |

---

## Agent 工作原理

```
Agent 启动
  │
  ├─ 生成/加载 UUID（持久化到 /var/lib/ip-hijack/uuid）
  │
  ├─ 通过 umbra 加密连接到 Server（ECDH 密钥交换）
  │
  ├─ 每 5 秒上报连接列表（conntrack / netstat）
  │
  ├─ 每 30 秒发送心跳（双向检测连接存活）
  │
  ├─ 接收 Server 指令：
  │   ├─ hijack  → iptables -t nat -A PREROUTING -d <原IP> -j DNAT --to <新IP>
  │   └─ unhijack → 删除对应 DNAT 规则
  │
  └─ 断线自动重连（指数退避 3s → 60s，永不停止）
```

### 安全特性

- **ECDH P-256 密钥交换 + ChaCha20-Poly1305 加密** — 所有流量均加密
- **前向保密（PFS）** — 每次连接使用临时密钥
- **UUID 持久化** — 重启后保持同一身份，不会丢失分配关系
- **规则持久化** — Agent 重连后 Server 自动下发之前的劫持规则

### 路由器环境要求

| 依赖 | 说明 | 检查命令 |
|------|------|---------|
| `conntrack` | 连接追踪（推荐） | `conntrack -L` |
| `iptables` | 流量劫持（必须） | `iptables -V` |
| `ip_forward` | IP 转发（必须） | `cat /proc/sys/net/ipv4/ip_forward` |

开启 IP 转发：

```bash
echo 1 > /proc/sys/net/ipv4/ip_forward
# 永久生效
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p
```

安装 conntrack（如果没有）：

```bash
# Debian/Ubuntu
apt install conntrack

# OpenWrt
opkg install conntrack
```

---

## 快速部署流程

### Step 1: 部署 Server

在一台有公网 IP 的服务器上（如云服务器）：

```bash
curl -fsSL https://raw.githubusercontent.com/hivecassiny/ip-hijack-bin/main/install.sh | sudo bash
# 选择 2) Install Server
# 设置管理员密码（务必修改默认值）
```

### Step 2: 部署 Agent

SSH 到路由器上：

```bash
curl -fsSL https://raw.githubusercontent.com/hivecassiny/ip-hijack-bin/main/install.sh | sudo bash
# 选择 1) Install Agent
# 输入 Server 地址（如 203.0.113.50:9000）
```

### Step 3: 登录 Web 管理面板

浏览器打开 `http://<server-ip>:8080`，使用管理员账号登录。

你将看到已连接的 Agent 列表，可以：
- 查看每个 Agent 的实时外部连接列表
- 选择目标 IP 执行劫持 → 流量转发到指定地址
- 管理子账号和权限

---

## 常见问题

### Agent 连不上 Server？

1. 检查 Server 是否在运行：`systemctl status ip-hijack-server`
2. 检查防火墙是否放行了 9000 端口：`iptables -L -n | grep 9000`
3. 检查 Agent 日志：`journalctl -u ip-hijack-agent -f`
4. Agent 会无限重试连接，等待 Server 上线后自动恢复

### 路由器没有 systemd？

直接运行二进制文件，或使用 `nohup` / `screen` / `procd`（OpenWrt）等方式后台运行：

```bash
nohup ip-hijack-agent -server 1.2.3.4:9000 &
```

OpenWrt procd init 脚本：

```bash
cat > /etc/init.d/ip-hijack-agent <<'INITEOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/local/bin/ip-hijack-agent -server 1.2.3.4:9000
    procd_set_param respawn
    procd_close_instance
}
INITEOF
chmod +x /etc/init.d/ip-hijack-agent
/etc/init.d/ip-hijack-agent enable
/etc/init.d/ip-hijack-agent start
```

### 如何确认我的路由器架构？

```bash
uname -m
# x86_64     → amd64
# aarch64    → arm64
# armv7l     → arm
# mips       → mips
# mipsel     → mipsle
```

---

## 许可

[MIT License](https://github.com/hivecassiny/ip-hijack/blob/main/LICENSE)
