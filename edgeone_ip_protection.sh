#!/bin/bash
#
# EdgeOne IP Protection Script
# 用于腾讯云 EdgeOne 源站保护的 Shell 脚本
# 从官方 API 获取 EdgeOne IP 列表，并配置防火墙规则，只允许 EdgeOne 节点访问指定端口
#

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本需要 root 权限运行。请使用 sudo 或以 root 用户身份运行。"
        exit 1
    fi
}

# 检查必要的命令是否存在
check_commands() {
    local missing_commands=()
    
    for cmd in curl jq iptables; do
        if ! command -v $cmd &> /dev/null; then
            missing_commands+=($cmd)
        fi
    done
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        log_error "缺少必要的命令: ${missing_commands[*]}"
        log_info "请安装缺少的命令后再运行此脚本。"
        log_info "Debian/Ubuntu: sudo apt-get install ${missing_commands[*]}"
        log_info "CentOS/RHEL: sudo yum install ${missing_commands[*]}"
        exit 1
    fi
}

# 将 CIDR 掩码转换为点分十进制格式
convert_cidr_to_netmask() {
    local cidr=$1
    local mask=""
    local full_octets=$(($cidr/8))
    local partial_octet=$(($cidr%8))
    
    for ((i=0; i<4; i++)); do
        if [ $i -lt $full_octets ]; then
            mask="${mask}255"
        elif [ $i -eq $full_octets ]; then
            local value=$((256 - 2**(8-$partial_octet)))
            mask="${mask}${value}"
        else
            mask="${mask}0"
        fi
        
        if [ $i -lt 3 ]; then
            mask="${mask}."
        fi
    done
    
    echo "$mask"
}

# 获取 EdgeOne IP 列表
get_edgeone_ips() {
    local version=$1  # v4 或 v6
    local area=$2     # global, mainland-china, overseas
    local url="https://api.edgeone.ai/ips"
    local query=""
    
    if [ -n "$version" ]; then
        query="?version=$version"
    fi
    
    if [ -n "$area" ]; then
        if [ -n "$query" ]; then
            query="${query}&area=$area"
        else
            query="?area=$area"
        fi
    fi
    
    log_info "正在获取 EdgeOne IP 列表 (${version:-全部} ${area:-全球})..."
    log_info "API 请求: $url$query"
    
    # 添加超时参数，避免无限等待
    local response
    response=$(curl -s --connect-timeout 10 --max-time 30 "$url$query")
    local curl_status=$?
    
    if [ $curl_status -ne 0 ]; then
        log_error "获取 EdgeOne IP 列表失败，curl 返回状态码: $curl_status"
        log_info "尝试使用备用方法..."
        
        # 备用方法：使用预定义的 EdgeOne IP 范围
        log_warn "使用预定义的 EdgeOne IP 范围（可能不是最新）"
        # 常见的 CDN IP 范围作为备用
        echo "101.32.0.0/16
101.33.0.0/16
203.205.128.0/19
203.205.176.0/20
101.226.0.0/16
182.254.0.0/16
2402:4e00:1000::/48
2402:4e00:2000::/48
2402:4e00:3000::/48
2402:4e00:4000::/48
2402:4e00:8000::/48
2402:4e00::/32"
        return 0
    fi
    
    if [ -z "$response" ]; then
        log_error "无法获取 EdgeOne IP 列表，API 返回为空。"
        return 1
    fi
    
    log_info "已成功获取 EdgeOne IP 列表，正在处理数据..."
    
    # 检查响应是否为有效的 JSON 或纯文本格式
    if [[ "$response" == *"["* && "$response" == *"]"* ]]; then
        # 可能是 JSON 数组格式
        if command -v jq &> /dev/null; then
            # 使用 jq 解析 JSON
            echo "$response" | jq -r '.[]' 2>/dev/null || {
                log_warn "无法使用 jq 解析 JSON 响应，尝试使用文本处理..."
                echo "$response" | tr -d '[]",' | tr ' ' '\n' | grep -v '^$'
            }
        else
            # 没有 jq，使用简单的文本处理
            echo "$response" | tr -d '[]",' | tr ' ' '\n' | grep -v '^$'
        fi
    else
        # 假设是每行一个 IP 地址的纯文本格式
        echo "$response" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/[0-9]\+\|[0-9a-fA-F:]\+/[0-9]\+' || echo "$response"
    fi
}

