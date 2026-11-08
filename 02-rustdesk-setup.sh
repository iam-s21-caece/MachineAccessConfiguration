#!/usr/bin/env bash
# =============================================================================
# 02-rustdesk-setup.sh — PASO 2 del camino: servidor RustDesk OSS (hbbs + hbbr)
#
# Requiere haber completado el paso 1 (01-duckdns-setup.sh).
#
# Fases:
#   0 Prerrequisitos      (root, SO, arquitectura, puertos libres, dominio resuelve)
#   1 Red LAN             (IP fija para el port-forward)       [+ACCIÓN MANUAL: reserva DHCP]
#   2 ISP / NAT           (CGNAT, doble NAT)                    [+ACCIÓN MANUAL: ISP]
#   3 Binarios            (descarga, sha256, instala solo si cambió)
#   4 Servicios           (usuario, units con hardening, puertos escuchando, clave)
#   5 Firewall local      (ufw, solo si ya está activo)
#   6 Router              (port-forward + prueba de alcance)    [+ACCIÓN MANUAL: router/ISP]
#   7 Cliente local       (opcional, --configure-client)
#   8 Ficha para el equipo
#
# Uso:
#   sudo ./02-rustdesk-setup.sh --domain miequipo.duckdns.org --check
#   sudo ./02-rustdesk-setup.sh --domain miequipo.duckdns.org --dry-run
#   sudo ./02-rustdesk-setup.sh --domain miequipo.duckdns.org
#   sudo ./02-rustdesk-setup.sh --domain miequipo.duckdns.org --configure-client
#   Opciones: --version 1.1.14 (fija versión)  --yes  --uninstall
#   Contraseña del cliente: se pide oculta, o RD_CLIENT_PASSWORD=... (nunca por argumento)
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_NAME="rustdesk"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly DATA_DIR="/var/lib/rustdesk-server"
readonly BIN_DIR="/usr/local/bin"
readonly SVC_USER="rustdesk"
readonly GH_REPO="rustdesk/rustdesk-server"
readonly TCP_PORTS=(21115 21116 21117)
readonly UDP_PORTS=(21116)

DOMAIN=""; RD_VERSION="latest"; CONFIGURE_CLIENT=0; ACTION="apply"
BIN_CHANGED=0; UNITS_CHANGED=0; PUBKEY=""

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)           DOMAIN="${2:?falta valor}"; shift 2 ;;
      --version)          RD_VERSION="${2:?falta valor}"; shift 2 ;;
      --configure-client) CONFIGURE_CLIENT=1; shift ;;
      --check)            CHECK_ONLY=1; DRY_RUN=1; shift ;;
      --dry-run)          DRY_RUN=1; shift ;;
      --yes)              ASSUME_YES=1; shift ;;
      --uninstall)        ACTION="uninstall"; shift ;;
      -h|--help)          usage 0 ;;
      *) echo "Argumento desconocido: $1" >&2; usage 1 ;;
    esac
  done
}

asset_for_arch() {
  case "$(uname -m)" in
    x86_64)        echo "rustdesk-server-linux-amd64.zip" ;;
    aarch64|arm64) echo "rustdesk-server-linux-arm64v8.zip" ;;
    armv7l)        echo "rustdesk-server-linux-armv7.zip" ;;
    *)             return 1 ;;
  esac
}

# Devuelve el proceso dueño de un puerto (vacío si está libre).
port_owner() {
  local f=-ltnpH; [[ "$1" == udp ]] && f=-lunpH
  ss "$f" "sport = :$2" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -n1 | cut -d'"' -f2
}

