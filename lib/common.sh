# shellcheck shell=bash
# =============================================================================
# lib/common.sh — Base compartida por 01-duckdns-setup.sh y 02-rustdesk-setup.sh
#
# Principios:
#  * Cada paso: VERIFICAR estado -> APLICAR solo si falta -> VERIFICAR de nuevo.
#  * Todo cambio pasa por run() o write_file(): queda en el log, respeta
#    --dry-run/--check y se anota en un manifiesto (para revertir sin adivinar).
#  * Lo que depende de terceros (router, ISP) es un CHECKPOINT MANUAL: el script
#    se detiene, muestra exactamente qué configurar y lo verifica si es posible.
#  * Al final se genera un reporte Markdown con el resultado de cada prueba.
#
# Códigos de salida: 0 todo OK | 1 hay fallas | 2 abortado | 3 quedan pasos
#                    manuales pendientes | 130 interrumpido (Ctrl+C)
# =============================================================================

[[ -n "${_RD_COMMON_LOADED:-}" ]] && return 0
_RD_COMMON_LOADED=1

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
CHECK_ONLY=${CHECK_ONLY:-0}
TOOL_NAME=${TOOL_NAME:-rdsetup}
CURRENT_PHASE="-"
RESULTS=()
CHANGES=0
RUN_ID="$(date +%Y%m%d-%H%M%S)"
NET_IFACE="" NET_IP="" NET_MAC="" NET_GW="" NET_PUBLIC="" NET_DHCP=0 NET_PATH="DESCONOCIDO"

if [[ $EUID -eq 0 ]]; then
  RD_STATE_DIR=${RD_STATE_DIR:-/var/lib/rdsetup}
  RD_LOG_DIR=${RD_LOG_DIR:-/var/log/rdsetup}
else
  RD_STATE_DIR=${RD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/rdsetup}
  RD_LOG_DIR=${RD_LOG_DIR:-$RD_STATE_DIR/logs}
fi
STATE_FILE="$RD_STATE_DIR/state.env"

if [[ -t 1 ]]; then
  C_R=$'\e[1;31m' C_G=$'\e[1;32m' C_Y=$'\e[1;33m' C_B=$'\e[1;36m' C_D=$'\e[2m' C_0=$'\e[0m'
else
  C_R='' C_G='' C_Y='' C_B='' C_D='' C_0=''
fi

# --------------------------------------------------------------------------- #
# Salida y trazabilidad
# --------------------------------------------------------------------------- #
log()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()   {  # si la última prueba ya registró la falla, no se duplica en el reporte
  printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2
  [[ "${RESULTS[-1]:-}" == FAIL\|* ]] || record FAIL "$*"
  summary; exit 1
}
phase() { CURRENT_PHASE="$1"; printf '\n%s━━━ FASE %s — %s ━━━%s\n' "$C_B" "$1" "$2" "$C_0"; }

mode_name() {
  if ((CHECK_ONLY)); then echo "check (solo pruebas, sin cambios)"
  elif ((DRY_RUN)); then echo "dry-run (muestra el plan, sin cambios)"
  else echo "apply (aplica cambios)"; fi
}

init_trace() {
  mkdir -p "$RD_STATE_DIR/backup" "$RD_LOG_DIR" || { echo "No se pudo crear $RD_STATE_DIR"; exit 1; }
  chmod 700 "$RD_STATE_DIR" "$RD_STATE_DIR/backup"
  LOG_FILE="$RD_LOG_DIR/${TOOL_NAME}-${RUN_ID}.log"
  REPORT_FILE="$RD_LOG_DIR/${TOOL_NAME}-${RUN_ID}-reporte.md"
  # Todo lo que se imprime queda también en el log (sin códigos de color).
  exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE")) 2>&1
  trap 'echo; warn "Interrumpido por el usuario."; summary; exit 130' INT
  log "Ejecución ${RUN_ID} | host $(hostname) | modo: $(mode_name)"
  info "Log: $LOG_FILE"
}

# record ESTADO "descripción"   ESTADO: PASS FAIL WARN SKIP PENDING MANUAL INFO
record() {
  local st="$1" desc="$2" icon col
  case "$st" in
    PASS)    icon="✔"; col=$C_G ;;
    FAIL)    icon="✘"; col=$C_R ;;
    WARN)    icon="!"; col=$C_Y ;;
    PENDING) icon="⏸"; col=$C_Y ;;
    MANUAL)  icon="✋"; col=$C_B ;;
    SKIP)    icon="–"; col=$C_D ;;
    *)       icon="i"; col=$C_D ;;
  esac
  RESULTS+=("${st}|${CURRENT_PHASE}|${desc}")
  printf '  %s%s %-7s%s %s\n' "$col" "$icon" "$st" "$C_0" "$desc"
}

