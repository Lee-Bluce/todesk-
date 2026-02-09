# RustDesk TLS 代理一键配置脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)

一键部署 RustDesk TLS 加密代理服务器，支持自动证书申请、端口转发和网站伪装。

## ✨ 功能特性

- ✅ **TLS 加密端口转发** - 为 RustDesk 提供安全的 TLS 加密通道
- ✅ **自动证书管理** - 自动申请和续期 Let's Encrypt 证书
- ✅ **网站伪装** - 可选的 80/443 端口网站伪装功能
- ✅ **交互式配置** - 支持自定义域名、端口范围等参数
- ✅ **自动依赖安装** - 自动检测系统并安装所需软件
- ✅ **防火墙配置** - 自动配置 firewalld/ufw 规则
- ✅ **完整错误处理** - 友好的错误提示和日志输出

## 📋 系统要求

- **操作系统**: CentOS 7+, Ubuntu 18.04+, Debian 10+
- **权限**: Root 权限
- **端口**: 80 (证书申请), 443 (可选), 自定义端口范围
- **域名**: 已解析到服务器的域名

## 🏗️ 架构说明

```
客户端 
  ↓ (HTTPS 访问网站)
  ↓ (TLS 加密连接 RustDesk)
代理服务器 (B机器)
  ├─ 80/443: 网站伪装 (可选)
  └─ 35000-35050: RustDesk TLS 代理
       ↓ (SSL 卸载，明文转发)
RustDesk 服务器 (A机器)
  └─ 10000-10050: RustDesk 服务
```

## 🚀 快速开始

### 1. DNS 解析配置

在 DNS 提供商处添加 A 记录，将域名指向代理服务器：

```
desk.example.com  →  你的代理服务器IP
```

### 2. 下载并运行脚本

```bash
# 下载脚本
wget https://raw.githubusercontent.com/Lee-Bluce/todesk-/main/setup_rustdesk_proxy.sh

# 添加执行权限
chmod +x setup_rustdesk_proxy.sh

# 以 root 权限运行
sudo bash setup_rustdesk_proxy.sh
```

### 3. 按提示输入配置

脚本会交互式询问以下信息：

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| 监听域名 | 代理服务器的域名 | desk.example.com |
| 入口端口起始 | 代理服务器监听的起始端口 | 35000 |
| 入口端口结束 | 代理服务器监听的结束端口 | 35050 |
| 转发目标 IP | RustDesk 服务器的 IP 地址 | 192.168.1.100 |
| 转发目标端口起始 | RustDesk 服务器的起始端口 | 10000 |
| 转发目标端口结束 | RustDesk 服务器的结束端口 | 10050 |
| 网站伪装 | 是否启用 80/443 端口伪装 | y |

### 4. 选择证书申请方式

#### 方式 1: HTTP 验证（推荐）
- ✅ 需要 80 端口可用
- ✅ 全自动完成
- ✅ 适合大多数场景

#### 方式 2: DNS 手动验证
- ✅ 不需要 80 端口
- ⚠️ 需要手动添加 DNS TXT 记录
- ✅ 适合 80 端口被占用的情况

#### 方式 3: 跳过（已有证书）
- ✅ 使用现有证书
- ⚠️ 证书需放在 `/etc/nginx/certs/` 目录

## 📝 配置示例

### 示例 1: 标准配置

```
监听域名: desk.example.com
入口端口: 35000-35050
转发目标: 192.168.1.100:10000-10050
网站伪装: 启用
```

### 示例 2: 自定义端口范围

```
监听域名: remote.mycompany.com
入口端口: 40000-40100
转发目标: 10.0.0.50:20000-20100
网站伪装: 启用
```

### 示例 3: 单端口转发

```
监听域名: desk.example.com
入口端口: 35000-35000
转发目标: 192.168.1.100:10000-10000
网站伪装: 禁用
```

## 🔧 使用说明

### 访问网站伪装

如果启用了网站伪装功能：

```bash
# HTTP 会自动跳转到 HTTPS
http://your-domain.com

# HTTPS 访问
https://your-domain.com
```

### RustDesk 客户端配置

在 RustDesk 客户端中配置服务器地址：

```
服务器地址: your-domain.com:35000
```

或使用端口范围内的任意端口。

### 修改网站内容

```bash
# 编辑网站首页
vim /var/www/your_domain/index.html

# 重载 nginx
systemctl reload nginx
```

## 🛠️ 维护操作

### 查看服务状态

```bash
# 查看 Nginx 状态
systemctl status nginx

# 查看监听端口
netstat -tlnp | grep nginx

# 查看实时日志
journalctl -u nginx -f
```

### 证书管理

```bash
# 查看证书到期时间
openssl x509 -in /etc/nginx/certs/your-domain.crt -noout -dates

# 手动强制续期
~/.acme.sh/acme.sh --renew -d your-domain.com --force

# 查看自动续期任务
crontab -l | grep acme
```

证书会自动续期，无需手动操作。

### 配置文件位置

```
/etc/nginx/nginx.conf                    # Nginx 主配置
/etc/nginx/stream.conf.d/rustdesk.conf   # Stream 转发配置
/etc/nginx/sites-available/your-domain   # 网站配置
/etc/nginx/certs/                        # 证书目录
~/.acme.sh/                              # acme.sh 配置
```

## 🐛 故障排查

### 1. 连接被拒绝

检查防火墙规则：

```bash
# CentOS/RHEL
firewall-cmd --list-all

# Ubuntu/Debian
ufw status
```

### 2. TLS 握手失败

检查证书文件：

```bash
ls -la /etc/nginx/certs/
openssl x509 -in /etc/nginx/certs/your-domain.crt -text -noout
```

### 3. 端口转发不通

检查目标服务器端口：

```bash
telnet target-ip target-port
```

### 4. Nginx 启动失败

查看详细错误：

```bash
journalctl -xe -u nginx
nginx -t
```

## 🔒 安全建议

1. **定期更新系统**
   ```bash
   # CentOS/RHEL
   yum update -y
   
   # Ubuntu/Debian
   apt update && apt upgrade -y
   ```

2. **限制源 IP 访问**
   
   在目标服务器上配置防火墙，只允许代理服务器访问：
   
   ```bash
   # 只允许代理服务器 IP 访问
   ufw allow from PROXY_SERVER_IP to any port 10000:10050 proto tcp
   ```

3. **监控日志**
   
   定期检查访问日志，发现异常及时处理：
   
   ```bash
   tail -f /var/log/nginx/access.log
   ```

4. **备份证书**
   ```bash
   cp -r /etc/nginx/certs/ /backup/nginx-certs-$(date +%Y%m%d)
   ```

## ⚡ 性能优化

如果需要处理大量并发连接，可以调整 Nginx 配置：

编辑 `/etc/nginx/nginx.conf`：

```nginx
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 10240;
    use epoll;
}
```

然后重启 Nginx：

```bash
systemctl restart nginx
```

## 🗑️ 卸载

如果需要移除配置：

```bash
# 停止 Nginx
systemctl stop nginx

# 删除配置文件
rm -f /etc/nginx/stream.conf.d/rustdesk.conf
rm -f /etc/nginx/sites-enabled/your-domain

# 删除证书
rm -rf /etc/nginx/certs/your-domain.*

# 删除防火墙规则
firewall-cmd --permanent --remove-port=35000-35050/tcp
firewall-cmd --reload
```

## 📄 许可证

MIT License

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📧 联系方式

如有问题，请提交 [Issue](https://github.com/Lee-Bluce/todesk-/issues)。

---

**注意**: 本脚本仅供学习和合法用途使用，请遵守当地法律法规。
