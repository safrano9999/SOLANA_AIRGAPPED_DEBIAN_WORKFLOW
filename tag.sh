#!/usr/bin/env bash
set -euo pipefail

remote="${REMOTE:-origin}"
latest_tag="latest"

auth_declined() {
  local provider="${1%%.*}"

  [ -f "$tag_preferences" ] || return 1
  tr ',' '\n' < "$tag_preferences" | grep -Fqx "$provider"
}

ensure_tag_ignored() {
  local gitignore="$repo_root/.gitignore"

  if [ ! -f "$gitignore" ]; then
    printf '.tag\n' > "$gitignore"
  elif ! grep -Fqx '.tag' "$gitignore"; then
    printf '\n.tag\n' >> "$gitignore"
  fi
}

remember_auth_decline() {
  local provider="${1%%.*}"
  local current=""

  auth_declined "$provider" && return 0
  ensure_tag_ignored
  [ -f "$tag_preferences" ] && current="$(tr ',' '\n' < "$tag_preferences")"
  printf '%s\n%s\n' "$current" "$provider" \
    | awk 'NF && !seen[$0]++' > "$tag_preferences"
}

confirm_login() {
  local provider="$1"
  local answer

  auth_declined "$provider" && return 1
  read -rp "Auth missing: $provider. Login for $provider? [Y/n]: " answer
  case "${answer:-y}" in
    n|N|no|NO|No) remember_auth_decline "$provider"; return 1 ;;
    *) return 0 ;;
  esac
}

prompt_credentials() {
  local provider="$1"
  local username_var="$2"
  local token_var="$3"
  local username token

  read -rp "$provider username: " username
  read -rsp "$provider token: " token
  echo
  printf -v "$username_var" '%s' "$username"
  printf -v "$token_var" '%s' "$token"
}

ensure_github_auth() {
  local github_username github_token authenticated_user

  command -v gh >/dev/null || {
    echo "Auth check failed: gh is not installed." >&2
    exit 1
  }
  gh auth status --hostname github.com >/dev/null 2>&1 && return 0
  confirm_login "github.com" || return 0
  prompt_credentials "github.com" github_username github_token
  printf '%s\n' "$github_token" | gh auth login \
    --hostname github.com \
    --git-protocol https \
    --with-token
  unset github_token
  authenticated_user="$(gh api user --jq .login)"
  if [ -n "$github_username" ] && [ "$authenticated_user" != "$github_username" ]; then
    echo "GitHub token belongs to $authenticated_user, not $github_username." >&2
    exit 1
  fi
}

workflow_uses_secret() {
  local secret="$1"

  [ -d .github/workflows ] && grep -Rqs "secrets\.${secret}" .github/workflows
}

secret_exists() {
  local secret="$1"

  gh secret list --json name --jq '.[].name' | grep -Fqx "$secret"
}

ensure_registry_auth() {
  local provider="$1"
  local username_secret="$2"
  local token_secret="$3"
  local registry_username registry_token

  if ! workflow_uses_secret "$username_secret" && ! workflow_uses_secret "$token_secret"; then
    return 0
  fi
  if secret_exists "$username_secret" && secret_exists "$token_secret"; then
    return 0
  fi
  confirm_login "$provider" || return 0
  prompt_credentials "$provider" registry_username registry_token
  gh secret set "$username_secret" --body "$registry_username"
  gh secret set "$token_secret" --body "$registry_token"
  unset registry_token
}

repo_root="$(git rev-parse --show-toplevel)"
tag_preferences="$repo_root/.tag"
month_prefix="$(date +%Y.%-m)"

monthly_tag() {
  local mode="$1"
  local refs ref suffix number
  local highest=0

  refs="$(git ls-remote --tags --refs "$remote" "refs/tags/${month_prefix}.*")"
  while read -r _ ref; do
    suffix="${ref#refs/tags/${month_prefix}.}"
    [[ "$suffix" =~ ^[0-9]+$ ]] || continue
    number=$((10#$suffix))
    ((number > highest)) && highest="$number"
  done <<< "$refs"

  if [ "$mode" = check ] && ((highest > 0)); then
    printf '%s.%d\n' "$month_prefix" "$highest"
  else
    printf '%s.%d\n' "$month_prefix" "$((highest + 1))"
  fi
}

ensure_github_auth
if [ -n "${TAG:-}" ]; then
  tag="$TAG"
elif [ "${1:-}" = "--check" ]; then
  tag="$(monthly_tag check)"
else
  tag="$(monthly_tag next)"
fi

[ "$tag" != "$latest_tag" ] || { echo "$latest_tag is reserved for the moving tag" >&2; exit 2; }
if [ "${1:-}" = "--check" ]; then
  set -x
  gh run list --branch "$tag" --limit 1
  exit 0
fi

ensure_registry_auth "docker.io" "DOCKERHUB_USERNAME" "DOCKERHUB_TOKEN"
ensure_registry_auth "quay.io" "QUAY_USERNAME" "QUAY_TOKEN"

git tag -d "$tag" 2>/dev/null || true
git tag "$tag"
git tag -f "$latest_tag"
git push --atomic "$remote" \
  "refs/tags/$tag:refs/tags/$tag" \
  "+refs/tags/$latest_tag:refs/tags/$latest_tag"
printf 'Tagged %s and moved %s to %s\n' "$tag" "$latest_tag" "$(git rev-parse --short HEAD)"
