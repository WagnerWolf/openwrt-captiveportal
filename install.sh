#!/bin/sh

echo "======================================================="
echo "   INSTALADOR WOLF-WRT CAPTIVE PORTAL SYSTEM (Versão Final) "
echo "======================================================="
echo ""

# --- ENTRADA DE DADOS ---
echo -n "Cole o TOKEN do Bot do Telegram: "
read MEU_TOKEN
echo -n "Digite o seu ID do Telegram (Admin): "
read MEU_ID

if [ -z "$MEU_TOKEN" ] || [ -z "$MEU_ID" ]; then
    echo "❌ Erro: Token ou ID não informados. Abortando."
    exit 1
fi

echo ">>> Instalando dependências..."
opkg update
opkg install opennds curl ca-bundle ca-certificates coreutils-base64 conntrack

# --- 1. CRIAÇÃO DO BOT TELEGRAM ---
echo ">>> Criando /root/bot_telegram.sh..."
cat << 'EOF' > /root/bot_telegram.sh
#!/bin/sh
TOKEN="PLACEHOLDER_TOKEN"
ADMIN_ID="PLACEHOLDER_ID"
URL="https://api.telegram.org/bot$TOKEN"
OFFSET="0"

sendMessage() {
    TEXT_PAYLOAD=$(printf "$2")
    curl -s -X POST "$URL/sendMessage" \
        --data-urlencode "chat_id=$1" \
        --data-urlencode "text=$TEXT_PAYLOAD" \
        --data-urlencode "parse_mode=Markdown" > /dev/null
}

HOST_NAME=$(uci get system.@system[0].hostname)
sendMessage "$ADMIN_ID" "🤖 *Bot Wolf-WRT Online!* (Host: $HOST_NAME)"

while true; do
    UPDATES=$(curl -s "$URL/getUpdates?offset=$OFFSET&timeout=60")
    if echo "$UPDATES" | grep -q '"update_id":'; then
        LAST_ID=$(echo "$UPDATES" | grep -o '"update_id":[0-9]*' | tail -n1 | cut -d: -f2)
        OFFSET=$((LAST_ID + 1))
        CHAT_ID=$(echo "$UPDATES" | grep -o '"chat":{"id":[0-9]*' | cut -d: -f3 | head -n1)
        TEXT=$(echo "$UPDATES" | grep -o '"text":"[^"]*"' | cut -d'"' -f4 | head -n1)

        if [ "$CHAT_ID" = "$ADMIN_ID" ]; then
            if echo "$TEXT" | grep -qE "^/ajuda|^/start"; then
                sendMessage "$CHAT_ID" "🛠 *Comandos:* /liberar, /bloquear, /vips, /status"
            elif echo "$TEXT" | grep -q "^/vips"; then
                MACS=$(uci show dhcp | grep ".mac=" | cut -d"'" -f2)
                [ -z "$MACS" ] && sendMessage "$CHAT_ID" "📋 Vazio." || {
                    RES="📋 *VIPs:*\n"
                    for mac in $MACS; do
                        ID=$(uci show dhcp | grep "$mac" | cut -d. -f2)
                        NOME=$(uci get dhcp.$ID.name 2>/dev/null || echo "Sem Nome")
                        RES="$RES👤 *$NOME*\n\`$mac\`\n\n"
                    done
                    sendMessage "$CHAT_ID" "$RES"
                }
            elif echo "$TEXT" | grep -q "^/liberar"; then
                MAC=$(echo "$TEXT" | awk '{print $2}' | tr 'A-Z' 'a-z')
                NAME=$(echo "$TEXT" | awk '{print $3}')
                IP=$(grep -i "$MAC" /tmp/dhcp.leases | awk '{print $3}')
                if [ -n "$IP" ]; then
                    uci add dhcp host >/dev/null
                    uci set dhcp.@host[-1].name="$NAME"; uci set dhcp.@host[-1].ip="$IP"; uci set dhcp.@host[-1].mac="$MAC"
                    uci commit dhcp; /etc/init.d/dnsmasq reload; ndsctl trust "$MAC" 2>/dev/null
                    sendMessage "$CHAT_ID" "✅ *$NAME* liberado!"
                else
                    sendMessage "$CHAT_ID" "⚠️ MAC não ativo."
                fi
            elif echo "$TEXT" | grep -q "^/bloquear"; then
                MAC=$(echo "$TEXT" | awk '{print $2}' | tr 'A-Z' 'a-z')
                ID=$(uci show dhcp | grep -i "$MAC" | head -n1 | cut -d. -f2)
                IP=$(grep -i "$MAC" /tmp/dhcp.leases | awk '{print $3}')
                [ -n "$ID" ] && { uci delete dhcp.$ID; uci commit dhcp; /etc/init.d/dnsmasq reload; }
                ndsctl untrust "$MAC" 2>/dev/null; ndsctl deauth "$MAC" 2>/dev/null
                [ -n "$IP" ] && conntrack -D -s "$IP" 2>/dev/null
                sendMessage "$CHAT_ID" "🚫 $MAC revogado."
            elif echo "$TEXT" | grep -q "^/status"; then
                 UP=$(uptime | awk '{print $3,$4}' | sed 's/,//')
                 sendMessage "$CHAT_ID" "ℹ️ Uptime: $UP | VIPs: $(uci show dhcp | grep -c ".mac=")"
            fi
        fi
    fi
    sleep 1
