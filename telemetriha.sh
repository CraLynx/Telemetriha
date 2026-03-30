#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Файл конфигурации
CONFIG_FILE="/etc/telemt/telemt.toml"
USERS_FILE="/etc/telemt/users.list"

# Функция для вывода сообщений
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_step() {
    echo -e "\n${BLUE}===${NC} $1 ${BLUE}===${NC}\n"
}

# Функция для генерации секрета
generate_secret() {
    openssl rand -hex 16
}

# Функция для добавления пользователя в конфиг
add_user_to_config() {
    local username=$1
    local secret=$2
    
    # Проверяем, существует ли уже пользователь
    if grep -q "^$username = " "$CONFIG_FILE"; then
        print_warning "Пользователь $username уже существует в конфигурации"
        return 1
    fi
    
    # Добавляем пользователя в секцию [access.users]
    sed -i "/\[access\.users\]/a $username = \"$secret\"" "$CONFIG_FILE"
    
    # Сохраняем в список пользователей
    echo "$username:$secret:active" >> "$USERS_FILE"
    
    print_message "Пользователь $username добавлен"
}

# Функция для отключения пользователя
disable_user() {
    local username=$1
    
    # Комментируем строку в конфиге
    sed -i "s/^$username = /#$username = /" "$CONFIG_FILE"
    
    # Обновляем статус в списке пользователей
    sed -i "s/^$username:\(.*\):active/$username:\1:disabled/" "$USERS_FILE"
    
    print_message "Пользователь $username отключен"
}

# Функция для включения пользователя
enable_user() {
    local username=$1
    
    # Раскомментируем строку в конфиге
    sed -i "s/^#$username = /$username = /" "$CONFIG_FILE"
    
    # Обновляем статус в списке пользователей
    sed -i "s/^$username:\(.*\):disabled/$username:\1:active/" "$USERS_FILE"
    
    print_message "Пользователь $username включен"
}

# Функция для удаления пользователя
delete_user() {
    local username=$1
    
    # Удаляем из конфига
    sed -i "/^#\?$username = /d" "$CONFIG_FILE"
    
    # Удаляем из списка пользователей
    sed -i "/^$username:/d" "$USERS_FILE"
    
    print_message "Пользователь $username удален"
}

# Функция для отображения списка пользователей
list_users() {
    if [ ! -f "$USERS_FILE" ]; then
        print_warning "Список пользователей пуст"
        return
    fi
    
    echo -e "\n${CYAN}Список пользователей:${NC}"
    echo "─────────────────────────────────────────────────────────"
    printf "%-20s %-40s %-10s\n" "Имя" "Секрет" "Статус"
    echo "─────────────────────────────────────────────────────────"
    
    while IFS=: read -r user secret status; do
        if [ "$status" = "active" ]; then
            printf "${GREEN}%-20s${NC} %-40s ${GREEN}%-10s${NC}\n" "$user" "$secret" "активен"
        else
            printf "${RED}%-20s${NC} %-40s ${RED}%-10s${NC}\n" "$user" "$secret" "отключен"
        fi
    done < "$USERS_FILE"
    
    echo "─────────────────────────────────────────────────────────"
}

