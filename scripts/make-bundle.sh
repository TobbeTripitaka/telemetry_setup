#!/usr/bin/env bash
# Build ONE ready-to-run TELE bundle for one unit. Run this on YOUR computer
# (Mac or Linux), inside a checkout of the repository, never on the station.
#
#   scripts/make-bundle.sh --setup tele9.conf --deb PegasusHarvester.deb [--encrypt]
#
# The result is NAME.zip (or NAME.zip.gpg): the committed TELE code, your filled
# setup file, the Nanometrics package, a checksum list and a short technician
# note. The technician unzips it anywhere and runs:  sudo bash INSTALL.sh
#
# Written for the bash 3.2 that ships with macOS.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/make-bundle.sh --setup FILE --deb FILE [options]
  --setup FILE   filled setup file for this unit (see credentials.example.txt)
  --deb FILE     the authorized Nanometrics Harvester .deb
  --ref REF      Git revision to ship (default HEAD; only committed code is used)
  --name NAME    bundle/folder name (default: the station= value)
  --out DIR      where to write the result (default: current directory)
  --encrypt      also encrypt with a passphrase (gpg, AES-256); the plain zip is removed
  --dir-only     write the ready folder OUT/NAME instead of a zip, and allow
                 unfilled REPLACE_WITH values (they are listed); fill them in
                 OUT/NAME/setup.conf, then zip the folder
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SETUP='' DEB='' REF=HEAD NAME='' OUT=. ENCRYPT=no DIR_ONLY=no
while (($#)); do
    case "$1" in
        --setup|--deb|--ref|--name|--out)
            [[ $# -ge 2 ]] || die "Missing value for $1"
            case "$1" in
                --setup) SETUP=$2 ;; --deb) DEB=$2 ;; --ref) REF=$2 ;;
                --name) NAME=$2 ;; --out) OUT=$2 ;;
            esac
            shift 2 ;;
        --encrypt) ENCRYPT=yes; shift ;;
        --dir-only) DIR_ONLY=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
