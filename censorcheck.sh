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

# Ключ RIPE Atlas. Берется из --key, иначе из окружения, иначе спрашивается.
# Свой ключ: https://atlas.ripe.net/keys/ (право "Schedule a new measurement")
RIPE_API_KEY="${RIPE_API_KEY:-}"
REALITY_SNI="max.ru"
NO_PROMPT=false
RADAR_TARGET=""            # по умолчанию — внешний IPv4 этой машины
RADAR_PORT=443             # порт, к которому подключаются зонды
RADAR_DEADLINE=240         # сек, сколько ждать результаты зондов
SKIP_LISTEN_CHECK=false

usage() {
  cat <<'USAGE'
censorcheck.sh [опции]

  -v, --verbose        подробный вывод по доменам
  -d, --debug          debug-лог радара RIPE Atlas
  -k, --key <uuid>     ключ RIPE Atlas (или переменная окружения RIPE_API_KEY)
  -s, --sni <hostname> SNI для TLS-хендшейка зондов (по умолчанию max.ru)
  -t, --target <ip>    проверять чужой IP, а не свой (включает --no-listen-check)
  -p, --port <port>    порт для зондов, по умолчанию 443
      --timeout <sec>  ждать результаты столько секунд, по умолчанию 240
      --no-listen-check  не проверять локального слушателя
      --no-prompt      не спрашивать ключ интерактивно
  -h, --help           эта справка

Примеры:
  ./censorcheck.sh --key <uuid> --target 192.0.2.10 --sni panel.example.com
  ./censorcheck.sh --key <uuid> --target 192.0.2.20 --port 8443 --sni www.example.net

Ключ создается за минуту на https://atlas.ripe.net/keys/ — нужно ровно одно
право, "Schedule a new measurement". Без ключа отрабатывает только проверка
доменов, радар ТСПУ пропускается.
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -d|--debug)
      DEBUG=true
      shift
      ;;
    -k|--key)
      RIPE_API_KEY="$2"
      shift 2
      ;;
    --no-prompt)
      NO_PROMPT=true
      shift
      ;;
    -s|--sni)
      REALITY_SNI="$2"
      shift 2
      ;;
    -t|--target)
      # чужой хост — локальная проверка слушателя для него бессмысленна
      RADAR_TARGET="$2"
      SKIP_LISTEN_CHECK=true
      shift 2
      ;;
    -p|--port)
      RADAR_PORT="$2"
      shift 2
      ;;
    --timeout)
      RADAR_DEADLINE="$2"
      shift 2
      ;;
    --no-listen-check)
      SKIP_LISTEN_CHECK=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

# "Insert the key" — плейсхолдер из старых версий. Для нас он равносилен
# пустому: он непустой, поэтому раньше проходил проверку и ловил 401.
[[ "$RIPE_API_KEY" == "Insert the key" ]] && RIPE_API_KEY=""

# Ключ спрашиваем через fd 9 на /dev/tty, а не со stdin: скрипт часто
# запускают как `curl ... | bash`, и stdin занят самим скриптом.
if [[ -z "$RIPE_API_KEY" && "$NO_PROMPT" == false ]]; then
  { exec 9<>/dev/tty; } 2>/dev/null
  if [[ -e /dev/fd/9 ]]; then
    printf 'Ключ RIPE Atlas (Enter — пропустить радар): ' >&9
    read -r RIPE_API_KEY <&9 || RIPE_API_KEY=""
    exec 9>&-
  fi
fi

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

clear
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e " ${YELLOW}◆${RESET}          ${BLUE}Network Censorship Checker${RESET}  ${DIM}·${RESET}  ${YELLOW}by Nikola Tesla${RESET}          ${YELLOW}◆${RESET} "
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo

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

RADAR_IP="${RADAR_TARGET:-$CURRENT_IP}"