# 创建 IPTABLES 链
create_iptables_chain() {
    # IPv4 规则链
    # 检查链是否已存在，如果不存在则创建
    if ! iptables -n -L EDGEONE &> /dev/null; then
        log_info "创建 IPv4 IPTABLES EDGEONE 链..."
        iptables -N EDGEONE
    else
        log_info "IPv4 EDGEONE 链已存在，清空现有规则..."
        iptables -F EDGEONE
    fi
    
    # 确保 EDGEONE 链在 INPUT 链中的引用
    if ! iptables -n -C INPUT -j EDGEONE &> /dev/null; then
        log_info "将 IPv4 EDGEONE 链添加到 INPUT 链..."
        iptables -I INPUT -j EDGEONE
    fi
    
    # IPv6 规则链
    if command -v ip6tables &> /dev/null; then
        if ! ip6tables -n -L EDGEONE &> /dev/null; then
            log_info "创建 IPv6 IPTABLES EDGEONE 链..."
            ip6tables -N EDGEONE 2>/dev/null
        else
            log_info "IPv6 EDGEONE 链已存在，清空现有规则..."
            ip6tables -F EDGEONE 2>/dev/null
        fi
        
        # 确保 EDGEONE 链在 INPUT 链中的引用
        if ! ip6tables -n -C INPUT -j EDGEONE &> /dev/null; then
            log_info "将 IPv6 EDGEONE 链添加到 INPUT 链..."
            ip6tables -I INPUT -j EDGEONE 2>/dev/null
        fi
    else
        log_warn "未找到 ip6tables 命令，跳过 IPv6 规则配置"
    fi
}