# Функция для получения ссылок пользователей
get_user_links() {
    print_message "Получаем ссылки для пользователей..."
    sleep 1
    
    RESPONSE=$(curl -s http://127.0.0.1:9091/v1/users 2>/dev/null)
    
    if [ -z "$RESPONSE" ]; then
        print_warning "Не удалось получить ответ от API"
        print_message "Убедитесь, что служба Telemt запущена"
        return 1
    fi
    
    # Проверяем успешность ответа
    OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
    if [ "$OK" != "true" ]; then
        print_error "API вернул ошибку"
        echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
    
    echo -e "\n${CYAN}Ссылки для подключения:${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    # Извлекаем данные пользователей
    echo "$RESPONSE" | jq -r '.data[] | @json' | while read -r user_data; do
        username=$(echo "$user_data" | jq -r '.username')
        
        # Проверяем статус пользователя
        if ! grep -q "^$username:.*:active" "$USERS_FILE" 2>/dev/null; then
            continue
        fi
        
        echo -e "\n${GREEN}━━━ Пользователь: $username ━━━${NC}"
        
        # Статистика
        current_conns=$(echo "$user_data" | jq -r '.current_connections')
        active_ips=$(echo "$user_data" | jq -r '.active_unique_ips')
        total_traffic=$(echo "$user_data" | jq -r '.total_octets')
        
        # Конвертируем трафик в читаемый формат
        if [ "$total_traffic" != "null" ] && [ "$total_traffic" -gt 0 ]; then
            traffic_gb=$(echo "scale=2; $total_traffic / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
            echo -e "${YELLOW}Статистика:${NC}"
            #echo "  • Активных подключений (устройств): $current_conns"
            echo "  • Активные IP адреса: $active_ips"
            echo "  • Общий трафик: ${traffic_gb} GB"
            echo ""
        fi
        
        # TLS ссылки (только IPv4, без IPv6)
        tls_links=$(echo "$user_data" | jq -r '.links.tls[]?' 2>/dev/null | grep -v '::')
        if [ -n "$tls_links" ]; then
            echo -e "${BLUE}Ссылка для подключения:${NC}"
            echo "$tls_links" | while read -r link; do
                echo -e "  ${GREEN}$link${NC}"
            done
        fi
        
        # Secure ссылки
        secure_links=$(echo "$user_data" | jq -r '.links.secure[]?' 2>/dev/null | grep -v '::')
        if [ -n "$secure_links" ]; then
            echo -e "\n${BLUE}Secure ссылка:${NC}"
            echo "$secure_links" | while read -r link; do
                echo -e "  ${GREEN}$link${NC}"
            done
        fi
        
        # Classic ссылки
        classic_links=$(echo "$user_data" | jq -r '.links.classic[]?' 2>/dev/null | grep -v '::')
        if [ -n "$classic_links" ]; then
            echo -e "\n${BLUE}Classic ссылка:${NC}"
            echo "$classic_links" | while read -r link; do
                echo -e "  ${GREEN}$link${NC}"
            done
        fi
    done
    
    echo -e "\n════════════════════════════════════════════════════════════════"
}

# Функция для смены TLS домена
change_tls_domain() {
    echo ""
    echo -e "${CYAN}Текущий TLS домен:${NC}"
    current_domain=$(grep '^tls_domain = ' "$CONFIG_FILE" | sed 's/tls_domain = "\(.*\)"/\1/')
    echo "  $current_domain"
    echo ""
    
    echo "Примеры TLS доменов для маскировки:"
    echo "  - petrovich.ru"
    echo "  - www.google.com"
    echo "  - www.microsoft.com"
    echo "  - www.cloudflare.com"
    echo "  - www.bing.com"
    echo ""
    
    read -p "Введите новый TLS домен: " new_domain
    
    if [ -z "$new_domain" ]; then
        print_error "Домен не может быть пустым"
        return 1
    fi
    
    # Заменяем домен в конфиге
    sed -i "s/^tls_domain = .*/tls_domain = \"$new_domain\"/" "$CONFIG_FILE"
    
    print_message "TLS домен изменен на: $new_domain"
    echo ""
    read -p "Перезапустить Telemt для применения изменений? (y/n): " restart
    if [ "$restart" = "y" ]; then
        systemctl restart telemt
        sleep 2
        if systemctl is-active --quiet telemt; then
            print_message "Telemt успешно перезапущен!"
            echo ""
            print_warning "Важно: все старые ссылки больше не работают!"
            print_message "Получите новые ссылки через пункт 5"
        else
            print_error "Ошибка при перезапуске Telemt"
            systemctl status telemt
        fi
    fi
}

# Функция управления пользователями
manage_users() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}   Управление пользователями Telemt    ${BLUE}║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
        echo ""
        
        list_users
        
        echo -e "\n${CYAN}Выберите действие:${NC}"
        echo "1) Добавить нового пользователя"
        echo "2) Отключить пользователя"
        echo "3) Включить пользователя"
        echo "4) Удалить пользователя"
        echo "5) Показать ссылки и статистику"
        echo "6) Изменить TLS домен"
        echo "7) Перезапустить Telemt"
        echo "0) Выход"
        echo ""
        read -p "Ваш выбор: " choice
        
        case $choice in
            1)
                echo ""
                read -p "Введите имя нового пользователя: " new_username
                if [ -z "$new_username" ]; then
                    print_error "Имя пользователя не может быть пустым"
                    read -p "Нажмите Enter для продолжения..."
                    continue
                fi
                
                new_secret=$(generate_secret)
                add_user_to_config "$new_username" "$new_secret"
                
                echo ""
                print_message "Пользователь создан:"
                echo "  Имя: $new_username"
                echo "  Секрет: $new_secret"
                echo ""
                read -p "Перезапустить Telemt для применения изменений? (y/n): " restart
                if [ "$restart" = "y" ]; then
                    systemctl restart telemt
                    print_message "Telemt перезапущен"
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            2)
                echo ""
                read -p "Введите имя пользователя для отключения: " disable_username
                if grep -q "^$disable_username:.*:active" "$USERS_FILE"; then
                    disable_user "$disable_username"
                    systemctl restart telemt
                    print_message "Telemt перезапущен"
                else
                    print_error "Пользователь не найден или уже отключен"
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            3)
                echo ""
                read -p "Введите имя пользователя для включения: " enable_username
                if grep -q "^$enable_username:.*:disabled" "$USERS_FILE"; then
                    enable_user "$enable_username"
                    systemctl restart telemt
                    print_message "Telemt перезапущен"
                else
                    print_error "Пользователь не найден или уже активен"
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            4)
                echo ""
                read -p "Введите имя пользователя для удаления: " delete_username
                if grep -q "^$delete_username:" "$USERS_FILE"; then
                    read -p "Вы уверены, что хотите удалить пользователя $delete_username? (y/n): " confirm
                    if [ "$confirm" = "y" ]; then
                        delete_user "$delete_username"
                        systemctl restart telemt
                        print_message "Telemt перезапущен"
                    fi
                else
                    print_error "Пользователь не найден"
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            5)
                echo ""
                get_user_links
                read -p "Нажмите Enter для продолжения..."
                ;;
            6)
                change_tls_domain
                read -p "Нажмите Enter для продолжения..."
                ;;
            7)
                systemctl restart telemt
                print_message "Telemt перезапущен"
                read -p "Нажмите Enter для продолжения..."
                ;;
            0)
                break
                ;;
            *)
                print_error "Неверный выбор"
                read -p "Нажмите Enter для продолжения..."
                ;;
        esac
    done
}