# check "descripción" comando...   -> registra PASS/FAIL y devuelve el estado
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then record PASS "$desc"; return 0; fi
  record FAIL "$desc"; return 1
}

# retry N SEG comando...  (para verificaciones que tardan en estabilizarse)
retry() {
  local n="$1" s="$2"; shift 2
  local i
  for ((i = 1; i <= n; i++)); do "$@" && return 0; sleep "$s"; done
  return 1
}

# --------------------------------------------------------------------------- #
# Cambios: run / write_file / manifiesto / estado
# --------------------------------------------------------------------------- #
# run comando...  -> en dry-run solo lo muestra; si falla, aborta con registro.
run() {
  if ((DRY_RUN)); then printf '    %s[plan]%s %s\n' "$C_D" "$C_0" "$*"; return 0; fi
  printf '    %s$ %s%s\n' "$C_D" "$*" "$C_0"
  "$@" || die "Comando falló: $*"
}

# write_file RUTA MODO [usuario:grupo]  <contenido por stdin>
# Devuelve 0 si cambió (o cambiaría en dry-run), 1 si ya estaba igual.
# Antes de sobrescribir, guarda backup en $RD_STATE_DIR/backup.
write_file() {
  local path="$1" mode="$2" owner="${3:-}" tmp
  tmp="$(mktemp)"; cat >"$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    info "sin cambios: $path"; rm -f "$tmp"; return 1
  fi
  if ((DRY_RUN)); then
    printf '    %s[plan]%s escribir %s (modo %s)\n' "$C_D" "$C_0" "$path" "$mode"
    if [[ "$mode" =~ ^0?[0-7]00$ ]]; then          # 0600/0400: solo el dueño → sensible
      info "  (contenido sensible: diff omitido)"
    elif [[ -f "$path" ]]; then
      diff -u "$path" "$tmp" | sed 's/^/      /'
    else
      sed 's/^/      + /' "$tmp"
    fi
    rm -f "$tmp"; return 0
  fi
  if [[ -f "$path" ]]; then
    cp -p "$path" "$RD_STATE_DIR/backup/$(basename "$path").${RUN_ID}"
    info "backup previo: $RD_STATE_DIR/backup/$(basename "$path").${RUN_ID}"
  fi
  local -a own=()
  [[ -n "$owner" ]] && own=(-o "${owner%%:*}" -g "${owner##*:}")
  install -D -m "$mode" "${own[@]}" "$tmp" "$path" || { rm -f "$tmp"; die "No se pudo escribir $path"; }
  rm -f "$tmp"
  manifest_add "$path"
  CHANGES=$((CHANGES + 1))
  log "escrito: $path"
  return 0
}

manifest_add() {
  ((DRY_RUN)) && return 0
  local f="$RD_STATE_DIR/manifest-${TOOL_NAME}"
  grep -qxF "$1" "$f" 2>/dev/null || echo "$1" >>"$f"
}

state_get() { [[ -f "$STATE_FILE" ]] && sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1; }
state_set() {
  ((DRY_RUN)) && return 0
  touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
  if grep -q "^$1=" "$STATE_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$STATE_FILE"
  else echo "$1=$2" >>"$STATE_FILE"; fi
}

# --------------------------------------------------------------------------- #
# Interacción y checkpoints manuales
# --------------------------------------------------------------------------- #
is_interactive() { ((ASSUME_YES == 0 && CHECK_ONLY == 0)) && [[ -t 0 ]]; }

box() {  # box "Título" "cuerpo multilínea"
  printf '\n%s┌─ ACCIÓN MANUAL: %s%s\n' "$C_Y" "$1" "$C_0"
  while IFS= read -r l; do printf '%s│%s %s\n' "$C_Y" "$C_0" "$l"; done <<<"$2"
  printf '%s└──────────────────────────────────────────────────────────%s\n' "$C_Y" "$C_0"
}

