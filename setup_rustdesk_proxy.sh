#!/bin/bash

# RustDesk TLS 代理一键配置脚本（完整版）
# 功能：TLS 证书申请、端口转发、网站伪装、自动续期

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印函数
print_info() { echo -e "${BLUE}[信息]${NC} $1"; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

# 默认配置
DEFAULT_DOMAIN="desk.example.com"
DEFAULT_ENTRY_PORT_START=35000
DEFAULT_ENTRY_PORT_END=35050
DEFAULT_TARGET_IP="192.168.1.100"
DEFAULT_TARGET_PORT_START=10000
DEFAULT_TARGET_PORT_END=10050

echo "=========================================="
echo "  RustDesk TLS 代理配置脚本"
echo "=========================================="
echo ""

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
    print_error "请使用 root 权限运行此脚本"
    exit 1
fi

# ==================== 交互式配置 ====================
echo "请输入配置信息（直接回车使用默认值）："
echo ""

# 域名配置
read -p "监听域名 [$DEFAULT_DOMAIN]: " DOMAIN
DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}

# 入口端口配置
read -p "入口端口起始 [$DEFAULT_ENTRY_PORT_START]: " ENTRY_PORT_START
ENTRY_PORT_START=${ENTRY_PORT_START:-$DEFAULT_ENTRY_PORT_START}

read -p "入口端口结束 [$DEFAULT_ENTRY_PORT_END]: " ENTRY_PORT_END
ENTRY_PORT_END=${ENTRY_PORT_END:-$DEFAULT_ENTRY_PORT_END}

# 转发目标配置
read -p "转发目标 IP [$DEFAULT_TARGET_IP]: " TARGET_IP
TARGET_IP=${TARGET_IP:-$DEFAULT_TARGET_IP}

read -p "转发目标端口起始 [$DEFAULT_TARGET_PORT_START]: " TARGET_PORT_START
TARGET_PORT_START=${TARGET_PORT_START:-$DEFAULT_TARGET_PORT_START}

read -p "转发目标端口结束 [$DEFAULT_TARGET_PORT_END]: " TARGET_PORT_END
TARGET_PORT_END=${TARGET_PORT_END:-$DEFAULT_TARGET_PORT_END}

# 网站伪装
echo ""
read -p "是否配置网站伪装（80/443端口）? (y/n) [y]: " ENABLE_WEB
ENABLE_WEB=${ENABLE_WEB:-y}

# 计算端口偏移
PORT_OFFSET=$((ENTRY_PORT_START - TARGET_PORT_START))
PORT_COUNT=$((ENTRY_PORT_END - ENTRY_PORT_START + 1))
TARGET_PORT_COUNT=$((TARGET_PORT_END - TARGET_PORT_START + 1))

# 验证端口数量
if [ $PORT_COUNT -ne $TARGET_PORT_COUNT ]; then
    print_error "入口端口数量 ($PORT_COUNT) 与目标端口数量 ($TARGET_PORT_COUNT) 不匹配"
    exit 1
fi

# 其他配置
CERT_DIR="/etc/nginx/certs"
NGINX_STREAM_CONF="/etc/nginx/stream.conf.d"
WEB_ROOT="/var/www/${DOMAIN//./_}"

# 显示配置摘要
echo ""
echo "=========================================="
echo "配置摘要"
echo "=========================================="
echo "监听域名: $DOMAIN"
echo "入口端口: $ENTRY_PORT_START-$ENTRY_PORT_END ($PORT_COUNT 个端口)"
echo "转发目标: $TARGET_IP:$TARGET_PORT_START-$TARGET_PORT_END"
echo "端口偏移: $PORT_OFFSET"
echo "网站伪装: $ENABLE_WEB"
echo "证书目录: $CERT_DIR"
echo "=========================================="
echo ""
read -p "确认配置并继续? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    print_info "已取消"
    exit 0
fi

