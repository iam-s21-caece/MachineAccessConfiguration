#!/usr/bin/env bash
# =============================================================================
# shellcheck disable=SC2034  # DRY_RUN se usa dentro de lib/common.sh
# tests/test_common.sh — Tests de la lógica de decisión (sin root, sin red).
# Uso: ./tests/test_common.sh        Sale con 0 si todo pasa.
#
# Cubre lo que decide el camino: detección de IP privada/CGNAT, veredicto de
# NAT, parseo de rutas y tracepath, validaciones de entrada e idempotencia de
# write_file (incluye backup y dry-run).
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export RD_STATE_DIR="$TMP/state" RD_LOG_DIR="$TMP/logs"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
mkdir -p "$RD_STATE_DIR/backup"

PASS=0; FAIL=0
ok()  { if "$@" >/dev/null 2>&1; then ((PASS++)); else ((FAIL++)); echo "FALLA (esperaba éxito): $*"; fi; }
nok() { if "$@" >/dev/null 2>&1; then ((FAIL++)); echo "FALLA (esperaba fallo): $*"; else ((PASS++)); fi; }
eq()  { if [[ "$1" == "$2" ]]; then ((PASS++)); else ((FAIL++)); echo "FALLA: esperaba '$2', obtuvo '$1' ($3)"; fi; }

echo "== IPv4 =="
ok  valid_ipv4 192.168.1.10;  ok valid_ipv4 0.0.0.0;  ok valid_ipv4 255.255.255.255
nok valid_ipv4 256.1.1.1;     nok valid_ipv4 1.2.3;    nok valid_ipv4 "1.2.3.4 ";  nok valid_ipv4 abc
ok  valid_ipv4 010.001.008.009      # ceros a la izquierda no rompen (base 10)
ok  ip_is_private 10.0.0.1;  ok ip_is_private 172.16.5.4;  ok ip_is_private 172.31.255.255
ok  ip_is_private 192.168.0.1
nok ip_is_private 172.32.0.1; nok ip_is_private 8.8.8.8;  nok ip_is_private 100.64.0.1
ok  ip_is_cgnat 100.64.0.1;  ok ip_is_cgnat 100.127.255.254
nok ip_is_cgnat 100.128.0.1; nok ip_is_cgnat 100.63.255.255

echo "== Veredicto NAT (IP WAN del router vs pública) =="
eq "$(wan_verdict 190.1.2.3 190.1.2.3)"    OK        "WAN = pública"
eq "$(wan_verdict 100.70.1.2 190.1.2.3)"   CGNAT     "WAN en 100.64/10"
eq "$(wan_verdict 192.168.0.2 190.1.2.3)"  DOBLE_NAT "WAN privada"
eq "$(wan_verdict 181.9.9.9 190.1.2.3)"    DISTINTA  "WAN pública distinta"
eq "$(wan_verdict hola 190.1.2.3)"         INVALIDA  "entrada inválida"

echo "== Parseo de ruta por defecto =="
R="default via 192.168.1.1 dev enp3s0 proto dhcp src 192.168.1.50 metric 100"
eq "$(parse_default_dev <<<"$R")" enp3s0      "dev"
eq "$(parse_default_gw  <<<"$R")" 192.168.1.1 "gw"
eq "$(parse_default_dev <<<"")"   ""          "sin ruta"

echo "== Análisis de camino (tracepath) =="
T_OK=' 1?: [LOCALHOST]                      pmtu 1500
 1:  192.168.1.1                                           0.6ms
 2:  181.10.0.1                                            5.1ms
 3:  1.1.1.1                                              12.0ms reached'
T_CG=' 1:  192.168.1.1                                           0.6ms
 2:  100.72.0.1                                            4.0ms
 3:  181.10.0.1                                            8.0ms'
T_DN=' 1:  192.168.0.1                                           0.6ms
 2:  192.168.1.1                                           1.0ms
 3:  181.10.0.1                                            8.0ms'
eq "$(extract_hop_ips <<<"$T_OK" | classify_path)" OK                 "camino limpio"
eq "$(extract_hop_ips <<<"$T_CG" | classify_path)" CGNAT              "salto 100.64/10"
eq "$(extract_hop_ips <<<"$T_DN" | classify_path)" POSIBLE_DOBLE_NAT  "dos privados"
eq "$(printf '' | classify_path)"                  DESCONOCIDO        "sin datos"
eq "$(extract_hop_ips <<<"$T_OK" | head -n1)"      192.168.1.1        "ignora [LOCALHOST]"

echo "== Validaciones de entrada =="
ok  valid_subdomain miequipo;  ok valid_subdomain lab-ues21;  ok valid_subdomain a1
nok valid_subdomain -malo;     nok valid_subdomain Mayus;     nok valid_subdomain "a.b"; nok valid_subdomain ""
ok  valid_duckdns_token a7c4d0ad-114e-40ef-ba1d-d217904a50f2
nok valid_duckdns_token a7c4d0ad114e40efba1dd217904a50f2;  nok valid_duckdns_token "x"
ok  valid_interval 5min; ok valid_interval 300s; ok valid_interval 1h
nok valid_interval 0min; nok valid_interval 5m;  nok valid_interval cinco
eq "$(printf 'OK\n1.2.3.4\n\nUPDATED\n' | first_line)" OK "respuesta DuckDNS"
eq "$(printf 'KO\n' | first_line)"                    KO "respuesta DuckDNS KO"

echo "== write_file: idempotencia, backup y dry-run =="
F="$TMP/etc/demo.conf"
write_file "$F" 0640 <<<"a=1" >/dev/null;      eq "$?" 0 "crea archivo nuevo"
eq "$(cat "$F")" "a=1" "contenido escrito"
eq "$(stat -c %a "$F")" 640 "modo aplicado"
write_file "$F" 0640 <<<"a=1" >/dev/null;      eq "$?" 1 "mismo contenido → sin cambios"
write_file "$F" 0640 <<<"a=2" >/dev/null;      eq "$?" 0 "contenido nuevo → cambia"
eq "$(find "$RD_STATE_DIR/backup" -name "demo.conf.*" | wc -l)" 1 "backup del contenido anterior"
eq "$(grep -cxF "$F" "$RD_STATE_DIR/manifest-$TOOL_NAME")" 1 "manifiesto sin duplicados"
# shellcheck disable=SC2034
DRY_RUN=1; write_file "$F" 0640 <<<"a=3" >/dev/null; rc=$?; DRY_RUN=0
eq "$rc" 0 "dry-run reporta cambio pendiente"
eq "$(cat "$F")" "a=2" "dry-run no modifica el archivo"

echo "== Estado persistente =="
state_set LAN_IP 192.168.1.50; state_set LAN_IP 192.168.1.60
eq "$(state_get LAN_IP)" 192.168.1.60 "state_set reemplaza"
eq "$(grep -c '^LAN_IP=' "$STATE_FILE")" 1 "sin claves duplicadas"

echo
echo "Resultado: $PASS OK, $FAIL fallas"
((FAIL == 0))
