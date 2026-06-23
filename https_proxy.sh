#!/bin/sh
# Interactive HTTPS forward proxy deploy script for Sub2API.

set -eu

SCRIPT_NAME="https_proxy.sh"
STATE_FILE="/etc/squid/https-proxy.env"
SQUID_CONF="/etc/squid/squid.conf"
PASSWD_FILE="/etc/squid/passwd"
CREDENTIAL_FILE="/etc/squid/https-proxy.credential"
STUNNEL_CONF="/etc/stunnel/https-proxy.conf"
CERTBOT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/reload-stunnel.sh"

DOMAIN=""
PUBLIC_PORT="3128"
INTERNAL_PORT="3129"
PROXY_USER="proxyuser"
PROXY_PASS=""
PASSWORD_STATUS="未修改"
INPUT_VALUE=""
YES_NO_RESULT="no"

OS_FAMILY="unknown"
AUTH_HELPER=""
SQUID_USER=""
STUNNEL_USER=""

log() {
  printf '%s\n' "[INFO] $*"
}

warn() {
  printf '%s\n' "[WARN] $*" >&2
}

die() {
  printf '%s\n' "[ERROR] $*" >&2
  exit 1
}

prompt_input() {
  prompt_text="$1"
  default_value="$2"
  printf '%s' "$prompt_text"
  if [ -n "$default_value" ]; then
    printf ' [%s]' "$default_value"
  fi
  printf ': '
  IFS= read -r INPUT_VALUE || INPUT_VALUE=""
  if [ -z "$INPUT_VALUE" ]; then
    INPUT_VALUE="$default_value"
  fi
}

prompt_secret() {
  prompt_text="$1"
  printf '%s' "$prompt_text"
  stty -echo 2>/dev/null || true
  IFS= read -r INPUT_VALUE || INPUT_VALUE=""
  stty echo 2>/dev/null || true
  printf '\n'
}

prompt_yes_no() {
  prompt_text="$1"
  default_value="$2"
  while :; do
    case "$default_value" in
      yes) suffix="Y/n" ;;
      no) suffix="y/N" ;;
      *) suffix="y/n" ;;
    esac
    printf '%s [%s]: ' "$prompt_text" "$suffix"
    IFS= read -r yn || yn=""
    if [ -z "$yn" ]; then
      yn="$default_value"
    fi
    case "$yn" in
      y|Y|yes|YES|Yes) YES_NO_RESULT="yes"; return 0 ;;
      n|N|no|NO|No) YES_NO_RESULT="no"; return 0 ;;
      *) printf '请输入 y 或 n。\n' ;;
    esac
  done
}

preflight() {
  [ "$(id -u)" = "0" ] || die "请用 root 执行：sudo sh $SCRIPT_NAME 或直接 root 登录执行"

  if [ "$#" -gt 0 ]; then
    cat <<EOF
本脚本使用交互式输入，不需要命令行参数。
请直接执行：
  sh $SCRIPT_NAME
EOF
    exit 1
  fi
}

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9._-' | head -c 23)"
    [ -n "$pw" ] || die "openssl rand 失败，无法生成密码"
    printf 'P%s' "$pw"
  elif [ -r /dev/urandom ]; then
    pw="$(tr -dc 'A-Za-z0-9._-' < /dev/urandom | head -c 23)"
    [ -n "$pw" ] || die "/dev/urandom 读取失败，无法生成密码"
    printf 'P%s' "$pw"
  else
    die "无法找到可用的随机源"
  fi
}

validate_port() {
  port_name="$1"
  port_value="$2"
  case "$port_value" in
    ''|*[!0-9]*) die "$port_name 必须是数字：$port_value" ;;
  esac
  if [ "$port_value" -lt 1 ] || [ "$port_value" -gt 65535 ]; then
    die "$port_name 端口范围必须是 1-65535"
  fi
}

validate_config() {
  [ -n "$DOMAIN" ] || die "代理域名不能为空"

  case "$DOMAIN" in
    *[!A-Za-z0-9_.-]*|.*|*.) die "代理域名包含非法字符或格式不完整：$DOMAIN" ;;
  esac

  validate_port "公网端口" "$PUBLIC_PORT"
  validate_port "内部 Squid 端口" "$INTERNAL_PORT"
  [ "$PUBLIC_PORT" != "$INTERNAL_PORT" ] || die "公网端口和内部 Squid 端口不能相同"

  case "$PROXY_USER" in
    ''|*:*|*' '*|*'	'*) die "用户名不能为空，且不能包含冒号、空格或 Tab" ;;
    *[!A-Za-z0-9_.@-]*) die "用户名只能包含字母、数字、下划线、点、@ 和短横线" ;;
  esac
}