# ==================== 步骤 1: 安装必要软件 ====================
echo ""
print_info "[步骤 1/8] 安装必要软件..."

if [ -f /etc/redhat-release ]; then
    print_info "检测到 CentOS/RHEL 系统"
    yum install -y epel-release
    yum install -y nginx nginx-mod-stream socat curl
elif [ -f /etc/debian_version ]; then
    print_info "检测到 Debian/Ubuntu 系统"
    apt-get update
    apt-get install -y nginx libnginx-mod-stream socat curl
else
    print_warning "未识别的系统类型，请手动安装 nginx 和 socat"
fi

print_success "软件安装完成"

# ==================== 步骤 2: 安装 acme.sh ====================
echo ""
print_info "[步骤 2/8] 安装 acme.sh..."

if [ ! -d ~/.acme.sh ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
    print_success "acme.sh 安装完成"
else
    print_info "acme.sh 已安装，跳过"
fi

# ==================== 步骤 3: 配置 Stream 模块 ====================
echo ""
print_info "[步骤 3/8] 配置 Nginx Stream 模块..."

# 查找 stream 模块
STREAM_MODULE=$(find /usr -name "ngx_stream_module.so" 2>/dev/null | head -1)

if [ -z "$STREAM_MODULE" ]; then
    print_warning "未找到 stream 模块，尝试安装 nginx-full..."
    if [ -f /etc/debian_version ]; then
        apt-get install -y nginx-full
    fi
    STREAM_MODULE=$(find /usr -name "ngx_stream_module.so" 2>/dev/null | head -1)
fi

if [ -n "$STREAM_MODULE" ]; then
    print_success "找到 stream 模块: $STREAM_MODULE"
    
    # 备份 nginx.conf
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d_%H%M%S)
    
    # 检查是否已加载模块
    if ! grep -q "load_module.*stream" /etc/nginx/nginx.conf; then
        sed -i "1i load_module $STREAM_MODULE;" /etc/nginx/nginx.conf
        print_success "Stream 模块已加载"
    else
        print_info "Stream 模块已存在"
    fi
else
    print_error "无法找到 stream 模块"
    exit 1
fi

# ==================== 步骤 4: 申请 TLS 证书 ====================
echo ""
print_info "[步骤 4/8] 申请 TLS 证书..."
echo "请选择证书申请方式:"
echo "1) HTTP 验证 (需要 80 端口可用)"
echo "2) DNS 手动验证"
echo "3) 跳过证书申请 (已有证书)"

read -p "请选择 [1-3]: " cert_choice

mkdir -p $CERT_DIR

case $cert_choice in
    1)
        print_info "使用 HTTP 验证申请证书..."
        
        # 检查并停止 nginx（如果正在运行）
        if systemctl is-active --quiet nginx; then
            print_info "停止 Nginx 以释放 80 端口..."
            systemctl stop nginx
            NGINX_WAS_RUNNING=true
        else
            NGINX_WAS_RUNNING=false
        fi
        
        # 再次检查 80 端口
        if netstat -tuln | grep -q ":80 "; then
            print_warning "80 端口仍被占用"
            netstat -tuln | grep ":80 "
            print_error "请手动停止占用 80 端口的服务"
            exit 1
        fi
        
        # 输入邮箱
        read -p "请输入邮箱地址: " email
        if [ -z "$email" ]; then
            print_error "邮箱不能为空"
            exit 1
        fi
        
        # 设置 Let's Encrypt
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --register-account -m $email
        
        # 申请证书
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --httpport 80 --force
        
        # 安装证书（不使用 reloadcmd，因为 nginx 还没启动）
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
            --key-file $CERT_DIR/$DOMAIN.key \
            --fullchain-file $CERT_DIR/$DOMAIN.crt
        
        print_success "证书申请成功"
        ;;
    2)
        print_info "使用 DNS 手动验证..."
        
        read -p "请输入邮箱地址: " email
        if [ -z "$email" ]; then
            print_error "邮箱不能为空"
            exit 1
        fi
        
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --register-account -m $email
        
        print_info "请按照提示在 DNS 提供商处添加 TXT 记录"
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please
        
        echo ""
        read -p "请在 DNS 提供商处添加上述 TXT 记录后按回车继续..."
        
        ~/.acme.sh/acme.sh --renew -d $DOMAIN --yes-I-know-dns-manual-mode-enough-go-ahead-please
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
            --key-file $CERT_DIR/$DOMAIN.key \
            --fullchain-file $CERT_DIR/$DOMAIN.crt
        
        print_success "证书申请成功"
        ;;
    3)
        print_info "跳过证书申请"
        ;;
    *)
        print_error "无效选择"
        exit 1
        ;;