# 应用 EdgeOne IP 白名单规则
apply_edgeone_whitelist() {
    local port=$1
    local ip_list=$2
    
    log_info "为端口 $port 应用 EdgeOne IP 白名单规则..."
    
    # 检查 IP 列表是否为空
    if [ -z "$ip_list" ]; then
        log_error "IP 列表为空，无法应用白名单规则"
        return 1
    fi
    
    # 计算 IP 数量
    local ip_count=$(echo "$ip_list" | grep -v '^$' | wc -l)
    log_info "共有 $ip_count 个 IP 地址/范围需要添加到白名单"
    
    # 设置进度计数器
    local counter=0
    local progress_step=$((ip_count > 100 ? ip_count/10 : 10))
    
    # 添加 EdgeOne IP 白名单规则
    echo "$ip_list" | while read -r ip; do
        if [ -n "$ip" ]; then
            counter=$((counter + 1))
            
            # 显示进度
            if [ $((counter % progress_step)) -eq 0 ]; then
                log_info "进度: $counter/$ip_count ($(( counter * 100 / ip_count ))%)"
            fi
            
            # 检查是否为 CIDR 格式
            if [[ "$ip" == *"/"* ]]; then
                # 提取 IP 和掩码
                local base_ip=$(echo "$ip" | cut -d'/' -f1)
                local mask=$(echo "$ip" | cut -d'/' -f2)
                
                # 检查是否为 IPv4 地址
                if [[ "$base_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    # 将 CIDR 掩码转换为点分十进制格式
                    local netmask=$(convert_cidr_to_netmask "$mask")
                    # 使用点分十进制掩码格式
                    iptables -A EDGEONE -p tcp -s "$base_ip/$netmask" --dport "$port" -j ACCEPT 2>/dev/null || \
                    iptables -A EDGEONE -p tcp -s "$base_ip" --dport "$port" -j ACCEPT
                else
                    # IPv6 地址，尝试直接使用
                    ip6tables -A EDGEONE -p tcp -s "$ip" --dport "$port" -j ACCEPT 2>/dev/null || \
                    ip6tables -A EDGEONE -p tcp -s "$base_ip" --dport "$port" -j ACCEPT
                fi
            else
                # 检查是否为 IPv4 地址
                if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    iptables -A EDGEONE -p tcp -s "$ip" --dport "$port" -j ACCEPT
                else
                    # IPv6 地址
                    ip6tables -A EDGEONE -p tcp -s "$ip" --dport "$port" -j ACCEPT
                fi
            fi
        fi
    done
    
    log_info "所有 EdgeOne IP 已添加到白名单"
    
    # 添加阻止其他 IP 访问该端口的规则
    log_info "添加端口 $port 的阻止规则..."
    iptables -A INPUT -p tcp --dport "$port" -j DROP
    ip6tables -A INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
    
    log_info "端口 $port 的 EdgeOne IP 白名单规则已应用。"
}

# 删除指定端口的 EdgeOne 保护规则
remove_edgeone_protection() {
    local port=$1
    
    log_info "正在删除端口 $port 的 EdgeOne 保护规则..."
    
    # 删除 IPv4 INPUT 链中阻止访问该端口的规则
    iptables -D INPUT -p tcp --dport "$port" -j DROP &> /dev/null
    
    # 删除 IPv6 INPUT 链中阻止访问该端口的规则
    if command -v ip6tables &> /dev/null; then
        ip6tables -D INPUT -p tcp --dport "$port" -j DROP &> /dev/null
    fi
    
    log_info "端口 $port 的 EdgeOne 保护规则已删除。"
}

# 列出当前的 EdgeOne 保护规则
list_edgeone_protection() {
    log_info "当前的 IPv4 EdgeOne 保护规则:"
    echo "----------------------------------------"
    iptables -L EDGEONE -n --line-numbers
    echo "----------------------------------------"
    log_info "IPv4 INPUT 链中的端口阻止规则:"
    echo "----------------------------------------"
    iptables -L INPUT -n | grep DROP
    echo "----------------------------------------"
    
    # 如果支持 IPv6，显示 IPv6 规则
    if command -v ip6tables &> /dev/null; then
        log_info "当前的 IPv6 EdgeOne 保护规则:"
        echo "----------------------------------------"
        ip6tables -L EDGEONE -n --line-numbers 2>/dev/null
        echo "----------------------------------------"
        log_info "IPv6 INPUT 链中的端口阻止规则:"
        echo "----------------------------------------"
        ip6tables -L INPUT -n 2>/dev/null | grep DROP
        echo "----------------------------------------"
    fi
}

# 保存 IPTABLES 规则
save_iptables_rules() {
    log_info "正在保存 IPTABLES 规则..."
    
    # 检测系统类型和可用的保存方法
    local saved=false
    
    # 方法1: 使用 netfilter-persistent (Debian/Ubuntu)
    if command -v netfilter-persistent &> /dev/null; then
        log_info "使用 netfilter-persistent 保存规则..."
        netfilter-persistent save
        saved=true
    # 方法2: 使用 iptables-save 和系统特定位置
    elif command -v iptables-save &> /dev/null; then
        # Debian/Ubuntu 系统
        if [ -f /etc/debian_version ]; then
            log_info "检测到 Debian/Ubuntu 系统，保存规则到 /etc/iptables/..."
            # 确保目录存在
            if [ ! -d /etc/iptables ]; then
                mkdir -p /etc/iptables
            fi
            iptables-save > /etc/iptables/rules.v4
            # 保存 IPv6 规则
            if command -v ip6tables-save &> /dev/null; then
                ip6tables-save > /etc/iptables/rules.v6
            fi
            saved=true
        # CentOS/RHEL 系统
        elif [ -f /etc/redhat-release ]; then
            log_info "检测到 CentOS/RHEL 系统，保存规则到 /etc/sysconfig/..."
            # 确保目录存在
            if [ ! -d /etc/sysconfig ]; then
                mkdir -p /etc/sysconfig
            fi
            iptables-save > /etc/sysconfig/iptables
            systemctl restart iptables 2>/dev/null || service iptables restart 2>/dev/null || true
            # 保存 IPv6 规则
            if command -v ip6tables-save &> /dev/null; then
                ip6tables-save > /etc/sysconfig/ip6tables
                systemctl restart ip6tables 2>/dev/null || service ip6tables restart 2>/dev/null || true
            fi
            saved=true
        fi
    fi
    
    # 如果上述方法都失败，使用通用方法
    if [ "$saved" = false ]; then
        log_info "使用通用方法保存规则..."
        
        # 创建保存规则的目录
        local save_dir="/etc/iptables"
        if [ ! -d "$save_dir" ]; then
            mkdir -p "$save_dir" 2>/dev/null || {
                save_dir="/tmp/iptables"
                mkdir -p "$save_dir" 2>/dev/null
            }
        fi
        
        # 保存 IPv4 规则
        if command -v iptables-save &> /dev/null; then
            local ipv4_rules="$save_dir/rules.v4"
            iptables-save > "$ipv4_rules"
            log_info "IPv4 规则已保存到 $ipv4_rules"
            
            # 创建恢复规则的启动脚本
            local restore_script="$save_dir/restore-iptables.sh"
            echo '#!/bin/sh' > "$restore_script"
            echo "# EdgeOne IP Protection - 防火墙规则恢复脚本" >> "$restore_script"
            echo "iptables-restore < $ipv4_rules" >> "$restore_script"
            
            # 保存 IPv6 规则
            if command -v ip6tables-save &> /dev/null; then
                local ipv6_rules="$save_dir/rules.v6"
                ip6tables-save > "$ipv6_rules"
                log_info "IPv6 规则已保存到 $ipv6_rules"
                echo "ip6tables-restore < $ipv6_rules" >> "$restore_script"
            fi
            
            # 设置脚本权限
            chmod +x "$restore_script"
            log_info "创建了恢复脚本: $restore_script"
            log_info "您可以将此脚本添加到系统启动项中，以确保规则在重启后仍然有效"
            log_info "例如: 'crontab -e' 然后添加 '@reboot $restore_script'"
        else
            log_warn "无法找到 iptables-save 命令，无法保存规则"
        fi
    fi
}

# 格式化时间戳为可读格式
format_timestamp() {
    local timestamp=$1
    
    # 尝试不同的 date 命令格式（兼容不同系统）
    if date -d @$timestamp '+%Y-%m-%d %H:%M:%S' &>/dev/null; then
        date -d @$timestamp '+%Y-%m-%d %H:%M:%S'
    elif date -r $timestamp '+%Y-%m-%d %H:%M:%S' &>/dev/null; then
        date -r $timestamp '+%Y-%m-%d %H:%M:%S'
    else
        echo "时间戳: $timestamp"
    fi
}

# 设置定时更新的默认间隔（天）
DEFAULT_UPDATE_INTERVAL=10

# 定时更新配置文件路径
CONFIG_DIR="/etc/edgeone-protection"
CONFIG_FILE="$CONFIG_DIR/config"
CRON_FILE="$CONFIG_DIR/cron_update"

# 创建配置目录和文件
create_config_dir() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR" 2>/dev/null || {
            CONFIG_DIR="/tmp/edgeone-protection"
            mkdir -p "$CONFIG_DIR" 2>/dev/null
        }
    fi
    
    # 创建配置文件（如果不存在）
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "# EdgeOne IP Protection 配置文件" > "$CONFIG_FILE"
        echo "UPDATE_INTERVAL=$DEFAULT_UPDATE_INTERVAL" >> "$CONFIG_FILE"
        echo "PROTECTED_PORTS=" >> "$CONFIG_FILE"
        echo "IP_VERSION=" >> "$CONFIG_FILE"
        echo "AREA=global" >> "$CONFIG_FILE"
        echo "LAST_UPDATE=$(date +%s)" >> "$CONFIG_FILE"
    fi
}

