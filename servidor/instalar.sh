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
chmod 755 /usr/local/bin/dinocards-clave /usr/local/bin/dinocards-actualizar

CLAVE=""
if [ ! -f "$DATOS/servidor.json" ]; then
  CLAVE=$(runuser -u dinocards -- /usr/local/bin/dinocards-servidor --servidor --datos "$DATOS" --clave-nueva)
fi
systemctl daemon-reload
systemctl enable dinocards >/dev/null 2>&1
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