# Проверка запуска от root
if [ "$EUID" -ne 0 ]; then 
    print_error "Пожалуйста, запустите скрипт от имени root или с помощью sudo"
    exit 1
fi

# Проверяем, установлен ли уже Telemt
if [ -f "$CONFIG_FILE" ] && [ -f "/etc/systemd/system/telemt.service" ]; then
    # Telemt уже установлен, предлагаем управление
    clear
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}        Telemt уже установлен!          ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "1) Управление пользователями"
    echo "2) Переустановить Telemt"
    echo "0) Выход"
    echo ""
    read -p "Ваш выбор: " main_choice
    
    case $main_choice in
        1)
            manage_users
            exit 0
            ;;
        2)
            print_warning "Начинаем переустановку..."
            ;;
        0)
            exit 0
            ;;
        *)
            print_error "Неверный выбор"
            exit 1
            ;;
    esac
fi

# Приветствие
clear
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}  Установка Telemt через Systemd      ${BLUE}║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# Шаг 1: Скачивание Telemt
print_step "Шаг 1: Скачивание Telemt"

if [ -f "/bin/telemt" ]; then
    print_warning "Telemt уже установлен в /bin/telemt"
    read -p "Хотите переустановить? (y/n): " reinstall
    if [ "$reinstall" != "y" ]; then
        print_message "Пропускаем установку бинарного файла"
    else
        print_message "Скачиваем последнюю версию Telemt..."
        wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-$(uname -m)-linux-$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu).tar.gz" | tar -xz
        
        if [ ! -f "telemt" ]; then
            print_error "Ошибка при скачивании Telemt"
            exit 1
        fi
        
        mv telemt /bin/
        chmod +x /bin/telemt
        print_message "Telemt успешно установлен"
    fi
else
    print_message "Скачиваем последнюю версию Telemt..."
    wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-$(uname -m)-linux-$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu).tar.gz" | tar -xz
    
    if [ ! -f "telemt" ]; then
        print_error "Ошибка при скачивании Telemt"
        exit 1
    fi
    
    mv telemt /bin/
    chmod +x /bin/telemt
    print_message "Telemt успешно установлен"
fi

# Шаг 2: Выбор порта
print_step "Шаг 2: Выбор порта"

print_message "Список занятых портов:"
netstat -lnp 2>/dev/null | grep LISTEN || ss -lnp | grep LISTEN

echo ""
read -p "Введите порт для Telemt (по умолчанию 443): " PORT
PORT=${PORT:-443}

# Проверка, занят ли порт
if netstat -lnp 2>/dev/null | grep -q ":$PORT " || ss -lnp 2>/dev/null | grep -q ":$PORT "; then
    print_warning "Порт $PORT уже используется!"
    read -p "Продолжить всё равно? (y/n): " continue_anyway
    if [ "$continue_anyway" != "y" ]; then
        print_error "Установка отменена"
        exit 1
    fi
else
    print_message "Порт $PORT свободен"
fi

# Шаг 3: Ввод TLS домена
print_step "Шаг 3: Настройка TLS домена"