# 读取配置
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

# 更新配置
update_config() {
    local key=$1
    local value=$2
    
    if [ -f "$CONFIG_FILE" ]; then
        # 如果键已存在，更新其值
        if grep -q "^$key=" "$CONFIG_FILE"; then
            sed -i "s|^$key=.*|$key=$value|" "$CONFIG_FILE" 2>/dev/null || \
            sed "s|^$key=.*|$key=$value|" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && \
            mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        else
            # 如果键不存在，添加新的键值对
            echo "$key=$value" >> "$CONFIG_FILE"
        fi
    fi
}

# 添加受保护的端口到配置
add_protected_port() {
    local port=$1
    local version=$2
    local area=$3
    
    read_config
    
    # 更新受保护端口列表
    local ports="$PROTECTED_PORTS"
    if [ -z "$ports" ]; then
        ports="$port"
    else
        # 检查端口是否已存在
        if ! echo "$ports" | grep -q "\<$port\>"; then
            ports="$ports $port"
        fi
    fi
    
    update_config "PROTECTED_PORTS" "$ports"
    
    # 更新其他配置
    if [ -n "$version" ]; then
        update_config "IP_VERSION" "$version"
    fi
    
    if [ -n "$area" ]; then
        update_config "AREA" "$area"
    fi
    
    update_config "LAST_UPDATE" "$(date +%s)"
}

