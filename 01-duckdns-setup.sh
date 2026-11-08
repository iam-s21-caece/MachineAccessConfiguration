#!/usr/bin/env bash
# =============================================================================
# 01-duckdns-setup.sh — PASO 1 del camino: DNS dinámico con DuckDNS
#
# Deja un subdominio DuckDNS apuntando a la IP pública de la red de esta
# máquina, actualizado por un timer de systemd.
#
# Fases:
#   0 Prerrequisitos        (root, systemd, curl, acceso a DuckDNS, datos)
#   1 Diagnóstico de red    (IP LAN, gateway, IP pública, CGNAT/doble NAT) [+ACCIÓN MANUAL: ISP]
#   2 Validar credenciales  (prueba el token ANTES de instalar nada)
#   3 Instalación           (credenciales 0600, actualizador, service + timer)
#   4 Verificación          (actualización OK, DNS = IP pública, timer activo)
#
# Uso:
#   sudo ./01-duckdns-setup.sh --subdomain miequipo --check     # solo pruebas
#   sudo ./01-duckdns-setup.sh --subdomain miequipo --dry-run   # ver plan
#   sudo ./01-duckdns-setup.sh --subdomain miequipo             # aplicar (pide token oculto)
#   sudo DUCKDNS_TOKEN=xxxx ./01-duckdns-setup.sh --subdomain miequipo --yes
#   Opciones: --interval 5min  --ipv6  --uninstall
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_NAME="duckdns"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly CONF_DIR="/etc/duckdns"
readonly ENV_FILE="$CONF_DIR/duckdns.env"
readonly UPDATER="/usr/local/bin/duckdns-update"
readonly UNIT="duckdns-update"

SUBDOMAIN=""; TOKEN="${DUCKDNS_TOKEN:-}"; INTERVAL="5min"; IPV6=0; ACTION="apply"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subdomain) SUBDOMAIN="${2:?falta valor}"; shift 2 ;;
      --interval)  INTERVAL="${2:?falta valor}"; shift 2 ;;
      --ipv6)      IPV6=1; shift ;;
      --check)     CHECK_ONLY=1; DRY_RUN=1; shift ;;
      --dry-run)   DRY_RUN=1; shift ;;
      --yes)       ASSUME_YES=1; shift ;;
      --uninstall) ACTION="uninstall"; shift ;;
      -h|--help)   usage 0 ;;
      *) echo "Argumento desconocido: $1" >&2; usage 1 ;;
    esac
  done
}

# --------------------------------------------------------------------------- #
phase0_prereqs() {
  phase 0 "Prerrequisitos"
  check "systemd disponible" command -v systemctl || die "Se requiere systemd."
  if ! command -v curl >/dev/null; then
    record WARN "curl no instalado: se instala"
    run apt-get update -qq; run apt-get install -y -qq curl
  else record PASS "curl disponible"; fi
  command -v dig >/dev/null && record PASS "dig disponible (consulta DNS directa a DuckDNS)" \
    || record INFO "dig no instalado: se usa el resolver del sistema (puede tener caché). Opcional: apt install dnsutils"

  check "Acceso HTTPS a www.duckdns.org" curl -fsS -o /dev/null --max-time 10 https://www.duckdns.org \
    || die "Sin acceso a DuckDNS: revisar Internet / proxy / firewall de salida."

  SUBDOMAIN="${SUBDOMAIN%.duckdns.org}"
  [[ -z "$SUBDOMAIN" ]] && SUBDOMAIN="$(state_get DUCKDNS_SUBDOMAIN)"
  [[ -n "$SUBDOMAIN" ]] || die "Falta --subdomain (lo creás en https://www.duckdns.org)."
  check "Subdominio válido: ${SUBDOMAIN}.duckdns.org" valid_subdomain "$SUBDOMAIN" || die "Subdominio inválido."
  check "Intervalo válido: $INTERVAL" valid_interval "$INTERVAL" || die "Intervalo inválido (ej: 5min, 300s, 1h)."

  # Token: reutiliza el instalado si no se pasa uno nuevo (no se vuelve a pedir).
  if [[ -z "$TOKEN" && -r "$ENV_FILE" ]]; then
    TOKEN="$(sed -n 's/^DUCKDNS_TOKEN=//p' "$ENV_FILE")"
    [[ -n "$TOKEN" ]] && record PASS "Token existente reutilizado ($ENV_FILE)"
  fi
  if [[ -z "$TOKEN" ]]; then
    if is_interactive; then read -rsp "  Token de DuckDNS (no se muestra): " TOKEN; echo
    else record PENDING "Token de DuckDNS (pasarlo con DUCKDNS_TOKEN=... o en modo interactivo)"; fi
  fi
  if [[ -n "$TOKEN" ]]; then
    check "Formato de token válido (UUID)" valid_duckdns_token "$TOKEN" || die "Token con formato inválido."
  fi
}

