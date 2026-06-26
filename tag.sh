#!/usr/bin/env bash
set -euo pipefail

tag="${TAG:-$(date +%Y.%-m.%-d)}"
remote="${REMOTE:-origin}"

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
if [ "${1:-}" = "--check" ]; then
  set -x
  gh run list --branch "$tag" --limit 1
  exit 0
fi

ensure_github_auth
ensure_registry_auth "docker.io" "DOCKERHUB_USERNAME" "DOCKERHUB_TOKEN"
ensure_registry_auth "quay.io" "QUAY_USERNAME" "QUAY_TOKEN"

git tag -d "$tag" 2>/dev/null || true
git push "$remote" ":refs/tags/$tag" 2>/dev/null || true
git tag "$tag"
git push "$remote" "$tag"