# 从配置中删除受保护的端口
remove_protected_port() {
    local port=$1
    
    read_config
    
    # 更新受保护端口列表
    local ports="$PROTECTED_PORTS"
    if [ -n "$ports" ]; then
        # 移除指定端口
        ports=$(echo "$ports" | sed "s/\<$port\>//g" | tr -s ' ' | sed 's/^ //' | sed 's/ $//')
        update_config "PROTECTED_PORTS" "$ports"
    fi
}

# 设置定时更新任务
setup_cron_job() {
    local interval=$1
    
    if [ -z "$interval" ]; then
        read_config
        interval=${UPDATE_INTERVAL:-$DEFAULT_UPDATE_INTERVAL}
    fi
    
    log_info "设置定时更新任务，每 $interval 天更新一次 EdgeOne IP 列表..."
    
    # 创建定时更新脚本
    cat > "$CRON_FILE" << EOF
#!/bin/bash
# EdgeOne IP Protection 定时更新脚本

# 加载配置
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "配置文件不存在，退出"
    exit 1
fi

# 检查是否需要更新
CURRENT_TIME=\$(date +%s)
LAST_UPDATE=\${LAST_UPDATE:-0}
UPDATE_INTERVAL=\${UPDATE_INTERVAL:-$DEFAULT_UPDATE_INTERVAL}
INTERVAL_SECONDS=\$((UPDATE_INTERVAL * 86400))

if [ \$((CURRENT_TIME - LAST_UPDATE)) -ge \$INTERVAL_SECONDS ]; then
    echo "正在更新 EdgeOne IP 列表..."
    
    # 对每个受保护的端口重新应用规则
    for PORT in \$PROTECTED_PORTS; do
        $0 --add \$PORT --version \$IP_VERSION --area \$AREA
    done
    
    # 更新最后更新时间
    sed -i "s|^LAST_UPDATE=.*|LAST_UPDATE=\$CURRENT_TIME|" "$CONFIG_FILE" 2>/dev/null || \
    sed "s|^LAST_UPDATE=.*|LAST_UPDATE=\$CURRENT_TIME|" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && \
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    echo "EdgeOne IP 列表已更新"
else
    echo "EdgeOne IP 列表不需要更新"
fi
EOF
    
    chmod +x "$CRON_FILE"
    
    # 使用每天运行的 crontab，但在脚本中检查是否需要更新
    local cron_expression="0 4 * * *"  # 每天凌晨4点运行
    
    # 尝试添加到 crontab
    if command -v crontab &>/dev/null; then
        (crontab -l 2>/dev/null | grep -v "$CRON_FILE" ; echo "$cron_expression $CRON_FILE > /dev/null 2>&1") | crontab - 2>/dev/null
        
        if [ $? -eq 0 ]; then
            log_info "定时更新任务已设置，脚本将每天凌晨 4 点检查，并在需要时更新 EdgeOne IP 列表"
        else
            log_warn "无法设置 crontab，请手动添加以下行到 crontab:"
            log_warn "$cron_expression $CRON_FILE > /dev/null 2>&1"
        fi
    else
        # 如果没有 crontab 命令，尝试使用 systemd timer
        if command -v systemctl &>/dev/null; then
            log_info "未找到 crontab 命令，尝试使用 systemd timer..."
            
            # 创建 systemd service 文件
            local service_file="/etc/systemd/system/edgeone-update.service"
            cat > "$service_file" 2>/dev/null << EOF
[Unit]
Description=EdgeOne IP Protection Update Service
After=network.target

[Service]
Type=oneshot
ExecStart=$CRON_FILE

[Install]
WantedBy=multi-user.target
EOF
            
            # 创建 systemd timer 文件
            local timer_file="/etc/systemd/system/edgeone-update.timer"
            cat > "$timer_file" 2>/dev/null << EOF
[Unit]
Description=Run EdgeOne IP Protection Update Service daily

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
            
            # 启用并启动 timer
            systemctl daemon-reload 2>/dev/null
            systemctl enable edgeone-update.timer 2>/dev/null
            systemctl start edgeone-update.timer 2>/dev/null
            
            if [ $? -eq 0 ]; then
                log_info "定时更新任务已使用 systemd timer 设置，脚本将每天凌晨 4 点检查更新"
            else
                log_warn "无法设置 systemd timer，请手动设置定时任务"
            fi
        else
            log_warn "未找到 crontab 或 systemd，请手动设置定时任务运行以下脚本:"
            log_warn "$CRON_FILE"
        fi
    fi
    
    # 更新配置
    update_config "UPDATE_INTERVAL" "$interval"
}

