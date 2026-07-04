#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQLITE_PERSISTENCE="$SCRIPT_DIR/sqlite_persistence.sh"
OPTIONAL_PERSISTENCE="$SCRIPT_DIR/optional_persistence.sh"
if [ -f "$SCRIPT_DIR/env.example" ] || [ -f "$SCRIPT_DIR/config.conf_example" ] || [ -f "$SCRIPT_DIR/container.example" ]; then
    DIR="$SCRIPT_DIR"
else
    DIR="$(pwd)"
fi

PROJECT_NAME="$(basename "$DIR")"
CONTAINER_NAME="${PROJECT_NAME,,}"
ENV_FILE="$DIR/.env"
CONFIG_FILE="$DIR/config.conf"
CONTAINER_FILE="$DIR/container.conf"
BUILD_FILE="$DIR/build.conf"
CONTAINER_NAME_MODE=false
CONFIG_SHOW=""
NO_CONTAINER=false

declare -A REPEAT_GROUP_MODES=()
declare -A REPEAT_GROUP_INDEXES=()

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

configure_container_name() {
    local example default_name="" value="${CONFIG_CONTAINER_NAME:-}"

    for example in "$DIR"/*example; do
        [ -f "$example" ] || continue
        grep -qx '#CONTAINER-NAME' "$example" || continue
        default_name="$(awk '
            $0 == "#CONTAINER-NAME" { active = 1; next }
            active && $0 ~ /^CONTAINER_NAME=/ { sub(/^[^=]*=/, ""); print; exit }
        ' "$example")"
        break
    done
    [ -n "$default_name" ] || return 0
    CONTAINER_NAME_MODE=true

    if [ -z "$value" ]; then
        if [ -t 0 ]; then
            read -rp "  Container name [$default_name]: " value
        fi
        value="${value:-$default_name}"
    fi
    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        echo "Invalid container name: $value" >&2
        exit 2
    fi

    CONTAINER_NAME="$value"
    export CONFIG_CONTAINER_NAME="$CONTAINER_NAME"
    ENV_FILE="$DIR/$CONTAINER_NAME.env"
    CONFIG_FILE="$DIR/${CONTAINER_NAME}_config.conf"
    CONTAINER_FILE="$DIR/${CONTAINER_NAME}_container.conf"
    BUILD_FILE="$DIR/${CONTAINER_NAME}_build.conf"
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
        read_kv_file "$CONTAINER_FILE" "$key" && return 0
    fi
    for file in "$CONFIG_FILE" "$ENV_FILE"; do
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
        return 1
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

initialize_sqlite_persistence() {
    [ -x "$SQLITE_PERSISTENCE" ] || return 0
    if find "$DIR/safrano9999" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
        "$SQLITE_PERSISTENCE" init --repo-root "$DIR/safrano9999" --config-dir "$DIR"
    else
        "$SQLITE_PERSISTENCE" init --repo "$DIR" --config-dir "$DIR"
    fi
}

add_sqlite_volume_mounts() {
    local item source
    [ -x "$SQLITE_PERSISTENCE" ] || return 0

    if find "$DIR/safrano9999" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
        while IFS= read -r item || [ -n "$item" ]; do
            [ -n "$item" ] || continue
            source="${item%%:*}"
            add_unique "$item" volumes
            add_unique "$source" named_volumes
        done < <("$SQLITE_PERSISTENCE" mounts --repo-root "$DIR/safrano9999" --config-dir "$DIR" --container "$CONTAINER_NAME")
    elif find "$DIR/safrano9999" -maxdepth 1 -type f -name '*-latest.zip' -print -quit 2>/dev/null | grep -q .; then
        while IFS= read -r item || [ -n "$item" ]; do
            [ -n "$item" ] || continue
            source="${item%%:*}"
            add_unique "$item" volumes
            add_unique "$source" named_volumes
        done < <("$SQLITE_PERSISTENCE" mounts --zip-root "$DIR/safrano9999" --config-dir "$DIR" --container "$CONTAINER_NAME")
    else
        while IFS= read -r item || [ -n "$item" ]; do
            [ -n "$item" ] || continue
            source="${item%%:*}"
            add_unique "$item" volumes
            add_unique "$source" named_volumes
        done < <("$SQLITE_PERSISTENCE" mounts --repo "$DIR" --config-dir "$DIR" --container "$CONTAINER_NAME")
    fi
}

add_optional_persistence_mounts() {
    local item source key path
    [ -x "$OPTIONAL_PERSISTENCE" ] || return 0
    while IFS= read -r item || [ -n "$item" ]; do
        [ -n "$item" ] || continue
        source="${item%%:*}"
        add_unique "$item" volumes
        add_unique "$source" named_volumes
    done < <("$OPTIONAL_PERSISTENCE" mounts --config-dir "$DIR" --container "$CONTAINER_NAME")
    while IFS=$'\t' read -r key path; do
        add_unique "$key=$path" persistent_envs
    done < <("$OPTIONAL_PERSISTENCE" entries --config-dir "$DIR")
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
    declare -A value_dupe_targets=()
    declare -A reverse_varname_sources=()
    declare -A repeat_group_styles=()
    declare -A repeat_group_fields=()
    declare -A repeat_key_groups=()
    declare -A repeat_optional_complete=()
    declare -A db_defaults=()
    declare -A db_seen_keys=()
    local -a db_config_keys=()
    local -a db_backend_keys=()
    local required_next=false
    local secret_next=false
    local directive condition condition_key condition_value target_key target_list secret
    local repeat_group repeat_style repeat_fields base_key repeat_choice repeat_index repeat_suffix
    local pending_value_dupe="" pending_reverse_varname="" value_dupe_target value_dupe_existing value_dupe_choice
    local pending_choices="" pending_when="" pending_when_not="" pending_default_rules=""
    local field_choices="" field_when="" field_when_not="" field_default_rules=""
    local generator_label choice
    local rule_key db_bulk_eligible=false db_bulk_decided=false

    while IFS= read -r line <&7; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        if [[ "$stripped" == \#repeat-optional-complete:* ]]; then
            directive="$(trim "${stripped#\#repeat-optional-complete:}")"
            for target_key in $directive; do
                [[ "$target_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
                repeat_optional_complete[$target_key]=1
            done
            continue
        fi
        [[ "$stripped" == \#repeat-group:* ]] || continue
        directive="$(trim "${stripped#\#repeat-group:}")"
        read -r repeat_group repeat_style repeat_fields <<< "$directive"
        [[ "$repeat_group" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [[ "$repeat_style" == "suffix" || "$repeat_style" == "suffix02" || "$repeat_style" == "infix" ]] || continue
        [ -n "$repeat_fields" ] || continue
        repeat_group_styles[$repeat_group]="$repeat_style"
        for target_key in $repeat_fields; do
            [[ "$target_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            repeat_key_groups[$target_key]="$repeat_group"
            repeat_group_fields[$repeat_group]="${repeat_group_fields[$repeat_group]:-} $target_key"
        done
    done 7< "$example"

    repeat_group_key() {
        local group="$1"
        local style="$2"
        local field="$3"
        local index="$4"

        if [ "$index" -eq 1 ]; then
            printf '%s\n' "$field"
        elif [ "$style" = "infix" ]; then
            printf '%s_%s_%s\n' "$group" "$index" "${field#${group}_}"
        elif [ "$style" = "suffix02" ]; then
            printf '%s_%02d\n' "$field" "$index"
        else
            printf '%s_%s\n' "$field" "$index"
        fi
    }

    prepare_repeat_group() {
        local group="$1"
        local style="${repeat_group_styles[$group]}"
        local fields="${repeat_group_fields[$group]}"
        local index field mapped value all complete=false slot_found=false next_index=1
        local mode default_mode

        [ -z "${REPEAT_GROUP_MODES[$group]+x}" ] || return 0

        for ((index = 1; index <= 50; index++)); do
            all=true
            for field in $fields; do
                mapped="$(repeat_group_key "$group" "$style" "$field" "$index")"
                value="$(read_kv_file "$target" "$mapped" || true)"
                case "${value,,}" in ""|blank|null) value="" ;; esac
                if [ -z "$value" ] && [[ -z "${repeat_optional_complete[$field]+x}" ]]; then
                    all=false
                fi
            done
            if [ "$all" = "true" ]; then
                complete=true
                continue
            fi
            next_index="$index"
            slot_found=true
            break
        done
        if [ "$slot_found" != "true" ]; then
            echo "    no free $group slot" >&2
            return 1
        fi

        mode="new"
        if [ "$complete" = "true" ]; then
            default_mode="skip"
            while :; do
                if [ -t 0 ]; then
                    read -r -p "    $group [skip/new] (default: $default_mode): " repeat_choice || true
                else
                    repeat_choice="$default_mode"
                fi
                repeat_choice="${repeat_choice:-$default_mode}"
                case "${repeat_choice,,}" in
                    skip|s|1) mode="skip"; break ;;
                    new|n|2) mode="new"; break ;;
                    *) echo "    choose skip or new" ;;
                esac
            done
        fi

        REPEAT_GROUP_MODES[$group]="$mode"
        REPEAT_GROUP_INDEXES[$group]="$next_index"
    }

    while IFS= read -r line <&5; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$stripped" || "$stripped" == \#* ]] && continue

        entry="${line%%#*}"
        entry="$(trim "$entry")"
        [[ "$entry" == *=* ]] || continue

        key="$(trim "${entry%%=*}")"
        default="$(trim "${entry#*=}")"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*_DB_(BACKEND|HOST|URL|PORT|NAME|USER|PW|PASSWORD|PREFIX)$ ]] || continue

        db_defaults[$key]="$default"
        if [[ -z "${db_seen_keys[$key]+x}" ]]; then
            db_seen_keys[$key]=1
            db_config_keys+=("$key")
            [[ "$key" == *_DB_BACKEND ]] && db_backend_keys+=("$key")
        fi
    done 5< "$example"

    while IFS= read -r line <&6; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        if [[ "$stripped" == \#valuedupe:* ]]; then
            pending_value_dupe="$(trim "${stripped#\#valuedupe:}")"
            [[ "$pending_value_dupe" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || pending_value_dupe=""
            continue
        fi
        if [[ "$stripped" == \#reverse-varname:* ]]; then
            pending_reverse_varname="$(trim "${stripped#\#reverse-varname:}")"
            [[ "$pending_reverse_varname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || pending_reverse_varname=""
            continue
        fi
        [[ -z "$stripped" || "$stripped" == \#* ]] && continue

        entry="${line%%#*}"
        entry="$(trim "$entry")"
        if [[ "$entry" == *=* && -n "$pending_value_dupe" ]]; then
            key="$(trim "${entry%%=*}")"
            if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                value_dupe_targets[$key]="$pending_value_dupe"
            fi
        fi
        if [[ "$entry" == *=* && -n "$pending_reverse_varname" ]]; then
            key="$(trim "${entry%%=*}")"
            if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                reverse_varname_sources[$key]="$pending_reverse_varname"
            fi
        fi
        pending_value_dupe=""
        pending_reverse_varname=""
    done 6< "$example"

    if [ "$target" = "$ENV_FILE" ] && [ "${#db_backend_keys[@]}" -gt 1 ]; then
        db_bulk_eligible=true
        for key in "${db_config_keys[@]}"; do
            if grep -q "^${key}=" "$target" 2>/dev/null; then
                db_bulk_eligible=false
                break
            fi
        done
    fi

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

    maybe_apply_value_dupe() {
        local source_key="$1"
        local source_value="$2"

        value_dupe_target="${value_dupe_targets[$source_key]:-}"
        [ -n "$value_dupe_target" ] || return 0
        [ -n "$source_value" ] || return 0

        value_dupe_existing="$(read_kv_file "$target" "$value_dupe_target" || true)"
        [ -z "$value_dupe_existing" ] || return 0

        value_dupe_choice="y"
        if [ -t 0 ]; then
            read -r -p "    Reuse $source_key value for $value_dupe_target? [Y/n]: " value_dupe_choice || true
            value_dupe_choice="${value_dupe_choice:-y}"
        fi
        case "${value_dupe_choice,,}" in
            y|yes)
                write_config_value "$target" "$value_dupe_target" "$source_value"
                echo "    $value_dupe_target= reused from $source_key"
                ;;
            n|no) ;;
            *)
                echo "    choose y or n" >&2
                return 1
                ;;
        esac
    }

    maybe_apply_reverse_varname() {
        local alias_base_key="$1" alias_name="$2"
        local source_base_key source_key source_value group index style

        [ "$target" = "$ENV_FILE" ] || return 0
        source_base_key="${reverse_varname_sources[$alias_base_key]:-}"
        [ -n "$source_base_key" ] || return 0
        [[ "$alias_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0

        source_key="$source_base_key"
        group="${repeat_key_groups[$alias_base_key]:-}"
        if [ -n "$group" ]; then
            index="${REPEAT_GROUP_INDEXES[$group]}"
            style="${repeat_group_styles[$group]}"
            source_key="$(repeat_group_key "$group" "$style" "$source_base_key" "$index")"
        fi
        source_value="$(read_kv_file "$target" "$source_key" || true)"
        [ -n "$source_value" ] || return 0
        write_config_value "$target" "$alias_name" "$source_value"
        echo "    $alias_name= injected from $source_key"
    }

    normalize_db_backend() {
        local value
        value="$(normalize_rule_value "$1")"
        case "$value" in
            postgres|postgresql|pgsql|psql) printf 'postgres\n' ;;
            mysql) printf 'mysql\n' ;;
            mariadb) printf 'mariadb\n' ;;
            sqlite|sqlite3) printf 'sqlite\n' ;;
            *) printf '%s\n' "$value" ;;
        esac
    }

    first_db_default() {
        local suffix="$1"
        local db_key

        for db_key in "${db_config_keys[@]}"; do
            [[ "$db_key" == *_DB_"$suffix" ]] || continue
            if [ -n "${db_defaults[$db_key]:-}" ]; then
                printf '%s\n' "${db_defaults[$db_key]}"
                return 0
            fi
        done
        return 1
    }

    read_bulk_db_value() {
        local prompt="$1"
        local preset="$2"
        local secret="${3:-false}"
        local input=""

        while [ -z "$input" ]; do
            if [ -t 0 ]; then
                if [ "$secret" = "true" ]; then
                    read -r -s -p "    $prompt: " input || true
                    echo "" >&2
                elif [ -n "$preset" ]; then
                    read -e -i "$preset" -r -p "    $prompt: " input || true
                else
                    read -r -p "    $prompt: " input || true
                fi
            else
                read -r input || true
                [ -n "$input" ] || input="$preset"
            fi
            [ -n "$input" ] || echo "    $prompt required" >&2
        done
        printf '%s\n' "$input"
    }

    apply_bulk_db_config() {
        local selected_backend="$1"
        local common_host common_port common_name common_user common_pw
        local db_key prefix suffix value default_name

        selected_backend="$(normalize_db_backend "$selected_backend")"
        if [ "$selected_backend" = "sqlite" ]; then
            for db_key in "${db_config_keys[@]}"; do
                if [[ "$db_key" == *_DB_BACKEND ]]; then
                    write_config_value "$target" "$db_key" "$selected_backend"
                else
                    write_config_value "$target" "$db_key" "blank"
                fi
            done
            echo "    ${#db_backend_keys[@]} backends configured as sqlite in ./sqlite"
            return 0
        fi

        common_host="$(first_db_default HOST || first_db_default URL || printf '127.0.0.1\n')"
        case "$selected_backend" in
            postgres) common_port="5432" ;;
            mysql|mariadb) common_port="3306" ;;
            *) common_port="$(first_db_default PORT || true)" ;;
        esac
        default_name="${CONTAINER_NAME//-/_}"

        common_host="$(read_bulk_db_value "DB host" "$common_host")"
        common_port="$(read_bulk_db_value "DB port" "$common_port")"
        common_name="$(read_bulk_db_value "DB name" "$default_name")"
        common_user="$(read_bulk_db_value "DB user" "$default_name")"
        common_pw="$(read_bulk_db_value "DB password" "" true)"

        for db_key in "${db_config_keys[@]}"; do
            prefix="${db_key%%_DB_*}"
            suffix="${db_key#${prefix}_DB_}"
            case "$suffix" in
                BACKEND) value="$selected_backend" ;;
                HOST|URL) value="$common_host" ;;
                PORT) value="$common_port" ;;
                NAME) value="$common_name" ;;
                USER) value="$common_user" ;;
                PW|PASSWORD) value="$common_pw" ;;
                PREFIX) value="${db_defaults[$db_key]:-${prefix,,}}" ;;
                *) continue ;;
            esac
            write_config_value "$target" "$db_key" "$value"
        done
        echo "    ${#db_backend_keys[@]} backends configured as $selected_backend"
    }

    maybe_apply_bulk_db_config() {
        local selected_backend="$1"
        local bulk_choice=""

        [ "$db_bulk_eligible" = "true" ] || return 1
        [ "$db_bulk_decided" = "false" ] || return 1
        selected_backend="$(normalize_db_backend "$selected_backend")"
        case "$selected_backend" in
            sqlite|postgres|mysql|mariadb) ;;
            *) return 1 ;;
        esac
        db_bulk_decided=true

        echo ""
        echo "    ${#db_backend_keys[@]} database backends found."
        echo "      (1) use $selected_backend for all [default]"
        echo "      (2) configure individually"
        while :; do
            if [ -t 0 ]; then
                read -r -p "    Choose [1/2] (default: 1): " bulk_choice || true
            else
                read -r bulk_choice || true
            fi
            bulk_choice="${bulk_choice:-1}"
            case "$bulk_choice" in
                1)
                    apply_bulk_db_config "$selected_backend"
                    return 0
                    ;;
                2)
                    return 1
                    ;;
                *) echo "    choose 1 or 2" ;;
            esac
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
        if [[ "$stripped" == \#choices:* ]]; then
            pending_choices="$(trim "${stripped#\#choices:}")"
            continue
        fi
        if [[ "$stripped" == \#when:* ]]; then
            pending_when="$(trim "${stripped#\#when:}")"
            continue
        fi
        if [[ "$stripped" == \#when-not:* ]]; then
            pending_when_not="$(trim "${stripped#\#when-not:}")"
            continue
        fi
        if [[ "$stripped" == \#default-if:* ]]; then
            pending_default_rules+="$(trim "${stripped#\#default-if:}")"$'\n'
            continue
        fi
        if [[ "$stripped" == \#required:* ]]; then
            required_next=true
            continue
        fi
        if [[ "$stripped" == "#secret" ]]; then
            secret_next=true
            continue
        fi
        if [[ -z "$stripped" ]]; then
            required_next=false
            secret_next=false
            pending_choices=""
            pending_when=""
            pending_when_not=""
            pending_default_rules=""
            continue
        fi
        if [[ "$stripped" == \#* ]]; then
            continue
        fi
        required="$required_next"
        secret="$secret_next"
        field_choices="$pending_choices"
        field_when="$pending_when"
        field_when_not="$pending_when_not"
        field_default_rules="$pending_default_rules"
        required_next=false
        secret_next=false
        pending_choices=""
        pending_when=""
        pending_when_not=""
        pending_default_rules=""

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
        while IFS= read -r directive || [ -n "$directive" ]; do
            [ -n "$directive" ] || continue
            condition="${directive%%[[:space:]]*}"
            value="$(trim "${directive#"$condition"}")"
            [[ "$condition" == *=* ]] || continue
            condition_key="${condition%%=*}"
            condition_value="$(normalize_rule_value "${condition#*=}")"
            existing="$(config_value "$condition_key" || true)"
            if [ "$(normalize_rule_value "$existing")" = "$condition_value" ]; then
                default="$value"
            fi
        done <<< "$field_default_rules"
        default="${default//\$\{CONTAINER_NAME\}/$CONTAINER_NAME}"

        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        base_key="$key"
        repeat_group="${repeat_key_groups[$base_key]:-}"
        if [ -n "$repeat_group" ]; then
            prepare_repeat_group "$repeat_group"
            [ "${REPEAT_GROUP_MODES[$repeat_group]}" = "new" ] || continue
            repeat_style="${repeat_group_styles[$repeat_group]}"
            repeat_index="${REPEAT_GROUP_INDEXES[$repeat_group]}"
            key="$(repeat_group_key "$repeat_group" "$repeat_style" "$base_key" "$repeat_index")"
            repeat_suffix=""
            [ "$repeat_index" -eq 1 ] || printf -v repeat_suffix '_%02d' "$repeat_index"
            default="${default//\$\{REPEAT_SUFFIX\}/$repeat_suffix}"
        fi
        if [[ -n "${seen_keys[$key]+x}" ]]; then
            echo "    duplicate $key in $(basename "$example")" >&2
            continue
        fi
        seen_keys[$key]=1

        if [ -n "$field_when" ]; then
            condition_key="${field_when%%=*}"
            condition_value="$(normalize_rule_value "${field_when#*=}")"
            existing="$(config_value "$condition_key" || true)"
            if [ "$(normalize_rule_value "$existing")" != "$condition_value" ]; then
                write_config_value "$target" "$key" "blank"
                echo "    $key= blank"
                continue
            fi
        fi
        if [ -n "$field_when_not" ]; then
            condition_key="${field_when_not%%=*}"
            condition_value="$(normalize_rule_value "${field_when_not#*=}")"
            existing="$(config_value "$condition_key" || true)"
            if [ "$(normalize_rule_value "$existing")" = "$condition_value" ]; then
                write_config_value "$target" "$key" "blank"
                echo "    $key= blank"
                continue
            fi
        fi

        if [[ -n "${skip_existing_keys[$key]+x}" ]]; then
            continue
        fi

        env_existing=""
        if [ "$target" = "$CONFIG_FILE" ]; then
            env_existing="$(read_kv_file "$ENV_FILE" "$key" || true)"
        elif [ "$target" = "$CONTAINER_FILE" ]; then
            env_existing="$(read_kv_file "$CONFIG_FILE" "$key" || read_kv_file "$ENV_FILE" "$key" || true)"
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
            maybe_apply_value_dupe "$key" "$env_existing"
            maybe_apply_reverse_varname "$base_key" "$env_existing"
            activate_blank_rules "$key" "$env_existing"
            continue
        fi
        if [ -n "$existing_line" ] && { [ "$required" != "true" ] || [ -n "$existing" ]; }; then
            if [ "$target" = "$ENV_FILE" ]; then
                echo "    $key= exists"
            else
                echo "    $key=$existing"
            fi
            maybe_apply_value_dupe "$key" "$existing"
            maybe_apply_reverse_varname "$base_key" "$existing"
            activate_blank_rules "$key" "$existing"
            continue
        fi
        sed -i "/^${key}=$/d" "$target" 2>/dev/null || true

        if [ -n "$env_existing" ]; then
            echo "$key=$env_existing" >> "$target"
            echo "    $key= migrated from .env"
            maybe_apply_value_dupe "$key" "$env_existing"
            maybe_apply_reverse_varname "$base_key" "$env_existing"
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
                            if [ "$secret" = "true" ]; then
                                read -r -s -p "    $key: " val || read_status=$?
                                echo "" >&2
                            else
                                read -r -p "    $key: " val || read_status=$?
                            fi
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
            elif [ -n "$field_choices" ]; then
                prompt_suffix="[$(printf '%s' "$field_choices" | tr ' ' '/')]"
            fi
            if [ "$secret" = "true" ] && [ -t 0 ]; then
                read -r -s -p "    $key ${prompt_suffix}: " val || read_status=$?
                echo "" >&2
            elif [ -n "$default" ] && [ -t 0 ]; then
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
            if [ -n "$field_choices" ]; then
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    val="$(printf '%s\n' $field_choices | sed -n "${val}p")"
                fi
                if ! printf '%s\n' $field_choices | grep -Fxq "$val"; then
                    echo "    choose one of: $field_choices"
                    val=""
                    continue
                fi
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
        if [[ "$key" == *_DB_BACKEND ]] && maybe_apply_bulk_db_config "$val"; then
            continue
        fi
        echo "$key=$val" >> "$target"
        maybe_apply_value_dupe "$key" "$val"
        maybe_apply_reverse_varname "$base_key" "$val"
        activate_blank_rules "$key" "$val"
    done 3< "$example"

    rewrite_config_with_comments "$example" "$target"
}

existing_image() {
    local quadlet="$DIR/$CONTAINER_NAME.container"
    local compose="$DIR/docker-compose.yml"
    $CONTAINER_NAME_MODE && compose="$DIR/$CONTAINER_NAME-compose.yml"

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
    if [ -f "$CONFIG_FILE" ]; then
        printf '%s\n' "$CONFIG_FILE"
    elif [ -f "$DIR/config.conf_example" ]; then
        printf '%s\n' "$DIR/config.conf_example"
    fi
    if [ "$NO_CONTAINER" != "true" ]; then
        if [ -f "$CONTAINER_FILE" ]; then
            printf '%s\n' "$CONTAINER_FILE"
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
    local -a persistent_envs=()
    local -a additional_lines=()
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
    $CONTAINER_NAME_MODE && compose_file="$DIR/$CONTAINER_NAME-compose.yml"
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

            if [[ "$key" =~ ^ADDITIONAL_LINE(_[0-9]+)?$ ]]; then
                case "${value,,}" in ""|blank|null) ;; *) add_unique "$value" additional_lines ;; esac
                continue
            fi

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
    add_sqlite_volume_mounts
    add_optional_persistence_mounts

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
        if [ -f "$CONFIG_FILE" ] || [ -f "$CONTAINER_FILE" ] || [ -f "$ENV_FILE" ] || [ -f "$BUILD_FILE" ]; then
            printf '    # Runtime configuration files generated from *example files\n'
            printf '    env_file:\n'
            [ -f "$CONFIG_FILE" ] && printf '      - %s\n' "$CONFIG_FILE"
            [ -f "$CONTAINER_FILE" ] && printf '      - %s\n' "$CONTAINER_FILE"
            [ -f "$BUILD_FILE" ] && printf '      - %s\n' "$BUILD_FILE"
            [ -f "$ENV_FILE" ] && printf '      - %s\n' "$ENV_FILE"
        fi
        if [ "${#persistent_envs[@]}" -gt 0 ]; then
            printf '    environment:\n'
            for item in "${persistent_envs[@]}"; do printf '      - "%s"\n' "$item"; done
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
        if [ -f "$CONFIG_FILE" ] || [ -f "$CONTAINER_FILE" ] || [ -f "$ENV_FILE" ] || [ -f "$BUILD_FILE" ]; then
            printf '# Runtime configuration files generated from *example files\n'
        fi
        [ -f "$CONFIG_FILE" ] && printf 'EnvironmentFile=%s\n' "$CONFIG_FILE"
        [ -f "$CONTAINER_FILE" ] && printf 'EnvironmentFile=%s\n' "$CONTAINER_FILE"
        [ -f "$BUILD_FILE" ] && printf 'EnvironmentFile=%s\n' "$BUILD_FILE"
        [ -f "$ENV_FILE" ] && printf 'EnvironmentFile=%s\n' "$ENV_FILE"
        for item in "${persistent_envs[@]}"; do printf 'Environment=%s\n' "$item"; done
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
        for item in "${additional_lines[@]}"; do printf '%s\n' "$item"; done
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

configure_container_name
if $CONTAINER_NAME_MODE; then
    touch "$CONFIG_FILE"
    write_config_value "$CONFIG_FILE" CONTAINER_NAME "$CONTAINER_NAME"
fi

for example in "$DIR"/*build.conf_example; do configure_from_example "$example" "$BUILD_FILE" "$(basename "$BUILD_FILE")"; done
for example in "$DIR"/env*example; do configure_from_example "$example" "$ENV_FILE" "$(basename "$ENV_FILE")"; done
for example in "$DIR"/config*example; do configure_from_example "$example" "$CONFIG_FILE" "$(basename "$CONFIG_FILE")"; done
if [ "$NO_CONTAINER" != "true" ]; then
    touch "$CONTAINER_FILE"
    for example in "$DIR"/container*example "$DIR"/config*.container; do configure_from_example "$example" "$CONTAINER_FILE" "$(basename "$CONTAINER_FILE")"; done
    initialize_sqlite_persistence
    generate_container_files
else
    initialize_sqlite_persistence
fi

echo ""