done
[[ -f $SETUP ]] || die '--setup FILE is required and must exist'
[[ -f $DEB ]] || die '--deb FILE is required and must exist'
abs_path() { (cd "$(dirname -- "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename -- "$1")"); }
SETUP=$(abs_path "$SETUP")
DEB=$(abs_path "$DEB")
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
# Always build from the repository this script belongs to, wherever it is run from.
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
git rev-parse --git-dir >/dev/null 2>&1 || die 'This script must live inside a checkout of the TELE repository'
cd "$(git rev-parse --show-toplevel)"

if command -v sha256sum >/dev/null; then
    sha256() { sha256sum "$@"; }
else
    sha256() { shasum -a 256 "$@"; }
fi

if [[ -z $NAME ]]; then
    NAME=$(sed -n 's/^station=//p' "$SETUP" | head -n 1 | tr -d '\r')
fi
[[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die 'Bundle name: use --name, or a valid station= in the setup file'
COMMIT=$(git rev-parse "$REF^{commit}") || die "Unknown Git revision: $REF"
if [[ $REF == HEAD && -n $(git status --porcelain --untracked-files=no) ]]; then
    echo 'NOTE: you have uncommitted changes; the bundle contains only COMMITTED code.' >&2
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
DIR="$STAGE/$NAME"
mkdir "$DIR"

# Code only: the old field logs and state in the repository are not shipped.
git archive --format=tar "$COMMIT" -- . ':!log' ':!state' | tar -x -C "$DIR"
printf '%s\n' "$COMMIT" >"$DIR/REVISION"

DEB_NAME=$(basename "$DEB")
cp "$DEB" "$DIR/$DEB_NAME"
DEB_SHA=$(sha256 "$DIR/$DEB_NAME")
DEB_SHA=${DEB_SHA%% *}

# The package name and checksum are written here, so they cannot be mistyped.
{
    grep -vE '^(HARVESTER_DEB|HARVESTER_SHA256|HARVESTER_URL)=' "$SETUP" || true
    printf 'HARVESTER_DEB=%s\nHARVESTER_SHA256=%s\n' "$DEB_NAME" "$DEB_SHA"
} >"$DIR/setup.conf"
chmod 600 "$DIR/setup.conf"

LEFT=$(grep -nE '^[^#]*REPLACE_WITH' "$DIR/setup.conf" | cut -d= -f1 || true)
if [[ -n $LEFT && $DIR_ONLY == no ]]; then
    printf 'Unfilled placeholders remain in %s (line: key):\n%s\n' "$SETUP" "$LEFT" >&2
    die 'Fill in every REPLACE_WITH value, or comment out optional lines with #'
fi

cat >"$DIR/README-TECHNICIAN.txt" <<EOF
TELE station installation: $NAME
=================================

This folder holds PASSWORDS (setup.conf). Do not email, upload or share it.

1. Put this whole folder on the Desktop (unzip it first if it is a .zip).
2. Plug the Pegasus recorder into USB and the computer into a network cable with
   internet access.
3. Open a terminal IN this folder (right-click the folder, "Open in Terminal"):

       sudo bash INSTALL.sh

   Enter the computer's password when asked. It runs by itself for about 10 to 30
   minutes and prints what it does. It does NOT switch on field operation or
   power the computer off.
4. If it stops with an ERROR, fix what it says and run the same command again.
   It is safe to repeat. If you cannot fix it, send the text of the ERROR line.
5. When it says "Installed TELE revision ...", restart the computer:

       sudo reboot

   The computer should log in by itself. Then run:

       sudo /opt/tele/current/tele.sh --check

   and send the output to the project lead. The installer also left a short
   report, INSTALL-REPORT.txt, in this folder (and /var/log/tele-install-report.txt):
   send it to the project lead as well. It says whether everything succeeded.
6. BIOS wake-up and the USB relay port are set on the computer itself; follow
   INSTALLATION.md in this folder ("Configure BIOS wake-up and shutdown behaviour"
   and "Choose and test the USB relay-control port").
7. Switch on field operation ONLY when the project lead says so:

       sudo bash INSTALL.sh --enable-field

8. When the installation has been accepted, delete this folder:

       sudo rm -rf <path of this folder>

Revision: $COMMIT
EOF

# Checksums of everything except the secrets and the package (the package is
# checked against HARVESTER_SHA256 instead).
(
    cd "$DIR"
    find . -type f ! -name setup.conf ! -name '*.deb' ! -name MANIFEST.sha256 | LC_ALL=C sort |
        while IFS= read -r file; do sha256 "$file"; done >MANIFEST.sha256
)

if [[ $DIR_ONLY == yes ]]; then
    TARGET="$OUT/$NAME"
    # Only ever replace a folder that an earlier run of this script made.
    if [[ -e $TARGET ]]; then
        [[ -f $TARGET/REVISION && -f $TARGET/MANIFEST.sha256 ]] ||
            die "$TARGET exists and is not a TELE bundle folder; move it away first"
        rm -rf -- "$TARGET"
    fi
    mv "$DIR" "$TARGET"
    echo
    echo "Folder:   $TARGET"
    echo "Revision: $COMMIT"
    echo "Harvester package: $DEB_NAME  sha256 $DEB_SHA"
    if [[ -n $LEFT ]]; then
        echo "Still to fill in $TARGET/setup.conf (line: key):"
        printf '  %s\n' $LEFT
    fi
    exit 0
fi

ZIP="$OUT/$NAME.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -qrX "$ZIP" "$NAME")
RESULT=$ZIP
if [[ $ENCRYPT == yes ]]; then
    command -v gpg >/dev/null || die 'gpg is not installed (macOS: brew install gnupg)'
    rm -f "$ZIP.gpg"
    gpg --symmetric --cipher-algo AES256 --output "$ZIP.gpg" "$ZIP"
    rm -f "$ZIP"
    RESULT=$ZIP.gpg
fi

echo
echo "Bundle:   $RESULT"
echo "Revision: $COMMIT"
echo "Harvester package: $DEB_NAME  sha256 $DEB_SHA"
if [[ $ENCRYPT == yes ]]; then
    echo "Send the passphrase by a DIFFERENT channel. The technician decrypts with:"
    echo "  gpg --decrypt $NAME.zip.gpg > $NAME.zip && unzip $NAME.zip"
else
    echo 'This zip contains passwords: send it only over a private channel (or use --encrypt).'
fi