# --------------------------------------------------------------------------- #
phase0_prereqs() {
  phase 0 "Prerrequisitos"
  local os_id os_name   # se lee en subshell: os-release define VERSION, ID, etc.
  os_id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
  os_name="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
  if [[ "$os_id" == ubuntu ]]; then record PASS "SO: ${os_name}"
  else record WARN "SO '${os_name}': pensado para Ubuntu, se continúa"; fi
  check "systemd disponible" command -v systemctl || die "Se requiere systemd."
  ASSET="$(asset_for_arch)" || die "Arquitectura no soportada: $(uname -m)"
  record PASS "Arquitectura $(uname -m) → $ASSET"

  local missing=() c
  for c in curl unzip ss sha256sum; do command -v "$c" >/dev/null || missing+=("$c"); done
  if ((${#missing[@]})); then
    record WARN "Faltan herramientas: ${missing[*]} — se instalan"
    run apt-get update -qq; run apt-get install -y -qq curl unzip iproute2 coreutils
  else record PASS "Herramientas base disponibles (curl, unzip, ss, sha256sum)"; fi

  check "Acceso HTTPS a github.com (descarga de binarios)" \
    curl -fsS -o /dev/null --max-time 10 "https://github.com/${GH_REPO}" \
    || die "Sin acceso a GitHub: no se pueden descargar los binarios."

  [[ -z "$DOMAIN" ]] && [[ -n "$(state_get DUCKDNS_SUBDOMAIN)" ]] && DOMAIN="$(state_get DUCKDNS_SUBDOMAIN).duckdns.org"
  [[ -n "$DOMAIN" ]] || die "Falta --domain (ej: miequipo.duckdns.org). ¿Corriste 01-duckdns-setup.sh?"
  state_set RUSTDESK_DOMAIN "$DOMAIN"

  # Puertos: libres o ya tomados por hbbs/hbbr (re-ejecución).
  local p owner ok=1
  for p in "${TCP_PORTS[@]}"; do
    owner="$(port_owner tcp "$p")"
    if [[ -n "$owner" && "$owner" != hbbs && "$owner" != hbbr ]]; then
      record FAIL "Puerto TCP $p ocupado por '$owner'"; ok=0
    fi
  done
  for p in "${UDP_PORTS[@]}"; do
    owner="$(port_owner udp "$p")"
    [[ -n "$owner" && "$owner" != hbbs ]] && { record FAIL "Puerto UDP $p ocupado por '$owner'"; ok=0; }
  done
  ((ok)) && record PASS "Puertos 21115-21117/tcp y 21116/udp disponibles" \
         || die "Liberar los puertos ocupados antes de continuar."
}

# --------------------------------------------------------------------------- #
phase1_lan() {
  phase 1 "Red LAN: IP fija para el port-forward"
  net_diagnose
  local resolved; resolved="$(resolve_a "$DOMAIN")"
  if [[ -n "$NET_PUBLIC" && "$resolved" == "$NET_PUBLIC" ]]; then
    record PASS "$DOMAIN resuelve a la IP pública de esta red ($resolved)"
  else
    record WARN "$DOMAIN resuelve a '${resolved:-nada}' y la pública es '${NET_PUBLIC:-?}' → revisar paso 1 (01-duckdns-setup.sh --check)"
  fi

  if ((NET_DHCP)); then
    manual_checkpoint LAN_RESERVATION "Reservar la IP LAN de esta máquina en el router" \
"La IP ${NET_IP} la asigna el DHCP del router y puede cambiar; el port-forward
apunta a una IP fija, así que si cambia, el acceso se corta.
En el panel del router (http://${NET_GW}) → LAN / DHCP → «Reserva de direcciones»
(Address Reservation / Static Lease / IP fija por MAC) cargar:
    MAC: ${NET_MAC}     IP: ${NET_IP}
Si el router es del ISP y no tenés acceso al panel, pedirlo al ISP junto con
los reenvíos de puertos de la fase 6.
(El script no fija IP estática en Ubuntu a propósito: un error ahí corta la red
 y el acceso remoto; la reserva en el router es más segura y reversible.)"
  else
    record PASS "IP LAN estática configurada en el sistema ($NET_IP)"
  fi
}

# --------------------------------------------------------------------------- #
phase2_isp() {
  phase 2 "ISP / NAT: ¿llegan conexiones entrantes a esta red?"
  isp_checkpoint
}

# --------------------------------------------------------------------------- #
resolve_version_tag() {
  if [[ "$RD_VERSION" != latest ]]; then echo "$RD_VERSION"; return; fi
  curl -fsSI -o /dev/null -w '%{redirect_url}' --max-time 10 \
    "https://github.com/${GH_REPO}/releases/latest" 2>/dev/null | sed -n 's|.*/tag/||p'
}

phase3_binaries() {
  phase 3 "Binarios del servidor"
  local tag cur_tag
  tag="$(resolve_version_tag)"; cur_tag="$(state_get RUSTDESK_VERSION)"
  info "Versión objetivo: ${tag:-desconocida (latest)} | instalada: ${cur_tag:-ninguna}"

  if [[ -n "$tag" && "$tag" == "$cur_tag" && -x "$BIN_DIR/hbbs" && -x "$BIN_DIR/hbbr" ]] \
     && [[ "$(sha256sum "$BIN_DIR/hbbs" | cut -d' ' -f1)" == "$(state_get HBBS_SHA256)" ]]; then
    record PASS "Versión $tag ya instalada e íntegra (sha256 coincide): no se descarga"; return
  fi
  if ((DRY_RUN)); then
    info "[plan] descargar ${ASSET} (${tag:-latest}), verificar contenido e instalar hbbs/hbbr en $BIN_DIR"
    record SKIP "Descarga omitida en modo $(mode_name)"; return
  fi

  local stage="$RD_STATE_DIR/staging-$RUN_ID" url
  mkdir -p "$stage"
  if [[ -n "$tag" ]]; then url="https://github.com/${GH_REPO}/releases/download/${tag}/${ASSET}"
  else url="https://github.com/${GH_REPO}/releases/latest/download/${ASSET}"; fi
  run curl -fL --retry 3 --proto '=https' -o "$stage/server.zip" "$url"
  run unzip -q -o "$stage/server.zip" -d "$stage/x"

  local f src new_sha
  for f in hbbs hbbr; do
    src="$(find "$stage/x" -type f -name "$f" | head -n1)"
    [[ -n "$src" ]] || die "El zip no contiene '$f' (¿cambió el formato del release?)."
    new_sha="$(sha256sum "$src" | cut -d' ' -f1)"
    info "$f sha256: $new_sha"
    if [[ -x "$BIN_DIR/$f" ]] && [[ "$(sha256sum "$BIN_DIR/$f" | cut -d' ' -f1)" == "$new_sha" ]]; then
      info "$f idéntico al instalado"
    else
      [[ -f "$BIN_DIR/$f" ]] && cp -p "$BIN_DIR/$f" "$RD_STATE_DIR/backup/$f.$RUN_ID"
      run install -m 0755 "$src" "$BIN_DIR/$f"; manifest_add "$BIN_DIR/$f"; BIN_CHANGED=1; CHANGES=$((CHANGES + 1))
    fi
    [[ "$f" == hbbs ]] && state_set HBBS_SHA256 "$new_sha"
  done
  rm -rf "$stage"
  state_set RUSTDESK_VERSION "${tag:-latest}"
  record PASS "Binarios hbbs/hbbr ${tag:-latest} instalados en $BIN_DIR $( ((BIN_CHANGED)) || echo '(sin cambios)')"
}

# --------------------------------------------------------------------------- #
unit_content() {  # unit_content nombre "ExecStart" "Descripción"
  cat <<EOF
# Instalado por 02-rustdesk-setup.sh
[Unit]
Description=$3
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=${DATA_DIR}
ExecStart=$2
Restart=on-failure
RestartSec=5
LimitNOFILE=1000000
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF
}

all_ports_listening() {
  local p
  for p in "${TCP_PORTS[@]}"; do port_listening tcp "$p" || return 1; done
  for p in "${UDP_PORTS[@]}"; do port_listening udp "$p" || return 1; done
}

phase4_services() {
  phase 4 "Servicios hbbs (ID) y hbbr (relay)"
  if ! id "$SVC_USER" &>/dev/null; then
    run useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SVC_USER"
  else info "usuario '$SVC_USER' ya existe"; fi
  if [[ ! -d "$DATA_DIR" ]]; then
    run install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$DATA_DIR"; manifest_add "$DATA_DIR"
  fi

  # -r: relay que hbbs anuncia a los clientes | -k _: rechaza clientes sin la clave pública
  # (process substitution, no pipe: write_file debe correr en este shell para registrar cambios)
  write_file /etc/systemd/system/rustdesk-hbbs.service 0644 root:root \
    < <(unit_content hbbs "${BIN_DIR}/hbbs -r ${DOMAIN}:21117 -k _" "RustDesk ID/Rendezvous server (hbbs)") \
    && UNITS_CHANGED=1
  write_file /etc/systemd/system/rustdesk-hbbr.service 0644 root:root \
    < <(unit_content hbbr "${BIN_DIR}/hbbr -k _" "RustDesk Relay server (hbbr)") \
    && UNITS_CHANGED=1

  ((UNITS_CHANGED)) && run systemctl daemon-reload
  local s
  for s in rustdesk-hbbs rustdesk-hbbr; do
    systemctl is-enabled --quiet "$s" 2>/dev/null || run systemctl enable "$s"
    if ((UNITS_CHANGED || BIN_CHANGED)) || ! systemctl is-active --quiet "$s"; then
      run systemctl restart "$s"
    else info "$s activo y sin cambios: no se reinicia"; fi
  done

  check "Servicio rustdesk-hbbs activo" systemctl is-active --quiet rustdesk-hbbs
  check "Servicio rustdesk-hbbr activo" systemctl is-active --quiet rustdesk-hbbr
  if retry 10 1 all_ports_listening; then record PASS "Escuchando en 21115-21117/tcp y 21116/udp"
  else record FAIL "No están todos los puertos escuchando (ss -tulpn | grep 2111; journalctl -u rustdesk-hbbs)"; fi

  if retry 10 1 test -s "$DATA_DIR/id_ed25519.pub"; then
    PUBKEY="$(cat "$DATA_DIR/id_ed25519.pub")"
    local ksha prev; ksha="$(sha256sum "$DATA_DIR/id_ed25519.pub" | cut -d' ' -f1)"; prev="$(state_get KEY_SHA256)"
    if [[ -n "$prev" && "$prev" != "$ksha" ]]; then
      record FAIL "La clave del servidor CAMBIÓ respecto de la ejecución anterior: todos los clientes deben actualizarla"
    else record PASS "Par de claves presente y estable"; fi
    state_set KEY_SHA256 "$ksha"
    check "Clave privada con permisos restringidos" bash -c "[[ \$(stat -c '%a' '$DATA_DIR/id_ed25519') =~ ^[46]00$ ]]"
  else
    record FAIL "hbbs no generó la clave ($DATA_DIR/id_ed25519.pub)"
  fi
}

# --------------------------------------------------------------------------- #
phase5_firewall() {
  phase 5 "Firewall local (ufw)"
  if ! command -v ufw >/dev/null; then record SKIP "ufw no instalado"; return; fi
  if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    record SKIP "ufw inactivo: no se activa automáticamente (podría cortar accesos existentes, ej. SSH)"
    info "Si deciden activarlo: sudo ufw allow OpenSSH && re-ejecutar este script && sudo ufw enable"
    return
  fi
  local st; st="$(ufw status)"
  grep -q "21115:21117/tcp.*ALLOW" <<<"$st" || run ufw allow 21115:21117/tcp comment 'RustDesk hbbs/hbbr'
  grep -q "21116/udp.*ALLOW"       <<<"$st" || run ufw allow 21116/udp comment 'RustDesk hbbs NAT'
  st="$(ufw status)"
  if grep -q "21115:21117/tcp.*ALLOW" <<<"$st" && grep -q "21116/udp.*ALLOW" <<<"$st"; then
    record PASS "ufw permite 21115-21117/tcp y 21116/udp"
  else record FAIL "Reglas ufw no presentes"; fi
}

# --------------------------------------------------------------------------- #
hairpin_ok() {
  [[ -n "${NET_PUBLIC:-}" ]] || return 1
  local p; for p in "${TCP_PORTS[@]}"; do tcp_open "$NET_PUBLIC" "$p" || return 1; done
}

phase6_router() {
  phase 6 "Router: reenvío de puertos hacia esta máquina"
  local nat; nat="$(state_get NAT_STATUS)"
  if [[ "$nat" == CGNAT || "$nat" == DISTINTA ]]; then
    record PENDING "Port-forward: no tiene efecto hasta que el ISP quite el CGNAT (fase 2)"
  fi
  manual_checkpoint PORT_FORWARD "Reenviar puertos en el router" \
"Panel del router: http://${NET_GW} → NAT / Port Forwarding / Servidores virtuales.
Crear estas reglas (IP interna = la reservada en la fase 1):

  Protocolo  Puerto externo   IP interna        Puerto interno   Uso
  TCP        21115            ${NET_IP}   21115            prueba de NAT
  TCP        21116            ${NET_IP}   21116            servidor de ID
  UDP        21116            ${NET_IP}   21116            registro / NAT traversal
  TCP        21117            ${NET_IP}   21117            relay

NO usar DMZ ni abrir rangos extra (21118-21119 solo si usan el cliente web).
Si el router lo administra el ISP: pedirles exactamente esta tabla.
Si hay doble NAT (fase 2): repetir en el equipo del ISP hacia la WAN de tu router." \
    hairpin_ok

  # Prueba de alcance: desde adentro solo funciona si el router soporta NAT loopback.
  if hairpin_ok; then
    record PASS "Puertos TCP alcanzables vía IP pública desde la LAN (NAT loopback OK)"
  else
    record WARN "Desde la LAN no se alcanza la IP pública (normal si el router no hace NAT loopback)"
    box "Probar desde una red externa (datos móviles, otra casa)" \
"Linux/macOS :  for p in 21115 21116 21117; do nc -vz -w5 ${DOMAIN} \$p; done
Windows (PS):  21115..21117 | % { Test-NetConnection ${DOMAIN} -Port \$_ } | ft ComputerName,RemotePort,TcpTestSucceeded
Los tres deben dar «succeeded» / True."
    if is_interactive; then
      local ans; read -rp "  Resultado de la prueba externa [o]k / [f]alló / [d]espués: " ans
      case "${ans,,}" in
        o*) record MANUAL "Prueba externa de puertos OK (informada por el operador)"; state_set EXTERNAL_TEST ok ;;
        f*) record FAIL "Prueba externa falló: revisar port-forward, IP reservada, CGNAT y firewall" ;;
        *)  record PENDING "Prueba externa de puertos" ;;
      esac
    else
      [[ "$(state_get EXTERNAL_TEST)" == ok ]] && record PASS "Prueba externa OK (ejecución anterior)" \
        || record PENDING "Prueba externa de puertos"
    fi
  fi
}

# --------------------------------------------------------------------------- #
client_configured() {
  grep -qs "$DOMAIN" /root/.config/rustdesk/RustDesk2.toml /home/*/.config/rustdesk/RustDesk2.toml
}

phase7_client() {
  phase 7 "Cliente RustDesk de esta máquina"
  if ((CONFIGURE_CLIENT == 0)); then
    client_configured && record PASS "Cliente local ya apunta a $DOMAIN" \
      || record SKIP "Configuración del cliente local no pedida (--configure-client)"
    return
  fi
  if ! command -v rustdesk >/dev/null; then
    record PENDING "Instalar el cliente RustDesk (.deb de github.com/rustdesk/rustdesk/releases) y re-ejecutar con --configure-client"
    return
  fi
  [[ -n "$PUBKEY" ]] || { record FAIL "Sin clave pública del servidor (fase 4)"; return; }

  local pw="${RD_CLIENT_PASSWORD:-}" pw2
  if [[ -z "$pw" ]] && is_interactive; then
    read -rsp "  Contraseña permanente para acceso desatendido (Enter = no cambiar): " pw; echo
    if [[ -n "$pw" ]]; then read -rsp "  Repetir: " pw2; echo; [[ "$pw" == "$pw2" ]] || { record FAIL "Las contraseñas no coinciden"; pw=""; }; fi
  fi
  [[ -n "$pw" && ${#pw} -lt 12 ]] && record WARN "Contraseña de menos de 12 caracteres"

  run rustdesk --option custom-rendezvous-server "$DOMAIN"
  run rustdesk --option relay-server "$DOMAIN"
  run rustdesk --option key "$PUBKEY"
  if [[ -n "$pw" ]]; then
    if ((DRY_RUN)); then info "[plan] rustdesk --password ********"
    else rustdesk --password "$pw" >/dev/null 2>&1 && record PASS "Contraseña permanente establecida" \
         || record FAIL "No se pudo fijar la contraseña"; fi
  fi
  ((DRY_RUN)) || systemctl restart rustdesk 2>/dev/null
  if retry 5 1 client_configured; then record PASS "Cliente local apunta a $DOMAIN"
  else record FAIL "No se encontró $DOMAIN en la config del cliente (RustDesk2.toml)"; fi
  local rid; rid="$(rustdesk --get-id 2>/dev/null)"
  [[ -n "$rid" ]] && { record PASS "ID RustDesk de esta máquina: $rid"; state_set RUSTDESK_ID "$rid"; }

  local s wl=0
  for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    [[ "$(loginctl show-session "$s" -p Type --value 2>/dev/null)" == wayland ]] && wl=1
  done
  if ((wl)); then
    record WARN "Sesión Wayland activa: el acceso desatendido es más estable con Xorg"
    box "Pasar el escritorio a Xorg (cuando se pueda reiniciar)" \
"Editar /etc/gdm3/custom.conf y dejar:  WaylandEnable=false
Luego reiniciar la máquina (se cierra la sesión gráfica).
No se hace automático porque corta la sesión de quien esté usando la máquina."
  fi
}

# --------------------------------------------------------------------------- #
phase8_card() {
  phase 8 "Ficha para el equipo"
  [[ -n "$PUBKEY" ]] || PUBKEY="$(cat "$DATA_DIR/id_ed25519.pub" 2>/dev/null)"
  local card="$RD_STATE_DIR/ficha-equipo.txt"
  local body
  body="Servidor RustDesk del equipo — generado ${RUN_ID}
ID server   : ${DOMAIN}
Relay server: ${DOMAIN}
Key         : ${PUBKEY:-(pendiente)}
ID máquina  : $(state_get RUSTDESK_ID)

Cada integrante: RustDesk → Ajustes → Red → Servidor ID/Relay → cargar los datos.
La contraseña de acceso se comparte por un canal privado, nunca en esta ficha.
RustDesk comparte UN mismo escritorio: si dos personas se conectan a la vez,
ven y controlan la misma pantalla."
  printf '%s\n' "$body"
  if ((DRY_RUN == 0)); then printf '%s\n' "$body" >"$card"; chmod 644 "$card"; info "Guardada en $card"; fi
}

# --------------------------------------------------------------------------- #
uninstall() {
  phase U "Desinstalación (según manifiesto; claves conservadas)"
  run systemctl disable --now rustdesk-hbbs rustdesk-hbbr
  local f mf="$RD_STATE_DIR/manifest-${TOOL_NAME}"
  if [[ -f "$mf" ]]; then
    tac "$mf" | while read -r f; do
      [[ "$f" == "$DATA_DIR" ]] && continue          # las claves no se borran
      [[ -f "$f" ]] && run rm -f "$f"
    done
  fi
  run systemctl daemon-reload
  record PASS "Servicios y binarios eliminados. Claves en $DATA_DIR (borrar a mano si corresponde)"
  record INFO "Reglas del router y reserva DHCP: quitarlas a mano si ya no se usan"
}

main() {
  parse_args "$@"
  require_root
  init_trace
  if [[ "$ACTION" == uninstall ]]; then uninstall; summary; exit $?; fi
  phase0_prereqs
  phase1_lan
  phase2_isp
  phase3_binaries
  phase4_services
  phase5_firewall
  phase6_router
  phase7_client
  phase8_card
  summary; exit $?
}

main "$@"