esac

# 验证证书
if [ ! -f "$CERT_DIR/$DOMAIN.key" ] || [ ! -f "$CERT_DIR/$DOMAIN.crt" ]; then
    print_error "证书文件不存在"
    exit 1
fi

print_success "证书文件已就绪"

# ==================== 步骤 5: 配置证书自动续期 ====================
echo ""
print_info "[步骤 5/8] 配置证书自动续期..."

if crontab -l 2>/dev/null | grep -q "acme.sh"; then
    print_info "自动续期任务已存在"
else
    ~/.acme.sh/acme.sh --install-cronjob
    print_success "自动续期任务已安装"
fi

# 更新证书的 reloadcmd（在 nginx 启动后才能 reload）
if [ "$cert_choice" = "1" ] || [ "$cert_choice" = "2" ]; then
    print_info "配置证书续期时的 Nginx 重载命令..."
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file $CERT_DIR/$DOMAIN.key \
        --fullchain-file $CERT_DIR/$DOMAIN.crt \
        --reloadcmd "systemctl reload nginx" 2>/dev/null || true
fi

# ==================== 步骤 6: 生成 Stream 配置 ====================
echo ""
print_info "[步骤 6/8] 生成 Nginx Stream 配置..."

mkdir -p $NGINX_STREAM_CONF

cat > $NGINX_STREAM_CONF/rustdesk.conf << 'HEADER'
# RustDesk TLS 代理配置
# 自动生成，请勿手动编辑

HEADER

for port in $(seq $ENTRY_PORT_START $ENTRY_PORT_END); do
    target_port=$((port - PORT_OFFSET))
    cat >> $NGINX_STREAM_CONF/rustdesk.conf << EOF
server {
    listen $port ssl;
    listen [::]:$port ssl;
    
    ssl_certificate $CERT_DIR/$DOMAIN.crt;
    ssl_certificate_key $CERT_DIR/$DOMAIN.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:StreamSSL:10m;
    ssl_session_timeout 10m;
    
    proxy_pass $TARGET_IP:$target_port;
    proxy_connect_timeout 10s;
    proxy_timeout 30s;
}

EOF
done

print_success "已生成 $PORT_COUNT 个端口的转发配置"

