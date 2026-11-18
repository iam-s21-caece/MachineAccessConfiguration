#!/usr/bin/env bash
# =============================================================================
# 03-xrdp-setup.sh — PASO 3 del camino: multisesión con xrdp
#
# Complementa los pasos 1 (DuckDNS) y 2 (RustDesk) SIN modificarlos: agrega un
# escritorio XFCE independiente por integrante, cada uno con su usuario Linux,
# accesible desde el cliente de Escritorio remoto (mstsc / Remmina / xfreerdp).
#   RustDesk  → pantalla física (administración, mirar algo todos juntos)
#   xrdp      → una sesión propia por persona, en paralelo
#
# Fases:
#   0 Prerrequisitos   (SO, usuarios, modo de acceso, RAM, puerto 3389)   [+MANUAL: Escritorio remoto de GNOME]
#   1 Paquetes         (xrdp, xorgxrdp, XFCE — solo los que falten, sin cambiar GDM)
#   2 Usuarios         (uno por integrante, grupo tsusers, contraseñas)
#   3 Configuración    (xrdp.ini, sesman.ini, startwm.sh, polkit, servicios, ufw)
#   4 Acceso           (túnel RustDesk | port-forward | VPN)               [+MANUAL según el modo]
#   5 Verificación     (servicios, escucha, protocolo RDP, grupo, TLS, config)
#   6 Ficha de conexión para el equipo
#
# Modos de acceso (--access):
#   tunnel      xrdp escucha SOLO en 127.0.0.1; se llega por el túnel TCP de RustDesk.
#               No abre puertos nuevos. (recomendado, por defecto)
#   portforward xrdp escucha en todas las interfaces; regla en el router (expone RDP).
#   vpn         xrdp escucha en todas las interfaces; se entra por una VPN existente.
#
# Uso:
#   sudo ./03-xrdp-setup.sh --users ana,juan,pedro --check
#   sudo ./03-xrdp-setup.sh --users ana,juan,pedro --dry-run
#   sudo ./03-xrdp-setup.sh --users ana,juan,pedro --access tunnel
#   sudo ./03-xrdp-setup.sh --users ana,juan,pedro,lucia          (agregar un integrante)
#   sudo ./03-xrdp-setup.sh --reset-password juan                 (nueva contraseña)
#   Opciones: --listen local|all  --port 3389  --external-port N  --max-sessions N
#             --disable-gnome-rd  --yes  --uninstall [--purge-packages]
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_NAME="xrdp"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/xrdp.sh
source "$SCRIPT_DIR/lib/xrdp.sh"

readonly XRDP_INI="/etc/xrdp/xrdp.ini"
readonly SESMAN_INI="/etc/xrdp/sesman.ini"
readonly STARTWM="/etc/xrdp/startwm.sh"
readonly XR_GROUP="tsusers"
readonly PKGS=(xrdp xorgxrdp xfce4 xfce4-terminal dbus-x11)
readonly POLKIT_JS="/etc/polkit-1/rules.d/45-xrdp-colord.rules"
readonly POLKIT_PKLA="/etc/polkit-1/localauthority/50-local.d/45-xrdp-colord.pkla"
readonly MARKER="Gestionado por 03-xrdp-setup.sh"

USERS_ARG=""; ACCESS=""; LISTEN=""; PORT=""; EXT_PORT=""; MAX_SESSIONS=""
DISABLE_GRD=0; ACTION="apply"; PURGE=0
RESET_PW=(); USERS=(); NEW_CREDS=()
CONF_CHANGED=0; RESTART_PENDING=0

usage() { sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --users)            USERS_ARG="${2:?falta valor}"; shift 2 ;;
      --access)           ACCESS="${2:?falta valor}"; shift 2 ;;
      --listen)           LISTEN="${2:?falta valor}"; shift 2 ;;
      --port)             PORT="${2:?falta valor}"; shift 2 ;;
      --external-port)    EXT_PORT="${2:?falta valor}"; shift 2 ;;
      --max-sessions)     MAX_SESSIONS="${2:?falta valor}"; shift 2 ;;
      --reset-password)   RESET_PW+=("${2:?falta valor}"); shift 2 ;;
      --disable-gnome-rd) DISABLE_GRD=1; shift ;;
      --check)            CHECK_ONLY=1; DRY_RUN=1; shift ;;
      --dry-run)          DRY_RUN=1; shift ;;
      --yes)              ASSUME_YES=1; shift ;;
      --uninstall)        ACTION="uninstall"; shift ;;
      --purge-packages)   PURGE=1; shift ;;
      -h|--help)          usage 0 ;;
      *) echo "Argumento desconocido: $1" >&2; usage 1 ;;
    esac
  done
}

