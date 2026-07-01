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

example_files() {
    find "$1" -maxdepth 1 -type f -name '*example*' -print | LC_ALL=C sort
}

configured_value() {
    local config_dir="$1" key="$2" file value
    value="${!key:-}"
    [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    for file in "$config_dir/config.conf" "$config_dir/container.conf" "$config_dir/.env" "$config_dir/build.conf"; do
        value="$(read_key "$file" "$key" || true)"
        [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    done
    while IFS= read -r file; do
        value="$(read_key "$file" "$key" || true)"
        [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    done < <(example_files "$config_dir")
}

named_volume_specs() {
    local config_dir="$1" file
    while IFS= read -r file; do
        awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /^[[:space:]]*#named-volume:/ {
            value=$0
            sub(/^[[:space:]]*#named-volume:[[:space:]]*/, "", value)
            specs[++count]=trim(value)
            next
        }
        count && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
            key=$0
            sub(/[[:space:]]*=.*/, "", key)
            for (i=1; i<=count; i++) print trim(key) "\t" specs[i]
            delete specs
            count=0
        }' "$file"
    done < <(example_files "$config_dir")
}

enabled_named_volume_specs() {
    local config_dir="$1" key mount source target kind value
    while IFS=$'\t ' read -r key mount source target kind; do
        [ -n "$key" ] && [ -n "$mount" ] && [ -n "$source" ] && [ -n "$target" ] || continue
        value="$(configured_value "$config_dir" "$key")"
        case "${value,,}" in 1|true|yes|on) ;; *) continue ;; esac
        valid_path "$mount" && valid_path "$source" && valid_path "$target" || {
            echo "Invalid #named-volume for $key" >&2
            return 1
        }
        case "$kind" in ""|file|dir) ;; *) echo "Invalid #named-volume type for $key" >&2; return 1 ;; esac
        printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$mount" "$source" "$target" "$kind"
    done < <(named_volume_specs "$config_dir" | awk -F '\t' '!seen[$0]++')
}

path_keys() {
    local config_dir="$1" file
    for file in "$config_dir"/*build.conf_example "$config_dir/build.conf" "$config_dir/container.conf"; do
        [ -f "$file" ] || continue
        awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*_PERSISTENT_PATH[[:space:]]*=/ {
            key=$0
            sub(/[[:space:]]*=.*/, "", key)
            sub(/^[[:space:]]*/, "", key)
            if (!seen[key]++) print key
        }' "$file"
    done | awk '!seen[$0]++'
}

configured_path() {
    local config_dir="$1" key="$2" file value
    value="${!key:-}"
    [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    for file in "$config_dir/container.conf" "$config_dir/build.conf" "$config_dir"/*build.conf_example; do
        value="$(read_key "$file" "$key" || true)"
        [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    done
}

valid_path() {
    local path="$1"
    [[ "$path" == /* && "$path" != *:* && "$path" != *'|'* && "$path" != *';'* && "$path" != *$'\n'* && "$path" != *$'\r'* ]]
}

safe_name() {
    printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9_.-]/-/g'
}

emit_entries() {
    local config_dir="$1" key path
    while IFS= read -r key || [ -n "$key" ]; do
        [ -n "$key" ] || continue
        path="$(configured_path "$config_dir" "$key")"
        case "${path,,}" in ""|blank|null) continue ;; esac
        valid_path "$path" || { echo "Invalid $key: $path" >&2; return 1; }
        printf '%s\t%s\n' "$key" "$path"
    done < <(path_keys "$config_dir")
}

command="${1:-}"
shift || true
config_dir="."
container_name=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config-dir) config_dir="$2"; shift 2 ;;
        --container) container_name="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$command" in
    entries)
        emit_entries "$config_dir"
        links=""
        while IFS=$'\t' read -r _ mount source target kind; do
            valid_path "$mount" && valid_path "$source" && valid_path "$target" || {
                echo "Invalid #named-volume specification" >&2
                exit 1
            }
            spec="$mount|$source|$target|$kind"
            links="${links:+$links;}$spec"
        done < <(enabled_named_volume_specs "$config_dir")
        [ -z "$links" ] || printf 'NAMED_VOLUME_LINKS\t%s\n' "$links"
        ;;
    mounts)
        [ -n "$container_name" ] || { echo "mounts requires --container" >&2; exit 2; }
        while IFS=$'\t' read -r key path; do
            prefix="${key%_PERSISTENT_PATH}"
            printf '%s-%s-persistent:%s:Z\n' "$(safe_name "$container_name")" "$(safe_name "$prefix")" "$path"
        done < <(emit_entries "$config_dir")
        while IFS=$'\t' read -r _ mount _ _ _; do
            printf '%s-%s:%s:Z\n' "$(safe_name "$container_name")" "$(safe_name "${mount##*/}")" "$mount"
        done < <(enabled_named_volume_specs "$config_dir" | awk -F '\t' '!seen[$2]++')
        ;;
    init)
        while IFS= read -r key; do
            [[ "$key" == *_PERSISTENT_PATH ]] || continue
            path="${!key:-}"
            case "${path,,}" in ""|blank|null) continue ;; esac
            valid_path "$path" || { echo "Invalid $key: $path" >&2; exit 1; }
            mkdir -p "$path"
        done < <(compgen -e | LC_ALL=C sort -u)
        ;;
    *)
        echo "Usage: optional_persistence.sh entries|mounts|init [options]" >&2
        exit 2
        ;;
esac
