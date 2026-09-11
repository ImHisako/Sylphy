#!/bin/sh
set -eu
umask 077
version='@VERSION@'
build='@BUILD@'
payload_sha='@SHA256@'
root="$HOME/.local/opt/sylphy"
mode=${1:-}

if [ "$mode" = '--launch-after-exit' ]; then
    case "${2:-}" in ''|*[!0-9]*) exit 2 ;; esac
    # Never kill an app with pending writes. The old process exits itself.
    tries=0
    while kill -0 "$2" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt 180 ] || exit 1
        sleep 1
    done
    exec "$root/current/sylphy"
fi
if [ "$mode" != '--install-only' ]; then
    printf 'Installare Sylphy %s per questo utente? [s/N] ' "$version"
    read -r answer
    case "$answer" in s|S|y|Y) ;; *) exit 0 ;; esac
fi
[ "$(uname -m)" = 'x86_64' ] || { echo 'Questo installer richiede Linux x86_64.' >&2; exit 1; }
mkdir -p "$root" "$HOME/.local/bin" "$HOME/.local/share/applications"
# flock releases the lock even if the installer is interrupted or killed.
exec 9>"$root/.install.lock"
flock -n 9 || { echo 'Un altro aggiornamento è in corso.' >&2; exit 1; }
stage=''
cleanup() {
    if [ -n "$stage" ] && [ -d "$stage" ]; then rm -rf -- "$stage"; fi
}
trap cleanup EXIT HUP INT TERM
stage=$(mktemp -d "$root/.staging.XXXXXX")
line=$(awk '/^__SYLPHY_PAYLOAD__$/ {print NR + 1; exit}' "$0")
[ -n "$line" ] || exit 1
tail -n +"$line" "$0" > "$stage/payload.tar.gz"
printf '%s  %s\n' "$payload_sha" "$stage/payload.tar.gz" | sha256sum -c - >/dev/null
mkdir "$stage/app"
tar -xzf "$stage/payload.tar.gz" -C "$stage/app" --no-same-owner
test -f "$stage/app/sylphy"
test -f "$stage/app/lib/libsylphy_core.so"
chmod 755 "$stage/app/sylphy"
# Check runtime libraries before changing the launch target.
if ldd "$stage/app/sylphy" | grep -q 'not found'; then
    echo 'Mancano librerie di sistema. Installa GTK 3 e libsecret e riprova.' >&2
    exit 1
fi
destination="$root/$version-$build"
# A fresh staging name avoids modifying a version still used by a running app.
if [ -e "$destination" ]; then destination="$destination-$(date +%s)-$$"; fi
mv "$stage/app" "$destination"
ln -s "$root/current/sylphy" "$stage/launcher"
# Desktop entry uses a stable launcher and never touches the app's data directory.
escaped_root=$(printf '%s' "$root" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/`/\\`/g' -e 's/\$/\\$/g' -e 's/%/%%/g')
printf '[Desktop Entry]\nType=Application\nName=Sylphy\nExec="%s/current/sylphy"\nTerminal=false\nCategories=Network;InstantMessaging;\n' "$escaped_root" > "$stage/sylphy.desktop"
mv -Tf "$stage/launcher" "$HOME/.local/bin/sylphy"
mv -f "$stage/sylphy.desktop" "$HOME/.local/share/applications/sylphy.desktop"
ln -s "$destination" "$stage/current"
mv -Tf "$stage/current" "$root/current"
printf 'Sylphy %s installato. Account e chat conservati.\n' "$version"
exit 0
__SYLPHY_PAYLOAD__
