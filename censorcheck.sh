#!/usr/bin/env bash

# -----------------------------------------
# Censor-check script
# Автор скрипта Nikola Tesla ©, по багам, вопросам пишите в ТГ https://t.me/tracerlab 
# Некоторые функции экспериментальные
# -----------------------------------------

TIMEOUT=4
RETRIES=2
MAX_PARALLEL=10
USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
IP_VERSION=4
PROXY=""
VERBOSE=false
DEBUG=false

# Ключ RIPE Atlas. Приоритет: --key > $RIPE_API_KEY из окружения > пусто.
# Свой ключ: https://atlas.ripe.net/keys/ (право "Create a new measurement")
RIPE_API_KEY="${RIPE_API_KEY:-}"
SNI_EXPLICIT=false         # true, если SNI задан флагом или переменной
if [[ -n "${CENSORCHECK_SNI:-}" ]]; then
  REALITY_SNI="$CENSORCHECK_SNI"
  SNI_EXPLICIT=true
else
  REALITY_SNI="max.ru"
fi
RADAR_TARGET=""            # по умолчанию — внешний IPv4 этой машины
RADAR_DEADLINE=240         # сек, сколько ждать результаты зондов
SKIP_LISTEN_CHECK=false
ASK_KEY=true               # спрашивать ключ, если он нигде не задан

usage() {
  cat <<'USAGE'
censorcheck.sh [опции]

  -v, --verbose            подробный вывод по доменам
  -d, --debug              debug-лог радара (RIPE Atlas)
  -k, --key <uuid>         ключ RIPE Atlas (или переменная RIPE_API_KEY)
  -s, --sni <hostname>     SNI для TLS-хендшейка зондов (иначе спросит, default max.ru)
  -t, --target <ip>        проверять чужой IP, а не свой (включает --no-listen-check)
      --timeout <sec>      ожидание результатов, по умолчанию 240
      --no-listen-check    не проверять, слушает ли кто-то :443 локально
      --no-prompt          ничего не спрашивать интерактивно: ни ключ, ни SNI (для cron)
  -h, --help               эта справка
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose)      VERBOSE=true; shift ;;
    -d|--debug)        DEBUG=true; shift ;;
    -k|--key)          RIPE_API_KEY="$2"; shift 2 ;;
    -s|--sni)          REALITY_SNI="$2"; SNI_EXPLICIT=true; shift 2 ;;
    -t|--target)       RADAR_TARGET="$2"; SKIP_LISTEN_CHECK=true; shift 2 ;;
    --timeout)         RADAR_DEADLINE="$2"; shift 2 ;;
    --no-listen-check) SKIP_LISTEN_CHECK=true; shift ;;
    --no-prompt)       ASK_KEY=false; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) shift ;;
  esac
done

DOMAINS=(
  "youtube.com"
  "instagram.com"
  "facebook.com"
  "x.com"
  "patreon.com"
  "linkedin.com"
  "signal.org"
  "tiktok.com"
  "api.telegram.org"
  "web.whatsapp.com"
  "discord.com"
  "viber.com"
  "chatgpt.com"
  "grok.com"
  "reddit.com"
  "twitch.tv"
  "netflix.com"
  "rutracker.org"
  "nnmclub.to"
  "digitalocean.com"
  "api.cloudflare.com"
  "speedtest.net"
  "aws.amazon.com"
  "ooni.org"
  "amnezia.org"
  "torproject.org"
  "proton.me"
  "github.com"
  "google.com"
)

AI_DOMAINS=(
  "chatgpt.com"
  "grok.com"
  "netflix.com"
)

RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
GREEN="\033[32m"
BLUE="\033[34m"
RESET="\033[0m"
ITALIC="\033[3m"
RED_ITALIC="\033[31;3m"
GREEN_ITALIC="\033[32;3m"
YELLOW_ITALIC="\033[33;3m"
BLUE_ITALIC="\033[34;3m"
DIM="\033[2;90m"

DOMAIN_WIDTH=22
LINE_SEP="----------------------------------------------------------------------"

# Чек на заглушки
RKN_STUB_IPS=(
  "195.208.4.1"    # Ростелеком
  "195.208.5.1"    # Ростелеком
  "188.186.157.35" # МТС
  "80.93.183.168"  # Билайн
  "213.87.154.141" # МТС
  "92.101.255.255" # Мегафон
)

# Провайдеры
declare -A ASN_NAMES=(
  [12389]="Ростелеком"
  [8402]="Билайн"
  [25513]="МГТС"
  [8359]="МТС"
  [3216]="Билайн"
  [20485]="ТТК"
  [25490]="РТК-Юг"
  [43727]="Мегафон"
  [12714]="Мегафон"
  [34757]="Sib Seti"
  [29124]="Iskratelecom"
  [12768]="Дом.ру"
)

is_rkn_spoof() {
  local ip="$1"
  for stub in "${RKN_STUB_IPS[@]}"; do
    [[ "$ip" == "$stub" ]] && return 0
  done
  return 1
}

