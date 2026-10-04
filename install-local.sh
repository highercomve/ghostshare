#!/usr/bin/env bash
# Build and install GhostShare for the current Linux user, without sudo.
set -euo pipefail

usage() {
    printf 'Usage: %s [--skip-build] [-D<zig build option>...]\n' "$0"
}

skip_build=false
build_flags=()
for argument in "$@"; do
    case "$argument" in
        --skip-build) skip_build=true ;;
        -D*) build_flags+=("$argument") ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

if [[ $(uname -s) != Linux ]]; then
    printf 'This installer requires Linux (.desktop launchers).\n' >&2
    exit 1
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd -- "$project_dir"
if ! "$skip_build"; then
    # The app's dependency points at the local Oriel checkout. Build directly
    # with Zig so an older CLI on PATH cannot select an outdated build flow.
    zig build -Doptimize=ReleaseSafe -Dnative_ui "${build_flags[@]}"
fi

source_binary="$project_dir/zig-out/bin/ghostshare"
if [[ ! -x "$source_binary" || ! -f "$project_dir/icon.png" ]]; then
    printf 'Missing GhostShare binary or icon. Run this script without --skip-build.\n' >&2
    exit 1
fi

app_id=dev.ghostshare.App
bin_dir="$HOME/.local/bin"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
desktop_dir="$data_dir/applications"
icon_dir="$data_dir/icons/hicolor/1024x1024/apps"
installed_binary="$bin_dir/ghostshare"
desktop_file="$desktop_dir/$app_id.desktop"
case "$installed_binary$data_dir" in
    *$'\n'*|*$'\r'*) printf 'Installation paths must not contain line breaks.\n' >&2; exit 1 ;;
esac

mkdir -p -- "$bin_dir" "$desktop_dir" "$icon_dir"
staging_dir=$(mktemp -d "$bin_dir/.ghostshare-install.XXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT
install -m 755 -- "$source_binary" "$staging_dir/ghostshare"
install -m 644 -- "$project_dir/icon.png" "$staging_dir/$app_id.png"

# Escape the Exec argument, then the desktop-entry string. Percent signs
# must be doubled so paths containing them are not interpreted as field codes.
exec_path=${installed_binary//\\/\\\\}
exec_path=${exec_path//\"/\\\"}
exec_path=${exec_path//\$/\\\$}
exec_path=${exec_path//\`/\\\`}
exec_path=${exec_path//%/%%}
exec_path=${exec_path//\\/\\\\}
try_exec_path=${installed_binary//\\/\\\\}
cat > "$staging_dir/$app_id.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=GhostShare
GenericName=Local File Sharing
Comment=Share files with computers and Android Quick Share
Exec="$exec_path"
TryExec=$try_exec_path
Icon=$app_id
Terminal=false
StartupNotify=true
StartupWMClass=$app_id
Categories=Network;FileTransfer;
Keywords=files;sharing;Quick Share;Android;LAN;
EOF
chmod 644 "$staging_dir/$app_id.desktop"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$staging_dir/$app_id.desktop"
fi
# Renaming the staged binary also permits updating a running installation.
mv -f -- "$staging_dir/ghostshare" "$installed_binary"
mv -f -- "$staging_dir/$app_id.png" "$icon_dir/$app_id.png"
mv -f -- "$staging_dir/$app_id.desktop" "$desktop_file"

# Replace launchers from the previous application name. Downloaded files
# and the user's configuration are preserved.
rm -f -- "$desktop_dir/dev.ghostfile.App.desktop" "$icon_dir/dev.ghostfile.App.png" "$bin_dir/ghostfile"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$desktop_dir" || printf 'Could not refresh the desktop database.\n' >&2
fi
if [[ -f "$data_dir/icons/hicolor/index.theme" ]] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -f "$data_dir/icons/hicolor" || printf 'Could not refresh the icon cache.\n' >&2
fi

printf 'Installed %s\nDesktop launcher: %s\n' "$installed_binary" "$desktop_file"
printf 'Open GhostShare from your application menu or run %s\n' "$installed_binary"
