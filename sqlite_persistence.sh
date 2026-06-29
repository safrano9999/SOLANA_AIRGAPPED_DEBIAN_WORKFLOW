#!/usr/bin/env bash
set -euo pipefail

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_key() {
    local file="$1" wanted="$2" line entry key
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        entry="$(trim "${line%%#*}")"
        [[ "$entry" == *=* ]] || continue
        key="$(trim "${entry%%=*}")"
        [ "$key" = "$wanted" ] || continue
        trim "${entry#*=}"
        printf '\n'
        return 0
    done < "$file"
    return 1
}

configured_value() {
    local config_dir="$1" key="$2" default_value="$3" file value
    value="${!key:-}"
    [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    for file in "$config_dir/.env" "$config_dir/config.conf" "$config_dir/container.conf"; do
        value="$(read_key "$file" "$key" || true)"
        [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    done
    printf '%s\n' "$default_value"
}

backend_entries() {
    awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*_DB_BACKEND[[:space:]]*=/ {
        line = $0
        sub(/[[:space:]]*#.*/, "", line)
        key = line
        sub(/[[:space:]]*=.*/, "", key)
        sub(/^[[:space:]]*/, "", key)
        value = line
        sub(/^[^=]*=/, "", value)
        sub(/^[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        print key "\t" value
    }'
}

safe_name() {
    printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9_.-]/-/g'
}

repo_sqlite_enabled() {
    local env_file="$1" config_dir="$2" key default_value value
    [ -f "$env_file" ] || return 1
    while IFS=$'\t' read -r key default_value; do
        [ -n "$key" ] || continue
        value="$(configured_value "$config_dir" "$key" "$default_value")"
        case "${value,,}" in
            sqlite|sqlite3) return 0 ;;
        esac
    done < <(backend_entries < "$env_file")
    return 1
}

zip_member() {
    local zip="$1" suffix="$2"
    unzip -Z1 "$zip" | awk -v suffix="$suffix" '$0 == suffix || $0 ~ ("/" suffix "$") { print; exit }'
}

zip_plugin_id() {
    local zip="$1" member
    member="$(zip_member "$zip" openclaw.plugin.json)"
    [ -n "$member" ] || return 1
    unzip -p "$zip" "$member" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
}

emit_mount() {
    local container_name="$1" prefix="$2" target="$3" volume
    volume="$(safe_name "$container_name")-$(safe_name "$prefix")-sqlite"
    printf '%s:%s/sqlite:Z\n' "$volume" "${target%/}"
}

init_repo() {
    local repo="$1" config_dir="$2"
    repo_sqlite_enabled "$repo/env.example" "$config_dir" || return 0
    mkdir -p "$repo/sqlite"
}

mount_repo() {
    local repo="$1" config_dir="$2" container_name="$3" target="$4"
    local key default_value value
    [ -f "$repo/env.example" ] || return 0
    while IFS=$'\t' read -r key default_value; do
        [ -n "$key" ] || continue
        value="$(configured_value "$config_dir" "$key" "$default_value")"
        case "${value,,}" in
            sqlite|sqlite3) emit_mount "$container_name" "${key%_DB_BACKEND}" "$target" ;;
        esac
    done < <(backend_entries < "$repo/env.example")
}

command="${1:-}"
shift || true
repo=""
repo_root=""
zip_root=""
config_dir=""
container_name=""
target=""
target_root=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --repo-root) repo_root="$2"; shift 2 ;;
        --zip-root) zip_root="$2"; shift 2 ;;
        --config-dir) config_dir="$2"; shift 2 ;;
        --container) container_name="$2"; shift 2 ;;
        --target) target="$2"; shift 2 ;;
        --target-root) target_root="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$config_dir" ] || config_dir="${repo:-.}"

case "$command" in
    init)
        if [ -n "$repo" ]; then
            init_repo "$repo" "$config_dir"
        elif [ -n "$repo_root" ]; then
            for repo in "$repo_root"/*; do [ -d "$repo" ] && init_repo "$repo" "$config_dir"; done
        else
            echo "init requires --repo or --repo-root" >&2
            exit 2
        fi
        ;;
    mounts)
        [ -n "$container_name" ] || { echo "mounts requires --container" >&2; exit 2; }
        if [ -n "$repo" ]; then
            [ -n "$target" ] || target="/opt/safrano9999/$(basename "$repo")"
            mount_repo "$repo" "$config_dir" "$container_name" "$target"
        elif [ -n "$repo_root" ]; then
            [ -n "$target_root" ] || target_root="/opt/safrano9999"
            for repo in "$repo_root"/*; do
                [ -d "$repo" ] || continue
                mount_repo "$repo" "$config_dir" "$container_name" "$target_root/$(basename "$repo")"
            done
        elif [ -n "$zip_root" ]; then
            [ -n "$target_root" ] || target_root="/root/.openclaw/extensions"
            for zip in "$zip_root"/*-latest.zip; do
                [ -f "$zip" ] || continue
                member="$(zip_member "$zip" env.example)"
                [ -n "$member" ] || continue
                tmp="$(mktemp)"
                trap 'rm -f "${tmp:-}"' EXIT
                unzip -p "$zip" "$member" > "$tmp"
                plugin_id="$(zip_plugin_id "$zip" || true)"
                [ -n "$plugin_id" ] || continue
                while IFS=$'\t' read -r key default_value; do
                    [ -n "$key" ] || continue
                    value="$(configured_value "$config_dir" "$key" "$default_value")"
                    case "${value,,}" in
                        sqlite|sqlite3) emit_mount "$container_name" "${key%_DB_BACKEND}" "$target_root/$plugin_id" ;;
                    esac
                done < <(backend_entries < "$tmp")
                rm -f "$tmp"
                tmp=""
            done
        else
            echo "mounts requires --repo, --repo-root or --zip-root" >&2
            exit 2
        fi
        ;;
    *)
        echo "Usage: sqlite_persistence.sh init|mounts [options]" >&2
        exit 2
        ;;
esac