echo "Примеры TLS доменов для маскировки:"
echo "  - petrovich.ru"
echo "  - www.google.com"
echo "  - www.microsoft.com"
echo "  - www.cloudflare.com"
echo ""

read -p "Введите TLS домен (по умолчанию petrovich.ru): " TLS_DOMAIN
TLS_DOMAIN=${TLS_DOMAIN:-petrovich.ru}

print_message "Используется TLS домен: $TLS_DOMAIN"

# Шаг 4: Создание пользователей
print_step "Шаг 4: Создание пользователей"

read -p "Сколько пользователей создать? (по умолчанию 1): " USER_COUNT
USER_COUNT=${USER_COUNT:-1}

# Проверка на число
if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [ "$USER_COUNT" -lt 1 ]; then
    print_error "Неверное количество пользователей"
    exit 1
fi

declare -a USERS
declare -a SECRETS

for ((i=1; i<=USER_COUNT; i++)); do
    echo ""
    read -p "Введите имя пользователя #$i (по умолчанию user$i): " username
    username=${username:-user$i}
    
    secret=$(generate_secret)
    
    USERS+=("$username")
    SECRETS+=("$secret")
    
    print_message "Пользователь $username создан с секретом: $secret"
done

# Шаг 5: Создание конфигурации
print_step "Шаг 5: Создание конфигурации"

mkdir -p /etc/telemt

cat > "$CONFIG_FILE" <<EOF
# === General Settings ===
[general]
# ad_tag = "00000000000000000000000000000000"
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = $PORT

[server.api]
enabled = true
# listen = "127.0.0.1:9091"
# whitelist = ["127.0.0.1/32"]
# read_only = true

# === Anti-Censorship & Masking ===
[censorship]
tls_domain = "$TLS_DOMAIN"

[access.users]
# format: "username" = "32_hex_chars_secret"
EOF

# Добавляем пользователей в конфиг
for ((i=0; i<${#USERS[@]}; i++)); do
    echo "${USERS[$i]} = \"${SECRETS[$i]}\"" >> "$CONFIG_FILE"
done

# Создаем файл со списком пользователей
> "$USERS_FILE"
for ((i=0; i<${#USERS[@]}; i++)); do
    echo "${USERS[$i]}:${SECRETS[$i]}:active" >> "$USERS_FILE"
done

print_message "Конфигурация создана в $CONFIG_FILE"

# Шаг 6: Создание пользователя
print_step "Шаг 6: Создание системного пользователя"

if id "telemt" &>/dev/null; then
    print_warning "Пользователь telemt уже существует"
else
    useradd -d /opt/telemt -m -r -U telemt
    print_message "Пользователь telemt создан"
fi

chown -R telemt:telemt /etc/telemt

# Шаг 7: Создание Systemd service
print_step "Шаг 7: Создание Systemd службы"

cat > /etc/systemd/system/telemt.service <<EOF
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

print_message "Systemd служба создана"

# Перезагрузка systemd
systemctl daemon-reload
print_message "Systemd конфигурация перезагружена"

# Шаг 8: Запуск службы
print_step "Шаг 8: Запуск и включение службы"

systemctl enable telemt
print_message "Автозапуск включен"

systemctl start telemt
sleep 2

if systemctl is-active --quiet telemt; then
    print_message "Telemt успешно запущен!"
else
    print_error "Ошибка при запуске Telemt"
    print_message "Проверьте статус: systemctl status telemt"
    exit 1
fi

# Шаг 9: Получение ссылок
print_step "Шаг 9: Получение ссылок для подключения"

sleep 2

get_user_links

# Итоговая информация
print_step "Установка завершена!"

echo -e "${GREEN}Конфигурация:${NC}"
echo "  • Порт: $PORT"
echo "  • TLS домен: $TLS_DOMAIN"
echo "  • Создано пользователей: $USER_COUNT"
echo ""

echo -e "${GREEN}Созданные пользователи:${NC}"
for ((i=0; i<${#USERS[@]}; i++)); do
    echo "  • ${USERS[$i]}: ${SECRETS[$i]}"
done

echo ""
echo -e "${GREEN}Полезные команды:${NC}"
echo "  • Управление пользователями: $0"
echo "  • Статус: systemctl status telemt"
echo "  • Логи: journalctl -u telemt -f"
echo "  • Перезапуск: systemctl restart telemt"
echo "  • Остановка: systemctl stop telemt"
echo "  • Получить ссылки: curl -s http://127.0.0.1:9091/v1/users | jq"
echo ""
echo -e "${YELLOW}Сохраните ссылки и секреты в безопасном месте!${NC}"
echo -e "${CYAN}Запустите скрипт снова для управления пользователями${NC}"
