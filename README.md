# rustdesk-toolkit — Acceso remoto del equipo vía RustDesk + DuckDNS

Configura una máquina Ubuntu del laboratorio como **servidor RustDesk propio**,
alcanzable desde Internet por un **subdominio DuckDNS** que sigue a la IP pública
de la red donde está la máquina.

## Cómo llega una conexión

```
Integrante (Internet)
   │  miequipo.duckdns.org  ──DNS──▶  IP pública de la red (la del router)
   ▼
Router de la red (IP pública)  ──port-forward 21115-21117/tcp, 21116/udp──▶
   ▼
Máquina Ubuntu (IP LAN fija, ej. 192.168.1.50)
   ├─ hbbs  (ID / rendezvous)  21115-21116
   ├─ hbbr  (relay)            21117
   └─ cliente RustDesk (comparte el escritorio)
```

La IP pública **no se asigna a la máquina**: vive en el router. La máquina conserva
su IP privada de LAN, y el router reenvía los puertos hacia ella. Por eso son necesarias dos cosas:

1. Que la máquina tenga **siempre la misma IP LAN** (reserva DHCP en el router).
2. Que el ISP entregue una **IP pública real** al router (sin CGNAT).

Ningún script puede resolver esto desde Ubuntu, así que aparecen como
**acciones manuales** dentro del recorrido.

## El camino (en orden)

| # | Qué | Dónde | Quién |
|---|---|---|---|
| 0 | Crear subdominio en duckdns.org y copiar el token | Web DuckDNS | Manual |
| 1 | `01-duckdns-setup.sh` — diagnóstico de red + DNS dinámico | Máquina | Script |
| 1a | ↳ Leer la **IP WAN del router** y compararla (detecta CGNAT / doble NAT) | Panel del router | Manual guiado |
| 1b | ↳ *Si hay CGNAT:* pedir **IP pública** al ISP | Gestión con el ISP | Manual guiado |
| 2 | `02-rustdesk-setup.sh` — servidor hbbs/hbbr | Máquina | Script |
| 2a | ↳ **Reserva DHCP** (MAC → IP) de la máquina | Panel del router | Manual guiado |
| 2b | ↳ **Port-forward** de 21115-21117/tcp y 21116/udp | Router (o ISP si lo administra) | Manual guiado |
| 2c | ↳ *Si hay doble NAT:* modo bridge o reenvío en ambos equipos | Router + ISP | Manual guiado |
| 2d | ↳ **Prueba desde red externa** (datos móviles) | Otro dispositivo | Manual guiado |
| 3 | Cada integrante carga la **ficha del equipo** en su cliente | PCs del equipo | Manual |

En cada acción manual, el script se detiene y muestra qué cargar, con los datos reales
de la máquina (MAC, IP, gateway, tabla de puertos). Si la acción se puede verificar
automáticamente, la verifica. Si no, la registra como *confirmada por el operador*.

## Modos de ejecución

| Modo | Qué hace | Cambia algo |
|---|---|---|
| `--check` | Corre solo las pruebas y reporta el estado actual | No |
| `--dry-run` | Muestra el plan: comandos y diff de cada archivo | No |
| *(sin flag)* | Aplica lo que falta y verifica | Sí |
| `--yes` | No interactivo: las acciones manuales quedan PENDIENTES | Sí |
| `--uninstall` | Revierte lo creado, según el manifiesto | Sí |

Flujo recomendado para cada script: `--check` → `--dry-run` → aplicar → `--check`.

```bash
sudo ./01-duckdns-setup.sh --subdomain miequipo --check
sudo ./01-duckdns-setup.sh --subdomain miequipo            # pide el token oculto
sudo ./02-rustdesk-setup.sh --domain miequipo.duckdns.org --dry-run
sudo ./02-rustdesk-setup.sh --domain miequipo.duckdns.org --configure-client
```

## Garantías de diseño

- **Idempotente.** Se puede re-ejecutar sin efectos secundarios:
  - Un archivo idéntico no se reescribe.
  - Un servicio sin cambios no se reinicia.
  - Un binario con el mismo sha256 no se reinstala.
- **Falla temprano y sin dejar basura.** El token de DuckDNS se valida contra la API
  *antes* de instalar nada. Los puertos ocupados por otro proceso frenan la instalación.
- **No toma decisiones riesgosas por su cuenta.** No activa ufw (podría cortar SSH),
  no fija IP estática en Ubuntu (podría cortar la red) y no pasa GDM a Xorg (cerraría la
  sesión). En esos tres casos explica cómo hacerlo y deja la decisión al equipo.
- **Detecta cambios entre ejecuciones:**
  - Si la IP LAN cambió, avisa que el port-forward quedó apuntando a otra IP.
  - Si la clave del servidor cambió, avisa que todos los clientes deben actualizarla.
- **Secretos protegidos:**
  - El token se guarda en `/etc/duckdns/duckdns.env` con permisos 0600.
  - El token nunca va como argumento de curl, así que no aparece en `ps`.
  - La contraseña del cliente no se pasa por argumento ni queda en logs.

## Trazabilidad

| Ruta | Contenido |
|---|---|
| `/var/log/rdsetup/<script>-<fecha>.log` | Salida completa de cada ejecución |
| `/var/log/rdsetup/<script>-<fecha>-reporte.md` | Tabla de pruebas: PASS / FAIL / WARN / PENDING / MANUAL |
| `/var/lib/rdsetup/state.env` | Estado: IP LAN, MAC, versión, sha256, huella de la clave, acciones manuales hechas |
| `/var/lib/rdsetup/manifest-*` | Archivos creados por cada script (base del `--uninstall`) |
| `/var/lib/rdsetup/backup/` | Copia previa de cada archivo sobrescrito |
| `/var/lib/rdsetup/ficha-equipo.txt` | Datos para configurar los clientes (sin contraseña) |

**Códigos de salida:**

| Código | Significado |
|---|---|
| 0 | OK |
| 1 | Hay fallas |
| 2 | Abortado por el operador |
| 3 | Quedan acciones manuales pendientes |
| 130 | Interrumpido con Ctrl+C |

## Tests

```bash
./tests/test_common.sh      # 61 pruebas de la lógica de decisión, sin root ni red
shellcheck -x lib/common.sh 0*.sh tests/test_common.sh
```

Cubren:
- La detección de IP privada y CGNAT.
- El veredicto de NAT a partir de la IP WAN del router.
- El parseo de rutas y de tracepath.
- La validación del subdominio, el token y el intervalo.
- La idempotencia de `write_file`, con backup, manifiesto y dry-run.
- El estado persistente.

## Consideraciones de uso

- **Escritorio compartido.** RustDesk comparte *un* escritorio: si dos personas se conectan
  a la vez, ven y controlan la misma pantalla. Conviene acordar turnos o sumar SSH para
  el trabajo de consola.
- **Datos de conexión y contraseña:**
  - La clave pública del servidor (`Key`) no es secreta, pero sin ella ningún cliente se conecta (`-k _`).
  - La contraseña de acceso desatendido se comparte por un canal privado.
- **Plan B ante CGNAT.** Si el ISP no entrega IP pública: servidor RustDesk en un VPS con
  IP pública, o una VPN overlay (WireGuard/Tailscale) sin abrir puertos.
