#!/bin/bash
# Instalador del servidor de Dino Cards (Ubuntu 24.04 en DigitalOcean).
# Se pega en la consola del Droplet:
#   curl -fsSL https://raw.githubusercontent.com/DinoCardsSLW/dino-cards-actualizaciones/main/servidor/instalar.sh | bash
# Se puede volver a correr para actualizar el servidor: los datos y la clave no se tocan.
set -euo pipefail
BASE="https://raw.githubusercontent.com/DinoCardsSLW/dino-cards-actualizaciones/main/servidor"
DATOS=/var/lib/dinocards
paso() { echo; echo "==> $*"; }

[ "$(id -u)" = 0 ] || { echo "Hay que correrlo como root."; exit 1; }
echo "=============================================="
echo "  Dino Cards · instalando el servidor"
echo "=============================================="

paso "Zona horaria y memoria de respaldo"
timedatectl set-timezone America/Mexico_City || true
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

paso "Paquetes del sistema (esto tarda un par de minutos)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q curl ufw gnupg debian-keyring debian-archive-keyring apt-transport-https ca-certificates >/dev/null

paso "Caddy (pone la conexión segura https)"
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
fi
apt-get install -y -q caddy >/dev/null
caddy version

paso "Programa de Dino Cards"
id dinocards >/dev/null 2>&1 || useradd --system --home "$DATOS" --shell /usr/sbin/nologin dinocards
mkdir -p "$DATOS" && chown dinocards:dinocards "$DATOS" && chmod 700 "$DATOS"
TMP=$(mktemp -d)
curl -fsSL "$BASE/dinocards-servidor" -o "$TMP/dinocards-servidor"
curl -fsSL "$BASE/dinocards-servidor.sha256" -o "$TMP/sha"
(cd "$TMP" && echo "$(cut -d' ' -f1 sha)  dinocards-servidor" | sha256sum -c --quiet -) || { echo "El archivo descargado no coincide. Vuelve a intentar."; exit 1; }
install -m 755 "$TMP/dinocards-servidor" /usr/local/bin/dinocards-servidor
rm -rf "$TMP"

cat > /etc/systemd/system/dinocards.service <<'EOF'
[Unit]
Description=Dino Cards · servidor del punto de venta
After=network-online.target
Wants=network-online.target

[Service]
User=dinocards
ExecStart=/usr/local/bin/dinocards-servidor --servidor --datos /var/lib/dinocards
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/dinocards

[Install]
WantedBy=multi-user.target
EOF

