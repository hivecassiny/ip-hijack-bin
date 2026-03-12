# IP Hijack Agent — 预编译发行版

路由器级 IP 流量劫持 Agent。部署在路由器上，通过加密通道连接管理服务器，实时上报所有外部网络连接，接收并执行 IP 劫持（DNAT 转发）指令。

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

**Agent** 部署在路由器（Linux）上，负责：
- 通过 `conntrack` 实时采集所有网络连接
- 执行 `iptables` DNAT 规则（IP 劫持 / 解除）
- 通过加密通道上报数据到 Server
- 断线自动重连，永不停止

---

## 特性

| 特性 | 说明 |
|------|------|
| **端到端加密** | 使用 [umbra](https://github.com/hivecassiny/umbra) 加密（ECDH + ChaCha20-Poly1305） |
| **前向保密** | 每次连接使用临时密钥，历史通信无法被回溯解密 |
| **Zstd 压缩** | 默认开启，节省带宽（适合低带宽路由器环境） |
| **断线自动重连** | 指数退避（3s → 60s），心跳检测，永不停止重试 |
| **多平台支持** | amd64 / arm64 / arm / mips / mipsle |
| **规则持久化** | 重连后 Server 自动下发之前的劫持规则 |
| **一键安装** | 交互式脚本，自动检测架构、下载、配置 systemd |

---

## 预编译二进制

| 平台 | 文件 | 适用设备 |
|------|------|---------|
| linux/amd64 | `agent-linux-amd64` | x86 软路由、服务器 |
| linux/arm64 | `agent-linux-arm64` | 树莓派 4/5、ARM 路由器 |
| linux/arm | `agent-linux-arm` | 树莓派 2/3、旧 ARM 设备 |
| linux/mips | `agent-linux-mips` | OpenWrt 路由器（大端 MIPS） |
| linux/mipsle | `agent-linux-mipsle` | OpenWrt 路由器（小端 MIPS） |
| darwin/amd64 | `agent-darwin-amd64` | macOS Intel（仅调试用） |
| darwin/arm64 | `agent-darwin-arm64` | macOS Apple Silicon（仅调试用） |

---

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/hivecassiny/ip-hijack-bin/main/install.sh | sudo bash
```

显示交互式菜单：

```
  ╔══════════════════════════════════════════╗
  ║        IP Hijack Agent Installer         ║
  ║                  v1.0.0                   ║
  ╚══════════════════════════════════════════╝

  [✓] Detected platform: linux-amd64

  Select an option:

    1)  Install Agent
    2)  Update Agent
    3)  Uninstall Agent
    4)  Show Status
    0)  Exit
```

### 安装流程（选择 1）

脚本会交互式询问：

1. **Server address** — 管理服务器地址和端口（如 `1.2.3.4:9000`）
2. **Username** — 登录用户名（默认 `admin`）
3. **Compression** — 是否开启压缩（默认 `Y`）

安装完成后自动创建 systemd 服务并启动。

### 直接命令（跳过菜单）

```bash
# 安装
sudo ./install.sh install

# 更新
sudo ./install.sh update

# 卸载
sudo ./install.sh uninstall

# 查看状态
./install.sh status
```

---

## 手动安装

### 1. 下载二进制文件

```bash
# 以 linux/amd64 为例，其他架构替换文件名即可
wget https://raw.githubusercontent.com/hivecassiny/ip-hijack-bin/main/bin/agent-linux-amd64
chmod +x agent-linux-amd64
sudo mv agent-linux-amd64 /usr/local/bin/ip-hijack-agent
```

### 2. 运行

```bash
# 前台运行（测试用）
ip-hijack-agent -server 1.2.3.4:9000 -user admin

# 可选参数
ip-hijack-agent \
  -server 1.2.3.4:9000 \
  -user admin \
  -uuid "custom-uuid" \
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
sudo systemctl status ip-hijack-agent      # 查看状态
sudo journalctl -u ip-hijack-agent -f      # 实时日志
sudo systemctl restart ip-hijack-agent     # 重启
sudo systemctl stop ip-hijack-agent        # 停止
```

---

## 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-server` | `127.0.0.1:9000` | 管理服务器地址 |
| `-user` | `admin` | 认证用户名 |
| `-uuid` | 自动生成 | 设备 UUID（首次自动生成并持久化到 `/var/lib/ip-hijack/uuid`） |
| `-compress` | `true` | 启用 Zstd 压缩 |

---

## 工作原理

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
  │   ├─ hijack   → iptables -t nat -A PREROUTING -d <原IP> -j DNAT --to <新IP>
  │   └─ unhijack → 删除对应 DNAT 规则
  │
  └─ 断线自动重连（指数退避 3s → 60s，永不停止）
```

### 安全特性

- **ECDH P-256 + ChaCha20-Poly1305** — 所有通信加密
- **前向保密（PFS）** — 每次连接临时密钥
- **UUID 持久化** — 重启后身份不变，不丢失 Server 端分配关系

---

## 路由器环境要求

| 依赖 | 说明 | 检查命令 |
|------|------|---------|
| `conntrack` | 连接追踪（推荐） | `conntrack -L` |
| `iptables` | 流量劫持（必须） | `iptables -V` |
| `ip_forward` | IP 转发（必须） | `cat /proc/sys/net/ipv4/ip_forward` |

```bash
# 开启 IP 转发
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p

# 安装 conntrack
apt install conntrack        # Debian/Ubuntu
opkg install conntrack       # OpenWrt
```

---

## 常见问题

### Agent 连不上 Server？

1. Server 是否在运行？
2. 防火墙是否放行了 9000 端口？
3. 查看 Agent 日志：`journalctl -u ip-hijack-agent -f`
4. Agent 会无限重试，Server 上线后自动恢复

### 路由器没有 systemd？

直接运行或用 `nohup` 后台运行：

```bash
nohup ip-hijack-agent -server 1.2.3.4:9000 &
```

OpenWrt procd：

```bash
cat > /etc/init.d/ip-hijack-agent <<'EOF'
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
EOF
chmod +x /etc/init.d/ip-hijack-agent
/etc/init.d/ip-hijack-agent enable
/etc/init.d/ip-hijack-agent start
```

### 如何确认路由器架构？

```bash
uname -m
# x86_64   → amd64
# aarch64  → arm64
# armv7l   → arm
# mips     → mips
# mipsel   → mipsle
```

---

## 许可

[MIT License](https://github.com/hivecassiny/ip-hijack/blob/main/LICENSE)