install_missing_deps() {
  local deps=("curl" "nslookup" "nc" "openssl" "date" "awk" "python3")
  local missing=()

  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null; then
      missing+=("$dep")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    return 0
  fi

  echo "Missing dependencies: ${missing[*]}. Installing automatically..."

  local prefix=""
  if [ "$(id -u)" -eq 0 ]; then
    prefix=""
  elif command -v sudo >/dev/null 2>&1; then
    prefix="sudo "
  else
    echo "You are not root, and sudo is not available."
    exit 1
  fi

  local pkg_mgr=""
  local update_cmd=""
  local quiet_update_cmd=""
  local install_cmd=""
  local quiet_install_cmd=""
  local pkg_names=()

  if [ -f /etc/debian_version ] || grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
    pkg_mgr="apt"
    update_cmd="apt update -y"
    quiet_update_cmd="apt update -y -q"
    install_cmd="apt install -y"
    quiet_install_cmd="apt install -y -q"
    for dep in "${missing[@]}"; do
      case "$dep" in
        curl) pkg_names+=("curl") ;;
        nslookup) pkg_names+=("dnsutils") ;;
        nc) pkg_names+=("netcat-openbsd") ;;
        openssl) pkg_names+=("openssl") ;;
        date) pkg_names+=("coreutils") ;;
        awk) pkg_names+=("gawk") ;;
        python3) pkg_names+=("python3") ;;
      esac
    done
  elif [ -f /etc/fedora-release ] || grep -qi "fedora" /etc/os-release 2>/dev/null; then
    pkg_mgr="dnf"
    update_cmd="dnf check-update -y"
    quiet_update_cmd="dnf check-update -y --quiet"
    install_cmd="dnf install -y"
    quiet_install_cmd="dnf install -y --quiet"
    for dep in "${missing[@]}"; do
      case "$dep" in
        curl) pkg_names+=("curl") ;;
        nslookup) pkg_names+=("bind-utils") ;;
        nc) pkg_names+=("nc") ;;
        openssl) pkg_names+=("openssl") ;;
        date) pkg_names+=("coreutils") ;;
        awk) pkg_names+=("gawk") ;;
        python3) pkg_names+=("python3") ;;
      esac
    done
  elif [ -f /etc/centos-release ] || grep -qi "centos\|rhel" /etc/os-release 2>/dev/null; then
    if command -v dnf >/dev/null; then
      pkg_mgr="dnf"
      update_cmd="dnf check-update -y"
      quiet_update_cmd="dnf check-update -y --quiet"
      install_cmd="dnf install -y"
      quiet_install_cmd="dnf install -y --quiet"
    else
      pkg_mgr="yum"
      update_cmd="yum check-update -y"
      quiet_update_cmd="yum check-update -y --quiet"
      install_cmd="yum install -y"
      quiet_install_cmd="yum install -y --quiet"
    fi
    for dep in "${missing[@]}"; do
      case "$dep" in
        curl) pkg_names+=("curl") ;;
        nslookup) pkg_names+=("bind-utils") ;;
        nc) pkg_names+=("nc") ;;
        openssl) pkg_names+=("openssl") ;;
        date) pkg_names+=("coreutils") ;;
        awk) pkg_names+=("gawk") ;;
        python3) pkg_names+=("python3") ;;
      esac
    done
  elif [ -f /etc/arch-release ] || grep -qi "arch" /etc/os-release 2>/dev/null; then
    pkg_mgr="pacman"
    update_cmd="pacman -Sy --noconfirm"
    quiet_update_cmd="pacman -Sy --noconfirm -qq"
    install_cmd="pacman -S --noconfirm"
    quiet_install_cmd="pacman -S --noconfirm -qq"
    for dep in "${missing[@]}"; do
      case "$dep" in
        curl) pkg_names+=("curl") ;;
        nslookup) pkg_names+=("bind") ;;
        nc) pkg_names+=("openbsd-netcat") ;;
        openssl) pkg_names+=("openssl") ;;
        date) pkg_names+=("coreutils") ;;
        awk) pkg_names+=("gawk") ;;
        python3) pkg_names+=("python3") ;;
      esac
    done
  else
    echo "Unsupported distribution. Please install dependencies manually."
    exit 1
  fi

  ${prefix}${quiet_update_cmd} >/dev/null 2>&1
  for pkg in "${pkg_names[@]}"; do
    ${prefix}${quiet_install_cmd} "$pkg" >/dev/null 2>&1
  done
}

install_missing_deps