# --------------------------------------------------------------------------- #
# Helpers de sistema (solo lectura)
# --------------------------------------------------------------------------- #
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

port_owner() {
  ss -ltnpH "sport = :$1" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -n1 | cut -d'"' -f2
}

domain_or_placeholder() { local d; d="$(state_get RUSTDESK_DOMAIN)"; echo "${d:-<dominio>}"; }

port_free_or_xrdp() { local o; o="$(port_owner "$PORT")"; [[ -z "$o" || "$o" == xrdp ]]; }

session_ids() { loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'; }

xrdp_sessions_count() {
  local s n=0
  for s in $(session_ids); do
    [[ "$(loginctl show-session "$s" -p Service --value 2>/dev/null)" == xrdp-sesman ]] && n=$((n + 1))
  done
  echo "$n"
}

console_users() {  # usuarios con sesión en la pantalla física (seat0)
  local s
  for s in $(session_ids); do
    [[ "$(loginctl show-session "$s" -p Seat --value 2>/dev/null)" == seat0 ]] \
      && loginctl show-session "$s" -p Name --value 2>/dev/null
  done | sort -u
}

in_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }


listen_addrs() { ss -ltnH "sport = :$PORT" 2>/dev/null | awk '{print $4}'; }

choose_access() {
  {
    echo "  ¿Cómo van a llegar los integrantes a sus sesiones xrdp?"
    echo "   1) tunnel      — túnel TCP de RustDesk (recomendado: no abre puertos nuevos)"
    echo "   2) portforward — regla en el router hacia esta máquina (expone RDP a Internet)"
    echo "   3) vpn         — a través de una VPN existente (WireGuard / Tailscale)"
  } >&2
  local a; read -rp "  Opción [1]: " a
  case "$a" in 2) echo portforward ;; 3) echo vpn ;; *) echo tunnel ;; esac
}