done
EOF

sed -i "s/PLACEHOLDER_TOKEN/$MEU_TOKEN/g" /root/bot_telegram.sh
sed -i "s/PLACEHOLDER_ID/$MEU_ID/g" /root/bot_telegram.sh
chmod +x /root/bot_telegram.sh

# --- 2. SCRIPT DE SYNC ---
cat << 'EOF' > /root/sync_clients.sh
#!/bin/sh
MACS=$(uci show dhcp | grep "\.mac.*=" | cut -d"'" -f2 | tr 'A-Z' 'a-z')
for mac in $MACS; do ndsctl trust $mac 2>/dev/null; done
EOF
chmod +x /root/sync_clients.sh

# --- 3. PÁGINA DE BLOQUEIO ---
cat << 'EOF' > /etc/opennds/theme_custom.sh
#!/bin/sh
TOKEN="PLACEHOLDER_TOKEN"; ADMIN_ID="PLACEHOLDER_ID"; INTERVALO=1800 
RAW_INPUT="$1"
CLEAN_INPUT=$(echo "$RAW_INPUT" | sed 's/%3[dD]/=/g; s/%3[fF]/?/g; s/%2[cC]/,/g; s/%2[6]/&/g')
FAS_PAYLOAD=$(echo "$CLEAN_INPUT" | sed -n 's/.*fas=\([^&]*\).*/\1/p')
CLIENT_MAC=$(echo "$FAS_PAYLOAD" | base64 -d 2>/dev/null | grep -oE 'clientmac=[0-9a-fA-F:]{17}' | cut -d= -f2)
[ -z "$CLIENT_MAC" ] && CLIENT_MAC="$clientmac"
[ -z "$CLIENT_MAC" ] && CLIENT_MAC="Desconhecido"

if [ "$CLIENT_MAC" != "Desconhecido" ]; then
    AGORA=$(date +%s); ARQUIVO_TRAVA="/tmp/lock_msg_$(echo $CLIENT_MAC | tr -d ':')"
    ENVIAR="sim"
    [ -f "$ARQUIVO_TRAVA" ] && { [ $((AGORA - $(cat "$ARQUIVO_TRAVA"))) -lt "$INTERVALO" ] && ENVIAR="nao"; }
    if [ "$ENVIAR" = "sim" ]; then
        echo "$AGORA" > "$ARQUIVO_TRAVA"
        MSG="🔔 *Novo Acesso Detectado!*\nMAC: \`$CLIENT_MAC\`\n\n/liberar $CLIENT_MAC NOME"
        curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" --data-urlencode "chat_id=$ADMIN_ID" --data-urlencode "text=$(printf "$MSG")" --data-urlencode "parse_mode=Markdown" > /dev/null &
    fi
fi

cat <<HTML
<!DOCTYPE html>
<html lang="pt-BR">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
body{font-family:sans-serif;background:#f0f2f5;display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;margin:0;padding:20px;text-align:center}
.card{background:white;padding:2rem;border-radius:12px;box-shadow:0 8px 16px rgba(0,0,0,0.1);max-width:400px;width:100%;border-top:5px solid #d32f2f}
.mac-box{background:#2d3436;color:#55efc4;padding:12px;border-radius:6px;font-family:monospace;font-size:1.2em;margin:15px 0;font-weight:bold}
.footer{margin-top:25px;font-size:0.85rem;color:#b2bec3;border-top:1px solid #dfe6e9;padding-top:15px}
</style></head>
<body><div class="card"><h1>⛔ Acesso Restrito</h1><p>O administrador foi notificado.</p><div class="mac-box">$CLIENT_MAC</div>
<div class="footer">Wagner Wolf - Administrador de Rede</div></div></body></html>
HTML
exit 0
EOF

sed -i "s/PLACEHOLDER_TOKEN/$MEU_TOKEN/g" /etc/opennds/theme_custom.sh
sed -i "s/PLACEHOLDER_ID/$MEU_ID/g" /etc/opennds/theme_custom.sh
chmod +x /etc/opennds/theme_custom.sh

# --- 4. PERSISTÊNCIA ---
sed -i '/bot_telegram.sh/d' /etc/rc.local; sed -i '/sync_clients.sh/d' /etc/rc.local
sed -i '$i /root/sync_clients.sh &' /etc/rc.local; sed -i '$i /root/bot_telegram.sh &' /etc/rc.local
echo "*/2 * * * * /root/sync_clients.sh" >> /etc/crontabs/root
/etc/init.d/cron restart; /etc/init.d/opennds restart; /root/bot_telegram.sh &

echo "✅ SISTEMA WOLF-WRT INSTALADO!"
