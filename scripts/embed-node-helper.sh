#!/bin/bash
set -euo pipefail

brew_bin=/opt/homebrew/bin/brew
if [[ ! -x "$brew_bin" ]]; then
    echo "error: Homebrew is required at /opt/homebrew/bin/brew to embed Node."
    exit 1
fi

node_prefix="$("$brew_bin" --prefix node)"
source_node="$node_prefix/bin/node"
if [[ ! -x "$source_node" ]]; then
    echo "error: Node is required. Install it with: brew install node"
    exit 1
fi

helper_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
library_dir="$helper_dir/lib"
helper_path="$helper_dir/vibetalker-node"
resource_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
manifest="$DERIVED_FILE_DIR/vibetalker-node-dependencies"

rm -rf "$helper_dir"
mkdir -p "$library_dir"
cp -f "$source_node" "$helper_path"
chmod 755 "$helper_path"
/usr/bin/codesign --remove-signature "$helper_path" 2>/dev/null || true
cp -f /opt/homebrew/etc/openssl@3/openssl.cnf "$resource_dir/openssl.cnf"

: > "$manifest"
printf '%s\t%s\n' "$source_node" "$helper_path" >> "$manifest"

index=1
while true; do
    entry="$(sed -n "${index}p" "$manifest")"
    [[ -n "$entry" ]] || break

    source_binary="${entry%%	*}"
    bundled_binary="${entry#*	}"
    is_helper=false
    [[ "$bundled_binary" == "$helper_path" ]] && is_helper=true

    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        case "$dependency" in
            /System/*|/usr/lib/*)
                continue
                ;;
            @rpath/*)
                dependency_name="${dependency#@rpath/}"
                dependency_source="$(dirname "$source_binary")/$dependency_name"
                if [[ ! -f "$dependency_source" ]]; then
                    dependency_source="$node_prefix/lib/$dependency_name"
                fi
                ;;
            @loader_path/*)
                dependency_name="${dependency#@loader_path/}"
                dependency_source="$(dirname "$source_binary")/$dependency_name"
                ;;
            /*)
                dependency_source="$dependency"
                dependency_name="$(basename "$dependency")"
                ;;
            *)
                echo "error: Unsupported Node dependency path: $dependency"
                exit 1
                ;;
        esac

        if [[ ! -f "$dependency_source" ]]; then
            echo "error: Missing Node dependency: $dependency_source"
            exit 1
        fi

        dependency_destination="$library_dir/$dependency_name"
        if [[ ! -f "$dependency_destination" ]]; then
            cp -fL "$dependency_source" "$dependency_destination"
            chmod 755 "$dependency_destination"
            /usr/bin/codesign --remove-signature "$dependency_destination" 2>/dev/null || true
            printf '%s\t%s\n' "$dependency_source" "$dependency_destination" >> "$manifest"
        fi

        if $is_helper; then
            replacement="@loader_path/lib/$dependency_name"
        else
            replacement="@loader_path/$dependency_name"
        fi
        /usr/bin/install_name_tool -change "$dependency" "$replacement" "$bundled_binary"
    done < <(/usr/bin/otool -L "$source_binary" | tail -n +2 | awk '{print $1}')

    if ! $is_helper; then
        /usr/bin/install_name_tool -id "@rpath/$(basename "$bundled_binary")" "$bundled_binary"
    fi
    index=$((index + 1))
done

while IFS= read -r library; do
    /usr/bin/codesign \
        --force \
        --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
        --options runtime \
        "$library"
done < <(find "$library_dir" -type f -maxdepth 1 | sort)

/usr/bin/codesign \
    --force \
    --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$SRCROOT/VibeTalker/Resources/node-helper.entitlements" \
    "$helper_path"

library_count="$(find "$library_dir" -type f | wc -l | tr -d ' ')"
echo "Embedded Node $("$helper_path" --version) with $library_count libraries."