# --------------------------------------------------------------------------- #
phase0_prereqs() {
  phase 0 "Prerrequisitos"
  local os_id os_name
  os_id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
  os_name="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
  if [[ "$os_id" == ubuntu ]]; then record PASS "SO: $os_name"
  else record WARN "SO '$os_name': pensado para Ubuntu, se continúa"; fi
  check "systemd disponible" command -v systemctl || die "Se requiere systemd."
  check "apt disponible" command -v apt-get || die "Se requiere apt (Ubuntu/Debian)."
  if ! command -v ss >/dev/null; then
    record WARN "Falta 'ss' (iproute2): se instala"; run apt-get install -y -qq iproute2
  fi

  # Pasos previos: informativo (xrdp no depende de ellos, el túnel sí de RustDesk)
  local dom; dom="$(state_get RUSTDESK_DOMAIN)"
  if [[ -n "$dom" ]]; then record PASS "Pasos 1-2 detectados: servidor RustDesk en $dom (no se modifican)"
  else record INFO "No se detectaron los pasos 1-2 en este equipo"; fi

  # Usuarios
  [[ -z "$USERS_ARG" ]] && USERS_ARG="$(state_get XRDP_USERS)"
  [[ -n "$USERS_ARG" ]] || die "Falta --users (ej: --users ana,juan,pedro)."
  mapfile -t USERS < <(split_users "$USERS_ARG")
  local u bad=0
  for u in "${USERS[@]}"; do valid_username "$u" || { record FAIL "Nombre de usuario inválido: '$u'"; bad=1; }; done
  ((bad)) && die "Corregir los nombres (minúsculas, números, - y _; no root)."
  for u in "${RESET_PW[@]}"; do
    printf '%s\n' "${USERS[@]}" | grep -qx "$u" || die "--reset-password $u: no está en --users."
  done
  record PASS "Integrantes (${#USERS[@]}): $(IFS=,; echo "${USERS[*]}")"

  # Modo de acceso
  [[ -z "$ACCESS" ]] && ACCESS="$(state_get XRDP_ACCESS)"
  if [[ -z "$ACCESS" ]]; then
    if is_interactive; then ACCESS="$(choose_access)"
    else ACCESS=tunnel; record INFO "Sin --access: se usa 'tunnel' (no abre puertos)"; fi
  fi
  valid_access "$ACCESS" || die "--access inválido: '$ACCESS' (tunnel|portforward|vpn)."
  [[ -z "$LISTEN" ]] && { [[ "$ACCESS" == tunnel ]] && LISTEN=local || LISTEN=all; }
  [[ "$LISTEN" =~ ^(local|all)$ ]] || die "--listen inválido: '$LISTEN' (local|all)."
  [[ "$ACCESS" != tunnel && "$LISTEN" == local ]] \
    && die "Con --access $ACCESS xrdp no puede escuchar solo en localhost (usar --listen all)."
  [[ -z "$PORT" ]] && PORT="$(state_get XRDP_PORT)"; PORT="${PORT:-3389}"
  [[ -z "$EXT_PORT" ]] && EXT_PORT="$(state_get XRDP_EXT_PORT)"; EXT_PORT="${EXT_PORT:-$PORT}"
  valid_port "$PORT" && valid_port "$EXT_PORT" || die "Puerto inválido."
  [[ -z "$MAX_SESSIONS" ]] && MAX_SESSIONS="$(max_sessions_for "${#USERS[@]}")"
  [[ "$MAX_SESSIONS" =~ ^[1-9][0-9]*$ ]] || die "--max-sessions inválido."
  record PASS "Acceso: $ACCESS | xrdp escucha en: $( [[ $LISTEN == local ]] && echo "127.0.0.1:$PORT (solo local)" || echo "todas las interfaces :$PORT")"
  if [[ "$ACCESS" == tunnel ]]; then
    command -v rustdesk >/dev/null && record PASS "Cliente RustDesk presente (necesario para el túnel)" \
      || record FAIL "Modo túnel sin cliente RustDesk instalado en esta máquina"
  fi

  # RAM
  local mem_mb need; mem_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
  need="$(mem_needed_mb "${#USERS[@]}")"
  if (( mem_mb >= need )); then record PASS "RAM: ${mem_mb} MB (recomendado para ${#USERS[@]} sesiones: ~${need} MB)"
  else record WARN "RAM: ${mem_mb} MB < ~${need} MB recomendados para ${#USERS[@]} sesiones simultáneas"; fi

  # Puerto: libre, ya de xrdp, o tomado por el Escritorio remoto de GNOME
  local owner; owner="$(port_owner "$PORT")"
  case "$owner" in
    "")    record PASS "Puerto $PORT/tcp libre" ;;
    xrdp)  record PASS "Puerto $PORT/tcp ya en uso por xrdp (re-ejecución)" ;;
    gnome-remote*)
      record WARN "El puerto $PORT lo usa el Escritorio remoto de GNOME"
      if ((DISABLE_GRD)) && systemctl is-active --quiet gnome-remote-desktop 2>/dev/null; then
        run systemctl disable --now gnome-remote-desktop
      fi
      manual_checkpoint GNOME_RD "Desactivar el Escritorio remoto de GNOME" \
"Ubuntu trae su propio servidor RDP que ocupa el puerto $PORT.
Desactivarlo en: Configuración → Sistema → Escritorio remoto
  · «Compartir escritorio» → desactivar
  · «Inicio de sesión remoto» → desactivar (o: sudo systemctl disable --now gnome-remote-desktop)
RustDesk no se ve afectado." port_free_or_xrdp \
        || { ((DRY_RUN)) || die "El puerto $PORT sigue ocupado: no se puede instalar xrdp."; } ;;
    *) die "Puerto $PORT/tcp ocupado por '$owner' (usar --port o liberar el puerto)." ;;
  esac

  state_set XRDP_USERS "$(IFS=,; echo "${USERS[*]}")"
  state_set XRDP_ACCESS "$ACCESS"; state_set XRDP_LISTEN "$LISTEN"
  state_set XRDP_PORT "$PORT"; state_set XRDP_EXT_PORT "$EXT_PORT"
}

