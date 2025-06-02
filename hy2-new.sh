#!/bin/bash
set -euo pipefail

# 1. 必要的常量
FRP_DIR="/home/user/Downloads/frp_0.62.1_linux_amd64"
FRPC_BIN="$FRP_DIR/frpc"
FRPC_CONF="$FRP_DIR/frpc.toml"

HYSTERIA_DIR="/opt/hysteria"
NEZHA_DIR="/opt/nezha"
UUID_FILE="/etc/nezhaclient/uuid.txt"
KEEPALIVE_DIR="/opt/keepalive"

# 2. 检查 root
if [[ $(id -u) -ne 0 ]]; then
  echo "请以 root 身份运行此脚本。"
  exit 1
fi

# ========= 安装依赖（只在缺少时） ==========
install_deps() {
  echo "[+] 安装基础工具包..."
  apt update -y
  apt install -y curl wget unzip uuid-runtime jq openssl dnsutils

  if ! command -v node &>/dev/null; then
    echo "[+] 安装 Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt install -y nodejs
  else
    echo "[*] 已检测到 node：$(node -v)"
  fi

  if ! command -v npm &>/dev/null; then
    echo "[+] 安装 npm..."
    apt install -y npm
  else
    echo "[*] 已检测到 npm：$(npm -v)"
  fi
}

install_deps

# 4. 生成或读取 UUID
mkdir -p "$(dirname $UUID_FILE)"
if [[ ! -f "$UUID_FILE" ]]; then
  uuidgen > "$UUID_FILE"
fi
UUID=$(<"$UUID_FILE")

# 5. 配置并启用 frpc.service
cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=FRP Client
After=network.target

[Service]
ExecStart=$FRPC_BIN -c $FRPC_CONF
Restart=always
RestartSec=3
User=root
StandardOutput=append:/var/log/frpc.log
StandardError=append:/var/log/frpc_error.log
WorkingDirectory=$FRP_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now frpc

# 6. 安装并配置 Hysteria2
mkdir -p "$HYSTERIA_DIR"
cd "$HYSTERIA_DIR"
HYSTERIA_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
wget -qO hy2.tar.gz https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VER}/hysteria-linux-amd64.tar.gz
tar -xzf hy2.tar.gz
mv hysteria-linux-amd64 hysteria
chmod +x hysteria
rm -f hy2.tar.gz

# 7. 生成自签证书
mkdir -p "$HYSTERIA_DIR/certs"
LOCAL_IP=$(dig @resolver1.opendns.com myip.opendns.com +short || echo "127.0.0.1")
openssl req -new -x509 -days 3650 -nodes \
  -out "$HYSTERIA_DIR/certs/cert.crt" \
  -keyout "$HYSTERIA_DIR/certs/cert.key" \
  -subj "/CN=$LOCAL_IP"

# 8. 随机 UDP 端口
PORT=$(shuf -i 20000-40000 -n 1)

# 9. 写入 hysteria config
cat > "$HYSTERIA_DIR/config.yaml" <<EOF
listen: $LOCAL_IP:$PORT
auth:
  type: password
  password: "$UUID"
tls:
  cert: $HYSTERIA_DIR/certs/cert.crt
  key: $HYSTERIA_DIR/certs/cert.key
fastOpen: true
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
transport:
  udp:
    hopInterval: 30s
EOF

# 10. 启用 hysteria2.service
cat > /etc/systemd/system/hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Client
After=network.target

[Service]
ExecStart=$HYSTERIA_DIR/hysteria client -c $HYSTERIA_DIR/config.yaml
Restart=always
RestartSec=3
User=root
WorkingDirectory=$HYSTERIA_DIR
StandardOutput=append:/var/log/hysteria.log
StandardError=append:/var/log/hysteria_error.log
EOF

systemctl daemon-reload
systemctl enable --now hysteria2

# 11. 提示用户输入 Nezha 安装命令
mkdir -p "$NEZHA_DIR"
cd "$NEZHA_DIR"
read -rp "请输入包含 env NZ_SERVER=... NZ_TLS=... NZ_CLIENT_SECRET=... 的安装命令： " INSTALL_CMD

NZ_SERVER=$(echo "$INSTALL_CMD" | grep -oP 'NZ_SERVER=\K[^ ]+')
NZ_TLS=$(echo "$INSTALL_CMD" | grep -oP 'NZ_TLS=\K[^ ]+')
NZ_CLIENT_SECRET=$(echo "$INSTALL_CMD" | grep -oP 'NZ_CLIENT_SECRET=\K[^ ]+')

