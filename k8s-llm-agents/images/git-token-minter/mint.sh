#!/bin/sh
# Mints a GitHub App installation token restricted to $REPOS (comma-separated
# repo names, without owner) and writes it into Secret $TARGET_NAMESPACE/$TARGET_SECRET.
# The App private key never leaves the agent-credentials namespace.
set -eu

APP_ID="$(cat /var/run/github-app/app-id)"
INSTALLATION_ID="$(cat /var/run/github-app/installation-id)"
KEY=/var/run/github-app/private-key.pem
: "${REPOS:?}" "${TARGET_NAMESPACE:?}" "${TARGET_SECRET:?}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64url)
sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$KEY" | b64url)
jwt="$header.$payload.$sig"

repos_json=$(printf '%s' "$REPOS" | jq -Rc 'split(",") | map(select(length > 0))')
body=$(jq -nc --argjson r "$repos_json" \
  '{repositories: $r, permissions: {contents: "write", pull_requests: "write", metadata: "read"}}')

token=$(curl -fsS -X POST \
  -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens" \
  -d "$body" | jq -er .token)

# Patch the target Secret via the Kubernetes API (RBAC allows only this Secret).
SA=/var/run/secrets/kubernetes.io/serviceaccount
patch=$(jq -nc --arg t "$(printf '%s' "$token" | openssl base64 -A)" '{data: {token: $t}}')
curl -fsS -o /dev/null -X PATCH \
  --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" \
  -H "Content-Type: application/merge-patch+json" \
  "https://kubernetes.default.svc/api/v1/namespaces/$TARGET_NAMESPACE/secrets/$TARGET_SECRET" \
  -d "$patch"

echo "{\"audit\":\"git-token-minted\",\"repos\":$repos_json,\"ts\":\"$(date -u +%FT%TZ)\"}"