if [[ -n "$RADAR_IP" ]]; then
  echo "$LINE_SEP"

  if [[ -z "$RIPE_API_KEY" ]]; then
    echo -e "${YELLOW}Радар ТСПУ пропущен: не задан ключ RIPE Atlas.${RESET}"
    echo -e "${DIM}Создать: https://atlas.ripe.net/keys/ (право Schedule a new measurement)${RESET}"
    echo -e "${DIM}Затем: ./censorcheck.sh --key <uuid>   или   export RIPE_API_KEY=<uuid>${RESET}"
  # Чекер 443 порта, нужен для Atlas
  # Проверка локального слушателя осмысленна только когда цель — эта же машина.
  # command -v ss: на macOS ss нет вообще, без этого радар там не запускается.
  elif [[ "$SKIP_LISTEN_CHECK" == false ]] && command -v ss >/dev/null 2>&1 \
       && ! ss -tuln 2>/dev/null | grep -qE "(0\.0\.0\.0|\*|$CURRENT_IP):${RADAR_PORT}\b"; then
    echo -e "${DIM}Радар ТСПУ отменен: на :${RADAR_PORT} локально никто не слушает.${RESET}"
    echo -e "${DIM}Запустите VPN (Xray/3X-UI), либо укажите --target <ip> для чужого хоста.${RESET}"
  else
    echo -e "Опрос сетей РФ: РТК, МТС, МГТС, Билайн, ТТК, РТК-Юг, Мегафон .."
    
    TMP_ATLAS=$(mktemp)
    TMP_ATLAS_DEBUG=$(mktemp)
    # Программа передается через кавычечный heredoc во временный файл, а не
    # через python3 -c "...": внутри двойных кавычек bash раскрывает $ и
    # обратные кавычки и закрывает строку на первой же кавычке в исходнике.
    TMP_PY=$(mktemp)
    cat > "$TMP_PY" <<'PYEOF'
import sys, json, time, urllib.request, urllib.error

api_key = sys.argv[1]
target_ip = sys.argv[2]
sni = sys.argv[3]
debug = (len(sys.argv) > 4 and sys.argv[4] == 'true')
deadline_s = int(sys.argv[5]) if len(sys.argv) > 5 else 240
port = int(sys.argv[6]) if len(sys.argv) > 6 else 443

def dlog(msg):
    if debug:
        print(f'[DEBUG] {msg}', file=sys.stderr, flush=True)

dlog(f'target_ip={target_ip} port={port} sni={sni} deadline={deadline_s}')

BASE = 'https://atlas.ripe.net/api/v2'

if not api_key or api_key == 'Insert the key':
    print('ERROR NOKEY', flush=True)
    sys.exit(0)

# Преflight. 401 = ключ мертв, дальше идти незачем. 403 = у ключа просто нет
# права читать баланс (такого права в дропдауне RIPE и нет) — это не ошибка.
balance = None
try:
    req = urllib.request.Request(BASE + '/credits/',
                                 headers={'Authorization': 'Key ' + api_key})
    with urllib.request.urlopen(req, timeout=15) as r:
        balance = json.loads(r.read().decode()).get('current_balance')
    dlog(f'credit balance={balance}')
except urllib.error.HTTPError as e:
    body = ''
    try:
        body = e.read().decode()[:300]
    except Exception:
        pass
    if e.code == 401:
        print('ERROR AUTH ' + body.replace(chr(10), ' '), flush=True)
        sys.exit(0)
    dlog(f'credits check HTTP {e.code} (не фатально): {body}')
except Exception as e:
    dlog(f'credits check failed: {type(e).__name__}: {e}')

url = BASE + '/measurements/'
data = {
    'definitions': [{
        'target': target_ip, 
        'description': 'Reality TLS Handshake',
        'type': 'sslcert',
        'port': port,
        'hostname': sni,
        'af': 4
    }],
    'probes': [
        {'requested': 3, 'type': 'asn', 'value': 12389, 'tags': {'include': ['system-ipv4-works']}},
        {'requested': 5, 'type': 'asn', 'value': 8402,  'tags': {'include': ['system-ipv4-works']}},
        {'requested': 5, 'type': 'asn', 'value': 25513, 'tags': {'include': ['system-ipv4-works']}},
        {'requested': 3, 'type': 'asn', 'value': 8359,  'tags': {'include': ['system-ipv4-works']}},
        {'requested': 3, 'type': 'asn', 'value': 3216,  'tags': {'include': ['system-ipv4-works']}},
        {'requested': 2, 'type': 'asn', 'value': 20485, 'tags': {'include': ['system-ipv4-works']}},
        {'requested': 1, 'type': 'asn', 'value': 25490, 'tags': {'include': ['system-ipv4-works']}},
        {'requested': 1, 'type': 'asn', 'value': 43727, 'tags': {'include': ['system-ipv4-works']}},
        {'requested': 4, 'type': 'asn', 'value': 12714, 'tags': {'include': ['system-ipv4-works']}},
        {'requested': 2, 'type': 'asn', 'value': 34757, 'tags': {'include': ['system-ipv4-works']}},
        {'requested': 2, 'type': 'asn', 'value': 29124, 'tags': {'include': ['system-ipv4-works']}},
        {'requested': 2, 'type': 'asn', 'value': 12768, 'tags': {'include': ['system-ipv4-works']}}
    ],
    'is_oneoff': True
}

req = urllib.request.Request(url, data=json.dumps(data).encode('utf-8'),
                             headers={'Content-Type': 'application/json',
                                      'Authorization': 'Key ' + api_key})