if [[ -z "$NZ_SERVER" || -z "$NZ_TLS" || -z "$NZ_CLIENT_SECRET" ]]; then
  echo "❌ 未能解析到 NZ_SERVER、NZ_TLS 或 NZ_CLIENT_SECRET，请检查输入。"
  exit 1
fi

# 把server补全端口
if [[ "$NZ_SERVER" != *:* ]]; then
  NZ_SERVER="${NZ_SERVER}:443"
fi
# 布尔转换
TLS_VALUE="false"
[[ "$NZ_TLS" =~ ^(true|1)$ ]] && TLS_VALUE="true"

# 写入 agent.yaml
cat > "$NEZHA_DIR/agent.yaml" <<EOF
client_secret: $NZ_CLIENT_SECRET
debug: false
disable_auto_update: false
disable_command_execute: false
disable_force_update: false
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 1
server: $NZ_SERVER
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: $TLS_VALUE
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $UUID
EOF

echo "✅ Nezha 配置已写入：$NEZHA_DIR/agent.yaml"

# 12. 准备 Node 保活脚本
mkdir -p "$KEEPALIVE_DIR"
cd "$KEEPALIVE_DIR"

npm init -y >/dev/null
npm install axios dotenv >/dev/null

# 写入 .env（如果不需要 ping 外部，可留空或写默认值）
cat > .env <<EOF
# 例：如果你想给 Nezha 或 Hysteria2 保活接口，可在此配置
# PING_URL=http://keep.example.com/api/ping
EOF

# 写入 index.js
cat > index.js <<'EOF'
require('dotenv').config();
const { spawn, execSync } = require('child_process');

const HYSTERIA_PATH = '/opt/hysteria/hysteria';
const HYSTERIA_CONF = '/opt/hysteria/config.yaml';

const NEZHA_PATH = '/opt/nezha/nezha-agent';       // 确认二进制名
const NEZHA_CONF = '/opt/nezha/agent.yaml';

let restartCount = 0;
let lastRestartTs = Date.now();

function isProcessAlive(procName) {
  try {
    execSync(`pgrep -x "${procName}"`);
    return true;
  } catch {
    return false;
  }
}

function spawnHysteria() {
  spawn(HYSTERIA_PATH, ['client', '-c', HYSTERIA_CONF], {
    detached: true, stdio: 'ignore'
  }).unref();
}

function spawnNezha() {
  spawn(NEZHA_PATH, ['-c', NEZHA_CONF], {
    detached: true, stdio: 'ignore'
  }).unref();
}

function checkAndRestart() {
  const now = Date.now();
  if (now - lastRestartTs > 60000) {
    restartCount = 0;
  }
  lastRestartTs = now;

  if (!isProcessAlive('hysteria')) {
    if (restartCount < 5) {
      restartCount++;
      spawnHysteria();
    } else {
      setTimeout(() => {
        restartCount = 0;
        checkAndRestart();
      }, 30000);
      return;
    }
  }

  if (!isProcessAlive('nezha-agent')) {
    spawnNezha();
  }
}

process.on('uncaughtException', err => {
  console.error('Uncaught Exception:', err);
});

checkAndRestart();
setInterval(checkAndRestart, 30000);
EOF

chmod +x index.js

# 13. 启用 keepalive.service
cat > /etc/systemd/system/keepalive.service <<EOF
[Unit]
Description=Hysteria2 & Nezha Agent 保活服务
After=network.target

[Service]
WorkingDirectory=$KEEPALIVE_DIR
ExecStart=/usr/bin/node $KEEPALIVE_DIR/index.js
Restart=always
RestartSec=5
User=root
StandardOutput=append:/var/log/keepalive.log
StandardError=append:/var/log/keepalive_error.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now keepalive

# 14. 清理临时（如果有 temp_downloads，可按需删除）
# rm -rf /opt/myclient/temp_downloads

# 15. 显示关键信息
echo "======================"
echo "FRPC 已启动，请确认服务端配置正确。"
echo "Hysteria2 已运行，端口: $PORT，密码 UUID: $UUID"
echo "Nezha Agent 配置在：$NEZHA_DIR/agent.yaml"
echo "保活服务已启动，日志：/var/log/keepalive.log"
echo "======================"
