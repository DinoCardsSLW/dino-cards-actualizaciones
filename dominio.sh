#!/bin/bash
# Dino Cards · conecta el dominio de la tienda al servidor (Caddy saca el certificado https solo).
# Uso, en la consola del Droplet:  curl -fsSL https://raw.githubusercontent.com/DinoCardsSLW/dino-cards-actualizaciones/main/dominio.sh | bash -s dinocards.com.mx
set -e
DOM="${1:-dinocards.com.mx}"; DOM="${DOM#https://}"; DOM="${DOM#http://}"; DOM="${DOM#www.}"; DOM="${DOM%%/*}"
case "$DOM" in *[!a-z0-9.-]*|"") echo "Dominio inválido: $1"; exit 1;; esac
[ "$(id -u)" = 0 ] || { echo "Corre este comando como root (en la consola del Droplet)."; exit 1; }
CF=/etc/caddy/Caddyfile
[ -f "$CF" ] || { echo "No encuentro $CF; ¿es el servidor de Dino Cards?"; exit 1; }
IP=$(curl -fsS --max-time 5 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || curl -fsS --max-time 8 https://api.ipify.org)
echo "IP del servidor: $IP"
for h in "$DOM" "www.$DOM"; do
  R=$(getent ahostsv4 "$h" | awk '{print $1; exit}')
  if [ "$R" = "$IP" ]; then echo "  ✔ $h apunta a este servidor"; else echo "  ✘ $h apunta a ${R:-nada} (debe ser $IP). Cambia el DNS en HostGator y espera a que se actualice."; FALTA=1; fi
done
[ -z "$FALTA" ] || { echo "No cambié nada. Cuando los dos apunten a $IP vuelve a correr este comando."; exit 1; }
cp "$CF" "$CF.antes-dominio"
sed -i '/^# dominio-inicio/,/^# dominio-fin/d' "$CF"
cat >> "$CF" <<CAD
# dominio-inicio
www.$DOM {
	encode zstd gzip
	reverse_proxy 127.0.0.1:47652
}
$DOM {
	redir https://www.$DOM{uri} permanent
}
# dominio-fin
CAD
if ! caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1; then cp "$CF.antes-dominio" "$CF"; echo "La configuración no es válida; dejé todo como estaba."; exit 1; fi
systemctl reload caddy
echo "Esperando el certificado seguro (hasta 2 minutos)…"
for i in $(seq 1 24); do
  if curl -fsS --max-time 5 -o /dev/null "https://www.$DOM/tienda"; then echo "✔ Listo: https://www.$DOM/tienda ya funciona con candado."; exit 0; fi
  sleep 5
done
echo "Caddy sigue pidiendo el certificado. Revisa en unos minutos https://www.$DOM/tienda o mira:  journalctl -u caddy --no-pager | tail -20"