try:
    with urllib.request.urlopen(req, timeout=30) as response:
        msm_id = json.loads(response.read().decode())['measurements'][0]
        dlog(f'measurement_id={msm_id}')
        # печатаем сразу: bash покажет ссылку во время ожидания, и прерывание
        # больше не теряет уже оплаченное измерение
        print(f'MSM {msm_id}', flush=True)
except urllib.error.HTTPError as e:
    body = ''
    try:
        body = e.read().decode()[:400]
    except Exception:
        pass
    dlog(f'create HTTP {e.code}: {body}')
    one_line = body.replace(chr(10), ' ')
    if e.code == 401:
        print('ERROR AUTH ' + one_line, flush=True)
    elif e.code == 403 and 'credit' in body.lower():
        print('ERROR CREDITS ' + one_line, flush=True)
    else:
        print(f'ERROR CREATE {e.code} ' + one_line, flush=True)
    sys.exit(0)
except Exception as e:
    dlog(f'create error: {type(e).__name__}: {e}')
    print('ERROR CREATE 0 ' + type(e).__name__, flush=True)
    sys.exit(0)

results_url = f'https://atlas.ripe.net/api/v2/measurements/{msm_id}/results/'
results = []
start_time = time.time()

# Раньше окно было жестко 25 x 2 s = 50 s. Одноразовые измерения RIPE
# регулярно собираются дольше, и результаты просто терялись.
attempt = 0
last_n = -1
stall = 0
STALL_POLLS = 15   # 15 x 3s = 45s без новых результатов -> считаем, что все
while time.time() - start_time < deadline_s:
    time.sleep(3)
    attempt += 1
    try:
        with urllib.request.urlopen(results_url, timeout=20) as response:
            results = json.loads(response.read().decode())
        elapsed = int(time.time() - start_time)
        dlog(f'poll {attempt} [{elapsed}s/{deadline_s}s]: results={len(results)} stall={stall}')
        if len(results) >= 33:
            break
        if len(results) == last_n and len(results) > 0:
            stall += 1
            if stall >= STALL_POLLS:
                dlog(f'no new results for {STALL_POLLS * 3}s, stopping')
                break
        else:
            stall = 0
        last_n = len(results)
    except Exception as e:
        dlog(f'poll {attempt} error: {type(e).__name__}: {e}')

if debug:
    dlog(f'FINAL: total={len(results)} after {int(time.time()-start_time)}s')
    for i, probe in enumerate(results):
        prb_id = probe.get('prb_id', '?')
        asn = probe.get('asn', '?')
        keys = [k for k in ('cert','method','alert','err') if k in probe]
        err = probe.get('err', '')
        dlog(f'  probe[{i}] prb_id={prb_id} asn={asn} keys={keys} err={err!r}')

if not results:
    print(f'ERROR NODATA {msm_id}', flush=True)
    sys.exit(0)
    sys.exit(0)

blocked = 0
blocked_prb_ids = []
for probe in results:
    if 'cert' in probe or 'method' in probe or 'alert' in probe:
        pass 
    else:
        blocked += 1
        prb_id = probe.get('prb_id')
        if prb_id:
            blocked_prb_ids.append(prb_id)

total = len(results)
success = total - blocked
print(f'OK {total} {success} {blocked}')

blocked_asns = {}
if blocked_prb_ids:
    try:
        ids_str = ','.join(str(p) for p in blocked_prb_ids)
        probes_url = f'https://atlas.ripe.net/api/v2/probes/?id__in={ids_str}&fields=id,asn_v4'
        with urllib.request.urlopen(probes_url, timeout=10) as response:
            probe_info = json.loads(response.read().decode())
            for p in probe_info.get('results', []):
                asn = p.get('asn_v4')
                if asn:
                    blocked_asns[asn] = blocked_asns.get(asn, 0) + 1
            dlog(f'blocked asns: {blocked_asns}')
    except Exception as e:
        dlog(f'probe info error: {type(e).__name__}: {e}')

if blocked_asns:
    parts = ' '.join(f'{asn}:{cnt}' for asn, cnt in blocked_asns.items())
    print(f'BLOCKED_ASN {parts}')
