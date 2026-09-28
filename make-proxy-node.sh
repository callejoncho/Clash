#!/usr/bin/env bash
# make-proxy-node.sh —— 在一台 VPS 上装一个「固定账号密码」的代理节点：
#   单端口同时提供 HTTP/HTTPS(CONNECT) 和 SOCKS5，带基础认证，systemd 常驻 + 开机自启。
#   只往 /usr/local/bin/gost、/etc/gost/config.yaml、/etc/systemd/system/gost-node.service 写东西，
#   不碰 3x-ui / x-ui / xray / docker / 其它监听端口。
#
# 用法（一条命令，跑完会打印 IP:端口:账号:密码）：
#   sudo NODE_USER=myuser NODE_PASS='myPassw0rd' bash make-proxy-node.sh
#   sudo NODE_PORT=3128 NODE_USER=... NODE_PASS=... bash make-proxy-node.sh   # 换端口
#   sudo NODE_ALLOW_IP=1.2.3.4 ... bash make-proxy-node.sh                     # 只放行该源 IP（防火墙层兜底）
#   sudo bash make-proxy-node.sh --status
#   sudo bash make-proxy-node.sh --uninstall
set -euo pipefail
trap 'echo "[node] 意外退出（第 $LINENO 行，退出码 $?）" >&2' ERR

GOST_VER="3.3.0"
PORT="${NODE_PORT:-1080}"
NODE_USER_="${NODE_USER:-}"
NODE_PASS_="${NODE_PASS:-}"
ALLOW_IP="${NODE_ALLOW_IP:-}"
UNIT="gost-node.service"
BIN="/usr/local/bin/gost"
CFG_DIR="/etc/gost"
CFG="$CFG_DIR/config.yaml"
MIRROR="${NODE_GH_MIRROR:-}"     # 可选：GitHub 加速前缀，例如 https://ghfast.top/

log()  { printf '\033[32m[node]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[node]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[node] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo ...）"

uninstall() {
  log "卸载：停服务并删除 gost 相关文件（不动 3x-ui/xray/docker）"
  systemctl disable --now "$UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$UNIT" "$BIN"
  rm -rf "$CFG_DIR"
  systemctl daemon-reload
  log "已卸载。"
}

status() {
  systemctl --no-pager --full status "$UNIT" 2>/dev/null | head -12 || warn "服务未安装"
  echo "--- 监听："; ss -lntp 2>/dev/null | grep -E ":${PORT}\b" || warn "端口 $PORT 没有监听"
  [ -f "$CFG" ] && { echo "--- 配置："; sed -n '1,40p' "$CFG"; }
}

case "${1:-}" in
  --uninstall) uninstall; exit 0 ;;
  --status)    status;    exit 0 ;;
  ""|[[:space:]]) ;;
  *) die "未知参数：$1（只支持 --status / --uninstall）" ;;
esac

[ -n "$NODE_USER_" ] && [ -n "$NODE_PASS_" ] || die "必须给 NODE_USER 和 NODE_PASS，例如：sudo NODE_USER=u NODE_PASS='p' bash $0"
case "$NODE_USER_$NODE_PASS_" in
  *'"'*|*'\'*) die "账号/密码里不要用双引号或反斜杠（会破坏 YAML），其它符号如 # ! @ 都可以" ;;
esac
case "$PORT" in (*[!0-9]*) die "NODE_PORT 必须是数字" ;; esac

# --- 端口占用检查：必须确认该端口是「本服务自己的进程」在听，才允许继续（按更新处理）
PORT_PID() { local p; p="$(ss -lntpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)" || true; printf '%s' "$p"; }
OLD_PID="$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)"
CUR_PID="$(PORT_PID)"
if [ -n "$CUR_PID" ]; then
  if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "0" ] && [ "$CUR_PID" = "$OLD_PID" ]; then
    log "端口 $PORT 当前由本服务占用 → 按更新处理"
  else
    die "端口 $PORT 已被其它进程占用，换端口（NODE_PORT=xxxx）再来：
$(ss -lntp "sport = :$PORT" 2>/dev/null | tail -n +2 | head -2)"
  fi
fi

# --- 架构 / 校验值
A="$(uname -m)"
case "$A" in
  x86_64|amd64)  ARCH=amd64; SHA=676fb7f78d267b6ae73df719c0c7f2b565dde7147da935cfafbc1e1da558b6d5 ;;
  aarch64|arm64) ARCH=arm64; SHA=d03699e3f385d4ff5dad68046712adfcc7515325a064d2ab046e0bece30f8f8f ;;
  *) die "不支持的架构 $A" ;;
esac
TARBALL="gost_${GOST_VER}_linux_${ARCH}.tar.gz"
URL="${MIRROR}https://github.com/go-gost/gost/releases/download/v${GOST_VER}/${TARBALL}"