# --------------------------------------------------------------------------- #
phase1_packages() {
  phase 1 "Paquetes (xrdp + escritorio XFCE para las sesiones remotas)"
  local p missing=()
  for p in "${PKGS[@]}"; do pkg_installed "$p" || missing+=("$p"); done
  if ((${#missing[@]} == 0)); then
    record PASS "Paquetes ya instalados: ${PKGS[*]}"
  else
    info "Faltan: ${missing[*]}"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # --no-install-recommends: evita que XFCE arrastre otro gestor de inicio de sesión (lightdm)
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
    if ((DRY_RUN == 0)); then
      CHANGES=$((CHANGES + 1))
      local prev; prev="$(state_get XRDP_PKGS_INSTALLED)"
      state_set XRDP_PKGS_INSTALLED "$(printf '%s\n' ${prev//,/ } "${missing[@]}" | awk 'NF && !s[$0]++' | paste -sd,)"
      for p in "${missing[@]}"; do check "Paquete $p instalado" pkg_installed "$p"; done
    else
      record SKIP "Instalación de ${missing[*]} omitida en modo $(mode_name)"
    fi
  fi
  record INFO "El escritorio del monitor físico (GDM/GNOME) no se modifica: XFCE se usa solo en sesiones xrdp"
}

# --------------------------------------------------------------------------- #
set_password() {  # set_password USUARIO
  local u="$1" pw="" pw2="" origin="ingresada"
  if ((DRY_RUN)); then info "[plan] establecer contraseña de $u (chpasswd, por stdin)"; return; fi
  if is_interactive; then
    read -rsp "  Contraseña para $u (Enter = generar una aleatoria): " pw; echo >&2
    if [[ -n "$pw" ]]; then
      read -rsp "  Repetir: " pw2; echo >&2
      [[ "$pw" == "$pw2" ]] || { record FAIL "Las contraseñas de $u no coinciden: no se cambió"; return; }
      (( ${#pw} >= 10 )) || record WARN "Contraseña de $u con menos de 10 caracteres"
    fi
  fi
  if [[ -z "$pw" ]]; then pw="$(gen_password 16)"; origin="generada"; NEW_CREDS+=("$u:$pw"); fi
  # Por stdin: la contraseña no aparece en ps, ni en el log, ni en el historial.
  if printf '%s:%s\n' "$u" "$pw" | chpasswd; then record PASS "Contraseña de $u establecida ($origin)"
  else record FAIL "No se pudo establecer la contraseña de $u"; fi
}

phase2_users() {
  phase 2 "Usuarios (uno por integrante) y grupo $XR_GROUP"
  if getent group "$XR_GROUP" >/dev/null; then record PASS "Grupo $XR_GROUP existe"
  else run groupadd --system "$XR_GROUP"; ((DRY_RUN)) || { state_set XRDP_GROUP_CREATED 1; CHANGES=$((CHANGES + 1)); }; fi

  local u consoles; consoles="$(console_users)"
  for u in "${USERS[@]}"; do
    if id "$u" &>/dev/null; then
      record PASS "Usuario $u existe (no se modifica su contraseña)"
      printf '%s\n' "${RESET_PW[@]}" | grep -qx "$u" && set_password "$u"
    else
      run useradd -m -s /bin/bash "$u"
      ((DRY_RUN)) || CHANGES=$((CHANGES + 1))
      set_password "$u"
    fi
    if in_group "$u" "$XR_GROUP"; then info "$u ya pertenece a $XR_GROUP"
    else run usermod -aG "$XR_GROUP" "$u"; ((DRY_RUN)) || CHANGES=$((CHANGES + 1)); fi
    grep -qx "$u" <<<"$consoles" && record WARN "$u tiene sesión abierta en el monitor físico: si entra por RDP con el mismo usuario puede ver pantalla negra (usar otro usuario o cerrar esa sesión)"
  done

  # Trazabilidad: quién más puede entrar por xrdp
  local extra; extra="$(getent group "$XR_GROUP" | cut -d: -f4 | tr ',' '\n' | grep -vxF -f <(printf '%s\n' "${USERS[@]}") | paste -sd, -)"
  [[ -n "$extra" ]] && record WARN "Miembros de $XR_GROUP fuera de --users: $extra (pueden entrar por xrdp; quitar con: sudo gpasswd -d USUARIO $XR_GROUP)"

  if ((${#NEW_CREDS[@]})); then
    local cred="$RD_STATE_DIR/xrdp-credenciales-$RUN_ID.txt"
    write_file "$cred" 0600 root:root < <(
      echo "# Contraseñas generadas por 03-xrdp-setup.sh ($RUN_ID). Entregar por canal privado y BORRAR este archivo."
      echo "# Cada integrante puede cambiarla desde su sesión con: passwd"
      printf '%s\n' "${NEW_CREDS[@]}")
    record WARN "Contraseñas generadas en $cred (0600, solo root): entregarlas en privado y borrar el archivo"
  fi
}

# --------------------------------------------------------------------------- #
startwm_content() {
  cat <<EOF
#!/bin/sh
# $MARKER — inicia XFCE en las sesiones xrdp.
# El monitor físico sigue usando GDM/GNOME: este archivo solo lo usa xrdp.
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE
fi
# Evita la pantalla negra cuando el usuario también tiene una sesión local abierta.
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce
exec startxfce4
EOF
}

polkit_content() {  # polkit_content js|pkla
  if [[ "$1" == js ]]; then
    cat <<EOF
// $MARKER
// Sesiones xrdp: evita el diálogo «Se requiere autenticación para crear un dispositivo
// gestionado por color». Solo afecta a miembros de $XR_GROUP; en sesiones inactivas o
// remotas se deniega en silencio (mínimo privilegio, sin ventana emergente).
polkit.addRule(function (action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") === 0 && subject.isInGroup("$XR_GROUP")) {
    return subject.active ? polkit.Result.YES : polkit.Result.NO;
  }
});
EOF
  else
    cat <<EOF
# $MARKER
[Sesiones xrdp: dispositivos de color sin diálogo de autenticación]
Identity=unix-group:$XR_GROUP
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
  fi
}

phase3_config() {
  phase 3 "Configuración de xrdp, sesiones y servicios"
  if [[ ! -f "$XRDP_INI" || ! -f "$SESMAN_INI" ]]; then
    record SKIP "xrdp aún no instalado: configuración omitida en modo $(mode_name)"; return
  fi

  local portval; portval="$(xrdp_port_value "$LISTEN" "$PORT")"
  write_file "$XRDP_INI" 0644 root:root < <(
    ini_set Globals port "$portval" <"$XRDP_INI" \
      | ini_set Globals crypt_level high \
      | ini_set Globals ssl_protocols "TLSv1.2, TLSv1.3" \
      | ini_set Globals max_bpp 32) && CONF_CHANGED=1

  # [Security]: solo el grupo tsusers entra, nunca root.
  # [Sessions]: la sesión sobrevive al cerrar la ventana (reconexión) y se retoma por usuario (Policy=UB).
  write_file "$SESMAN_INI" 0644 root:root < <(
    ini_set Security AllowRootLogin false <"$SESMAN_INI" \
      | ini_set Security AlwaysGroupCheck true \
      | ini_set Security TerminalServerUsers "$XR_GROUP" \
      | ini_set Sessions MaxSessions "$MAX_SESSIONS" \
      | ini_set Sessions KillDisconnected false \
      | ini_set Sessions DisconnectedTimeLimit 0 \
      | ini_set Sessions Policy UB) && CONF_CHANGED=1

  write_file "$STARTWM" 0755 root:root < <(startwm_content) && CONF_CHANGED=1

  if command -v pkaction >/dev/null; then
    if polkit_uses_js "$(pkaction --version 2>/dev/null)"; then
      write_file "$POLKIT_JS" 0644 root:root < <(polkit_content js) || true
    else
      write_file "$POLKIT_PKLA" 0644 root:root < <(polkit_content pkla) || true
    fi
  else
    record SKIP "polkit no encontrado: regla de color omitida"
  fi

  # xrdp necesita leer la clave TLS (/etc/ssl/private): grupo ssl-cert
  if in_group xrdp ssl-cert; then info "usuario xrdp ya pertenece a ssl-cert"
  else run usermod -aG ssl-cert xrdp; CONF_CHANGED=1; fi

  local s
  for s in xrdp-sesman xrdp; do
    systemctl is-enabled --quiet "$s" 2>/dev/null || run systemctl enable "$s"
  done
  if ((CONF_CHANGED)); then
    local n; n="$(xrdp_sessions_count)"
    if ((n > 0)) && ! ask_yes_no "Hay $n sesión(es) xrdp activas y reiniciar puede cortarlas. ¿Reiniciar ahora?" n; then
      RESTART_PENDING=1
      record PENDING "Reiniciar xrdp para aplicar la configuración ($n sesiones activas): sudo systemctl restart xrdp-sesman xrdp"
    else
      run systemctl restart xrdp-sesman xrdp
    fi
  else
    for s in xrdp-sesman xrdp; do systemctl is-active --quiet "$s" || run systemctl start "$s"; done
    info "configuración sin cambios: no se reinicia xrdp"
  fi

  # Firewall local: solo si ufw ya está activo (nunca se activa automáticamente)
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [[ "$LISTEN" == all ]]; then
      ufw status | grep -qE "^$PORT/tcp .*ALLOW" || { run ufw allow "$PORT/tcp" comment 'xrdp'; state_set XRDP_UFW_RULE 1; }
      record PASS "ufw permite $PORT/tcp"
    elif [[ "$(state_get XRDP_UFW_RULE)" == 1 ]]; then
      run ufw delete allow "$PORT/tcp"; state_set XRDP_UFW_RULE 0
      record PASS "Regla ufw $PORT/tcp quitada (en modo túnel xrdp escucha solo en localhost)"
    else
      record PASS "ufw: no hace falta regla (xrdp escucha solo en localhost)"
    fi
  else
    record SKIP "ufw inactivo o no instalado: sin cambios de firewall"
  fi
}

# --------------------------------------------------------------------------- #
tunnel_instructions() {
  local dom id; dom="$(state_get RUSTDESK_DOMAIN)"; id="$(state_get RUSTDESK_ID)"
  cat <<EOF
En el RustDesk de cada integrante (configurado con el servidor ${dom:-del equipo}):
 1. Abrir el menú de opciones junto a «Conectar» (flecha / ⋮) y elegir «Túnel TCP»
    (TCP Tunneling). La ubicación exacta puede variar según la versión.
 2. ID remoto: ${id:-<ID de esta máquina>}   Puerto local: 13389
    Host remoto: localhost   Puerto remoto: $PORT
 3. Conectar con la contraseña de RustDesk de la máquina y dejar esa ventana abierta.
 4. Escritorio remoto (mstsc) → Equipo: localhost:13389 → usuario y contraseña Linux propios.
    Linux: Remmina, o  xfreerdp /v:localhost:13389 /u:USUARIO /dynamic-resolution
El puerto 13389 es local de cada PC: todos pueden usar el mismo.
EOF
}

portforward_ok() { [[ -n "${NET_PUBLIC:-}" ]] && rdp_probe "$NET_PUBLIC" "$EXT_PORT"; }

phase4_access() {
  phase 4 "Acceso a las sesiones ($ACCESS)"
  case "$ACCESS" in
    tunnel)
      record PASS "Sin cambios en el router: xrdp viaja dentro de la conexión RustDesk"
      manual_checkpoint XRDP_TUNNEL "Crear el túnel TCP en el RustDesk de cada integrante" "$(tunnel_instructions)"
      ;;
    portforward)
      net_diagnose
      local nat; nat="$(state_get NAT_STATUS)"
      [[ "$nat" == CGNAT || "$nat" == DISTINTA ]] && record PENDING "Port-forward sin efecto mientras haya CGNAT (ver paso 1)"
      manual_checkpoint XRDP_PORTFORWARD "Reenviar el puerto RDP en el router" \
"Panel del router: http://${NET_GW} → NAT / Port Forwarding.
  Protocolo TCP   Puerto externo $EXT_PORT   →   IP interna ${NET_IP}   Puerto interno $PORT
Recomendado: puerto externo distinto de 3389 (ej. --external-port 53389) para
reducir el escaneo automático. RDP expuesto recibe fuerza bruta constante:
contraseñas largas por usuario y, si es posible, VPN en lugar de port-forward." portforward_ok
      if ! portforward_ok; then
        box "Probar desde una red externa" \
"Windows (PS):  Test-NetConnection $(domain_or_placeholder) -Port $EXT_PORT
Linux:         nc -vz -w5 $(domain_or_placeholder) $EXT_PORT
Luego: Escritorio remoto → Equipo: $(domain_or_placeholder):$EXT_PORT"
        record PENDING "Prueba externa del puerto $EXT_PORT"
      fi
      ;;
    vpn)
      manual_checkpoint XRDP_VPN "Confirmar el acceso por VPN" \
"Este script no instala la VPN. Con la VPN activa en la PC del integrante:
  Escritorio remoto → Equipo: <IP de esta máquina en la VPN>:$PORT
Verificar que el router NO reenvíe el puerto $PORT a Internet."
      ;;
  esac
}

# --------------------------------------------------------------------------- #
phase5_verify() {
  phase 5 "Verificación"
  ((RESTART_PENDING)) && record WARN "xrdp no se reinició: lo que sigue refleja la configuración anterior"
  if ! pkg_installed xrdp; then
    record FAIL "xrdp no está instalado (ejecutar sin --check/--dry-run para instalarlo)"
    return
  fi
  check "Servicio xrdp-sesman activo" systemctl is-active --quiet xrdp-sesman
  check "Servicio xrdp activo" systemctl is-active --quiet xrdp
  check "Servicios xrdp habilitados al arranque" bash -c 'systemctl is-enabled --quiet xrdp && systemctl is-enabled --quiet xrdp-sesman'

  local addrs a scope bad=0
  retry 5 1 port_listening tcp "$PORT"     # xrdp tarda un instante en abrir el socket tras reiniciar
  addrs="$(listen_addrs)"
  if [[ -z "$addrs" ]]; then
    record FAIL "Nada escuchando en $PORT/tcp"
  else
    for a in $addrs; do
      scope="$(bind_scope "$a")"
      [[ "$LISTEN" == local && "$scope" != local ]] && bad=1
    done
    if ((bad)); then record FAIL "xrdp expuesto en $addrs pero el modo es solo local (revisar port= en $XRDP_INI)"
    else record PASS "Escuchando en $(paste -sd' ' <<<"$addrs") (modo $LISTEN)"; fi
  fi

  if retry 5 1 rdp_probe 127.0.0.1 "$PORT"; then record PASS "xrdp responde el protocolo RDP (X.224 Connection Confirm)"
  else record FAIL "xrdp no responde el saludo RDP en 127.0.0.1:$PORT"; fi

  if id xrdp &>/dev/null; then
    check "Usuario xrdp en ssl-cert" in_group xrdp ssl-cert
    check "xrdp puede leer su clave TLS" runuser -u xrdp -- test -r /etc/xrdp/key.pem
  fi

  if [[ -f "$SESMAN_INI" ]]; then
    local agc tsu root
    agc="$(ini_get Security AlwaysGroupCheck <"$SESMAN_INI")"
    tsu="$(ini_get Security TerminalServerUsers <"$SESMAN_INI")"
    root="$(ini_get Security AllowRootLogin <"$SESMAN_INI")"
    [[ "$agc" == true && "$tsu" == "$XR_GROUP" && "$root" == false ]] \
      && record PASS "Acceso restringido al grupo $XR_GROUP, sin root" \
      || record FAIL "sesman.ini: AlwaysGroupCheck=$agc TerminalServerUsers=$tsu AllowRootLogin=$root"
  fi
  check "startwm.sh gestionado (sesión XFCE)" grep -q "$MARKER" "$STARTWM"

  local u
  for u in "${USERS[@]}"; do
    if id "$u" &>/dev/null && in_group "$u" "$XR_GROUP" && [[ -d "$(getent passwd "$u" | cut -d: -f6)" ]]; then
      record PASS "Integrante $u: usuario, carpeta personal y grupo OK"
    else
      record FAIL "Integrante $u: falta usuario, carpeta personal o pertenencia a $XR_GROUP"
    fi
  done

  local errs; errs="$(journalctl -u xrdp -u xrdp-sesman --since '-10min' -p err --no-pager -q 2>/dev/null | wc -l)"
  ((errs == 0)) && record PASS "Sin errores de xrdp en el journal (últimos 10 min)" \
    || record WARN "$errs línea(s) de error en el journal: journalctl -u xrdp -u xrdp-sesman -p err -n 20"
  record INFO "Sesiones xrdp activas ahora: $(xrdp_sessions_count)"
}

# --------------------------------------------------------------------------- #
phase6_card() {
  phase 6 "Ficha de conexión para el equipo"
  local how
  case "$ACCESS" in
    tunnel)      how="$(tunnel_instructions)" ;;
    portforward) how="Escritorio remoto (mstsc) → Equipo: $(domain_or_placeholder):$EXT_PORT → usuario Linux propio." ;;
    vpn)         how="Con la VPN activa: Escritorio remoto → Equipo: <IP VPN de la máquina>:$PORT → usuario Linux propio." ;;
  esac
  local body
  body="Sesiones individuales (xrdp) — generado $RUN_ID
Integrantes: $(IFS=,; echo "${USERS[*]}")
Modo de acceso: $ACCESS

$how

Uso:
 · Cada uno entra con SU usuario: escritorio XFCE propio, en paralelo con los demás.
 · Cerrar la ventana deja la sesión viva para reconectar; para liberarla: menú XFCE → Cerrar sesión.
 · Cambiar la contraseña desde la sesión: abrir terminal → passwd
 · No usar por RDP el usuario que tiene la sesión abierta en el monitor físico.
 · La pantalla física compartida sigue estando por RustDesk."
  printf '%s\n' "$body"
  if ((DRY_RUN == 0)); then
    printf '%s\n' "$body" >"$RD_STATE_DIR/ficha-xrdp.txt"; chmod 644 "$RD_STATE_DIR/ficha-xrdp.txt"
    info "Guardada en $RD_STATE_DIR/ficha-xrdp.txt (sin contraseñas)"
  fi
}

# --------------------------------------------------------------------------- #
uninstall() {
  phase U "Desinstalación del paso 3 (pasos 1-2 intactos)"
  run systemctl disable --now xrdp xrdp-sesman
  local f oldest mf="$RD_STATE_DIR/manifest-${TOOL_NAME}"
  if [[ -f "$mf" ]]; then
    tac "$mf" | while read -r f; do
      oldest="$(find "$RD_STATE_DIR/backup" -maxdepth 1 -name "$(basename "$f").*" 2>/dev/null | sort | head -n1)"
      if [[ -n "$oldest" ]]; then run cp -p "$oldest" "$f"; info "restaurado original: $f"
      elif [[ -f "$f" ]]; then run rm -f "$f"; fi
    done
    ((DRY_RUN)) || rm -f "$mf"
  fi
  if [[ "$(state_get XRDP_UFW_RULE)" == 1 ]] && command -v ufw >/dev/null; then
    run ufw delete allow "$(state_get XRDP_PORT)/tcp"; state_set XRDP_UFW_RULE 0
  fi
  if ((PURGE)); then
    local pk; pk="$(state_get XRDP_PKGS_INSTALLED)"
    if [[ -n "$pk" ]]; then
      # shellcheck disable=SC2086
      run env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq ${pk//,/ }
      run apt-get autoremove -y -qq
      state_set XRDP_PKGS_INSTALLED ""
    fi
  fi
  record PASS "xrdp detenido y configuración original restaurada (backups en $RD_STATE_DIR/backup)"
  record INFO "Usuarios y su información NO se borran. Si corresponde: sudo deluser --remove-home USUARIO"
  record INFO "Router: quitar a mano la regla de xrdp si se usó port-forward"
}

main() {
  parse_args "$@"
  require_root
  init_trace
  if [[ "$ACTION" == uninstall ]]; then uninstall; summary; exit $?; fi
  phase0_prereqs
  phase1_packages
  phase2_users
  phase3_config
  phase4_access
  phase5_verify
  phase6_card
  summary; exit $?
}

main "$@"