# manual_checkpoint ID "Título" "instrucciones" [función_de_verificación]
# Devuelve 0 si quedó resuelto, 1 si queda pendiente.
manual_checkpoint() {
  local id="$1" title="$2" body="$3" verify="${4:-}" ans
  if [[ "$(state_get "MANUAL_$id")" == "done" && -z "$verify" ]]; then
    record PASS "Manual «$title» (confirmado en una ejecución anterior)"; return 0
  fi
  box "$title" "$body"
  if [[ -n "$verify" ]] && "$verify"; then
    record PASS "Manual «$title» verificado automáticamente"; state_set "MANUAL_$id" "done"; return 0
  fi
  if ! is_interactive; then
    record PENDING "Manual «$title»"; echo "$title" >>"$RD_STATE_DIR/pendientes-${TOOL_NAME}" 2>/dev/null
    return 1
  fi
  while :; do
    read -rp "  ¿Ya está hecho? [s]í / [n]o, lo hago después / [a]bortar: " ans
    case "${ans,,}" in
      s|si|sí)
        if [[ -z "$verify" ]]; then
          record MANUAL "Manual «$title» (confirmado por el operador, sin verificación automática)"
          state_set "MANUAL_$id" "done"; return 0
        elif "$verify"; then
          record PASS "Manual «$title» verificado"; state_set "MANUAL_$id" "done"; return 0
        else
          warn "La verificación todavía no pasa. Revisá la configuración y respondé de nuevo."
        fi ;;
      n|no) record PENDING "Manual «$title»"; return 1 ;;
      a)    record FAIL "Abortado por el operador en «$title»"; summary; exit 2 ;;
    esac
  done
}

ask_yes_no() {  # ask_yes_no "pregunta" [default s|n]
  local def="${2:-n}" ans
  is_interactive || { [[ "$def" == s ]]; return; }
  read -rp "  $1 [$( [[ $def == s ]] && echo S/n || echo s/N )]: " ans
  ans="${ans:-$def}"; [[ "${ans,,}" == s* ]]
}

# --------------------------------------------------------------------------- #
# Reporte final
# --------------------------------------------------------------------------- #
summary() {
  [[ -n "${_SUMMARY_DONE:-}" ]] && return "${_SUMMARY_RC:-0}"
  _SUMMARY_DONE=1
  local r st ph desc nfail=0 npend=0 nwarn=0 npass=0
  printf '\n%s━━━ RESUMEN ━━━%s\n' "$C_B" "$C_0"
  {
    echo "# Reporte ${TOOL_NAME} — ${RUN_ID}"
    echo
    echo "- Host: $(hostname)  |  Modo: $(mode_name)  |  Cambios aplicados: ${CHANGES}"
    echo "- Log completo: ${LOG_FILE:-n/a}"
    echo
    echo "| Estado | Fase | Prueba / paso |"
    echo "|---|---|---|"
  } >"${REPORT_FILE:-/dev/null}" 2>/dev/null
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r st ph desc <<<"$r"
    case "$st" in FAIL) ((nfail++)) ;; PENDING) ((npend++)) ;; WARN) ((nwarn++)) ;; PASS|MANUAL) ((npass++)) ;; esac
    echo "| $st | $ph | $desc |" >>"${REPORT_FILE:-/dev/null}" 2>/dev/null
  done
  printf '  OK: %d   Advertencias: %d   Pendientes manuales: %d   Fallas: %d   Cambios: %d\n' \
    "$npass" "$nwarn" "$npend" "$nfail" "$CHANGES"
  if ((nfail + npend > 0)); then
    echo "  A resolver:"
    for r in "${RESULTS[@]}"; do
      IFS='|' read -r st ph desc <<<"$r"
      [[ "$st" == FAIL || "$st" == PENDING ]] && printf '   - [%s] fase %s: %s\n' "$st" "$ph" "$desc"
    done
  fi
  [[ -n "${REPORT_FILE:-}" ]] && info "Reporte: $REPORT_FILE"
  if ((nfail)); then _SUMMARY_RC=1; elif ((npend)); then _SUMMARY_RC=3; else _SUMMARY_RC=0; fi
  return "$_SUMMARY_RC"
}

