# 腾讯云 EdgeOne 源站保护脚本 (edgeone_ip_protection.sh)

## 功能简介
本脚本用于自动获取腾讯云 EdgeOne 官方回源节点 IP 列表，并通过 iptables（支持 IPv4/IPv6）自动配置防火墙白名单，只允许 EdgeOne 节点访问指定端口。支持自动定时更新、日志输出、测试/调试模式、多系统兼容。

## 主要特性
- 自动拉取 EdgeOne 官方 IP（支持全球/区域/IPv4/IPv6）
- 自动配置/清理防火墙白名单规则
- 支持多端口、多区域、多 IP 版本
- 支持自动定时更新（crontab 或 systemd timer）
- 支持测试模式（不实际更改防火墙）和调试模式
- 详细中文注释和日志
- 自动保存/恢复防火墙规则，兼容多种 Linux 发行版

## 依赖环境
- bash
- curl
- jq
- iptables、ip6tables
- （可选）netfilter-persistent、crontab 或 systemd

安装依赖示例：
```bash
# Debian/Ubuntu
sudo apt-get install curl jq iptables iptables-persistent
# CentOS/RHEL
sudo yum install curl jq iptables
```

## 用法说明
脚本需 root 权限运行。

```bash
sudo bash edgeone_ip_protection.sh [选项]
```

### 常用参数
| 参数 | 说明 |
|------|------|
| --add PORT | 为指定端口添加 EdgeOne IP 白名单保护 |
| --delete PORT | 删除指定端口的 EdgeOne IP 白名单保护 |
| --list | 列出当前的 EdgeOne 保护规则及配置信息 |
| --version v4/v6 | 指定 IP 版本（可选，默认全部）|
| --area 区域 | 指定区域（global, mainland-china, overseas，默认 global）|
| --debug | 启用调试模式，显示详细执行信息 |
| --test | 启用测试模式，不实际更改防火墙 |
| --update-interval N | 设置自动更新间隔（天，默认10天）|
| --disable-update | 禁用自动定时更新 |
| --help | 显示帮助信息 |

### 示例
```bash
# 添加 80 端口的 EdgeOne 白名单保护（仅允许 EdgeOne IP 访问）
sudo bash edgeone_ip_protection.sh --add 80

# 添加 443 端口，仅允许中国大陆 EdgeOne IPv4 节点访问
echo sudo bash edgeone_ip_protection.sh --add 443 --version v4 --area mainland-china

# 删除 80 端口的保护规则
sudo bash edgeone_ip_protection.sh --delete 80

# 查看当前所有规则和配置信息
sudo bash edgeone_ip_protection.sh --list

# 设置每7天自动更新一次 IP 白名单
sudo bash edgeone_ip_protection.sh --update-interval 7

# 禁用自动定时更新
sudo bash edgeone_ip_protection.sh --disable-update

# 测试模式（不实际更改防火墙，仅打印操作）
sudo bash edgeone_ip_protection.sh --add 80 --test

# 调试模式（显示详细执行过程）
sudo bash edgeone_ip_protection.sh --add 80 --debug
```

## 自动定时更新说明
- 默认每10天自动拉取最新 EdgeOne IP 并更新防火墙规则。
- 可用 `--update-interval N` 设置间隔天数。
- 支持 crontab（优先）或 systemd timer（自动检测）。
- 可用 `--disable-update` 禁用自动更新。
- 配置和定时脚本保存在 `/etc/edgeone-protection/`。

## 常见问题与注意事项
- 脚本需 root 权限。
- 防火墙规则变更有风险，建议先用 `--test` 模式验证。
- 若系统不支持 crontab 或 systemd，请手动定时运行脚本。
- 若 iptables-save/restore 报错，请检查依赖和权限。

## 卸载与恢复
- 删除防火墙规则：用 `--delete PORT`。
- 删除自动定时任务：用 `--disable-update`。
- 如需完全卸载，删除 `/etc/edgeone-protection/` 目录及相关定时任务。

