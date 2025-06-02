#!/bin/bash

set -e

# frpc路径配置
FRP_DIR="/home/user/Downloads/frp_0.62.1_linux_amd64"
FRPC_BIN="$FRP_DIR/frpc"
FRPC_CONF="$FRP_DIR/frpc.toml"

# === 检查是否为root ===
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 身份运行此脚本。"
  exit 1
fi

# === 自动安装必要组件 ===
apt update -y && apt install -y curl wget unzip jq uuid-runtime nodejs npm

# === 安装并配置 frpc （未按转时启用）===
#FRP_VER="0.62.1"
#FRP_DIR="/opt/frpc"
#mkdir -p "$FRP_DIR"
#cd "$FRP_DIR"

#wget -qO frp.tar.gz https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_linux_amd64.tar.gz
#tar -xzf frp.tar.gz --strip-components=1
#rm -f frp.tar.gz

#cat > "$FRP_DIR/frpc.toml" <<EOF
#[common]
#server_addr = YOUR_SERVER_IP
#server_port = 7000
#tls_enable = true

#[ssh]
#type = tcp
#local_ip = 127.0.0.1
#local_port = 22
#remote_port = 6000
#EOF

# === 创建frpc服务 ===
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now frpc

# === 安装并配置 Hysteria2 ===
HYSTERIA_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
HY2_DIR="/opt/hysteria"
mkdir -p "$HY2_DIR"
cd "$HY2_DIR"

wget -qO hy2.tar.gz https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VER}/hysteria-linux-amd64.tar.gz
tar -xzf hy2.tar.gz
rm -f hy2.tar.gz
chmod +x hysteria

# === 生成自签证书 ===
mkdir -p "$HY2_DIR/certs"
openssl req -new -x509 -days 3650 -nodes -out "$HY2_DIR/certs/cert.crt" -keyout "$HY2_DIR/certs/cert.key" -subj "/CN=$(hostname -I | awk '{print $1}')"

# === UUID password ===
UUID=$(uuidgen)

# === 获取ip ===
get_ip() {
  dig @resolver1.opendns.com myip.opendns.com +short
}
HOST_IP=$(get_ip)

# === 创建udp端口 ===
POST=$(shuf -i 20000-40000 -n 1)

cat > "$HY2_DIR/config.yaml" <<EOF
listen: $HOST_IP:$POST
auth:
  type: password
  password: "$UUID"
tls:
  cert: $HY2_DIR/certs/cert.crt
  key: $HY2_DIR/certs/cert.key

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

cat > /etc/systemd/system/hysteria2.service <<EOF
[Unit]
Description=Hysteria2
After=network.target

[Service]
ExecStart=$HY2_DIR/hysteria client -c $HY2_DIR/config.yaml
Restart=always
RestartSec=3
User=root
StandardOutput=append:/var/log/hysteria.log
StandardError=append:/var/log/hysteria_error.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now hysteria2

# === 部署保活 NodeJS 服务 ===
KEEPALIVE_DIR="/opt/keepalive"
mkdir -p "$KEEPALIVE_DIR"
cd "$KEEPALIVE_DIR"

npm init -y
npm install axios dotenv --save

cat > "$KEEPALIVE_DIR/.env" <<EOF
PING_URL=https://your.internal/api/ping
EOF

cat > "$KEEPALIVE_DIR/index.js" <<'EOF'
require('dotenv').config();
const axios = require('axios');

async function ping() {
  try {
    await axios.get(process.env.PING_URL);
    console.log("Ping success:", new Date().toISOString());
  } catch (e) {
    console.error("Ping failed:", new Date().toISOString(), e.message);
  }
}

setInterval(ping, 30000);
ping();
EOF

cat > /etc/systemd/system/keepalive.service <<EOF
[Unit]
Description=KeepAlive Ping Service
After=network.target

[Service]
WorkingDirectory=$KEEPALIVE_DIR
ExecStart=/usr/bin/node index.js
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now keepalive

cat > ${HY2_DIR}/hy2.info <<EOF
hysteria2://$UUID@$HOST_IP:$PORT/?sni=www.bing.com&alpn=h3&insecure=1#ufodie
EOF

# === 展示重要信息 ===
echo "======================"
echo "FRPC 配置完成。请确保服务端已正确设置。"
echo "Hysteria2 已运行”
echo "保活服务已启动。可在 .env 设置目标接口 URL"
echo "日志见 /var/log/{frpc,hysteria}.log"
echo "======================"