# --------------------------------------------------------------------------- #
phase1_network() {
  phase 1 "Diagnóstico de red (solo lectura)"
  net_diagnose
  isp_checkpoint
  local nat; nat="$(state_get NAT_STATUS)"
  if [[ "$nat" == CGNAT || "$nat" == DISTINTA ]]; then
    warn "Con CGNAT el DNS apuntaría a una IP compartida: no sirve para conexiones entrantes."
    if ! ask_yes_no "¿Instalar igual, para que quede listo cuando el ISP asigne IP pública?" n; then
      record SKIP "Instalación postergada hasta resolver CGNAT con el ISP"; summary; exit $?
    fi
  fi
}

# --------------------------------------------------------------------------- #
duckdns_update_now() {  # imprime la respuesta de DuckDNS (token por stdin, no visible en ps)
  printf 'url = "https://www.duckdns.org/update?domains=%s&token=%s&ip=&verbose=true"\n' \
    "$SUBDOMAIN" "$TOKEN" | curl -4 -fsS --max-time 20 -K - 2>&1
}

phase2_validate() {
  phase 2 "Validar credenciales contra DuckDNS (antes de instalar)"
  if [[ -z "$TOKEN" ]]; then record SKIP "Sin token: validación omitida"; return; fi
  if ((DRY_RUN)); then record SKIP "Validación omitida en modo $(mode_name)"; return; fi
  local resp; resp="$(duckdns_update_now)"
  if [[ "$(first_line <<<"$resp")" == OK ]]; then
    record PASS "DuckDNS aceptó subdominio + token (registro actualizado a la IP actual)"
  else
    die "DuckDNS respondió '$(first_line <<<"$resp")': subdominio o token incorrectos. No se instaló nada."
  fi
}

# --------------------------------------------------------------------------- #
UNITS_CHANGED=0
phase3_install() {
  phase 3 "Instalación (credenciales, actualizador, service + timer)"
  if [[ -z "$TOKEN" ]]; then record SKIP "Sin token: instalación omitida"; return; fi

  ((DRY_RUN)) || { install -d -m 0700 -o root -g root "$CONF_DIR"; manifest_add "$CONF_DIR"; }
  write_file "$ENV_FILE" 0600 root:root <<EOF
DUCKDNS_DOMAINS=${SUBDOMAIN}
DUCKDNS_TOKEN=${TOKEN}
DUCKDNS_IPV6=${IPV6}
EOF
  state_set DUCKDNS_SUBDOMAIN "$SUBDOMAIN"

  write_file "$UPDATER" 0755 root:root <<'EOF'
#!/usr/bin/env bash
# duckdns-update — instalado por 01-duckdns-setup.sh. Corre vía systemd (duckdns-update.service).
set -uo pipefail
: "${DUCKDNS_DOMAINS:?}" "${DUCKDNS_TOKEN:?}"
url="https://www.duckdns.org/update?domains=${DUCKDNS_DOMAINS}&token=${DUCKDNS_TOKEN}&verbose=true&ip="
if [[ "${DUCKDNS_IPV6:-0}" == "1" ]]; then
  v6="$(curl -6 -fsS --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
  [[ -n "$v6" ]] && url+="&ipv6=${v6}"
fi
# URL por stdin: el token no aparece en la lista de procesos.
resp="$(printf 'url = "%s"\n' "$url" | curl -4 -fsS --max-time 20 --retry 3 -K - 2>&1)"
if [[ "$(head -n1 <<<"$resp")" == "OK" ]]; then
  echo "OK ${DUCKDNS_DOMAINS}.duckdns.org -> $(sed -n 2p <<<"$resp") ($(sed -n 4p <<<"$resp"))"
else
  echo "ERROR respuesta='$(head -n1 <<<"$resp")' (revisar subdominio/token)" >&2; exit 1
fi
EOF

  write_file "/etc/systemd/system/${UNIT}.service" 0644 root:root <<EOF && UNITS_CHANGED=1
# Instalado por 01-duckdns-setup.sh
[Unit]
Description=Actualiza la IP pública en DuckDNS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
ExecStart=${UPDATER}
DynamicUser=yes
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=
EOF

  write_file "/etc/systemd/system/${UNIT}.timer" 0644 root:root <<EOF && UNITS_CHANGED=1
# Instalado por 01-duckdns-setup.sh
[Unit]
Description=Ejecuta duckdns-update cada ${INTERVAL}

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}
RandomizedDelaySec=20s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  ((UNITS_CHANGED)) && run systemctl daemon-reload
  if systemctl is-enabled --quiet "${UNIT}.timer" 2>/dev/null && systemctl is-active --quiet "${UNIT}.timer"; then
    if ((UNITS_CHANGED)); then run systemctl restart "${UNIT}.timer"; else info "timer ya habilitado y activo"; fi
  else
    run systemctl enable --now "${UNIT}.timer"
  fi
}