# 删除定时更新任务
remove_cron_job() {
    log_info "删除定时更新任务..."
    
    # 从 crontab 中移除
    (crontab -l 2>/dev/null | grep -v "$CRON_FILE") | crontab - 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log_info "定时更新任务已删除"
    else
        log_warn "无法删除定时更新任务，请手动编辑 crontab"
    fi
}

# 显示帮助信息
show_help() {
    echo "EdgeOne IP Protection Script"
    echo "用于腾讯云 EdgeOne 源站保护的 Shell 脚本"
    echo
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  --add PORT         为指定端口添加 EdgeOne IP 白名单保护"
    echo "  --delete PORT      删除指定端口的 EdgeOne IP 白名单保护"
    echo "  --list             列出当前的 EdgeOne 保护规则"
    echo "  --version VERSION  指定 IP 版本 (v4 或 v6，默认为全部)"
    echo "  --area AREA        指定区域 (global, mainland-china, overseas，默认为 global)"
    echo "  --debug            启用调试模式，显示详细的执行信息"
    echo "  --test             启用测试模式，不会实际应用防火墙规则"
    echo "  --update-interval DAYS  设置自动更新间隔，单位为天 (默认: 10天)"
    echo "  --disable-update   禁用自动更新"
    echo "  --help             显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0 --add 80 --version v4 --area mainland-china"
    echo "  $0 --delete 80"
    echo "  $0 --list"
    echo "  $0 --add 3000 --debug"
    echo "  $0 --update-interval 7  # 设置每7天自动更新一次"
}