# --- 装二进制（已装且版本一致就跳过下载）
if [ -x "$BIN" ] && "$BIN" -V 2>/dev/null | grep -q "v${GOST_VER}"; then
  log "gost v${GOST_VER} 已存在，跳过下载"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  log "下载 gost v${GOST_VER} ($ARCH)"
  curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/$TARBALL" "$URL" \
    || die "下载失败（若该机连不上 GitHub，用 NODE_GH_MIRROR=https://ghfast.top/ 重试，或把 tar.gz 上传到某处用 NODE_GH_MIRROR=<你的前缀>）"
  echo "$SHA  $TMP/$TARBALL" | sha256sum -c - >/dev/null 2>&1 || die "校验值不匹配，已中止"
  tar -xzf "$TMP/$TARBALL" -C "$TMP" gost
  install -m 0755 "$TMP/gost" "$BIN"
  log "已安装 $($BIN -V)"
fi

# --- 配置：单端口同时吃 http / socks5，固定账号密码
mkdir -p "$CFG_DIR"
cat > "$CFG" <<YAML
services:
- name: node
  addr: ":${PORT}"
  handler:
    type: auto
    auth:
      username: "${NODE_USER_}"
      password: "${NODE_PASS_}"
  listener:
    type: tcp
YAML
chmod 600 "$CFG"

# --- systemd
cat > "/etc/systemd/system/$UNIT" <<'UNITEOF'
[Unit]
Description=gost proxy node (http+socks5, single port)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C /etc/gost/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable --now "$UNIT" >/dev/null
systemctl restart "$UNIT"      # 更新账号/端口后确保生效

# --- 等端口起来：必须确认监听者是「本服务的新 PID」，否则算失败
NEW_PID=""
for i in $(seq 1 20); do
  NEW_PID="$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)"
  [ -n "$NEW_PID" ] && [ "$NEW_PID" != "0" ] && [ "$(PORT_PID)" = "$NEW_PID" ] && break
  sleep 0.4
done
if [ -z "$NEW_PID" ] || [ "$NEW_PID" = "0" ] || [ "$(PORT_PID)" != "$NEW_PID" ]; then
  die "服务没在 $PORT 上监听（被占用或启动失败），看：journalctl -u $UNIT -n 30"
fi

# --- 防火墙（只动本机防火墙；云厂商安全组要你自己在控制台放行）
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  if [ -n "$ALLOW_IP" ]; then
    ufw allow from "$ALLOW_IP" to any port "$PORT" proto tcp >/dev/null && log "ufw: 仅放行 $ALLOW_IP → $PORT"
  else
    ufw allow "$PORT"/tcp >/dev/null && log "ufw: 放行 $PORT/tcp"
  fi
elif command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port="$PORT"/tcp >/dev/null 2>&1 || true
  [ -n "$ALLOW_IP" ] && firewall-cmd --add-rich-rule="rule family=ipv4 source address=$ALLOW_IP port port=$PORT protocol=tcp accept" >/dev/null 2>&1 || true
  firewall-cmd --runtime-to-permanent >/dev/null 2>&1 || true
  log "firewalld: 已放行 $PORT/tcp${ALLOW_IP:+ (仅 $ALLOW_IP)}"
else
  warn "本机没启用 ufw/firewalld；若是云主机请在控制台安全组放行 $PORT/tcp"
fi

# --- 自检：经节点访问外部（走本机环路，只验证代理可用）
OK=""
for T in "https://api.ipify.org" "https://ifconfig.me/ip" "http://ip-api.com/line/?fields=query"; do
  R="$(curl -s -m 12 -x "http://127.0.0.1:$PORT" --proxy-user "$NODE_USER_:$NODE_PASS_" "$T" || true)"
  [ -n "$R" ] && { OK="$R"; break; }
done
RS="$(curl -s -m 12 --socks5 "127.0.0.1:$PORT" --proxy-user "$NODE_USER_:$NODE_PASS_" https://api.ipify.org || true)"
BAD="$(curl -s -m 8 -o /dev/null -w '%{http_code}' -x "http://127.0.0.1:$PORT" https://api.ipify.org || true)"
if [ "$BAD" = "200" ]; then
  AUTH="⚠️  认证未生效（无账号也能用，检查配置！）"
elif [ -n "$BAD" ] && [ "$BAD" != "000" ]; then
  AUTH="✅ 生效（无认证请求被拒：HTTP $BAD）"
else
  AUTH="✅ 生效（无认证请求被直接断开）"
fi

IP="$(curl -s -m 10 https://api.ipify.org || curl -s -m 10 http://ifconfig.me/ip || true)"

echo
echo "==================== 节点就绪 ===================="
echo "HTTP CONNECT : $( [ -n "$OK" ] && echo "OK (出口 $OK)" || echo "失败，看 journalctl -u $UNIT")"
echo "SOCKS5       : $( [ -n "$RS" ] && echo "OK (出口 $RS)" || echo "失败")"
echo "认证         : $AUTH"
echo
echo "节点行（可直接喂给网关配置）："
echo "  ${IP}:${PORT}:${NODE_USER_}:${NODE_PASS_}"
echo
echo "xray outbound（tag 自己改成 US-01…US-29）："
cat <<JSON
{"tag": "US-NN", "protocol": "http", "settings": {"servers": [{"address": "${IP}", "port": ${PORT}, "users": [{"user": "${NODE_USER_}", "pass": "${NODE_PASS_}"}]}]}}
JSON
echo "================================================="
echo "管理： systemctl status|restart $UNIT   |   卸载： bash $0 --uninstall"