# --------------------------------------------------------------------------- #
dns_matches_public() {
  local got; got="$(resolve_a "${SUBDOMAIN}.duckdns.org" ns1.duckdns.org)"
  [[ -n "$got" && "$got" == "$NET_PUBLIC" ]]
}

phase4_verify() {
  phase 4 "Verificación"
  if ((DRY_RUN == 0)) && [[ -n "$TOKEN" ]]; then
    run systemctl start "${UNIT}.service"
  fi
  if [[ "$(systemctl show -p Result --value "${UNIT}.service" 2>/dev/null)" == success ]] \
     && [[ -n "$(systemctl show -p ExecMainExitTimestamp --value "${UNIT}.service" 2>/dev/null)" ]]; then
    record PASS "Última ejecución del actualizador: OK ($(journalctl -u "${UNIT}.service" -n1 -o cat --no-pager 2>/dev/null))"
  else
    record FAIL "El actualizador no tiene una ejecución exitosa (journalctl -u ${UNIT}.service -n 20)"
  fi
  check "Timer ${UNIT}.timer habilitado" systemctl is-enabled --quiet "${UNIT}.timer"
  check "Timer ${UNIT}.timer activo" systemctl is-active --quiet "${UNIT}.timer" \
    && info "Próxima ejecución: $(systemctl show -p NextElapseUSecRealtime --value "${UNIT}.timer")"
  check "Credenciales con permisos 0600 root" bash -c "[[ \$(stat -c '%a %U' '$ENV_FILE') == '600 root' ]]"

  if [[ -n "$NET_PUBLIC" ]]; then
    if retry 5 3 dns_matches_public; then
      record PASS "DNS ${SUBDOMAIN}.duckdns.org = IP pública ($NET_PUBLIC)"
    else
      record FAIL "DNS ${SUBDOMAIN}.duckdns.org = '$(resolve_a "${SUBDOMAIN}.duckdns.org" ns1.duckdns.org)' ≠ pública $NET_PUBLIC"
    fi
  fi
}

# --------------------------------------------------------------------------- #
uninstall() {
  phase U "Desinstalación (según manifiesto)"
  run systemctl disable --now "${UNIT}.timer"
  local f mf="$RD_STATE_DIR/manifest-${TOOL_NAME}"
  if [[ -f "$mf" ]]; then
    tac "$mf" | while read -r f; do
      [[ -d "$f" ]] && run rmdir --ignore-fail-on-non-empty "$f" || { [[ -e "$f" ]] && run rm -f "$f"; }
    done
    ((DRY_RUN)) || rm -f "$mf"
  fi
  run systemctl daemon-reload
  record PASS "Eliminado: timer, service, actualizador y credenciales. Backups en $RD_STATE_DIR/backup"
}

main() {
  parse_args "$@"
  require_root
  init_trace
  if [[ "$ACTION" == uninstall ]]; then uninstall; summary; exit $?; fi
  phase0_prereqs
  phase1_network
  phase2_validate
  phase3_install
  phase4_verify
  summary; local rc=$?
  ((rc == 0 && CHECK_ONLY == 0)) && log "Siguiente paso: sudo ./02-rustdesk-setup.sh --domain ${SUBDOMAIN}.duckdns.org"
  exit "$rc"
}

main "$@"
