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
    
    # Загружаем накопленную статистику
    TOTAL_STATS=""
    if [ -f "/opt/telemt/stats_total.json" ]; then
        TOTAL_STATS=$(cat /opt/telemt/stats_total.json)
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
        active_ips=$(echo "$user_data" | jq -r '.active_unique_ips')
        active_ips_list=$(echo "$user_data" | jq -r '.active_unique_ips_list[]?' 2>/dev/null)
        current_traffic=$(echo "$user_data" | jq -r '.total_octets')
        
        # Получаем накопленный трафик
        total_traffic=$current_traffic
        if [ -n "$TOTAL_STATS" ]; then
            saved_traffic=$(echo "$TOTAL_STATS" | jq -r ".data[] | select(.username == \"$username\") | .total_octets" 2>/dev/null)
            if [ -n "$saved_traffic" ] && [ "$saved_traffic" != "null" ]; then
                total_traffic=$saved_traffic
            fi
        fi
        
        # Показываем статистику
        echo -e "${YELLOW}Статистика:${NC}"
        echo "  • Активные IP адреса: $active_ips"
        
        # Показываем список IP если есть
        if [ -n "$active_ips_list" ]; then
            echo "$active_ips_list" | while read -r ip; do
                echo "    - $ip"
            done
        fi
        
        # Показываем трафик за текущую сессию
        if [ "$current_traffic" != "null" ] && [ "$current_traffic" -gt 0 ]; then
            if [ "$current_traffic" -lt 1048576 ]; then
                traffic_kb=$(echo "scale=2; $current_traffic / 1024" | bc 2>/dev/null || echo "0")
                echo "  • Трафик (текущая сессия): ${traffic_kb} KB"
            elif [ "$current_traffic" -lt 1073741824 ]; then
                traffic_mb=$(echo "scale=2; $current_traffic / 1024 / 1024" | bc 2>/dev/null || echo "0")
                echo "  • Трафик (текущая сессия): ${traffic_mb} MB"
            else
                traffic_gb=$(echo "scale=2; $current_traffic / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
                echo "  • Трафик (текущая сессия): ${traffic_gb} GB"
            fi
        else
            echo "  • Трафик (текущая сессия): 0 KB"
        fi
        
        # Показываем общий накопленный трафик
        if [ "$total_traffic" != "null" ] && [ "$total_traffic" -gt 0 ]; then
            if [ "$total_traffic" -lt 1048576 ]; then
                total_kb=$(echo "scale=2; $total_traffic / 1024" | bc 2>/dev/null || echo "0")
                echo -e "  • ${CYAN}Общий трафик (всего): ${total_kb} KB${NC}"
            elif [ "$total_traffic" -lt 1073741824 ]; then
                total_mb=$(echo "scale=2; $total_traffic / 1024 / 1024" | bc 2>/dev/null || echo "0")
                echo -e "  • ${CYAN}Общий трафик (всего): ${total_mb} MB${NC}"
            else
                total_gb=$(echo "scale=2; $total_traffic / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
                echo -e "  • ${CYAN}Общий трафик (всего): ${total_gb} GB${NC}"
            fi
        else
            echo -e "  • ${CYAN}Общий трафик (всего): 0 KB${NC}"
        fi
        echo ""
        
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
        # Сохраняем статистику перед перезапуском
        if [ -f "/opt/telemt/save_stats.sh" ]; then
            print_message "Сохраняем статистику перед перезапуском..."
            /opt/telemt/save_stats.sh
        fi
        
        systemctl restart telemt
        sleep 2
        if systemctl is-active --quiet telemt; then
            print_message "Telemt успешно перезапущен!"
            echo ""
            print_warning "Важно!"
            echo "  • Все старые ссылки больше не работают"
            echo "  • Получите новые ссылки через пункт 5"
        else
            print_error "Ошибка при перезапуске Telemt"
            systemctl status telemt
        fi
    fi
}

# Функция для установки лимита IP на пользователя
set_ip_limit() {
    echo ""
    list_users
    echo ""
    read -p "Введите имя пользователя для установки лимита IP: " username
    
    if ! grep -q "^$username:" "$USERS_FILE"; then
        print_error "Пользователь не найден"
        return 1
    fi
    
    # Получаем текущий лимит если есть
    current_limit=$(grep "^$username = " "$CONFIG_FILE" | grep -o 'max_unique_ips = [0-9]*' | awk '{print $3}')
    
    if [ -z "$current_limit" ]; then
        echo -e "${YELLOW}Текущий лимит:${NC} не установлен (без ограничений)"
    else
        echo -e "${YELLOW}Текущий лимит:${NC} $current_limit IP"
    fi
    
    echo ""
    echo "Примеры лимитов:"
    echo "  1 - только одно устройство (один IP)"
    echo "  2 - два устройства (например, телефон + компьютер)"
    echo "  3 - три устройства"
    echo "  0 - без ограничений (убрать лимит)"
    echo ""
    
    read -p "Введите максимальное количество уникальных IP (0 = без лимита): " ip_limit
    
    if ! [[ "$ip_limit" =~ ^[0-9]+$ ]]; then
        print_error "Неверное значение"
        return 1
    fi
    
    # Получаем секрет пользователя
    user_secret=$(grep "^$username:" "$USERS_FILE" | cut -d':' -f2)
    
    if [ "$ip_limit" -eq 0 ]; then
        # Убираем лимит - оставляем только username и secret
        sed -i "s/^$username = .*/$username = \"$user_secret\"/" "$CONFIG_FILE"
        print_message "Лимит IP для пользователя $username снят"
    else
        # Устанавливаем лимит
        sed -i "s/^$username = .*/$username = { secret = \"$user_secret\", max_unique_ips = $ip_limit }/" "$CONFIG_FILE"
        print_message "Лимит IP для пользователя $username установлен: $ip_limit"
    fi
    
    echo ""
    read -p "Перезапустить Telemt для применения изменений? (y/n): " restart
    if [ "$restart" = "y" ]; then
        # Сохраняем статистику перед перезапуском
        if [ -f "/opt/telemt/save_stats.sh" ]; then
            print_message "Сохраняем статистику перед перезапуском..."
            /opt/telemt/save_stats.sh
        fi
        
        systemctl restart telemt
        print_message "Telemt перезапущен"
    fi
}

# Функция для установки лимита IP на пользователя
set_ip_limit() {
    echo ""
    list_users
    echo ""
    read -p "Введите имя пользователя для установки лимита IP: " username
    
    if ! grep -q "^$username:" "$USERS_FILE"; then
        print_error "Пользователь не найден"
        return 1
    fi
    
    # Получаем текущий лимит если есть
    current_limit=$(grep "^$username = " "$CONFIG_FILE" | grep -o 'max_unique_ips = [0-9]*' | awk '{print $3}')
    
    if [ -z "$current_limit" ]; then
        echo -e "${YELLOW}Текущий лимит:${NC} не установлен (без ограничений)"
    else
        echo -e "${YELLOW}Текущий лимит:${NC} $current_limit IP"
    fi
    
    echo ""
    echo "Примеры лимитов:"
    echo "  1 - только одно устройство (один IP)"
    echo "  2 - два устройства (например, телефон + компьютер)"
    echo "  3 - три устройства"
    echo "  0 - без ограничений (убрать лимит)"
    echo ""
    
    read -p "Введите максимальное количество уникальных IP (0 = без лимита): " ip_limit
    
    if ! [[ "$ip_limit" =~ ^[0-9]+$ ]]; then
        print_error "Неверное значение"
        return 1
    fi
    
    # Получаем секрет пользователя
    user_secret=$(grep "^$username:" "$USERS_FILE" | cut -d':' -f2)
    
    if [ "$ip_limit" -eq 0 ]; then
        # Убираем лимит - оставляем только username и secret
        sed -i "s/^$username = .*/$username = \"$user_secret\"/" "$CONFIG_FILE"
        print_message "Лимит IP для пользователя $username снят"
    else
        # Устанавливаем лимит
        sed -i "s/^$username = .*/$username = { secret = \"$user_secret\", max_unique_ips = $ip_limit }/" "$CONFIG_FILE"
        print_message "Лимит IP для пользователя $username установлен: $ip_limit"
    fi
    
    echo ""
    read -p "Перезапустить Telemt для применения изменений? (y/n): " restart
    if [ "$restart" = "y" ]; then
        # Сохраняем статистику перед перезапуском
        if [ -f "/opt/telemt/save_stats.sh" ]; then
            print_message "Сохраняем статистику перед перезапуском..."
            /opt/telemt/save_stats.sh
        fi
        
        systemctl restart telemt
        print_message "Telemt перезапущен"
    fi
}

# Функция полного удаления Telemt
uninstall_telemt() {
    clear
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}      ПОЛНОЕ УДАЛЕНИЕ TELEMT           ${RED}║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}ВНИМАНИЕ! Это действие удалит:${NC}"
    echo "  • Службу Telemt (systemd)"
    echo "  • Бинарный файл /bin/telemt"
    echo "  • Конфигурацию /etc/telemt/"
    echo "  • Пользователя telemt"
    echo "  • Рабочую директорию /opt/telemt/"
    echo ""
    echo -e "${CYAN}НЕ будет удалено (можно удалить вручную):${NC}"
    echo "  • Статистика /opt/telemt/stats_total.json"
    echo "  • Бэкапы /opt/telemt/stats_backups/"
    echo ""
    
    read -p "Вы уверены? Введите 'yes' для подтверждения: " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_message "Удаление отменено"
        return 0
    fi
    
    echo ""
    print_step "Удаление Telemt"
    
    # Останавливаем и отключаем службу
    if systemctl is-active --quiet telemt; then
        print_message "Останавливаем службу Telemt..."
        systemctl stop telemt
    fi
    
    if systemctl is-enabled --quiet telemt 2>/dev/null; then
        print_message "Отключаем автозапуск..."
        systemctl disable telemt
    fi
    
    # Удаляем службу systemd
    if [ -f "/etc/systemd/system/telemt.service" ]; then
        print_message "Удаляем службу systemd..."
        rm -f /etc/systemd/system/telemt.service
        systemctl daemon-reload
    fi
    
    # Удаляем бинарный файл
    if [ -f "/bin/telemt" ]; then
        print_message "Удаляем бинарный файл..."
        rm -f /bin/telemt
    fi
    
    # Удаляем конфигурацию
    if [ -d "/etc/telemt" ]; then
        print_message "Удаляем конфигурацию..."
        rm -rf /etc/telemt
    fi
    
    # Удаляем системного пользователя
    if id "telemt" &>/dev/null; then
        print_message "Удаляем пользователя telemt..."
        userdel telemt 2>/dev/null
    fi
    
    # Спрашиваем про директорию с данными
    echo ""
    read -p "Удалить рабочую директорию /opt/telemt/ (включая статистику)? (y/n): " delete_data
    
    if [ "$delete_data" = "y" ]; then
        if [ -d "/opt/telemt" ]; then
            print_message "Удаляем /opt/telemt/..."
            rm -rf /opt/telemt
        fi
    else
        print_warning "Директория /opt/telemt/ сохранена"
        if [ -f "/opt/telemt/stats_total.json" ]; then
            echo "  • Статистика: /opt/telemt/stats_total.json"
        fi
        if [ -d "/opt/telemt/stats_backups" ]; then
            backup_count=$(ls /opt/telemt/stats_backups/*.json 2>/dev/null | wc -l)
            echo "  • Бэкапы ($backup_count): /opt/telemt/stats_backups/"
        fi
    fi
    
    echo ""
    print_message "${GREEN}Telemt успешно удален!${NC}"
    echo ""
    
    read -p "Нажмите Enter для выхода..."
    exit 0
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
        echo "7) Установить лимит IP для пользователя"
        echo "8) Управление накопленной статистикой"
        echo "9) Перезапустить Telemt"
        echo ""
        echo -e "${RED}99) Полностью удалить Telemt${NC}"
        echo ""
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
                    # Сохраняем статистику перед перезапуском
                    if [ -f "/opt/telemt/save_stats.sh" ]; then
                        print_message "Сохраняем статистику перед перезапуском..."
                        /opt/telemt/save_stats.sh
                    fi
                    
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
                    
                    # Сохраняем статистику перед перезапуском
                    if [ -f "/opt/telemt/save_stats.sh" ]; then
                        print_message "Сохраняем статистику перед перезапуском..."
                        /opt/telemt/save_stats.sh
                    fi
                    
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
                    
                    # Сохраняем статистику перед перезапуском
                    if [ -f "/opt/telemt/save_stats.sh" ]; then
                        print_message "Сохраняем статистику перед перезапуском..."
                        /opt/telemt/save_stats.sh
                    fi
                    
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
                        
                        # Сохраняем статистику перед перезапуском
                        if [ -f "/opt/telemt/save_stats.sh" ]; then
                            print_message "Сохраняем статистику перед перезапуском..."
                            /opt/telemt/save_stats.sh
                        fi
                        
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
                set_ip_limit
                read -p "Нажмите Enter для продолжения..."
                ;;
            8)
                while true; do
                    clear
                    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
                    echo -e "${BLUE}║${NC}   Управление накопленной статистикой  ${BLUE}║${NC}"
                    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
                    echo ""
                    
                    if [ -f "/opt/telemt/stats_total.json" ]; then
                        echo -e "${CYAN}Накопленная статистика по пользователям:${NC}"
                        echo "════════════════════════════════════════════════════════════════"
                        
                        TOTAL_DATA=$(cat /opt/telemt/stats_total.json)
                        
                        echo "$TOTAL_DATA" | jq -r '.data[]? | @json' 2>/dev/null | while read -r user_data; do
                            username=$(echo "$user_data" | jq -r '.username')
                            total_traffic=$(echo "$user_data" | jq -r '.total_octets')
                            
                            echo -e "\n${GREEN}Пользователь: $username${NC}"
                            
                            if [ "$total_traffic" != "null" ] && [ "$total_traffic" -gt 0 ]; then
                                if [ "$total_traffic" -lt 1048576 ]; then
                                    traffic_kb=$(echo "scale=2; $total_traffic / 1024" | bc 2>/dev/null || echo "0")
                                    echo "  Всего трафика: ${traffic_kb} KB"
                                elif [ "$total_traffic" -lt 1073741824 ]; then
                                    traffic_mb=$(echo "scale=2; $total_traffic / 1024 / 1024" | bc 2>/dev/null || echo "0")
                                    echo "  Всего трафика: ${traffic_mb} MB"
                                else
                                    traffic_gb=$(echo "scale=2; $total_traffic / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
                                    echo "  Всего трафика: ${traffic_gb} GB"
                                fi
                            else
                                echo "  Всего трафика: 0 KB"
                            fi
                        done
                        
                        echo -e "\n════════════════════════════════════════════════════════════════"
                    else
                        print_warning "Накопленная статистика не найдена"
                    fi
                    
                    echo ""
                    
                    # Показываем доступные бэкапы
                    if [ -d "/opt/telemt/stats_backups" ]; then
                        backup_count=$(ls /opt/telemt/stats_backups/stats_*.json 2>/dev/null | wc -l)
                        if [ "$backup_count" -gt 0 ]; then
                            echo -e "${YELLOW}Доступно бэкапов: $backup_count${NC}"
                        fi
                    fi
                    
                    echo ""
                    echo -e "${CYAN}Действия:${NC}"
                    echo "1) Показать последние бэкапы"
                    echo "2) Сбросить накопленную статистику"
                    echo "3) Сохранить текущую статистику вручную"
                    echo "0) Назад"
                    echo ""
                    read -p "Ваш выбор: " stats_choice
                    
                    case $stats_choice in
                        1)
                            echo ""
                            if [ -d "/opt/telemt/stats_backups" ]; then
                                echo -e "${CYAN}Последние 10 бэкапов:${NC}"
                                ls -lht /opt/telemt/stats_backups/stats_*.json 2>/dev/null | head -10 | awk '{print $9, "("$6, $7, $8")"}'
                            else
                                print_warning "Директория бэкапов не найдена"
                            fi
                            read -p "Нажмите Enter для продолжения..."
                            ;;
                        2)
                            echo ""
                            read -p "Вы уверены, что хотите сбросить всю накопленную статистику? (yes/no): " confirm
                            if [ "$confirm" = "yes" ]; then
                                # Создаем финальный бэкап перед сбросом
                                if [ -f "/opt/telemt/stats_total.json" ]; then
                                    mkdir -p /opt/telemt/stats_backups
                                    cp /opt/telemt/stats_total.json "/opt/telemt/stats_backups/stats_before_reset_$(date +%Y%m%d_%H%M%S).json"
                                fi
                                
                                rm -f /opt/telemt/stats_total.json
                                print_message "Накопленная статистика сброшена"
                                print_message "Бэкап сохранен в /opt/telemt/stats_backups/"
                            else
                                print_message "Отмена"
                            fi
                            read -p "Нажмите Enter для продолжения..."
                            ;;
                        3)
                            # Проверяем существует ли скрипт, если нет - создаем
                            if [ ! -f "/opt/telemt/save_stats.sh" ]; then
                                cat > /opt/telemt/save_stats.sh <<'STATS_EOF'
#!/bin/bash

STATS_FILE="/opt/telemt/stats_total.json"
CURRENT_STATS=$(curl -s http://127.0.0.1:9091/v1/users 2>/dev/null)

if [ -z "$CURRENT_STATS" ]; then
    exit 0
fi

# Проверяем, есть ли файл со старой статистикой
if [ ! -f "$STATS_FILE" ]; then
    # Создаем новый файл
    echo "$CURRENT_STATS" > "$STATS_FILE"
else
    # Суммируем статистику
    OLD_STATS=$(cat "$STATS_FILE")
    
    # Создаем временный Python скрипт для суммирования
    python3 <<PYTHON_EOF
import json
import sys

try:
    old = json.loads('''$OLD_STATS''')
    current = json.loads('''$CURRENT_STATS''')
    
    # Создаем словарь со старой статистикой по пользователям
    old_users = {}
    if 'data' in old and old['data']:
        for user in old['data']:
            old_users[user['username']] = user.get('total_octets', 0)
    
    # Обновляем текущую статистику, добавляя старую
    if 'data' in current and current['data']:
        for user in current['data']:
            username = user['username']
            old_traffic = old_users.get(username, 0)
            current_traffic = user.get('total_octets', 0)
            user['total_octets'] = old_traffic + current_traffic
    
    print(json.dumps(current, indent=2))
except Exception as e:
    # В случае ошибки просто сохраняем текущую статистику
    print('''$CURRENT_STATS''')
PYTHON_EOF
fi > "$STATS_FILE.tmp" && mv "$STATS_FILE.tmp" "$STATS_FILE"

# Также сохраняем бэкап с датой
BACKUP_DIR="/opt/telemt/stats_backups"
mkdir -p "$BACKUP_DIR"
cp "$STATS_FILE" "$BACKUP_DIR/stats_$(date +%Y%m%d_%H%M%S).json" 2>/dev/null

# Удаляем старые бэкапы (оставляем последние 30)
ls -t "$BACKUP_DIR"/stats_*.json 2>/dev/null | tail -n +31 | xargs -r rm
STATS_EOF
                                chmod +x /opt/telemt/save_stats.sh
                                chown telemt:telemt /opt/telemt/save_stats.sh 2>/dev/null
                            fi
                            
                            /opt/telemt/save_stats.sh
                            if [ $? -eq 0 ]; then
                                print_message "Статистика успешно сохранена"
                            else
                                print_error "Ошибка при сохранении статистики"
                            fi
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
                ;;
            9)
                # Сохраняем статистику перед перезапуском
                if [ -f "/opt/telemt/save_stats.sh" ]; then
                    print_message "Сохраняем статистику перед перезапуском..."
                    /opt/telemt/save_stats.sh
                fi
                
                systemctl restart telemt
                print_message "Telemt перезапущен"
                read -p "Нажмите Enter для продолжения..."
                ;;
            99)
                uninstall_telemt
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

# Создаем скрипт для сохранения и накопления статистики
cat > /opt/telemt/save_stats.sh <<'STATS_EOF'
#!/bin/bash

STATS_FILE="/opt/telemt/stats_total.json"
CURRENT_STATS=$(curl -s http://127.0.0.1:9091/v1/users 2>/dev/null)

if [ -z "$CURRENT_STATS" ]; then
    exit 0
fi

# Проверяем, есть ли файл со старой статистикой
if [ ! -f "$STATS_FILE" ]; then
    # Создаем новый файл
    echo "$CURRENT_STATS" > "$STATS_FILE"
else
    # Суммируем статистику
    OLD_STATS=$(cat "$STATS_FILE")
    
    # Создаем временный Python скрипт для суммирования
    python3 <<PYTHON_EOF
import json
import sys

try:
    old = json.loads('''$OLD_STATS''')
    current = json.loads('''$CURRENT_STATS''')
    
    # Создаем словарь со старой статистикой по пользователям
    old_users = {}
    if 'data' in old and old['data']:
        for user in old['data']:
            old_users[user['username']] = user.get('total_octets', 0)
    
    # Обновляем текущую статистику, добавляя старую
    if 'data' in current and current['data']:
        for user in current['data']:
            username = user['username']
            old_traffic = old_users.get(username, 0)
            current_traffic = user.get('total_octets', 0)
            user['total_octets'] = old_traffic + current_traffic
    
    print(json.dumps(current, indent=2))
except Exception as e:
    # В случае ошибки просто сохраняем текущую статистику
    print('''$CURRENT_STATS''')
PYTHON_EOF
fi > "$STATS_FILE.tmp" && mv "$STATS_FILE.tmp" "$STATS_FILE"

# Также сохраняем бэкап с датой
BACKUP_DIR="/opt/telemt/stats_backups"
mkdir -p "$BACKUP_DIR"
cp "$STATS_FILE" "$BACKUP_DIR/stats_$(date +%Y%m%d_%H%M%S).json" 2>/dev/null

# Удаляем старые бэкапы (оставляем последние 30)
ls -t "$BACKUP_DIR"/stats_*.json 2>/dev/null | tail -n +31 | xargs -r rm
STATS_EOF

chmod +x /opt/telemt/save_stats.sh
chown telemt:telemt /opt/telemt/save_stats.sh

# Создаем директорию для бэкапов
mkdir -p /opt/telemt/stats_backups
chown -R telemt:telemt /opt/telemt

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
ExecStop=/opt/telemt/save_stats.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

print_message "Systemd служба создана"
print_message "Накопительная статистика: /opt/telemt/stats_total.json"
print_message "Бэкапы статистики: /opt/telemt/stats_backups/"

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