# --------------------------------------------------------------------------- #
# Funciones puras (testeadas en tests/test_common.sh)
# --------------------------------------------------------------------------- #
valid_ipv4() {
  local ip="$1" x; local -a o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a o <<<"$ip"
  for x in "${o[@]}"; do ((10#$x <= 255)) || return 1; done
}
ip_to_int() {
  local a b c d; IFS=. read -r a b c d <<<"$1"
  echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}
ip_in_cidr() {
  local net="${2%/*}" bits="${2#*/}" mask
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( ($(ip_to_int "$1") & mask) == ($(ip_to_int "$net") & mask) ))
}
ip_is_private() { ip_in_cidr "$1" 10.0.0.0/8 || ip_in_cidr "$1" 172.16.0.0/12 || ip_in_cidr "$1" 192.168.0.0/16; }
ip_is_cgnat()   { ip_in_cidr "$1" 100.64.0.0/10; }

parse_default_dev() { awk '$1=="default"{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
parse_default_gw()  { awk '$1=="default"{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}'; }
extract_hop_ips()   { grep -E '^ *[0-9]+\??:' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' ; }

# classify_path: IPs de saltos (una por línea) -> CGNAT | POSIBLE_DOBLE_NAT | OK | DESCONOCIDO
# Es un INDICIO: la prueba concluyente es wan_verdict (IP WAN del router vs pública).
classify_path() {
  local ip priv=0 cg=0 pub=0
  while read -r ip; do
    valid_ipv4 "$ip" || continue
    if ip_is_cgnat "$ip"; then cg=1
    elif ip_is_private "$ip"; then ((pub)) || priv=$((priv + 1))
    else pub=1; fi
  done
  if ((cg)); then echo CGNAT
  elif ((priv >= 2)); then echo POSIBLE_DOBLE_NAT
  elif ((pub)); then echo OK
  else echo DESCONOCIDO; fi
}

# wan_verdict IP_WAN_ROUTER IP_PUBLICA -> OK | CGNAT | DOBLE_NAT | DISTINTA | INVALIDA
wan_verdict() {
  valid_ipv4 "$1" || { echo INVALIDA; return; }
  if [[ "$1" == "$2" ]]; then echo OK
  elif ip_is_cgnat "$1"; then echo CGNAT
  elif ip_is_private "$1"; then echo DOBLE_NAT
  else echo DISTINTA; fi
}

valid_subdomain()   { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; }
valid_duckdns_token() { [[ "$1" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; }
valid_interval()    { [[ "$1" =~ ^[1-9][0-9]*(s|min|h)$ ]]; }
first_line()        { head -n1 | tr -d '[:space:]'; }

# --------------------------------------------------------------------------- #
# Red: diagnóstico compartido (solo lectura)
# --------------------------------------------------------------------------- #
public_ip() {
  local s ip
  for s in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4 -fsS --max-time 8 "$s" 2>/dev/null | tr -d '[:space:]')"
    valid_ipv4 "$ip" && { echo "$ip"; return 0; }
  done
  return 1
}

resolve_a() {  # resolve_a nombre [servidor]
  if command -v dig >/dev/null; then
    dig +short +time=3 +tries=2 A "$1" @"${2:-1.1.1.1}" 2>/dev/null | grep -E '^[0-9.]+$' | head -n1
  else
    getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'
  fi
}

tcp_open() { timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

port_listening() {  # port_listening tcp|udp PUERTO
  local f=-ltnH; [[ "$1" == udp ]] && f=-lunH
  ss "$f" "sport = :$2" 2>/dev/null | grep -q .
}

# net_diagnose: detecta interfaz, IP LAN, MAC, gateway, IP pública y forma del camino.
# Exporta NET_IFACE NET_IP NET_MAC NET_GW NET_PUBLIC NET_DHCP NET_PATH
net_diagnose() {
  local route prev
  route="$(ip -4 route show default 2>/dev/null)"
  NET_IFACE="$(parse_default_dev <<<"$route")"
  NET_GW="$(parse_default_gw <<<"$route")"
  if [[ -z "$NET_IFACE" ]]; then record FAIL "Hay ruta por defecto (salida a Internet)"; return 1; fi
  NET_IP="$(ip -4 -o addr show dev "$NET_IFACE" | awk '{split($4,a,"/"); print a[1]; exit}')"
  NET_MAC="$(cat "/sys/class/net/$NET_IFACE/address" 2>/dev/null)"
  if ip -4 -o addr show dev "$NET_IFACE" | grep -q dynamic; then NET_DHCP=1; else NET_DHCP=0; fi
  NET_PUBLIC="$(public_ip || true)"

  info "Interfaz   : $NET_IFACE   MAC: ${NET_MAC:-?}"
  info "IP LAN     : ${NET_IP:-?}  ($( ((NET_DHCP)) && echo 'asignada por DHCP' || echo 'estática'))"
  info "Gateway    : ${NET_GW:-?}  (panel del router: http://${NET_GW:-?})"
  info "IP pública : ${NET_PUBLIC:-no detectada}"

  record PASS "Ruta por defecto vía ${NET_GW} (${NET_IFACE})"
  if [[ -n "$NET_PUBLIC" ]]; then record PASS "IP pública detectada: $NET_PUBLIC"
  else record FAIL "No se pudo obtener la IP pública (¿sin Internet o salida HTTPS bloqueada?)"; fi

  if [[ -n "$NET_IP" ]] && ! ip_is_private "$NET_IP"; then
    record WARN "La máquina tiene IP no privada ($NET_IP): sin router en el medio, el firewall local es la única barrera"
  fi

  prev="$(state_get LAN_IP)"
  if [[ -n "$prev" && "$prev" != "$NET_IP" ]]; then
    record FAIL "La IP LAN cambió (antes $prev, ahora $NET_IP): actualizar reserva DHCP y port-forward"
  fi
  state_set LAN_IP "$NET_IP"; state_set LAN_MAC "$NET_MAC"; state_set LAN_GW "$NET_GW"; state_set LAN_IFACE "$NET_IFACE"

  if command -v tracepath >/dev/null; then
    NET_PATH="$(timeout 25 tracepath -n -m 6 1.1.1.1 2>/dev/null | extract_hop_ips | classify_path)"
    case "$NET_PATH" in
      CGNAT)             record WARN "Indicio fuerte de CGNAT: hay saltos en 100.64.0.0/10" ;;
      POSIBLE_DOBLE_NAT) record WARN "Varios saltos privados al inicio: posible doble NAT (se confirma con la IP WAN)" ;;
      OK)                record PASS "Camino de salida sin indicios de CGNAT" ;;
      *)                 record SKIP "No se pudo analizar el camino de salida (tracepath sin respuesta)" ;;
    esac
  else
    NET_PATH=DESCONOCIDO; record SKIP "tracepath no disponible: análisis de camino omitido"
  fi
}

# isp_checkpoint: prueba concluyente de CGNAT / doble NAT comparando la IP WAN del router.
isp_checkpoint() {
  local wan verdict prev_ok
  prev_ok="$(state_get NAT_STATUS)"
  wan="$(state_get ROUTER_WAN_IP)"
  if [[ "$prev_ok" == OK && "$wan" == "$NET_PUBLIC" ]]; then
    record PASS "Sin CGNAT (IP WAN del router = IP pública, verificado antes)"; return 0
  fi
  box "Leer la IP WAN del router" \
"Entrá al panel del router: http://${NET_GW}
Buscá Estado / WAN / Internet y anotá la «IP WAN» o «IP de Internet».
Esta comparación es la prueba concluyente de si el ISP te da IP pública real."
  if ! is_interactive; then record PENDING "Comparar IP WAN del router con la pública ($NET_PUBLIC)"; return 1; fi
  read -rp "  IP WAN que muestra el router (Enter para hacerlo después): " wan
  [[ -z "$wan" ]] && { record PENDING "Comparar IP WAN del router con la pública"; return 1; }
  verdict="$(wan_verdict "$wan" "$NET_PUBLIC")"
  state_set ROUTER_WAN_IP "$wan"; state_set NAT_STATUS "$verdict"
  case "$verdict" in
    OK) record PASS "Sin CGNAT: la IP WAN del router ($wan) coincide con la pública" ;;
    CGNAT|DISTINTA)
      record FAIL "El ISP no entrega IP pública propia (WAN $wan ≠ pública $NET_PUBLIC): CGNAT"
      manual_checkpoint ISP_PUBLIC_IP "Pedir IP pública al ISP (gestión con el proveedor)" \
