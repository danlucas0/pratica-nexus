#!/usr/bin/env bash
# Configura o Nexus Repository pela API REST (configuração como código).
# Uso: ./scripts/configurar-nexus.sh
set -euo pipefail

NEXUS_URL="${NEXUS_URL:-http://localhost:8081}"
NOVA_SENHA="${NEXUS_SENHA:-admin123}"
API="$NEXUS_URL/service/rest/v1"

echo "==> Aguardando o Nexus ficar disponível..."
until curl -sf "$API/status" >/dev/null; do sleep 5; done

# Na primeira subida, a senha do admin fica num arquivo dentro do container
SENHA_INICIAL=$(MSYS_NO_PATHCONV=1 docker exec nexus cat /nexus-data/admin.password 2>/dev/null || true)
if [ -n "$SENHA_INICIAL" ]; then
  echo "==> Trocando a senha inicial do admin"
  curl -sf -u "admin:$SENHA_INICIAL" -X PUT "$API/security/users/admin/change-password" \
    -H "Content-Type: text/plain" --data "$NOVA_SENHA"
  MSYS_NO_PATHCONV=1 docker exec nexus rm -f /nexus-data/admin.password
fi
AUTH="admin:$NOVA_SENHA"

# Envia JSON para a API; ignora "já existe" para o script poder rodar de novo
enviar() {
  local metodo=$1 caminho=$2 corpo=$3
  local codigo
  codigo=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X "$metodo" "$API$caminho" \
    -H "Content-Type: application/json" --data "$corpo")
  case $codigo in
    2*) echo "    ok ($codigo)";;
    400) echo "    já existe / sem alteração ($codigo)";;
    *) echo "    ERRO $codigo em $caminho"; exit 1;;
  esac
}

echo "==> Aceitando o EULA da Community Edition"
# Devolve o mesmo JSON recebido, trocando accepted:false por true (preserva o texto exato)
curl -s -u "$AUTH" "$API/system/eula" | sed 's/"accepted" : false/"accepted" : true/' \
  | curl -sf -o /dev/null -u "$AUTH" -X POST "$API/system/eula" \
      -H "Content-Type: application/json; charset=utf-8" --data-binary @- \
  && echo "    ok"

echo "==> Ativando realms (login do npm e do Docker por token)"
enviar PUT /security/realms/active '["NexusAuthenticatingRealm","NpmToken","DockerToken"]'

echo "==> Liberando leitura anônima (navegar sem login)"
enviar PUT /security/anonymous '{"enabled": true, "userId": "anonymous", "realmName": "NexusAuthorizingRealm"}'

echo "==> Repositório npm-hosted (pacotes publicados pela equipe)"
enviar POST /repositories/npm/hosted '{
  "name": "npm-hosted", "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "allow_once"}
}'

echo "==> Repositório npm-proxy (cache do registry.npmjs.org)"
enviar POST /repositories/npm/proxy '{
  "name": "npm-proxy", "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
  "proxy": {"remoteUrl": "https://registry.npmjs.org", "contentMaxAge": 1440, "metadataMaxAge": 1440},
  "negativeCache": {"enabled": true, "timeToLive": 1440},
  "httpClient": {"blocked": false, "autoBlock": true}
}'

echo "==> Repositório npm-group (une hosted + proxy num endereço só)"
enviar POST /repositories/npm/group '{
  "name": "npm-group", "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
  "group": {"memberNames": ["npm-hosted", "npm-proxy"]}
}'

echo "==> Repositório docker-hosted (imagens Docker, porta 8082)"
enviar POST /repositories/docker/hosted '{
  "name": "docker-hosted", "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "allow"},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": 8082}
}'

echo
echo "Nexus configurado: $NEXUS_URL  (usuário: admin / senha: $NOVA_SENHA)"
