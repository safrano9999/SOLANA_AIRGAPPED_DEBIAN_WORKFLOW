#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/env.example" ] || [ -f "$SCRIPT_DIR/config.conf_example" ] || [ -f "$SCRIPT_DIR/container.example" ]; then
    DIR="$SCRIPT_DIR"
else
    DIR="$(pwd)"
fi

PROJECT_NAME="$(basename "$DIR")"
CONTAINER_NAME="${PROJECT_NAME,,}"
CONFIG_SHOW=""
NO_CONTAINER=false

for arg in "$@"; do
    case "$arg" in
        --show) CONFIG_SHOW="--show" ;;
        --no-container) NO_CONTAINER=true ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_kv_file() {
    local file="$1"
    local wanted="$2"
    local line stripped entry key value

    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="$(trim "$line")"
        [[ -z "$stripped" || "$stripped" == \#* ]] && continue

        entry="${line%%#*}"
        entry="$(trim "$entry")"
        [[ "$entry" == *=* ]] || continue

        key="$(trim "${entry%%=*}")"
        value="$(trim "${entry#*=}")"
        if [ "$key" = "$wanted" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$file"
    return 1
}

config_value() {
    local key="$1"
    local file

    if [ "$NO_CONTAINER" != "true" ]; then
        read_kv_file "$DIR/container.conf" "$key" && return 0
    fi
    for file in "$DIR/config.conf" "$DIR/.env"; do
        read_kv_file "$file" "$key" && return 0
    done
    if [ "$NO_CONTAINER" != "true" ]; then
        read_kv_file "$DIR/container.example" "$key" && return 0
    fi
    for file in "$DIR/config.conf_example" "$DIR/env.example"; do
        read_kv_file "$file" "$key" && return 0
    done
    return 1
}

provider_names_from_conf() {
    local provider_file="$1"
    local section name

    [ -f "$provider_file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        [[ "$line" =~ ^\[provider\.([^]]+)\]$ ]] || continue
        name="${BASH_REMATCH[1],,}"
        printf '%s\n' "$name"
    done < "$provider_file"
}

provider_file_for_example() {
    local example="$1"
    local key="${2:-}"
    local base prefix candidate

    base="$(dirname "$example")"
    if [ -f "$base/provider.conf" ]; then
        printf '%s\n' "$base/provider.conf"
        return 0
    fi
    if [ -f "$DIR/provider.conf" ]; then
        printf '%s\n' "$DIR/provider.conf"
        return 0
    fi
    if [ -n "$key" ] && [[ "$key" == *_PROVIDER* ]]; then
        prefix="${key%%_PROVIDER*}"
        candidate="$DIR/safrano9999/${prefix,,}-provider.conf"
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    for candidate in "$DIR"/safrano9999/*-provider.conf; do
        [ -f "$candidate" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

provider_prompt() {
    local example="$1"
    local key="${2:-}"
    local provider_file
    local -a names=()
    local name index=1

    provider_file="$(provider_file_for_example "$example" "$key" || true)"
    [ -n "$provider_file" ] || return 0
    while IFS= read -r name || [ -n "$name" ]; do
        [ -n "$name" ] || continue
        names+=("$name")
    done < <(provider_names_from_conf "$provider_file")
    [ "${#names[@]}" -gt 0 ] || return 0

    for name in "${names[@]}"; do
        printf '(%s) %s ' "$index" "$name"
        index=$((index + 1))
    done
}

normalize_provider_value() {
    local example="$1"
    local key="$2"
    local value="$3"
    local provider_file name index=1

    provider_file="$(provider_file_for_example "$example" "$key" || true)"
    if [ -n "$provider_file" ] && [[ "$value" =~ ^[0-9]+$ ]]; then
        while IFS= read -r name || [ -n "$name" ]; do
            if [ "$index" -eq "$value" ]; then
                printf '%s\n' "$name"
                return 0
            fi
            index=$((index + 1))
        done < <(provider_names_from_conf "$provider_file")
    fi
    printf '%s\n' "${value,,}"
}

provider_selector_key() {
    local key="$1"
    [[ "$key" =~ (^|_)PROVIDER(_[0-9]+)?$ ]]
}

normalize_rule_value() {
    local value="$1"
    value="$(trim "$value")"
    value="${value,,}"
    case "$value" in
        0|false|no|off) printf 'false\n' ;;
        1|true|yes|on) printf 'true\n' ;;
        *) printf '%s\n' "$value" ;;
    esac
}

openssl_generator_default() {
    local value="$1"
    [[ "$value" =~ ^example:[[:space:]]+openssl[[:space:]]+rand[[:space:]]+-(hex|base64)[[:space:]]+([0-9]+)$ ]]
}

openssl_generator_label() {
    local value="$1"
    value="$(trim "${value#example:}")"
    printf '%s\n' "$value"
}

run_openssl_generator() {
    local value="$1"
    local mode size

    if [[ "$value" =~ ^example:[[:space:]]+openssl[[:space:]]+rand[[:space:]]+-(hex|base64)[[:space:]]+([0-9]+)$ ]]; then
        mode="${BASH_REMATCH[1]}"
        size="${BASH_REMATCH[2]}"
        openssl rand "-$mode" "$size"
        return 0
    fi
    return 1
}

detect_gui_env_values() {
    local display="${DISPLAY:-}"
    local runtime="${XDG_RUNTIME_DIR:-}"

    [ -n "$display" ] || display=":0"
    [ -n "$runtime" ] || runtime="/run/user/$(id -u 2>/dev/null || printf '0')"

    printf 'DISPLAY=%s\n' "$display"
    printf 'NO_AT_BRIDGE=1\n'
    printf 'XDG_RUNTIME_DIR=%s\n' "$runtime"
}

write_config_value() {
    local target="$1"
    local key="$2"
    local value="$3"

    sed -i "/^${key}=/d" "$target" 2>/dev/null || true
    echo "$key=$value" >> "$target"
}

write_config_value_if_missing() {
    local target="$1"
    local key="$2"
    local value="$3"
    local existing_line existing

    existing_line="$(grep "^${key}=" "$target" 2>/dev/null | head -1 || true)"
    existing="${existing_line#*=}"
    if [ -n "$existing_line" ] && [ -n "$existing" ]; then
        echo "    $key= exists"
        return 0
    fi
    write_config_value "$target" "$key" "$value"
    echo "    $key=$value"
}

add_unique() {
    local value="$1"
    shift
    local -n target="$1"
    local existing

    [ -n "$value" ] || return 0
    for existing in "${target[@]}"; do
        [ "$existing" = "$value" ] && return 0
    done
    target+=("$value")
}

normalize_volume_item() {
    local item="$1"
    local source rest normalized_source

    if [[ "$item" != *:* ]]; then
        printf '%s\n' "$item"
        return 0
    fi

    source="${item%%:*}"
    rest="${item#*:}"
    normalized_source="$source"
    if [[ "$source" == "." || "$source" == ./* || "$source" == ../* || ( "$source" != /* && "$source" == */* ) ]]; then
        normalized_source="$(cd "$DIR" && realpath -m -- "$source")"
    fi
    printf '%s:%s\n' "$normalized_source" "$rest"
}

add_repo_bind_mount() {
    local rel="$1"
    local source target

    rel="$(trim "$rel")"
    [ -n "$rel" ] || return 0
    [[ "$rel" == /* || "$rel" == ../* ]] && return 0
    rel="${rel#./}"
    [ -n "$rel" ] || return 0

    source="$(cd "$DIR" && realpath -m -- "$rel")"
    mkdir -p "$source"
    target="/opt/safrano9999/$PROJECT_NAME/$rel"
    add_unique "${source}:${target}:Z" volumes
}

add_repo_file_bind_mount() {
    local rel="$1"
    local source target

    rel="$(trim "$rel")"
    [ -n "$rel" ] || return 0
    [[ "$rel" == /* || "$rel" == ../* || "$rel" == */* ]] && return 0

    source="$(cd "$DIR" && realpath -m -- "$rel")"
    touch "$source"
    target="/opt/safrano9999/$PROJECT_NAME/$rel"
    add_unique "${source}:${target}:Z" volumes
}

add_repo_sot_file_mounts() {
    local line entry

    [ -f "$DIR/.gitignore" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        entry="$(trim "${line%%#*}")"
        [[ "$entry" == *_SOT.md ]] || continue
        add_repo_file_bind_mount "$entry"
    done < "$DIR/.gitignore"
}

rewrite_config_with_comments() {
    local example="$1"
    local target="$2"
    local tmp

    [ -f "$example" ] || return 0
    [ -f "$target" ] || return 0

    tmp="$(mktemp)"
    awk -v target="$target" '
    function trim(s) {
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+$/, "", s)
        return s
    }
    function parse_env(line, parsed, allow_commented,    entry) {
        entry = line
        parsed["commented"] = 0
        sub(/^[[:space:]]+/, "", entry)
        if (allow_commented && substr(entry, 1, 1) == "#") {
            entry = substr(entry, 2)
            parsed["commented"] = 1
        } else if (substr(entry, 1, 1) == "#") {
            return 0
        }
        sub(/#.*/, "", entry)
        entry = trim(entry)
        if (entry !~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) return 0
        parsed["key"] = entry
        sub(/[[:space:]]*=.*/, "", parsed["key"])
        parsed["key"] = trim(parsed["key"])
        parsed["value"] = entry
        sub(/^[^=]*=/, "", parsed["value"])
        parsed["value"] = trim(parsed["value"])
        return 1
    }
    BEGIN {
        while ((getline line < target) > 0) {
            delete parsed
            if (parse_env(line, parsed, 0)) {
                if (!(parsed["key"] in current)) order[++order_count] = parsed["key"]
                current[parsed["key"]] = parsed["value"]
            }
        }
        close(target)
    }
    {
        raw = $0
        stripped = trim(raw)
        if (stripped == "") {
            pending[++pending_count] = raw
            next
        }
        delete parsed
        if (parse_env(raw, parsed, 1)) {
            key = parsed["key"]
            value = (key in current) ? current[key] : parsed["value"]
            for (i = 1; i <= pending_count; i++) print pending[i]
            if (parsed["commented"] && !(key in current)) {
                print "# " key "=" value
            } else {
                print key "=" value
                written[key] = 1
            }
            pending_count = 0
            next
        }
        if (substr(stripped, 1, 1) == "#") {
            comment = trim(substr(stripped, 2))
            pending[++pending_count] = raw
            next
        }
        pending_count = 0
    }
    END {
        for (i = 1; i <= order_count; i++) {
            key = order[i]
            if (key in written) continue
            if (!printed_extra) {
                print "# Additional local values"
                printed_extra = 1
            }
            print key "=" current[key]
        }
    }' "$example" > "$tmp"
    mv "$tmp" "$target"
}

configure_from_example() {
    local example="$1"
    local target="$2"
    local label="$3"
    local env_existing=""

    [ -f "$example" ] || return 0

    echo ""
    echo "  Configuring $label"
    echo ""

    touch "$target"
    declare -A seen_keys=()
    declare -A blank_if_targets=()
    declare -A autofill_blank_keys=()
    declare -A skip_existing_keys=()
    local required_next=false
    local directive condition condition_key condition_value target_key target_list
    local generator_label choice
    local rule_key

    while IFS= read -r line <&4; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        [[ "$stripped" == \#blank-if:* ]] || continue
        directive="$(trim "${stripped#\#blank-if:}")"
        [ -n "$directive" ] || continue

        condition="${directive%%[[:space:]]*}"
        target_list="${directive#"$condition"}"
        target_list="$(trim "$target_list")"
        [[ "$condition" == *=* ]] || continue

        condition_key="$(trim "${condition%%=*}")"
        condition_value="$(normalize_rule_value "${condition#*=}")"
        [[ "$condition_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [ -n "$target_list" ] || continue

        rule_key="${condition_key}=${condition_value}"
        blank_if_targets[$rule_key]="${blank_if_targets[$rule_key]:-} $target_list"
    done 4< "$example"

    activate_blank_rules() {
        local control_key="$1"
        local control_value="$2"
        local rule_key targets target_key

        rule_key="${control_key}=$(normalize_rule_value "$control_value")"
        targets="${blank_if_targets[$rule_key]:-}"
        [ -n "$targets" ] || return 0
        for target_key in $targets; do
            [[ "$target_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            autofill_blank_keys[$target_key]=1
        done
    }

    handle_display_env() {
        local target="$1"
        local choice read_status=0 val display_val no_at_bridge_val runtime_val line

        display_val=":0"
        no_at_bridge_val="1"
        runtime_val="/run/user/$(id -u 2>/dev/null || printf '0')"

        if [ -t 0 ]; then
            echo "    DISPLAY:"
            echo "      (1) autodetect GUI env"
            echo "      (2) enter manual"
            read -r -p "    Choose [1/2] (default: 1): " choice || read_status=$?
            choice="${choice:-1}"
        else
            choice="1"
        fi

        case "$choice" in
            1)
                while IFS= read -r line || [ -n "$line" ]; do
                    case "$line" in
                        DISPLAY=*) display_val="${line#DISPLAY=}" ;;
                        NO_AT_BRIDGE=*) no_at_bridge_val="${line#NO_AT_BRIDGE=}" ;;
                        XDG_RUNTIME_DIR=*) runtime_val="${line#XDG_RUNTIME_DIR=}" ;;
                    esac
                done < <(detect_gui_env_values || true)
                ;;
            2)
                if [ -t 0 ]; then
                    read -e -i "$display_val" -r -p "    DISPLAY: " val || read_status=$?
                    [ -n "$val" ] && display_val="$val"
                    read -e -i "$no_at_bridge_val" -r -p "    NO_AT_BRIDGE: " val || read_status=$?
                    [ -n "$val" ] && no_at_bridge_val="$val"
                    read -e -i "$runtime_val" -r -p "    XDG_RUNTIME_DIR: " val || read_status=$?
                    [ -n "$val" ] && runtime_val="$val"
                fi
                ;;
            *)
                echo "    choose 1 or 2"
                return 1
                ;;
        esac

        [ -n "$display_val" ] || display_val=":0"
        [ -n "$no_at_bridge_val" ] || no_at_bridge_val="1"
        [ -n "$runtime_val" ] || runtime_val="/tmp/runtime-root"

        write_config_value_if_missing "$target" "DISPLAY" "$display_val"
        write_config_value_if_missing "$target" "NO_AT_BRIDGE" "$no_at_bridge_val"
        write_config_value_if_missing "$target" "XDG_RUNTIME_DIR" "$runtime_val"
        return "$read_status"
    }

    while IFS= read -r line <&3; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        if [[ "$stripped" == \#required:* ]]; then
            required_next=true
            continue
        fi
        if [[ -z "$stripped" || "$stripped" == \#* ]]; then
            required_next=false
            continue
        fi
        required="$required_next"
        required_next=false

        entry="${line%%#*}"
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ "$entry" != *=* ]] && continue

        key="${entry%%=*}"
        default="${entry#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        default="${default#"${default%%[![:space:]]*}"}"
        default="${default%"${default##*[![:space:]]}"}"

        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [[ -n "${seen_keys[$key]+x}" ]]; then
            echo "    duplicate $key in $(basename "$example")" >&2
            continue
        fi
        seen_keys[$key]=1

        if [[ -n "${skip_existing_keys[$key]+x}" ]]; then
            continue
        fi

        env_existing=""
        if [ "$(basename "$target")" = "config.conf" ]; then
            env_existing="$(read_kv_file "$DIR/.env" "$key" || true)"
        elif [ "$(basename "$target")" = "container.conf" ]; then
            env_existing="$(read_kv_file "$DIR/config.conf" "$key" || read_kv_file "$DIR/.env" "$key" || true)"
        fi

        if [[ -n "${autofill_blank_keys[$key]+x}" ]]; then
            sed -i "/^${key}=/d" "$target" 2>/dev/null || true
            echo "$key=blank" >> "$target"
            echo "    $key= blank"
            continue
        fi

        existing_line="$(grep "^${key}=" "$target" 2>/dev/null | head -1 || true)"
        existing="${existing_line#*=}"
        if [ -n "$existing_line" ] && [ -z "$existing" ] && [ -n "$env_existing" ]; then
            sed -i "/^${key}=/d" "$target" 2>/dev/null || true
            echo "$key=$env_existing" >> "$target"
            echo "    $key= migrated from .env"
            activate_blank_rules "$key" "$env_existing"
            continue
        fi
        if [ -n "$existing_line" ] && { [ "$required" != "true" ] || [ -n "$existing" ]; }; then
            [ "$CONFIG_SHOW" = "--show" ] && echo "    $key=$existing" || echo "    $key= exists"
            activate_blank_rules "$key" "$existing"
            continue
        fi
        sed -i "/^${key}=$/d" "$target" 2>/dev/null || true

        if [ -n "$env_existing" ]; then
            echo "$key=$env_existing" >> "$target"
            echo "    $key= migrated from .env"
            activate_blank_rules "$key" "$env_existing"
            continue
        fi

        if [ "$key" = "DISPLAY" ]; then
            handle_display_env "$target"
            skip_existing_keys[NO_AT_BRIDGE]=1
            skip_existing_keys[XDG_RUNTIME_DIR]=1
            continue
        fi

        while :; do
            used_prefill=false
            read_status=0
            prompt_suffix=""
            if [ "$required" = "true" ] && openssl_generator_default "$default"; then
                generator_label="$(openssl_generator_label "$default")"
                if [ -t 0 ]; then
                    echo "    $key:"
                    echo "      (1) enter value"
                    echo "      (2) generate $generator_label"
                    read -r -p "    Choose [1/2] (default: 2): " choice || read_status=$?
                    choice="${choice:-2}"
                    case "$choice" in
                        1)
                            read -r -p "    $key: " val || read_status=$?
                            ;;
                        2)
                            val="$(run_openssl_generator "$default")" || {
                                echo "    $key generator failed" >&2
                                exit 1
                            }
                            echo "    $key= generated"
                            ;;
                        *)
                            echo "    choose 1 or 2"
                            val=""
                            ;;
                    esac
                else
                    val="$(run_openssl_generator "$default")" || {
                        echo "    $key generator failed" >&2
                        exit 1
                    }
                    echo "    $key= generated"
                fi
                if [ "$required" != "true" ] || [ -n "$val" ]; then
                    break
                fi
                if [ "$read_status" -ne 0 ] && [ ! -t 0 ]; then
                    echo "    $key required" >&2
                    exit 1
                fi
                echo "    $key required"
                continue
            fi
            if provider_selector_key "$key"; then
                prompt_suffix="$(provider_prompt "$example" "$key")"
            fi
            if [ -n "$default" ] && [ -t 0 ]; then
                read -e -i "$default" -r -p "    $key ${prompt_suffix}: " val || read_status=$?
                used_prefill=true
            else
                if [ -n "$default" ]; then
                    printf "    %s %s[%s]: " "$key" "$prompt_suffix" "$default"
                else
                    printf "    %s %s: " "$key" "$prompt_suffix"
                fi
                read -r val || read_status=$?
            fi
            if [ "$used_prefill" != "true" ] && [ -z "$val" ]; then
                val="$default"
            fi
            if provider_selector_key "$key"; then
                val="$(normalize_provider_value "$example" "$key" "$val")"
            fi
            if [ "$required" != "true" ] || [ -n "$val" ]; then
                break
            fi
            if [ "$read_status" -ne 0 ] && [ ! -t 0 ]; then
                echo "    $key required" >&2
                exit 1
            fi
            echo "    $key required"
        done

        if [ -z "$val" ]; then
            if [ "$used_prefill" = "true" ] && [ -n "$default" ]; then
                echo "$key=" >> "$target"
                echo "    $key= set empty"
                continue
            else
                echo "    $key= skipped"
                continue
            fi
        fi
        echo "$key=$val" >> "$target"
        activate_blank_rules "$key" "$val"
    done 3< "$example"

    rewrite_config_with_comments "$example" "$target"
}

existing_image() {
    local quadlet="$DIR/$CONTAINER_NAME.container"
    local compose="$DIR/docker-compose.yml"

    if [ -f "$quadlet" ]; then
        awk -F= '/^Image=/{print $2; exit}' "$quadlet"
        return 0
    fi
    if [ -f "$compose" ]; then
        awk '
        /^[[:space:]]*image:[[:space:]]*/ {
            sub(/^[[:space:]]*image:[[:space:]]*/, "")
            gsub(/^["'\''"]|["'\''"]$/, "")
            print
            exit
        }' "$compose"
        return 0
    fi
}

project_image() {
    local upper_name
    local configured
    upper_name="$(printf '%s' "$PROJECT_NAME" | tr '[:lower:]-' '[:upper:]_')"

    configured="$(config_value "${upper_name}_IMAGE" || true)"
    if [ -n "$configured" ]; then
        printf '%s\n' "$configured"
        return 0
    fi
    configured="$(config_value "IMAGE" || true)"
    if [ -n "$configured" ]; then
        printf '%s\n' "$configured"
        return 0
    fi
    existing_image | grep -m1 . && return 0
    printf 'localhost/%s:latest\n' "$CONTAINER_NAME"
}

config_source_files() {
    if [ -f "$DIR/config.conf" ]; then
        printf '%s\n' "$DIR/config.conf"
    elif [ -f "$DIR/config.conf_example" ]; then
        printf '%s\n' "$DIR/config.conf_example"
    fi
    if [ "$NO_CONTAINER" != "true" ]; then
        if [ -f "$DIR/container.conf" ]; then
            printf '%s\n' "$DIR/container.conf"
        elif [ -f "$DIR/container.example" ]; then
            printf '%s\n' "$DIR/container.example"
        fi
    fi
}

mount_if_source_files() {
    [ -f "$DIR/env.example" ] && printf '%s\n' "$DIR/env.example"
    [ -f "$DIR/config.conf_example" ] && printf '%s\n' "$DIR/config.conf_example"
    if [ "$NO_CONTAINER" != "true" ] && [ -f "$DIR/container.example" ]; then
        printf '%s\n' "$DIR/container.example"
    fi
}

publish_host_key() {
    local source_file line stripped directive target_key

    while IFS= read -r source_file || [ -n "$source_file" ]; do
        [ -f "$source_file" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            stripped="$(trim "$line")"
            [[ "$stripped" == \#publish-host:* ]] || continue
            directive="$(trim "${stripped#\#publish-host:}")"
            for target_key in $directive; do
                [[ "$target_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
                printf '%s\n' "$target_key"
                return 0
            done
        done < "$source_file"
    done < <(mount_if_source_files)
    return 1
}

mount_bind_from_value() {
    local key="$1"
    local rel

    rel="$(config_value "$key" || true)"
    [ -n "$rel" ] || return 0
    add_repo_bind_mount "$rel"
}

generate_container_files() {
    local source_file host image compose_file quadlet_file line stripped entry key value
    local prefix internal_key internal_port publish_port publish_host map
    local first_port="" command_host="0.0.0.0"
    local directive condition condition_key condition_value target_list target_key rel
    local host_key
    local -a ports=()
    local -a volumes=()
    local -a devices=()
    local -a caps=()
    local -a named_volumes=()
    local item source

    host_key="$(publish_host_key || true)"
    if [ -n "$host_key" ]; then
        host="$(config_value "$host_key" || true)"
    else
        host=""
    fi
    [ -n "$host" ] || host="127.0.0.1"
    image="$(project_image)"
    compose_file="$DIR/docker-compose.yml"
    quadlet_file="$DIR/$CONTAINER_NAME.container"

    while IFS= read -r source_file || [ -n "$source_file" ]; do
        [ -f "$source_file" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            stripped="$(trim "$line")"
            if [[ "$stripped" == \#mount-bind:* ]]; then
                directive="$(trim "${stripped#\#mount-bind:}")"
                [ -n "$directive" ] || continue
                for target_key in $directive; do
                    [[ "$target_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
                    mount_bind_from_value "$target_key"
                done
                continue
            fi
            [[ "$stripped" == \#mount-if:* ]] || continue
            directive="$(trim "${stripped#\#mount-if:}")"
            [ -n "$directive" ] || continue

            condition="${directive%%[[:space:]]*}"
            target_list="${directive#"$condition"}"
            target_list="$(trim "$target_list")"
            [[ "$condition" == *=* ]] || continue

            condition_key="$(trim "${condition%%=*}")"
            condition_value="$(normalize_rule_value "${condition#*=}")"
            [[ "$condition_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            [ -n "$target_list" ] || continue

            value="$(config_value "$condition_key" || true)"
            [ "$(normalize_rule_value "$value")" = "$condition_value" ] || continue
            for rel in $target_list; do
                add_repo_bind_mount "$rel"
            done
        done < "$source_file"
    done < <(mount_if_source_files)

    while IFS= read -r source_file || [ -n "$source_file" ]; do
        [ -f "$source_file" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            stripped="$(trim "$line")"
            [[ -z "$stripped" || "$stripped" == \#* ]] && continue

            entry="${line%%#*}"
            entry="$(trim "$entry")"
            [[ "$entry" == *=* ]] || continue

            key="$(trim "${entry%%=*}")"
            value="$(config_value "$key" || true)"

            if [[ "$key" == *_PUBLISH_PORT ]]; then
                prefix="${key%_PUBLISH_PORT}"
                internal_key="${prefix}_PORT"
                internal_port="$(config_value "$internal_key" || true)"
                [ -n "$internal_port" ] || internal_port="$value"
                publish_port="$value"
                publish_host="$(config_value "${prefix}_PUBLISH_HOST" || true)"
                [ -n "$publish_host" ] || publish_host="$host"
                map="${publish_host}:${publish_port}:${internal_port}"
                add_unique "$map" ports
                [ -n "$first_port" ] || first_port="$internal_port"
                continue
            fi

            if [[ "$key" == "PORT" || ( "$key" == *_PORT && "$key" != *_PUBLISH_PORT ) ]]; then
                [ -n "$first_port" ] || first_port="$value"
                continue
            fi

            if [[ "$key" == *_CAPABILITIES ]]; then
                IFS=',' read -ra items <<< "$value"
                for item in "${items[@]}"; do add_unique "$(trim "$item")" caps; done
                continue
            fi

            if [[ "$key" == *_DEVICES ]]; then
                IFS=',' read -ra items <<< "$value"
                for item in "${items[@]}"; do add_unique "$(trim "$item")" devices; done
                continue
            fi

            if [[ "$key" == *_VOLUMES ]]; then
                IFS=',' read -ra items <<< "$value"
                for item in "${items[@]}"; do
                    item="$(trim "$item")"
                    source="${item%%:*}"
                    item="$(normalize_volume_item "$item")"
                    add_unique "$item" volumes
                    if [[ "$source" != /* && "$source" != .* && "$source" != *"/"* ]]; then
                        add_unique "$source" named_volumes
                    fi
                done
                continue
            fi
        done < "$source_file"
    done < <(config_source_files)

    add_repo_sot_file_mounts

    if [ "${#ports[@]}" -eq 0 ] && [ -n "$first_port" ]; then
        add_unique "${host}:${first_port}:${first_port}" ports
    fi

    if [ -z "$first_port" ] && [ ! -f "$DIR/webui.py" ]; then
        return 0
    fi
    if [ -z "$first_port" ]; then
        echo "  No PORT or *_PORT found; skipping docker-compose.yml and $CONTAINER_NAME.container"
        return 0
    fi

    {
        printf '# Generated by config.sh for %s\n' "$PROJECT_NAME"
        printf '# Edit config.conf, then run ./config.sh again.\n'
        printf '# Usage: docker compose up -d\n\n'
        printf 'services:\n'
        printf '  %s:\n' "$CONTAINER_NAME"
        if [ -f "$DIR/Containerfile" ] || [ -f "$DIR/Dockerfile" ]; then
            printf '    # Local build context detected by config.sh\n'
            printf '    build:\n'
            printf '      context: .\n'
            [ -f "$DIR/Containerfile" ] && printf '      dockerfile: Containerfile\n'
            [ ! -f "$DIR/Containerfile" ] && [ -f "$DIR/Dockerfile" ] && printf '      dockerfile: Dockerfile\n'
        fi
        printf '    # Container image from config or existing generated file\n'
        printf '    image: %s\n' "$image"
        printf '    labels:\n'
        printf '      - "io.containers.autoupdate=registry"\n'
        printf '    container_name: %s\n' "$CONTAINER_NAME"
        printf '    hostname: %s\n' "$CONTAINER_NAME"
        if [ "${#ports[@]}" -gt 0 ]; then
            printf '    # Port mappings: publish host:PUBLISH_PORT:PORT from config.conf/container.conf\n'
            printf '    ports:\n'
            for item in "${ports[@]}"; do printf '      - "%s"\n' "$item"; done
        fi
        if [ -f "$DIR/config.conf" ] || [ -f "$DIR/container.conf" ] || [ -f "$DIR/.env" ]; then
            printf '    # Runtime configuration files generated from *example files\n'
            printf '    env_file:\n'
            [ -f "$DIR/config.conf" ] && printf '      - %s\n' "$DIR/config.conf"
            [ -f "$DIR/container.conf" ] && printf '      - %s\n' "$DIR/container.conf"
            [ -f "$DIR/.env" ] && printf '      - %s\n' "$DIR/.env"
        fi
        if [ -f "$DIR/webui.py" ]; then
            printf '    # Container-internal bind address; published host is controlled by config\n'
            printf '    command: uvicorn webui:app --host %s --port %s\n' "$command_host" "$first_port"
        fi
        if [ "${#volumes[@]}" -gt 0 ]; then
            printf '    # Bind mounts and named volumes from runtime config\n'
            printf '    volumes:\n'
            for item in "${volumes[@]}"; do printf '      - %s\n' "$item"; done
        fi
        if [ "${#caps[@]}" -gt 0 ]; then
            printf '    # Linux capabilities from *_CAPABILITIES in config.conf\n'
            printf '    cap_add:\n'
            for item in "${caps[@]}"; do printf '      - %s\n' "$item"; done
        fi
        if [ "${#devices[@]}" -gt 0 ]; then
            printf '    # Device mappings from *_DEVICES in config.conf\n'
            printf '    devices:\n'
            for item in "${devices[@]}"; do printf '      - %s\n' "$item"; done
        fi
        printf '    restart: always\n'
        if [ "${#named_volumes[@]}" -gt 0 ]; then
            printf '\n# Named volumes derived from *_VOLUMES sources\n'
            printf '\nvolumes:\n'
            for item in "${named_volumes[@]}"; do printf '  %s: {}\n' "$item"; done
        fi
    } > "$compose_file"
    echo "  Written: $compose_file"

    {
        printf '# Generated by config.sh for %s\n' "$PROJECT_NAME"
        printf '# Edit config.conf, then run ./config.sh again.\n'
        printf '\n'
        printf '[Container]\n'
        printf 'ContainerName=%s\n' "$CONTAINER_NAME"
        printf '# Container image from config or existing generated file\n'
        printf 'Image=%s\n' "$image"
        if [ -f "$DIR/config.conf" ] || [ -f "$DIR/container.conf" ] || [ -f "$DIR/.env" ]; then
            printf '# Runtime configuration files generated from *example files\n'
        fi
        [ -f "$DIR/config.conf" ] && printf 'EnvironmentFile=%s\n' "$DIR/config.conf"
        [ -f "$DIR/container.conf" ] && printf 'EnvironmentFile=%s\n' "$DIR/container.conf"
        [ -f "$DIR/.env" ] && printf 'EnvironmentFile=%s\n' "$DIR/.env"
        [ "${#ports[@]}" -gt 0 ] && printf '# Port mappings: publish host:PUBLISH_PORT:PORT from config.conf/container.conf\n'
        for item in "${ports[@]}"; do printf 'PublishPort=%s\n' "$item"; done
        if [ -f "$DIR/webui.py" ]; then
            printf '# Container-internal bind address; published host is controlled by config\n'
            printf 'Exec=uvicorn webui:app --host %s --port %s\n' "$command_host" "$first_port"
        fi
        [ "${#volumes[@]}" -gt 0 ] && printf '# Bind mounts and named volumes from runtime config\n'
        for item in "${volumes[@]}"; do printf 'Volume=%s\n' "$item"; done
        [ "${#caps[@]}" -gt 0 ] && printf '# Linux capabilities from *_CAPABILITIES in config.conf\n'
        for item in "${caps[@]}"; do printf 'AddCapability=%s\n' "$item"; done
        [ "${#devices[@]}" -gt 0 ] && printf '# Device mappings from *_DEVICES in config.conf\n'
        for item in "${devices[@]}"; do printf 'AddDevice=%s\n' "$item"; done
        printf 'AutoUpdate=registry\n\n'
        printf '[Service]\n'
        printf 'Restart=always\n'
        printf 'TimeoutStartSec=30\n\n'
        printf '[Install]\n'
        printf 'WantedBy=default.target\n'
    } > "$quadlet_file"
    echo "  Written: $quadlet_file"
}

if [ ! -f "$DIR/env.example" ] && [ ! -f "$DIR/config.conf_example" ] && [ ! -f "$DIR/container.example" ]; then
    echo "No env.example, config.conf_example or container.example"
    exit 1
fi

echo ""
echo "  Configuring $PROJECT_NAME"

configure_from_example "$DIR/env.example" "$DIR/.env" ".env"
configure_from_example "$DIR/config.conf_example" "$DIR/config.conf" "config.conf"
if [ "$NO_CONTAINER" != "true" ]; then
    configure_from_example "$DIR/container.example" "$DIR/container.conf" "container.conf"
    generate_container_files
fi

echo ""