# ==================== 步骤 7: 配置网站伪装 ====================
if [ "$ENABLE_WEB" = "y" ]; then
    echo ""
    print_info "[步骤 7/8] 配置网站伪装..."
    
    # 创建网站目录
    mkdir -p $WEB_ROOT
    chown -R www-data:www-data $WEB_ROOT 2>/dev/null || chown -R nginx:nginx $WEB_ROOT 2>/dev/null
    
    # 创建网站内容
    cat > $WEB_ROOT/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>远程桌面服务 - Desk Service</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            line-height: 1.6;
            color: #333;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        .container {
            max-width: 800px;
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 60px 40px;
            text-align: center;
        }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; font-weight: 700; }
        .header p { font-size: 1.2em; opacity: 0.9; }
        .content { padding: 40px; }
        .feature {
            margin-bottom: 30px;
            padding: 20px;
            background: #f8f9fa;
            border-radius: 10px;
            border-left: 4px solid #667eea;
        }
        .feature h3 { color: #667eea; margin-bottom: 10px; font-size: 1.3em; }
        .feature p { color: #666; line-height: 1.8; }
        .status {
            background: #d4edda;
            border: 1px solid #c3e6cb;
            color: #155724;
            padding: 15px;
            border-radius: 8px;
            text-align: center;
            margin-top: 30px;
            font-weight: 500;
        }
        .footer {
            background: #f8f9fa;
            padding: 20px 40px;
            text-align: center;
            color: #666;
            font-size: 0.9em;
        }
        .icon { font-size: 2em; margin-bottom: 10px; }
        @media (max-width: 600px) {
            .header h1 { font-size: 1.8em; }
            .header p { font-size: 1em; }
            .content { padding: 20px; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="icon">🖥️</div>
            <h1>远程桌面服务</h1>
            <p>安全、稳定、高效的远程连接解决方案</p>
        </div>
        <div class="content">
            <div class="feature">
                <h3>🔒 安全加密</h3>
                <p>采用 TLS 1.3 加密技术，确保您的远程连接安全可靠，数据传输全程加密保护。</p>
            </div>
            <div class="feature">
                <h3>⚡ 高速连接</h3>
                <p>优化的网络架构，提供低延迟、高带宽的远程桌面体验，支持高清画质传输。</p>
            </div>
            <div class="feature">
                <h3>🌐 跨平台支持</h3>
                <p>支持 Windows、macOS、Linux、iOS、Android 等多个平台，随时随地访问您的桌面。</p>
            </div>
            <div class="feature">
                <h3>💼 企业级服务</h3>
                <p>提供专业的技术支持和服务保障，满足企业级远程办公需求。</p>
            </div>
            <div class="status">
                ✓ 服务运行正常 | 在线用户: <span id="users">--</span> | 运行时间: <span id="uptime">--</span>
            </div>
        </div>
        <div class="footer">
            <p>&copy; 2026 Desk Service. All rights reserved.</p>
            <p>如需技术支持，请联系管理员</p>
        </div>
    </div>
    <script>
        function updateStatus() {
            const users = Math.floor(Math.random() * 50) + 10;
            const days = Math.floor(Math.random() * 30) + 1;
            const hours = Math.floor(Math.random() * 24);
            document.getElementById('users').textContent = users;
            document.getElementById('uptime').textContent = days + '天' + hours + '小时';
        }
        updateStatus();
        setInterval(updateStatus, 30000);
    </script>
</body>
</html>
EOF
    
    # 备份默认站点
    if [ -f /etc/nginx/sites-enabled/default ]; then
        mv /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/default.backup 2>/dev/null || true
    fi
    
    # 创建网站配置
    cat > /etc/nginx/sites-available/$DOMAIN << EOF
# HTTP - 重定向到 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS - 网站伪装
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate $CERT_DIR/$DOMAIN.crt;
    ssl_certificate_key $CERT_DIR/$DOMAIN.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    root $WEB_ROOT;
    index index.html;
    
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    server_tokens off;
}
EOF
    
    # 启用网站
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
    mkdir -p /var/www/acme/.well-known/acme-challenge
    
    print_success "网站伪装配置完成"
else
    print_info "[步骤 7/8] 跳过网站伪装"
fi

# ==================== 步骤 8: 配置 Nginx 并启动 ====================
echo ""
print_info "[步骤 8/8] 配置 Nginx 并启动..."

# 添加 stream 块
if ! grep -q "^stream {" /etc/nginx/nginx.conf; then
    cat >> /etc/nginx/nginx.conf << 'EOF'

# Stream 配置
stream {
    include /etc/nginx/stream.conf.d/*.conf;
}
EOF
    print_success "Stream 块已添加"
fi

# 测试配置
print_info "测试 Nginx 配置..."
nginx -t

if [ $? -ne 0 ]; then
    print_error "配置测试失败"
    exit 1
fi

print_success "配置测试通过"

# 清理旧进程
pkill -9 nginx 2>/dev/null || true
rm -f /run/nginx.pid

# 启动 nginx
print_info "启动 Nginx..."
systemctl enable nginx
systemctl start nginx
sleep 2

if ! systemctl is-active --quiet nginx; then
    print_error "Nginx 启动失败"
    systemctl status nginx --no-pager
    exit 1
fi

print_success "Nginx 启动成功"

# 配置防火墙
echo ""
print_info "配置防火墙..."

if command -v firewall-cmd &> /dev/null; then
    for port in $(seq $ENTRY_PORT_START $ENTRY_PORT_END); do
        firewall-cmd --permanent --add-port=$port/tcp >/dev/null 2>&1
    done
    [ "$ENABLE_WEB" = "y" ] && firewall-cmd --permanent --add-service=http --add-service=https >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    print_success "防火墙规则已添加 (firewalld)"
elif command -v ufw &> /dev/null; then
    for port in $(seq $ENTRY_PORT_START $ENTRY_PORT_END); do
        ufw allow $port/tcp >/dev/null 2>&1
    done
    [ "$ENABLE_WEB" = "y" ] && ufw allow 80/tcp && ufw allow 443/tcp >/dev/null 2>&1
    print_success "防火墙规则已添加 (ufw)"
elif command -v iptables &> /dev/null; then
    # 使用 iptables
    print_info "使用 iptables 配置防火墙..."
    
    # 备份规则
    iptables-save > /root/iptables.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    
    # 添加端口范围规则
    iptables -I INPUT -p tcp --dport $ENTRY_PORT_START:$ENTRY_PORT_END -j ACCEPT 2>/dev/null || true
    
    # 添加 HTTP/HTTPS 规则
    if [ "$ENABLE_WEB" = "y" ]; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    fi
    
    # 保存规则
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    elif [ -d /etc/sysconfig ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    fi
    
    print_success "防火墙规则已添加 (iptables)"
else
    print_warning "未检测到防火墙，请手动配置"
fi

# ==================== 完成 ====================
echo ""
echo "=========================================="
print_success "配置完成！"
echo "=========================================="
echo ""
echo "配置摘要:"
echo "  域名: $DOMAIN"
echo "  入口端口: $ENTRY_PORT_START-$ENTRY_PORT_END (TLS)"
echo "  转发目标: $TARGET_IP:$TARGET_PORT_START-$TARGET_PORT_END"
echo "  监听端口数: $(netstat -tlnp 2>/dev/null | grep nginx | grep -c LISTEN || echo '检测中...')"
echo ""

if [ "$ENABLE_WEB" = "y" ]; then
    echo "网站伪装:"
    echo "  HTTP:  http://$DOMAIN"
    echo "  HTTPS: https://$DOMAIN"
    echo ""
fi

echo "证书信息:"
openssl x509 -in $CERT_DIR/$DOMAIN.crt -noout -dates 2>/dev/null | grep "notAfter" || echo "  证书有效期: 请检查"
echo "  自动续期: 已启用"
echo ""

echo "测试连接:"
echo "  openssl s_client -connect $DOMAIN:$ENTRY_PORT_START"
echo ""

echo "查看日志:"
echo "  journalctl -u nginx -f"
echo ""

echo "查看监听端口:"
echo "  netstat -tlnp | grep nginx"
echo ""

echo "配置文件位置:"
echo "  Stream: $NGINX_STREAM_CONF/rustdesk.conf"
[ "$ENABLE_WEB" = "y" ] && echo "  Web: /etc/nginx/sites-available/$DOMAIN"
echo "  证书: $CERT_DIR/$DOMAIN.{crt,key}"
echo ""

echo "=========================================="
print_success "安装完成，祝使用愉快！"
echo "=========================================="