PYEOF
    python3 "$TMP_PY" "$RIPE_API_KEY" "$RADAR_IP" "$REALITY_SNI" "$DEBUG" "$RADAR_DEADLINE" "$RADAR_PORT" > "$TMP_ATLAS" 2>"$TMP_ATLAS_DEBUG" &
    
    ATLAS_PID=$!

    wave=(" " "▂" "▃" "▄" "▅" "▆" "▇" "█" "▇" "▆" "▅" "▄" "▃" "▂")
    wave_len=${#wave[@]}
    i=0
    
    tput civis 2>/dev/null

    RADAR_T0=$(date +%s)
    MSM_SHOWN=""

    # Ctrl-C во время ожидания больше не теряет измерение: оно уже создано на
    # стороне RIPE, кредиты списаны, и результаты доедут независимо от нас.
    trap 'tput cnorm 2>/dev/null; echo; MID=$(grep -m1 "^MSM " "$TMP_ATLAS" 2>/dev/null | cut -d" " -f2); [ -n "$MID" ] && echo "Прервано. Измерение продолжается: https://atlas.ripe.net/measurements/$MID/"; exit 130' INT

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
      if [[ -z "$MSM_SHOWN" ]] && (( i % 10 == 0 )); then
        MSM_LIVE=$(grep -m1 "^MSM " "$TMP_ATLAS" 2>/dev/null | cut -d" " -f2)
        if [[ -n "$MSM_LIVE" ]]; then
          printf "\r\e[K${DIM}Измерение: https://atlas.ripe.net/measurements/%s/${RESET}\n" "$MSM_LIVE"
          MSM_SHOWN=1
        fi
      fi
      RADAR_ELAPSED=$(( $(date +%s) - RADAR_T0 ))
      printf "\r${CYAN}Запуск радара ТСПУ${RESET} ${DIM}(%ss / до %ss)${RESET} %b\e[K" \
        "$RADAR_ELAPSED" "$RADAR_DEADLINE" "$pulse"
      sleep 0.1
      ((i++))
    done
    
    wait $ATLAS_PID
    tput cnorm 2>/dev/null
    trap - INT 
    
    printf "\r${CYAN}Запуск радара ТСПУ${RESET}\e[K\n"

    ATLAS_RESULT=$(cat "$TMP_ATLAS")
    rm -f "$TMP_ATLAS" "$TMP_PY"

    FIRST_LINE=$(echo "$ATLAS_RESULT" | grep -E '^(OK|ERROR) ' | head -n1)
    BLOCKED_ASN_LINE=$(echo "$ATLAS_RESULT" | grep "^BLOCKED_ASN" | head -n1)
    STATUS=$(echo "$FIRST_LINE" | awk '{print $1}')

    if [[ "$STATUS" == "OK" ]]; then
      TOTAL_PROBES=$(echo "$FIRST_LINE" | awk '{print $2}')
      SUCCESS_PROBES=$(echo "$FIRST_LINE" | awk '{print $3}')
      BLOCKED_PROBES=$(echo "$FIRST_LINE" | awk '{print $4}')
      
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

      echo -e "Зондов ответило: ${CYAN}${TOTAL_PROBES}${RESET} | Пробились: ${GREEN}${SUCCESS_PROBES}${RESET} | Заблокированы: ${RED}${BLOCKED_PROBES}${RESET}"
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
      ERR_CODE=$(echo "$FIRST_LINE" | awk '{print $2}')
      ERR_BODY=$(echo "$FIRST_LINE" | cut -d' ' -f3-)
      case "$ERR_CODE" in
        NOKEY)
          echo -e "${YELLOW}Радар: ключ RIPE Atlas не задан.${RESET}"
          echo -e "${DIM}https://atlas.ripe.net/keys/ → право Schedule a new measurement${RESET}"
          ;;
        AUTH)
          echo -e "${RED}Радар: RIPE Atlas отверг ключ (401).${RESET}"
          [[ -n "$ERR_BODY" ]] && echo -e "${DIM}${ERR_BODY}${RESET}"
          ;;
        CREDITS)
          echo -e "${RED}Радар: не хватает кредитов RIPE Atlas.${RESET}"
          [[ -n "$ERR_BODY" ]] && echo -e "${DIM}${ERR_BODY}${RESET}"
          echo -e "${DIM}Кредиты начисляются за хостинг зонда: https://atlas.ripe.net/apply/${RESET}"
          ;;
        CREATE)
          echo -e "${RED}Радар: RIPE Atlas отклонил измерение.${RESET}"
          [[ -n "$ERR_BODY" ]] && echo -e "${DIM}${ERR_BODY}${RESET}"
          ;;
        NODATA)
          echo -e "${YELLOW}Радар: зонды не успели ответить.${RESET}"
          echo -e "${DIM}Измерение создано, результаты придут позже:${RESET}"
          echo -e "${DIM}  https://atlas.ripe.net/measurements/${ERR_BODY}/${RESET}"
          ;;
        *)
          echo -e "${YELLOW}Не удалось получить данные, попробуйте позже${RESET}"
          ;;
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