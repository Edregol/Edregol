#!/bin/sh
# git credential helper: hands git the short-lived GitHub App installation
# token that the token-minter CronJob keeps fresh in the mounted Secret.
# Only answers "get" and only for github.com.
[ "$1" = "get" ] || exit 0
host=""
while IFS='=' read -r k v; do
  [ -z "$k" ] && break
  [ "$k" = "host" ] && host="$v"
done
[ "$host" = "github.com" ] || exit 0
token_file="${GIT_TOKEN_FILE:-/var/run/git-token/token}"
[ -r "$token_file" ] || exit 0
echo "username=x-access-token"
echo "password=$(cat "$token_file")"