# comandos de ayuda
cat > /usr/local/bin/dinocards-clave <<'EOF'
#!/bin/bash
# Crea una clave nueva para el servidor. Los equipos ya conectados siguen funcionando.
set -e
systemctl stop dinocards
C=$(runuser -u dinocards -- /usr/local/bin/dinocards-servidor --servidor --datos /var/lib/dinocards --clave-nueva)
systemctl start dinocards
echo; echo "  Clave nueva del servidor:  $C"; echo "  Guárdala en un lugar seguro."; echo
EOF
cat > /usr/local/bin/dinocards-actualizar <<'EOF'
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/DinoCardsSLW/dino-cards-actualizaciones/main/servidor/instalar.sh | bash
EOF
# actualización automática: cada 15 min revisa si hay versión nueva; la instala solo si viene
# firmada por Dino Cards y cuando no hay ventas en curso (5 min sin guardar) o de 2 a 5 de la mañana.
cat > /usr/local/bin/dinocards-auto-actualizar <<'EOF'
#!/bin/bash
set -uo pipefail
BASE="https://raw.githubusercontent.com/DinoCardsSLW/dino-cards-actualizaciones/main/servidor"
BIN=/usr/local/bin/dinocards-servidor
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsS --max-time 30 "$BASE/dinocards-servidor.sha256" -o "$TMP/sha" || exit 0
NUEVO=$(cut -d' ' -f1 "$TMP/sha")
ACTUAL=$(sha256sum "$BIN" | cut -d' ' -f1)
[ -n "$NUEVO" ] && [ "$NUEVO" != "$ACTUAL" ] || exit 0
H=$((10#$(date +%H)))
IN=$(curl -fsS --max-time 5 http://127.0.0.1:47652/api/salud | grep -o '"inactivo":[0-9]*' | cut -d: -f2)
if [ "${IN:-9999}" -lt 300 ] && ! [ "$H" -ge 2 -a "$H" -lt 5 ]; then echo "Hay una versión nueva; hay movimiento en la tienda, se instala más tarde."; exit 0; fi
curl -fsS --max-time 300 "$BASE/dinocards-servidor" -o "$TMP/bin" || exit 0
curl -fsS --max-time 30 "$BASE/dinocards-servidor.sig" -o "$TMP/sig" || exit 0
echo "$NUEVO  $TMP/bin" | sha256sum -c --quiet - || { echo "Descarga incompleta; se intenta más tarde."; exit 0; }
if ! "$BIN" --verificar "$TMP/bin" "$TMP/sig" >/dev/null; then echo "FIRMA INVÁLIDA: la versión descargada no se instala."; exit 1; fi
chmod 755 "$TMP/bin"
VER=$("$TMP/bin" --version)
cp -p "$BIN" "$BIN.anterior"
install -m 755 "$TMP/bin" "$BIN"
systemctl restart dinocards
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 2; curl -fsS --max-time 3 http://127.0.0.1:47652/api/salud >/dev/null 2>&1 && { echo "Servidor actualizado a la versión $VER."; exit 0; }; done
echo "La versión $VER no arrancó; se regresa a la anterior."
install -m 755 "$BIN.anterior" "$BIN"
systemctl restart dinocards
exit 1
EOF
cat > /etc/systemd/system/dinocards-actualizar.service <<'EOF'
[Unit]
Description=Dino Cards · revisar actualizaciones del servidor
After=network-online.target dinocards.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dinocards-auto-actualizar
EOF
cat > /etc/systemd/system/dinocards-actualizar.timer <<'EOF'
[Unit]
Description=Dino Cards · revisar actualizaciones cada 15 minutos

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
EOF
chmod 755 /usr/local/bin/dinocards-clave /usr/local/bin/dinocards-actualizar /usr/local/bin/dinocards-auto-actualizar

CLAVE=""
if [ ! -f "$DATOS/servidor.json" ]; then
  CLAVE=$(runuser -u dinocards -- /usr/local/bin/dinocards-servidor --servidor --datos "$DATOS" --clave-nueva)
fi
systemctl daemon-reload
systemctl enable dinocards >/dev/null 2>&1
systemctl enable --now dinocards-actualizar.timer >/dev/null 2>&1
systemctl restart dinocards

paso "Dirección pública"
IP=$(curl -fsS --max-time 5 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || true)
[ -n "$IP" ] || IP=$(curl -fsS --max-time 8 https://api.ipify.org)
echo "IP: $IP"

cat > /etc/caddy/Caddyfile <<EOF
# Dino Cards: conexión segura por IP (certificado de Let's Encrypt de 6 días, se renueva solo)
https://$IP {
	tls {
		issuer acme {
			profile shortlived
		}
	}
	encode zstd gzip
	reverse_proxy 127.0.0.1:47652
}
http://$IP {
	redir https://$IP{uri} permanent
}
EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
systemctl enable caddy >/dev/null 2>&1
systemctl restart caddy

paso "Firewall (solo consola, http y https)"
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null

paso "Esperando el certificado seguro (hasta 3 minutos)"
OK=""
for i in $(seq 1 36); do
  if curl -fsS --max-time 5 "https://$IP/api/salud" >/dev/null 2>&1; then OK=1; break; fi
  sleep 5
done

echo
echo "=============================================="
if [ -n "$OK" ]; then
  echo "  ¡Listo! El servidor de Dino Cards ya funciona."
else
  echo "  El programa ya corre, pero el certificado seguro"
  echo "  todavía no llega. Espera unos minutos y revisa con:"
  echo "    journalctl -u caddy --no-pager | tail -20"
fi
echo
echo "  Dirección:  https://$IP"
echo "  Versión:    $(/usr/local/bin/dinocards-servidor --version) (se actualiza sola)"
if [ -n "$CLAVE" ]; then
  echo "  Clave del servidor:  $CLAVE"
  echo
  echo "  Guarda la clave en un lugar seguro: se pide una vez"
  echo "  en cada computadora o celular."
else
  echo "  La clave del servidor no cambió."
  echo "  Si la perdiste, crea una nueva con:  dinocards-clave"
fi
echo "=============================================="