"Con CGNAT las conexiones entrantes desde Internet NO llegan a tu router,
por más port-forward que configures. Hay que gestionarlo con el ISP:
  • Pedir: «IP pública (sin CGNAT) para habilitar acceso remoto entrante».
    Algunos ISP la dan a pedido; otros la cobran como IP fija.
  • Si el router lo administra el ISP, pedir también que carguen los
    reenvíos de puertos de la fase de router (los muestra 02-rustdesk-setup.sh).
Si no es posible: servidor RustDesk en un VPS con IP pública, o VPN overlay
(WireGuard/Tailscale) en lugar de abrir puertos.
Cuando el ISP lo resuelva, volvé a correr este script." ;;
    DOBLE_NAT)
      record WARN "Doble NAT: la WAN del router ($wan) es privada; hay otro equipo del ISP adelante"
      manual_checkpoint DOUBLE_NAT "Resolver doble NAT" \
"Hay dos equipos haciendo NAT en cascada (ONT/módem del ISP + tu router).
Opción A (recomendada): poner el equipo del ISP en modo bridge (pedirlo al ISP).
Opción B: reenviar los puertos en AMBOS:
          equipo ISP  -> IP WAN de tu router ($wan)
          tu router   -> IP LAN de la máquina (${NET_IP})" ;;
    *) record FAIL "IP WAN ingresada inválida: '$wan'" ;;
  esac
}

require_root() { [[ $EUID -eq 0 ]] || { echo "Ejecutar con sudo." >&2; exit 1; }; }