# 主函数
main() {
    local action=""
    local port=""
    local version=""
    local area="global"
    local debug=false
    local test_mode=false
    local update_interval=""
    local disable_update=false
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --add)
                action="add"
                port="$2"
                shift 2
                ;;
            --delete)
                action="delete"
                port="$2"
                shift 2
                ;;
            --list)
                action="list"
                shift
                ;;
            --version)
                version="$2"
                shift 2
                ;;
            --area)
                area="$2"
                shift 2
                ;;
            --debug)
                debug=true
                shift
                ;;
            --test)
                test_mode=true
                log_info "测试模式已启用，不会实际应用防火墙规则"
                shift
                ;;
            --update-interval)
                update_interval="$2"
                shift 2
                ;;
            --disable-update)
                disable_update=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 如果开启调试模式
    if [ "$debug" = true ]; then
        set -x  # 开启 shell 调试模式
    fi
    
    # 检查必要条件
    check_root
    check_commands
    
    # 创建配置目录
    create_config_dir
    
    # 处理定时更新相关选项
    if [ -n "$update_interval" ]; then
        setup_cron_job "$update_interval"
        if [ -z "$action" ]; then
            exit 0
        fi
    fi
    
    if [ "$disable_update" = true ]; then
        remove_cron_job
        if [ -z "$action" ]; then
            exit 0
        fi
    fi
    
    # 执行相应的操作
    case $action in
        add)
            if [ -z "$port" ]; then
                log_error "请指定端口号"
                show_help
                exit 1
            fi
            
            if [ "$test_mode" = false ]; then
                create_iptables_chain
            else
                log_info "[测试模式] 将创建 IPTABLES EDGEONE 链"
            fi
            
            log_info "正在获取 EdgeOne IP 列表..."
            local ip_list
            ip_list=$(get_edgeone_ips "$version" "$area")
            
            if [ $? -ne 0 ]; then
                log_error "获取 EdgeOne IP 列表失败"
                exit 1
            fi
            
            # 在测试模式下，只显示前10个 IP 地址
            if [ "$test_mode" = true ]; then
                local ip_count=$(echo "$ip_list" | grep -v '^$' | wc -l)
                log_info "[测试模式] 获取到 $ip_count 个 IP 地址/范围"
                log_info "[测试模式] 前10个 IP 地址示例:"
                echo "$ip_list" | head -n 10
                log_info "[测试模式] 将为端口 $port 应用 EdgeOne IP 白名单规则"
            else
                apply_edgeone_whitelist "$port" "$ip_list"
                save_iptables_rules
                
                # 更新配置
                add_protected_port "$port" "$version" "$area"
                
                # 如果没有设置定时更新间隔，使用默认值
                if [ -z "$update_interval" ] && [ "$disable_update" = false ]; then
                    read_config
                    if [ -z "$UPDATE_INTERVAL" ]; then
                        setup_cron_job "$DEFAULT_UPDATE_INTERVAL"
                    fi
                fi
            fi
            ;;
        delete)
            if [ -z "$port" ]; then
                log_error "请指定端口号"
                show_help
                exit 1
            fi
            
            if [ "$test_mode" = true ]; then
                log_info "[测试模式] 将删除端口 $port 的 EdgeOne 保护规则"
            else
                remove_edgeone_protection "$port"
                save_iptables_rules
                
                # 从配置中删除端口
                remove_protected_port "$port"
            fi
            ;;
        list)
            if [ "$test_mode" = true ]; then
                log_info "[测试模式] 将列出当前的 EdgeOne 保护规则"
            else
                list_edgeone_protection
                
                # 显示配置信息
                read_config
                echo
                log_info "配置信息:"
                echo "----------------------------------------"
                echo "受保护的端口: ${PROTECTED_PORTS:-无}"
                echo "IP 版本: ${IP_VERSION:-全部}"
                echo "区域: ${AREA:-global}"
                echo "更新间隔: ${UPDATE_INTERVAL:-$DEFAULT_UPDATE_INTERVAL} 天"
                if [ -n "$LAST_UPDATE" ]; then
                    echo "上次更新时间: $(format_timestamp $LAST_UPDATE)"
                    
                    # 计算下次更新时间
                    local next_update=$((LAST_UPDATE + UPDATE_INTERVAL * 86400))
                    echo "下次更新时间: $(format_timestamp $next_update)"
                fi
                echo "----------------------------------------"
            fi
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
    
    # 如果开启了调试模式，关闭它
    if [ "$debug" = true ]; then
        set +x  # 关闭 shell 调试模式
    fi
}

# 执行主函数
main "$@" 