password_has_url_reserved_chars() {
  case "$PROXY_PASS" in *:*) return 0 ;; esac
  case "$PROXY_PASS" in *@*) return 0 ;; esac
  case "$PROXY_PASS" in */*) return 0 ;; esac
  case "$PROXY_PASS" in *\?*) return 0 ;; esac
  case "$PROXY_PASS" in *#*) return 0 ;; esac
  case "$PROXY_PASS" in *\[*) return 0 ;; esac
  case "$PROXY_PASS" in *\]*) return 0 ;; esac
  case "$PROXY_PASS" in *!*) return 0 ;; esac
  case "$PROXY_PASS" in *\$*) return 0 ;; esac
  case "$PROXY_PASS" in *"&"*) return 0 ;; esac
  case "$PROXY_PASS" in *"("*|*")"*|*"*"*|*"+"*|*","*|*";"*|*"="*|*"%"*) return 0 ;; esac
  case "$PROXY_PASS" in *' '*|*'	'*) return 0 ;; esac
  return 1
}

collect_config() {
  prompt_input "代理域名，例如 proxy.example.com" "$DOMAIN"
  DOMAIN="$INPUT_VALUE"

  prompt_input "公网 HTTPS 代理端口" "$PUBLIC_PORT"
  PUBLIC_PORT="$INPUT_VALUE"

  prompt_input "Squid 内部端口，仅监听 127.0.0.1" "$INTERNAL_PORT"
  INTERNAL_PORT="$INPUT_VALUE"

  prompt_input "代理用户名" "$PROXY_USER"
  PROXY_USER="$INPUT_VALUE"

  prompt_secret "代理密码；直接回车自动生成强随机密码: "
  PROXY_PASS="$INPUT_VALUE"
  if [ -z "$PROXY_PASS" ]; then
    PROXY_PASS="$(generate_password)"
    PASSWORD_STATUS="自动生成"
  else
    PASSWORD_STATUS="已设置"
  fi

  validate_config
}

print_config_preview() {
  printf '\n========== 配置预览 ==========\n'
  printf '代理域名：%s\n' "$DOMAIN"
  printf 'HTTPS 入口：0.0.0.0:%s\n' "$PUBLIC_PORT"
  printf 'Squid 内部：127.0.0.1:%s\n' "$INTERNAL_PORT"
  printf '代理用户：%s\n' "$PROXY_USER"
  printf '代理密码：%s\n' "$PASSWORD_STATUS"
  printf "证书方式：Let's Encrypt，无邮箱注册\n"
  printf '访问控制：Squid Basic Auth，不限制来源 IP\n'
}

detect_os() {
  ID=""
  ID_LIKE=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  case " $ID $ID_LIKE " in
    *" alpine "*) OS_FAMILY="alpine" ;;
    *" debian "*|*" ubuntu "*) OS_FAMILY="debian" ;;
    *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*) OS_FAMILY="rhel" ;;
    *)
      if command -v apk >/dev/null 2>&1; then
        OS_FAMILY="alpine"
      elif command -v apt-get >/dev/null 2>&1; then
        OS_FAMILY="debian"
      elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        OS_FAMILY="rhel"
      else
        die "暂不支持当前系统；需要 Debian/Ubuntu、CentOS/RHEL/Rocky/Alma/Fedora 或 Alpine"
      fi
      ;;
  esac

  case "$OS_FAMILY" in
    debian) STUNNEL_CONF="/etc/stunnel/https-proxy.conf" ;;
    rhel|alpine) STUNNEL_CONF="/etc/stunnel/stunnel.conf" ;;
  esac
}

install_packages() {
  log "安装依赖包：Squid、htpasswd、certbot、stunnel、openssl"
  case "$OS_FAMILY" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y squid apache2-utils certbot stunnel4 openssl
      ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y squid httpd-tools certbot stunnel openssl
      else
        yum install -y squid httpd-tools certbot stunnel openssl
      fi
      ;;
    alpine)
      apk update
      apk add --no-cache squid apache2-utils certbot stunnel openssl
      ;;
  esac
}

has_stunnel_command() {
  command -v stunnel >/dev/null 2>&1 || command -v stunnel4 >/dev/null 2>&1
}

check_environment() {
  missing=""
  for cmd in squid htpasswd certbot openssl; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  if ! has_stunnel_command; then
    missing="$missing stunnel"
  fi

  if [ -n "$missing" ]; then
    missing="$(printf '%s' "$missing" | awk '{$1=$1;print}')"
    warn "缺少依赖：$missing"
    return 1
  fi

  return 0
}

ensure_environment_ready() {
  detect_os
  log "检测到系统族：$OS_FAMILY"
  if check_environment; then
    return 0
  fi
  install_packages
  check_environment || die "依赖安装后仍不完整"
}

find_auth_helper() {
  for p in \
    /usr/lib/squid/basic_ncsa_auth \
    /usr/lib64/squid/basic_ncsa_auth \
    /usr/libexec/squid/basic_ncsa_auth \
    /usr/local/libexec/squid/basic_ncsa_auth \
    /usr/local/lib/squid/basic_ncsa_auth
  do
    if [ -x "$p" ]; then
      AUTH_HELPER="$p"
      return 0
    fi
  done

  AUTH_HELPER="$(find /usr /lib -type f -name basic_ncsa_auth 2>/dev/null | head -n 1 || true)"
  [ -n "$AUTH_HELPER" ] && [ -x "$AUTH_HELPER" ] && return 0

  die "找不到 basic_ncsa_auth；请确认 squid 包安装完整"
}

detect_squid_user() {
  if id squid >/dev/null 2>&1; then
    SQUID_USER="squid"
  elif id proxy >/dev/null 2>&1; then
    SQUID_USER="proxy"
  else
    SQUID_USER=""
  fi
}

detect_stunnel_user() {
  if id stunnel4 >/dev/null 2>&1; then
    STUNNEL_USER="stunnel4"
  elif id stunnel >/dev/null 2>&1; then
    STUNNEL_USER="stunnel"
  elif id nobody >/dev/null 2>&1; then
    STUNNEL_USER="nobody"
  else
    STUNNEL_USER=""
  fi
}

prepare_dirs() {
  mkdir -p /var/log/squid /var/spool/squid "$(dirname "$SQUID_CONF")"
  if [ -n "$SQUID_USER" ]; then
    chown -R "$SQUID_USER" /var/log/squid /var/spool/squid 2>/dev/null || true
  fi
}

create_or_update_password_file() {
  mkdir -p "$(dirname "$PASSWD_FILE")"
  htpasswd -bc "$PASSWD_FILE" "$PROXY_USER" "$PROXY_PASS" >/dev/null

  if [ -n "$SQUID_USER" ] && chgrp "$SQUID_USER" "$PASSWD_FILE" 2>/dev/null; then
    chmod 640 "$PASSWD_FILE"
  else
    chmod 644 "$PASSWD_FILE"
  fi

  mkdir -p "$(dirname "$CREDENTIAL_FILE")"
  old_umask="$(umask)"
  umask 077
  {
    printf '%s\n' "$PROXY_USER"
    printf '%s\n' "$PROXY_PASS"
  } > "$CREDENTIAL_FILE"
  umask "$old_umask"
  chmod 600 "$CREDENTIAL_FILE"
}

write_squid_config() {
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)"
  if [ -f "$SQUID_CONF" ]; then
    cp -a "$SQUID_CONF" "$SQUID_CONF.bak.$ts"
    log "已备份原 Squid 配置：$SQUID_CONF.bak.$ts"
  fi

  tmp_conf="$SQUID_CONF.tmp.$$"
  {
    cat <<EOF
# Generated by $SCRIPT_NAME at $ts
# HTTPS forward proxy backend. Public TLS is terminated by stunnel.

visible_hostname $DOMAIN
http_port 127.0.0.1:$INTERNAL_PORT

EOF

    if [ -n "$SQUID_USER" ]; then
      cat <<EOF
cache_effective_user $SQUID_USER

EOF
    fi

    cat <<EOF
cache_mem 8 MB
maximum_object_size_in_memory 64 KB
memory_pools off
client_db off
ipcache_size 1024
fqdncache_size 1024
max_filedescriptors 1024

auth_param basic program $AUTH_HELPER $PASSWD_FILE
auth_param basic children 3
auth_param basic realm https_proxy
auth_param basic credentialsttl 2 hours
auth_param basic casesensitive on
acl authenticated proxy_auth REQUIRED

acl SSL_ports port 443 563
acl Safe_ports port 80
acl Safe_ports port 443
acl Safe_ports port 563
acl Safe_ports port 1025-65535
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow authenticated
http_access deny all

access_log stdio:/dev/null
cache_log /dev/null
logfile_rotate 0
cache_store_log none
coredump_dir /var/spool/squid
cache deny all
EOF
  } > "$tmp_conf"

  mv "$tmp_conf" "$SQUID_CONF"
}

parse_squid_config() {
  if squid -k parse >/tmp/squid-parse.log.$$ 2>&1; then
    rm -f /tmp/squid-parse.log.$$
    log "Squid 配置语法检查通过"
    return 0
  fi

  cat /tmp/squid-parse.log.$$ >&2 || true
  rm -f /tmp/squid-parse.log.$$
  die "Squid 配置语法检查失败"
}

obtain_certificate() {
  cert_file="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  key_file="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

  if [ -r "$cert_file" ] && [ -r "$key_file" ]; then
    log "检测到已有证书，跳过申请：$cert_file"
    return 0
  fi

  log "申请 Let's Encrypt 证书：$DOMAIN"
  warn "请确认 $DOMAIN 已解析到本机公网 IP，且 80/tcp 可从公网访问"
  check_port_80_available
  certbot certonly --standalone \
    -d "$DOMAIN" \
    --agree-tos \
    --register-unsafely-without-email \
    --non-interactive
}

check_port_80_available() {
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])80$'; then
    die "80/tcp 已被占用，certbot standalone 无法完成 HTTP-01 验证；请先停止占用 80 端口的服务，或改用 DNS 验证。"
  fi

  if command -v netstat >/dev/null 2>&1 && netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])80$'; then
    die "80/tcp 已被占用，certbot standalone 无法完成 HTTP-01 验证；请先停止占用 80 端口的服务，或改用 DNS 验证。"
  fi
}

enable_stunnel_service_config() {
  if [ -f /etc/default/stunnel4 ]; then
    if grep -q '^ENABLED=' /etc/default/stunnel4; then
      sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4
    else
      printf '%s\n' 'ENABLED=1' >> /etc/default/stunnel4
    fi

    if grep -q '^FILES=' /etc/default/stunnel4; then
      sed -i 's|^FILES=.*|FILES="/etc/stunnel/*.conf"|' /etc/default/stunnel4
    else
      printf '%s\n' 'FILES="/etc/stunnel/*.conf"' >> /etc/default/stunnel4
    fi
  fi
}

write_stunnel_config() {
  mkdir -p "$(dirname "$STUNNEL_CONF")"
  if [ -f "$STUNNEL_CONF" ]; then
    ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)"
    cp -a "$STUNNEL_CONF" "$STUNNEL_CONF.bak.$ts"
    log "已备份原 stunnel 配置：$STUNNEL_CONF.bak.$ts"
  fi

  cat > "$STUNNEL_CONF" <<EOF
; Generated by $SCRIPT_NAME
[https-proxy]
client = no
accept = 0.0.0.0:$PUBLIC_PORT
connect = 127.0.0.1:$INTERNAL_PORT
cert = /etc/letsencrypt/live/$DOMAIN/fullchain.pem
key = /etc/letsencrypt/live/$DOMAIN/privkey.pem
EOF

  if [ -n "$STUNNEL_USER" ]; then
    cat >> "$STUNNEL_CONF" <<EOF
setuid = $STUNNEL_USER
setgid = $STUNNEL_USER
EOF
  fi

  chmod 600 "$STUNNEL_CONF"
  enable_stunnel_service_config
}

write_renewal_hook() {
  mkdir -p "$(dirname "$CERTBOT_HOOK")"
  cat > "$CERTBOT_HOOK" <<'EOF'
#!/bin/sh
systemctl reload stunnel4 2>/dev/null || systemctl restart stunnel4 2>/dev/null || systemctl reload stunnel 2>/dev/null || systemctl restart stunnel 2>/dev/null || rc-service stunnel restart 2>/dev/null || service stunnel4 restart 2>/dev/null || service stunnel restart 2>/dev/null || true
EOF
  chmod +x "$CERTBOT_HOOK"
}

restart_services() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl enable squid >/dev/null 2>&1 || true
    systemctl restart squid
    systemctl is-active --quiet squid || die "Squid 服务未能启动，请执行：systemctl status squid -l"
    if systemctl restart stunnel4 2>/dev/null; then
      systemctl enable stunnel4 >/dev/null 2>&1 || true
      systemctl is-active --quiet stunnel4 || die "stunnel4 服务未能启动，请执行：systemctl status stunnel4 -l"
    else
      systemctl enable stunnel >/dev/null 2>&1 || true
      systemctl restart stunnel
      systemctl is-active --quiet stunnel || die "stunnel 服务未能启动，请执行：systemctl status stunnel -l"
    fi
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add squid default >/dev/null 2>&1 || true
    rc-update add stunnel default >/dev/null 2>&1 || true
    rc-service squid restart
    rc-service stunnel restart
  elif command -v service >/dev/null 2>&1; then
    service squid restart
    service stunnel4 restart 2>/dev/null || service stunnel restart
  else
    die "找不到可用的服务管理器"
  fi

  log "Squid 和 stunnel 已启动，并尽量设置为开机自启"
}

configure_firewall() {
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PUBLIC_PORT/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    log "firewalld 已放行 $PUBLIC_PORT/tcp"
    return 0
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "$PUBLIC_PORT/tcp" >/dev/null || true
    log "ufw 已放行 $PUBLIC_PORT/tcp"
    return 0
  fi

  warn "未检测到已启用的 firewalld/ufw，未改动防火墙。若公网不可访问，请手动放行 $PUBLIC_PORT/tcp 和云安全组。"
}

write_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  old_umask="$(umask)"
  umask 077
  cat > "$STATE_FILE" <<EOF
# Generated by $SCRIPT_NAME
DOMAIN='$DOMAIN'
PUBLIC_PORT='$PUBLIC_PORT'
INTERNAL_PORT='$INTERNAL_PORT'
PROXY_USER='$PROXY_USER'
SQUID_CONF='$SQUID_CONF'
PASSWD_FILE='$PASSWD_FILE'
STUNNEL_CONF='$STUNNEL_CONF'
EOF
  umask "$old_umask"
  chmod 600 "$STATE_FILE"
}

print_summary() {
  cat <<EOF

========== 完成 ==========
HTTPS 代理信息：
  Type:     HTTPS
  Host:     $DOMAIN
  Port:     $PUBLIC_PORT
  Username: $PROXY_USER
  Password: $PROXY_PASS

Sub2API 代理 URL：
  https://$PROXY_USER:$PROXY_PASS@$DOMAIN:$PUBLIC_PORT

Sub2API 字段：
  Protocol: https
  Host:     $DOMAIN
  Port:     $PUBLIC_PORT
  Username: $PROXY_USER
  Password: $PROXY_PASS

测试命令：
  curl --proxy-user '$PROXY_USER:$PROXY_PASS' -x 'https://$DOMAIN:$PUBLIC_PORT' https://ifconfig.me

文件位置：
  Squid 配置：$SQUID_CONF
  stunnel 配置：$STUNNEL_CONF
  密码文件：$PASSWD_FILE
  状态文件：$STATE_FILE
  证书目录：/etc/letsencrypt/live/$DOMAIN

安全提醒：
  当前公网端口 $PUBLIC_PORT 允许连接，代理使用仍需用户名和密码。
  建议在云安全组中进一步限制来源，或至少使用强随机密码。
  申请和续期 Let's Encrypt 证书通常需要 80/tcp 可从公网访问。
EOF

  if password_has_url_reserved_chars; then
    warn "代理密码包含 URL 保留字符；Sub2API 若使用 URL 形式，密码可能需要百分号编码。字段形式无需编码。"
  fi
}

main() {
  preflight "$@"
  printf '\n========== HTTPS 代理一键部署 ==========\n'
  collect_config
  print_config_preview
  prompt_yes_no "确认开始部署或覆盖现有配置" "yes"
  [ "$YES_NO_RESULT" = "yes" ] || die "已取消"
  ensure_environment_ready
  find_auth_helper
  detect_squid_user
  detect_stunnel_user
  prepare_dirs
  obtain_certificate
  create_or_update_password_file
  write_squid_config
  parse_squid_config
  write_stunnel_config
  write_renewal_hook
  restart_services
  configure_firewall
  write_state
  print_summary
}

main "$@"