fetch_code() {
  local proxy_opt=""
  if [[ -n "$PROXY" ]]; then
    if [[ "$PROXY" == http://* ]]; then
      proxy_opt="--proxy $PROXY"
    else
      proxy_opt="--proxy socks5://$PROXY"
    fi
  fi

  curl -s -o /dev/null \
       --retry "$RETRIES" \
       --connect-timeout "$TIMEOUT" \
       --max-time "$TIMEOUT" \
       -$IP_VERSION \
       -A "$USER_AGENT" \
       $proxy_opt \
       -w "%{http_code}" \
       "$1"
}

check_keyword_blocking() {
  local domain="$1"
  local test_url="https://$domain"
  
  local dpi_response
  dpi_response=$(curl -s -A "Suspicious-Agent TLS/1.3" --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" "$test_url" 2>/dev/null)
  
  if echo "$dpi_response" | grep -qi "blocked\|forbidden\|access.denied\|roscomnadzor\|rkn\|firewall\|censorship\|prohibited\|restricted"; then
    return 0  
  fi
  
  local sni_code
  sni_code=$(curl -s -o /dev/null --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" --resolve "$domain:443:192.0.2.1" "$test_url" -w "%{http_code}" 2>/dev/null)
  
  if [[ "$sni_code" =~ [45][0-9][0-9] || "$sni_code" == "000" ]]; then
    return 0 
  fi
  
  return 1 
}

check_certificate() {
  local domain="$1"
  local cert_info
  cert_info=$(timeout "$TIMEOUT" openssl s_client -connect "$domain:443" -servername "$domain" -CApath /etc/ssl/certs -verify 5 < /dev/null 2>&1)
  
  if echo "$cert_info" | grep -q "Verification error:" || ! echo "$cert_info" | grep -q "Verification: OK"; then
    $VERBOSE && echo "TLS verification failed for $domain"
    return 1
  fi
  
  local not_after=$(echo "$cert_info" | openssl x509 -noout -dates 2>/dev/null | grep "notAfter" | cut -d= -f2)
  if [[ -n "$not_after" ]]; then
    local expire_epoch=$(date -d "$not_after" +%s 2>/dev/null)
    local current_epoch=$(date +%s)
    if [[ $expire_epoch -lt $current_epoch ]]; then
      $VERBOSE && echo "Certificate expired for $domain"
      return 1
    fi
    return 0
  fi
  return 1
}

check_domain() {
  local domain="$1"
  local block_type="UNKNOWN"
  local status_color=$RED
  local status_text="BLOCKED"

  local ips
  ips=$(timeout "$TIMEOUT" nslookup "$domain" 2>/dev/null | awk '/^Address: / && !/#/ {print $2}')
  
  if [[ -z "$ips" ]]; then
    block_type="DNS"
    printf "%-${DOMAIN_WIDTH}s  ${RED_ITALIC}%s${RESET} (${YELLOW}%s${RESET})\n" "$domain" "$status_text" "$block_type"
    echo "STATUS:BLOCKED"
    return
  fi

  for ip in $ips; do
    if is_rkn_spoof "$ip"; then
      block_type="DNS-SPOOF"
      printf "%-${DOMAIN_WIDTH}s  ${RED_ITALIC}%s${RESET} (${YELLOW}%s${RESET}) ${RED}[RKN stub: %s]${RESET}\n" \
        "$domain" "$status_text" "$block_type" "$ip"
      echo "STATUS:BLOCKED"
      return
    fi
  done

  local ip_ok=false
  local port_443_ok=false
  local port_80_ok=false
  
  for ip in $ips; do
    if nc -z -w "$TIMEOUT" "$ip" 443 2>/dev/null; then
      ip_ok=true
      port_443_ok=true
      break
    fi
  done
  
  if ! $port_443_ok; then
    for ip in $ips; do
      if nc -z -w "$TIMEOUT" "$ip" 80 2>/dev/null; then
        port_80_ok=true
        ip_ok=true
        break
      fi
    done
  fi

  if ! $ip_ok; then
    block_type="IP/TCP"
    printf "%-${DOMAIN_WIDTH}s  ${RED_ITALIC}%s${RESET} (${YELLOW}%s${RESET})\n" "$domain" "$status_text" "$block_type"
    echo "STATUS:BLOCKED"
    return
  fi

  local cert_status=""
  if check_certificate "$domain"; then
    cert_status="✓TLS"
  else
    cert_status="✗TLS"
    block_type="TLS/SSL"
  fi

  local http_code https_code
  http_code=$(fetch_code "http://$domain")
  https_code=$(fetch_code "https://$domain")

  if [[ "$http_code" =~ 3[0-9][0-9] ]]; then
    $VERBOSE && echo "HTTP redirect detected for $domain, falling back to HTTPS"
    http_code="$https_code"
  fi

  if [[ "$http_code" == "000" && "$https_code" == "000" ]]; then
    if $ip_ok; then
      block_type="HTTP(S)"
    else
      block_type="IP/HTTP"
    fi
  elif [[ "$http_code" =~ [45][0-9][0-9] && "$https_code" =~ [45][0-9][0-9] ]]; then
    block_type="HTTP-RESPONSE"
  fi

  if check_keyword_blocking "$domain"; then
    if [[ "$block_type" != "UNKNOWN" ]]; then
      block_type="$block_type/DPI"
    else
      block_type="DPI/KEYWORD"
    fi
  fi

  if [[ " ${AI_DOMAINS[*]} " =~ " ${domain} " ]]; then
    local ai_response
    ai_response=$(curl -s -A "$USER_AGENT" \
      -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \
      -H "Accept-Language: en-US,en;q=0.5" \
      -H "Upgrade-Insecure-Requests: 1" \
      -H "Sec-Fetch-Dest: document" \
      -H "Sec-Fetch-Mode: navigate" \
      -H "Sec-Fetch-Site: none" \
      -H "Sec-Fetch-User: ?1" \
      -H "Connection: keep-alive" \
      --compressed \
      --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" "https://$domain" 2>/dev/null)
    if echo "$ai_response" | grep -qi "sorry, you have been blocked\|you are unable to access\|not available in your region\|restricted in your country\|access denied due to location\|blocked in your area\|unable to load site\|if you are using a vpn\|Not Available"; then
      block_type="REGIONAL"
      http_code="000"  
      https_code="000"
    elif echo "$ai_response" | grep -qi "just a moment\|enable javascript and cookies"; then
      block_type=""  
      http_code="200"  
      https_code="200"
    fi
  fi

  if [[ "$http_code" == "000" && "$https_code" == "000" ]]; then
    printf "%-${DOMAIN_WIDTH}s  ${RED_ITALIC}%s${RESET} (${YELLOW}%s${RESET}) ${cert_status}\n" "$domain" "$status_text" "$block_type"
    echo "STATUS:BLOCKED"
  elif [[ "$http_code" =~ [23][0-9][0-9] || "$https_code" =~ [23][0-9][0-9] ]]; then
    printf "%-${DOMAIN_WIDTH}s  ${GREEN_ITALIC}%s${RESET} ${cert_status}\n" "$domain" "OK"
    echo "STATUS:OK"
  else
    printf "%-${DOMAIN_WIDTH}s  ${YELLOW_ITALIC}%s${RESET} (${BLUE}%s${RESET}) ${cert_status}\n" "$domain" "PARTIAL" "$block_type"
    echo "STATUS:PARTIAL"
  fi
}

animate() {
  local total=$1
  local tmpdir=$2
  local bar_width=50
  local i=0

  tput civis 2>/dev/null

  while true; do
    local done_count=$(ls "$tmpdir"/*.txt 2>/dev/null | wc -l)
    local percent=$(( done_count * 100 / total ))
    (( percent > 100 )) && percent=100

    local filled=$(( done_count * bar_width / total ))
    (( filled > bar_width )) && filled=$bar_width
    local remaining=$(( bar_width - filled ))
    (( remaining < 0 )) && remaining=0

    local fill_str empty_str
    printf -v fill_str  '%*s' "$filled"    ''
    printf -v empty_str '%*s' "$remaining" ''
    fill_str="${fill_str// /█}"
    empty_str="${empty_str// /░}"

    printf "\r  ${CYAN}Scanning${RESET}  [${BLUE}%s${DIM}%s${RESET}]  ${YELLOW}%3d%%${RESET}\e[K" \
      "$fill_str" "$empty_str" "$percent"

    sleep 0.1
    i=$(( i + 1 ))
  done
}

# ----------------------------------------------------------------- RIPE key
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/censorcheck"
KEY_FILE="$CONFIG_DIR/key"

save_ripe_key() {
  ( umask 077; mkdir -p "$CONFIG_DIR" && printf '%s\n' "$1" > "$KEY_FILE" ) 2>/dev/null
}

# Порядок: --key / $RIPE_API_KEY  ->  сохранённый ключ  ->  запрос у пользователя
resolve_ripe_key() {
  local answer

  [[ "$RIPE_API_KEY" == "Insert the key" ]] && RIPE_API_KEY=""

  if [[ -z "$RIPE_API_KEY" && -r "$KEY_FILE" ]]; then
    RIPE_API_KEY=$(tr -d '[:space:]' < "$KEY_FILE" 2>/dev/null)
    [[ -n "$RIPE_API_KEY" ]] && echo -e "${DIM}Ключ RIPE Atlas взят из ${KEY_FILE}${RESET}"
  fi

  [[ -n "$RIPE_API_KEY" ]] && return 0
  [[ "$ASK_KEY" != true ]] && return 1

  # stdin занят самим скриптом при запуске через `wget -qO- ... | bash`,
  # поэтому открываем управляющий терминал отдельным дескриптором.
  # Проверка [[ -r /dev/tty ]] тут не годится: она проходит и без tty,
  # а падает уже сам open (ENXIO).
  # порядок важен: 2>/dev/null должен применяться раньше самого open
  { exec 9<>/dev/tty; } 2>/dev/null || return 1

  {
    echo
    echo -e "${CYAN}Радар ТСПУ${RESET} — проверка вашего IP из сетей РФ через зонды RIPE Atlas."
    echo -e "${DIM}Нужен personal API key: https://atlas.ripe.net/keys/${RESET}"
    echo -e "${DIM}Право доступа: «Create a new measurement». Ключ никуда не отправляется, кроме atlas.ripe.net${RESET}"
    echo -ne "${YELLOW}Ключ RIPE Atlas${RESET} ${DIM}(Enter — пропустить радар):${RESET} "
  } >&9

  IFS= read -r answer <&9 || { echo >&9; exec 9>&-; return 1; }
  answer=$(printf '%s' "$answer" | tr -d '[:space:]')

  if [[ -z "$answer" ]]; then
    echo -e "${DIM}Радар ТСПУ пропущен. Домены всё равно проверю.${RESET}" >&9
    echo >&9
    exec 9>&-
    return 1
  fi

  RIPE_API_KEY="$answer"
  if [[ ! "$RIPE_API_KEY" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo -e "${DIM}Не похоже на UUID — пробую как есть.${RESET}" >&9
  fi

  echo -ne "${DIM}Запомнить ключ в ${KEY_FILE}? [Y/n]:${RESET} " >&9
  IFS= read -r answer <&9 || answer=""
  if [[ -z "$answer" || "$answer" =~ ^[YyДд] ]]; then
    if save_ripe_key "$RIPE_API_KEY"; then
      echo -e "${DIM}Сохранено, права 600. Удалить: rm ${KEY_FILE}${RESET}" >&9
    else
      echo -e "${DIM}Сохранить не вышло — ключ используется только в этом запуске.${RESET}" >&9
    fi
  fi
  echo >&9
  exec 9>&-
  return 0
}

# SNI спрашиваем только если он не задан явно и радар вообще будет запускаться.
# Значение НЕ сохраняется: оно своё для каждой ноды, в отличие от ключа.
resolve_sni() {
  local answer
  [[ "$SNI_EXPLICIT" == true ]] && return 0
  [[ "$ASK_KEY" != true ]] && return 0
  { exec 9<>/dev/tty; } 2>/dev/null || return 0

  {
    echo -e "${DIM}SNI, который зонды пошлют в TLS Client Hello. Для REALITY-ноды —"
    echo -e "то же имя, что стоит в serverNames инбаунда (например www.transip.nl).${RESET}"
    echo -ne "${YELLOW}SNI${RESET} ${DIM}[Enter — ${REALITY_SNI}]:${RESET} "
  } >&9

  IFS= read -r answer <&9 || answer=""
  answer=$(printf '%s' "$answer" | tr -d '[:space:]')

  if [[ -n "$answer" ]]; then
    if [[ "$answer" =~ ^[A-Za-z0-9._-]+$ ]]; then
      REALITY_SNI="$answer"
    else
      echo -e "${DIM}Это не похоже на имя хоста, оставляю ${REALITY_SNI}${RESET}" >&9
    fi
  fi

  echo >&9
  exec 9>&-
  return 0
}

clear
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e " ${YELLOW}◆${RESET}          ${BLUE}Network Censorship Checker${RESET}  ${DIM}·${RESET}  ${YELLOW}by Nikola Tesla${RESET}          ${YELLOW}◆${RESET} "
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo

if resolve_ripe_key; then
  resolve_sni
fi

printf "%-${DOMAIN_WIDTH}s  %-8s %s\n" "Domain" "Status" "Block Type"
echo "$LINE_SEP"

start_time=$(date +%s)

TMPDIR_RESULTS=$(mktemp -d)

animate "${#DOMAINS[@]}" "$TMPDIR_RESULTS" &
ANIM_PID=$!

job_pids=()

for i in "${!DOMAINS[@]}"; do
  d="${DOMAINS[$i]}"
  check_domain "$d" > "$TMPDIR_RESULTS/$i.txt" &
  job_pids+=($!)

  while (( $(jobs -p | wc -l) > MAX_PARALLEL )); do
    wait -n 2>/dev/null
  done
done

wait "${job_pids[@]}" 2>/dev/null

kill "$ANIM_PID" 2>/dev/null
wait "$ANIM_PID" 2>/dev/null 
printf "\r\e[K"              
tput cnorm 2>/dev/null       

count_ok=0
count_blocked=0
count_partial=0

for i in "${!DOMAINS[@]}"; do
  grep -v "^STATUS:" "$TMPDIR_RESULTS/$i.txt"
  status=$(grep "^STATUS:" "$TMPDIR_RESULTS/$i.txt" | cut -d: -f2)
  case "$status" in
    OK)      (( count_ok++ ))      ;;
    BLOCKED) (( count_blocked++ )) ;;
    PARTIAL) (( count_partial++ )) ;;
  esac
done

rm -rf "$TMPDIR_RESULTS"

total_domains=${#DOMAINS[@]}

# Чекаем IP сервера и его ASN/org
CURRENT_IP=$(curl -s -4 --connect-timeout 3 https://api.ipify.org 2>/dev/null)
CURRENT_ASN=""
if [[ -n "$CURRENT_IP" ]]; then
  CURRENT_ASN=$(curl -s --connect-timeout 3 "https://ipinfo.io/${CURRENT_IP}/org" 2>/dev/null | tr -d '\r\n')
fi

echo "$LINE_SEP"
printf "${GREEN}OK:%d${RESET}  ${RED}BLOCKED:%d${RESET}  ${YELLOW}PARTIAL:%d${RESET}  ${DIM}Total:%d${RESET}" \
  "$count_ok" "$count_blocked" "$count_partial" "$total_domains"
if [[ -n "$CURRENT_ASN" ]]; then
  printf " ${DIM}|${RESET} ${CYAN}%s${RESET}" "$CURRENT_ASN"
fi
echo

if [[ -n "$CURRENT_IP" ]]; then
  echo "$LINE_SEP"

  RADAR_IP="${RADAR_TARGET:-$CURRENT_IP}"

  if [[ -z "$RIPE_API_KEY" || "$RIPE_API_KEY" == "Insert the key" ]]; then
    echo -e "${YELLOW}Радар ТСПУ пропущен: не задан ключ RIPE Atlas.${RESET}"
    echo -e "${DIM}Создайте ключ на https://atlas.ripe.net/keys/ (право Create measurement) и запустите:${RESET}"
    echo -e "${DIM}  ./censorcheck.sh --key <uuid>   либо   export RIPE_API_KEY=<uuid>${RESET}"

  elif [[ "$SKIP_LISTEN_CHECK" == false ]] && ! ss -tuln 2>/dev/null | grep -qE "(0\.0\.0\.0|\[::\]|\*|$CURRENT_IP):443([[:space:]]|$)"; then
    echo -e "${DIM}Радар ТСПУ отменен: на :443 никто не слушает.${RESET}"
    echo -e "${DIM}Запустите VPN/веб-сервер, либо --no-listen-check / --target <ip>${RESET}"

  else
    echo -e "Опрос сетей РФ: РТК, МТС, МГТС, Билайн, ТТК, РТК-Юг, Мегафон .."
    echo -e "${DIM}Цель: ${RADAR_IP}:443   SNI: ${REALITY_SNI}${RESET}"

    TMP_ATLAS=$(mktemp)
    TMP_ATLAS_DEBUG=$(mktemp)
    python3 - "$RIPE_API_KEY" "$RADAR_IP" "$REALITY_SNI" "$DEBUG" "$RADAR_DEADLINE" \
      > "$TMP_ATLAS" 2>"$TMP_ATLAS_DEBUG" <<'PYRADAR' &
import sys, json, time, urllib.request, urllib.error

api_key   = sys.argv[1]
target_ip = sys.argv[2]
sni       = sys.argv[3]
debug     = (len(sys.argv) > 4 and sys.argv[4] == 'true')
deadline  = int(sys.argv[5]) if len(sys.argv) > 5 else 240

API = 'https://atlas.ripe.net/api/v2'

def dlog(msg):
    if debug:
        print('[DEBUG] ' + str(msg), file=sys.stderr, flush=True)

def api_get(path, key=None, timeout=25):
    req = urllib.request.Request(API + path)
    if key:
        req.add_header('Authorization', 'Key ' + key)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

# --- 1. ключ живой? сколько кредитов? -------------------------------------
if not api_key or api_key.strip() in ('', 'Insert the key', 'YOUR_KEY'):
    print('ERROR NOKEY')
    sys.exit(0)

balance = -1
try:
    balance = api_get('/credits/', api_key).get('current_balance', -1)
    dlog('credit balance = ' + str(balance))
except urllib.error.HTTPError as e:
    body = e.read().decode('utf-8', 'replace')[:200]
    dlog('credits HTTP ' + str(e.code) + ': ' + body)
    # 401 = такого ключа нет -> дальше идти бессмысленно.
    # 403 = ключ валиден, но у него нет прав на /credits/ (отдельного
    # разрешения для кредитов в списке нет) -> не фатально, просто
    # пропускаем проверку баланса и пробуем создать измерение.
    if e.code == 401:
        print('ERROR AUTH 401')
        sys.exit(0)
    dlog('no permission to read credits, skipping balance check')
except Exception as e:
    dlog('credits check failed: ' + repr(e))

# --- 2. сколько зондов реально доступно в каждой ASN? ---------------------
WANT = [(12389,3),(8402,5),(25513,5),(8359,3),(3216,3),(20485,2),
        (25490,1),(43727,1),(12714,4),(34757,2),(29124,2),(12768,2)]

probe_defs = []
expected = 0
for asn, want in WANT:
    try:
        q = '/probes/?asn_v4=%d&status=1&tags=system-ipv4-works&page_size=1' % asn
        avail = api_get(q).get('count', 0)
    except Exception as e:
        dlog('AS%d probe count failed (%r), assuming %d' % (asn, e, want))
        avail = want
    use = min(want, avail)
    dlog('AS%-6d want=%d avail=%s use=%d' % (asn, want, avail, use))
    if use > 0:
        probe_defs.append({'requested': use, 'type': 'asn', 'value': asn,
                           'tags': {'include': ['system-ipv4-works']}})
        expected += use

if not probe_defs:
    print('ERROR NOPROBES')
    sys.exit(0)

est_cost = expected * 20   # sslcert: 20 кредитов на зонд (проверено на реальном отказе API)
if 0 <= balance < est_cost:
    print('ERROR CREDITS %d %d' % (balance, est_cost))
    sys.exit(0)

# --- 3. создаём измерение -------------------------------------------------
payload = {
    'definitions': [{
        'target': target_ip,
        'description': 'censorcheck TLS radar ' + sni,
        'type': 'sslcert',
        'port': 443,
        'hostname': sni,
        'af': 4,
    }],
    'probes': probe_defs,
    'is_oneoff': True,
}
req = urllib.request.Request(
    API + '/measurements/',
    data=json.dumps(payload).encode('utf-8'),
    headers={'Content-Type': 'application/json', 'Authorization': 'Key ' + api_key})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        msm_id = json.loads(r.read().decode())['measurements'][0]
    dlog('measurement id = %s (expecting %d probes)' % (msm_id, expected))
except urllib.error.HTTPError as e:
    body = e.read().decode('utf-8', 'replace').replace('\n', ' ')[:300]
    dlog('create HTTP %d: %s' % (e.code, body))
    print('ERROR CREATE %d %s' % (e.code, body))
    sys.exit(0)
except Exception as e:
    dlog('create failed: ' + repr(e))
    print('ERROR CREATE 0 ' + type(e).__name__)
    sys.exit(0)

# --- 4. ждём результаты ---------------------------------------------------
results = []
t0 = time.time()
last_n = -1
stable_since = None
while time.time() - t0 < deadline:
    time.sleep(3)
    try:
        results = api_get('/measurements/%s/results/' % msm_id, api_key)
    except Exception as e:
        dlog('poll error: ' + repr(e))
        continue
    n = len(results)
    dlog('poll t=%3ds  results=%d/%d' % (int(time.time() - t0), n, expected))
    if n >= expected:
        break
    if n == last_n and n > 0:
        if stable_since is None:
            stable_since = time.time()
        elif time.time() - stable_since > 45:
            dlog('count stable %ds, stopping early' % 45)
            break
    else:
        stable_since = None
        last_n = n

if not results:
    print('ERROR NODATA %d %d' % (expected, int(time.time() - t0)))
    sys.exit(0)

# --- 5. классификация -----------------------------------------------------
blocked_ids = []
ok = 0
for p in results:
    if 'cert' in p or 'method' in p or 'alert' in p:
        ok += 1
    else:
        pid = p.get('prb_id')
        if pid:
            blocked_ids.append(pid)

total = len(results)
print('OK %d %d %d %d' % (total, ok, total - ok, expected))

blocked_asns = {}
if blocked_ids:
    try:
        ids = ','.join(str(i) for i in blocked_ids)
        info = api_get('/probes/?id__in=%s&fields=id,asn_v4&page_size=100' % ids, api_key)
        for p in info.get('results', []):
            a = p.get('asn_v4')
            if a:
                blocked_asns[a] = blocked_asns.get(a, 0) + 1
        dlog('blocked asns: ' + str(blocked_asns))
    except Exception as e:
        dlog('probe lookup failed: ' + repr(e))

if blocked_asns:
    print('BLOCKED_ASN ' + ' '.join('%d:%d' % (a, c) for a, c in blocked_asns.items()))
PYRADAR

    
    ATLAS_PID=$!

    wave=(" " "▂" "▃" "▄" "▅" "▆" "▇" "█" "▇" "▆" "▅" "▄" "▃" "▂")
    wave_len=${#wave[@]}
    i=0
    
    tput civis 2>/dev/null 
    
    while kill -0 $ATLAS_PID 2>/dev/null; do
      pulse=""
      for (( k=0; k<8; k++ )); do
        idx=$(( (i + k * 2) % wave_len ))
        case $(( k % 4 )) in
          0) pulse+="${CYAN}${wave[$idx]}${RESET}"  ;;
          1) pulse+="${BLUE}${wave[$idx]}${RESET}"  ;;
          2) pulse+="${CYAN}${wave[$idx]}${RESET}"  ;;
          3) pulse+="${GREEN}${wave[$idx]}${RESET}" ;;
        esac
      done
      printf "\r${CYAN}Запуск радара ТСПУ (Ожидайте проверки)${RESET} %b\e[K" "$pulse"
      sleep 0.1
      ((i++))
    done
    
    wait $ATLAS_PID
    tput cnorm 2>/dev/null 
    
    printf "\r${CYAN}Запуск радара ТСПУ${RESET}\e[K\n"

    ATLAS_RESULT=$(cat "$TMP_ATLAS")
    rm -f "$TMP_ATLAS"

    FIRST_LINE=$(echo "$ATLAS_RESULT" | head -n1)
    BLOCKED_ASN_LINE=$(echo "$ATLAS_RESULT" | grep "^BLOCKED_ASN" | head -n1)
    STATUS=$(echo "$FIRST_LINE" | awk '{print $1}')
    STATUS_CODE=$(echo "$FIRST_LINE" | awk '{print $2}')

    if [[ "$STATUS" == "OK" ]]; then
      TOTAL_PROBES=$(echo "$FIRST_LINE" | awk '{print $2}')
      SUCCESS_PROBES=$(echo "$FIRST_LINE" | awk '{print $3}')
      BLOCKED_PROBES=$(echo "$FIRST_LINE" | awk '{print $4}')
      EXPECTED_PROBES=$(echo "$FIRST_LINE" | awk '{print $5}')
      
      if (( TOTAL_PROBES > 0 )); then
        SUCCESS_PERCENT=$(( SUCCESS_PROBES * 100 / TOTAL_PROBES ))
      else
        SUCCESS_PERCENT=0
      fi
      
      if (( SUCCESS_PERCENT == 100 )); then
        COLOR=$GREEN
        STAT_TEXT="ПОЛНЫЙ ДОСТУП ИЗ РФ"
      elif (( SUCCESS_PERCENT > 50 )); then
        COLOR=$YELLOW
        STAT_TEXT="ЧАСТИЧНАЯ БЛОКИРОВКА IP (Дропы у части провайдеров)"
      else
        COLOR=$RED
        STAT_TEXT="КРИТИЧНАЯ БЛОКИРОВКА ТСПУ (IP недоступен)"
      fi

      PROBE_TALLY="${TOTAL_PROBES}"
      if [[ -n "$EXPECTED_PROBES" ]] && (( EXPECTED_PROBES > TOTAL_PROBES )); then
        PROBE_TALLY="${TOTAL_PROBES}/${EXPECTED_PROBES}"
      fi
      echo -e "Зондов ответило: ${CYAN}${PROBE_TALLY}${RESET} | Пробились: ${GREEN}${SUCCESS_PROBES}${RESET} | Заблокированы: ${RED}${BLOCKED_PROBES}${RESET}"
      echo -e "ТСПУ Статус: ${COLOR}${SUCCESS_PERCENT}% ${STAT_TEXT}${RESET}"

      if [[ -n "$BLOCKED_ASN_LINE" ]]; then
        BLOCKED_PARTS=${BLOCKED_ASN_LINE#BLOCKED_ASN }

        declare -A NAME_COUNTS=()
        NAME_ORDER=()
        for part in $BLOCKED_PARTS; do
          asn="${part%%:*}"
          cnt="${part##*:}"
          name="${ASN_NAMES[$asn]:-AS$asn}"
          if [[ -z "${NAME_COUNTS[$name]:-}" ]]; then
            NAME_ORDER+=("$name")
            NAME_COUNTS[$name]=$cnt
          else
            NAME_COUNTS[$name]=$(( NAME_COUNTS[$name] + cnt ))
          fi
        done

        BLOCK_MAX_WIDTH=70
        BLOCK_PREFIX_LEN=11      
        BLOCK_INDENT="           " 

        current_line="${DIM}Блокируют:${RESET} "
        current_width=$BLOCK_PREFIX_LEN
        is_first=true

        for name in "${NAME_ORDER[@]}"; do
          cnt="${NAME_COUNTS[$name]}"
          visible="${name} ${cnt}"
          vlen=${#visible}
          colored="${RED}${name}${RESET} ${DIM}${cnt}${RESET}"

          if $is_first; then
            current_line+="$colored"
            current_width=$((current_width + vlen))
            is_first=false
          else
            needed=$((2 + vlen))   
            if (( current_width + needed > BLOCK_MAX_WIDTH )); then
              current_line+="${DIM},${RESET}"
              echo -e "$current_line"
              current_line="${BLOCK_INDENT}${colored}"
              current_width=$((BLOCK_PREFIX_LEN + vlen))
            else
              current_line+="${DIM},${RESET} ${colored}"
              current_width=$((current_width + needed))
            fi
          fi
        done

        echo -e "$current_line"
      fi

    else
      ERR_DETAIL=$(echo "$FIRST_LINE" | cut -d" " -f3-)
      case "$STATUS_CODE" in
        NOKEY)
          echo -e "${YELLOW}Ключ RIPE Atlas не задан.${RESET} ${DIM}--key <uuid> или export RIPE_API_KEY${RESET}" ;;
        AUTH)
          echo -e "${RED}Ключ RIPE Atlas отклонён (HTTP ${ERR_DETAIL}).${RESET} ${DIM}Проверьте права ключа: нужен Create measurement${RESET}" ;;
        CREDITS)
          echo -e "${RED}Недостаточно кредитов RIPE Atlas.${RESET} ${DIM}Баланс/нужно: ${ERR_DETAIL}${RESET}" ;;
        NOPROBES)
          echo -e "${RED}Нет активных зондов ни в одной из целевых ASN.${RESET}" ;;
        CREATE)
          echo -e "${RED}RIPE Atlas отклонил измерение:${RESET} ${DIM}${ERR_DETAIL}${RESET}" ;;
        NODATA)
          echo -e "${YELLOW}Зонды не вернули результат за отведённое время.${RESET} ${DIM}(ожидалось ${ERR_DETAIL% *} зондов) Попробуйте --timeout 420${RESET}" ;;
        *)
          echo -e "${YELLOW}Не удалось получить данные, попробуйте позже${RESET} ${DIM}(запустите с -d)${RESET}" ;;
      esac
    fi

    if $DEBUG && [[ -s "$TMP_ATLAS_DEBUG" ]]; then
      echo "$LINE_SEP"
      echo -e "${CYAN}[DEBUG] RIPE Atlas log:${RESET}"
      cat "$TMP_ATLAS_DEBUG"
    fi
    rm -f "$TMP_ATLAS_DEBUG"
  fi
fi

echo "$LINE_SEP"

end_time=$(date +%s)
elapsed_time=$((end_time - start_time))
elapsed_minutes=$((elapsed_time / 60))
elapsed_seconds=$((elapsed_time % 60))

if (( elapsed_minutes > 0 )); then
  echo "Test completed in ${elapsed_minutes}m ${elapsed_seconds}s."
else
  echo "Test completed in ${elapsed_seconds}s."
fi

if $DEBUG; then
  echo "$LINE_SEP"
  echo -e "${CYAN}=== DEBUG INFO ===${RESET}"
  echo "Script:        $0"
  echo "Bash version:  $BASH_VERSION"
  echo "OS:            $(uname -a 2>/dev/null || echo 'n/a')"
  echo "Date:          $(date)"
  echo "Public IP:     ${CURRENT_IP:-not detected}"
  echo "Reality SNI:   $REALITY_SNI"
  echo "Total domains: ${#DOMAINS[@]}"
  echo "Max parallel:  $MAX_PARALLEL"
  echo "Timeout:       ${TIMEOUT}s"
  echo "Retries:       $RETRIES"
  echo "Elapsed:       ${elapsed_time}s"
  echo
  echo "--- Listening ports (ss -tlnp | head -20) ---"
  ss -tlnp 2>/dev/null | head -20 || echo 'ss not available'
  echo
  echo "--- Tools versions ---"
  echo "curl:    $(curl --version 2>/dev/null | head -1)"
  echo "openssl: $(openssl version 2>/dev/null)"
  echo "python3: $(python3 --version 2>/dev/null)"
  echo "nc:      $(nc -h 2>&1 | head -1)"
  echo
  echo "--- DNS test (nslookup google.com) ---"
  nslookup google.com 2>&1 | head -10
  echo
  echo "--- Ping test (1.1.1.1) ---"
  ping -c 2 -W 2 1.1.1.1 2>&1 | tail -5
fi

echo -e "Follow: $(tput setaf 6)https://t.me/tracerlab$(tput sgr0)"