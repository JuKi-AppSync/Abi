#!/usr/bin/env bash
#
# Abiturplaner – Installer / Updater (Apache + PHP + SQLite, Debian/Raspberry Pi OS)
#
#   sudo bash install.sh            # einmalige Installation (fragt nach Ordner, URL-Pfad, erstem Konto)
#   sudo bash install.sh update     # neueste ZIP-Datei von GitHub einspielen (läuft auch täglich per Cron)
#   sudo bash install.sh uninstall  # App entfernen (Daten bleiben; mit --purge auch Daten löschen)
#
# Einstellungen (optional als Umgebungsvariablen):
#   ABI_ZIP      Download-URL oder lokaler Pfad der ZIP-Datei
#   ABI_WEBROOT  Zielordner der Seite          (Standard: /var/www/abiturplaner)
#   ABI_URLPATH  Adresspfad auf deiner Domain  (Standard: /abi)
#   ABI_DATA_DIR Datenordner (Datenbank)       (Standard: /var/lib/abiturplaner)
#   ABI_ADMIN    Name des ersten Kontos (zusammen mit ABI_PASSWORD ohne Rückfragen)
#
set -euo pipefail

CONF=/etc/abiturplaner.conf
SELF=/usr/local/sbin/abiturplaner-install
# gespeicherte Einstellungen früherer Installation laden (Umgebungsvariablen haben Vorrang)
_env_zip="${ABI_ZIP:-}"; _env_web="${ABI_WEBROOT:-}"; _env_url="${ABI_URLPATH:-}"; _env_data="${ABI_DATA_DIR:-}"
[ -f "$CONF" ] && . "$CONF"
ZIP_URL="${_env_zip:-${ZIP_URL:-https://github.com/JuKi-AppSync/Abi/raw/main/abiturplaner-web.zip}}"
WEBROOT="${_env_web:-${WEBROOT:-/var/www/abiturplaner}}"
URLPATH="${_env_url:-${URLPATH:-/abi}}"
DATA="${_env_data:-${DATA:-/var/lib/abiturplaner}}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Bitte mit sudo ausführen:  sudo bash $0 ${1:-}"

web_user() {
	local u
	u="$(ps -eo user=,comm= 2>/dev/null | awk '$2 ~ /^(apache2|httpd)$/ && $1 != "root" {print $1; exit}')"
	if [ -z "$u" ]; then for u in www-data apache; do id "$u" >/dev/null 2>&1 && break; done; fi
	echo "${u:-www-data}"
}
WU="$(web_user)"

ask() { # ask VARNAME "Frage"  – nur interaktiv
	local cur="${!1}" in=""
	if [ -t 0 ] && [ -z "${ABI_ASSUME_DEFAULTS:-}" ]; then
		read -r -p "$2 [$cur]: " in || true
		[ -n "$in" ] && printf -v "$1" '%s' "$in"
	fi
	return 0
}

safe_webroot() {
	case "$WEBROOT" in
		/|/var|/var/www|/home|/root|/etc|/usr|/opt|"") die "Unsicherer Zielordner: '$WEBROOT'" ;;
		/*) ;;
		*) die "Zielordner muss ein absoluter Pfad sein" ;;
	esac
	case "$URLPATH" in
		/|"") die "URL-Pfad darf nicht '/' sein (Beispiel: /abi)" ;;
		/*) ;;
		*) die "URL-Pfad muss mit / beginnen (Beispiel: /abi)" ;;
	esac
}

has_sqlite() { # ohne Pipe, sonst bricht grep -q mit pipefail zufällig ab
	local m
	m="$(php -m 2>/dev/null)"
	grep -qi '^pdo_sqlite$' <<<"$m"
}

ensure_packages() {
	say "1/6  Pakete prüfen"
	local need=()
	command -v php   >/dev/null || need+=(php-cli)
	command -v unzip >/dev/null || need+=(unzip)
	command -v wget  >/dev/null || command -v curl >/dev/null || need+=(wget)
	if command -v php >/dev/null && ! has_sqlite; then need+=(php-sqlite3); fi
	if [ "${#need[@]}" -gt 0 ]; then
		warn "Installiere: ${need[*]}"
		apt-get update -qq
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
		systemctl restart apache2 2>/dev/null || true
		for s in $(systemctl list-units 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}'); do systemctl restart "$s" || true; done
	fi
	has_sqlite || die "PHP-Erweiterung pdo_sqlite fehlt (apt install php-sqlite3)"
	ok "PHP $(php -r 'echo PHP_VERSION;') mit SQLite, Webserver-Benutzer: $WU"
}

fetch_zip() {
	if [ -f "$ZIP_URL" ]; then
		cp "$ZIP_URL" "$TMP/app.zip"
	elif command -v wget >/dev/null; then
		wget -q -O "$TMP/app.zip" "$ZIP_URL" || die "Download fehlgeschlagen: $ZIP_URL (Repo öffentlich? Dateiname richtig?)"
	else
		curl -fsSL -o "$TMP/app.zip" "$ZIP_URL" || die "Download fehlgeschlagen: $ZIP_URL (Repo öffentlich? Dateiname richtig?)"
	fi
	unzip -tq "$TMP/app.zip" >/dev/null 2>&1 || die "Die heruntergeladene Datei ist keine gültige ZIP-Datei ($ZIP_URL)"
	local files
	files="$(unzip -Z1 "$TMP/app.zip")"
	grep -qx 'api.php' <<<"$files" || die "Die ZIP-Datei enthält keine api.php – falsche Datei?"
}

deploy() { # deploy install|update
	fetch_zip
	local new old=""
	new="$(sha256sum "$TMP/app.zip" | cut -d' ' -f1)"
	[ -f "$DATA/.zip.sha256" ] && old="$(cat "$DATA/.zip.sha256")"
	if [ "$1" = update ] && [ "$new" = "$old" ]; then
		echo "Keine Änderung seit der letzten Installation."
		return 1
	fi
	mkdir -p "$TMP/x" "$WEBROOT"
	unzip -q "$TMP/app.zip" -d "$TMP/x"
	# Sicherheitsnetz: nur leere oder bereits vom Abiturplaner belegte Ordner leeren
	if [ -n "$(ls -A "$WEBROOT")" ] && [ ! -f "$WEBROOT/api.php" ]; then
		die "$WEBROOT ist nicht leer und enthält keine Abiturplaner-Installation. Anderen Ordner wählen."
	fi
	find "$WEBROOT" -mindepth 1 -delete
	cp -a "$TMP/x/." "$WEBROOT/"
	chown -R "root:$WU" "$WEBROOT"
	find "$WEBROOT" -type d -exec chmod 755 {} +
	find "$WEBROOT" -type f -exec chmod 644 {} +
	echo "$new" > "$DATA/.zip.sha256"; chmod 600 "$DATA/.zip.sha256"
	return 0
}

setup_data() {
	mkdir -p "$DATA"
	chown "$WU:$WU" "$DATA"
	chmod 750 "$DATA"
}

abi() { runuser -u "$WU" -- env ABI_DATA_DIR="$DATA" php "$WEBROOT/tools/abi.php" "$@"; }

reload_apache() {
	systemctl reload apache2 2>/dev/null || apache2ctl graceful 2>/dev/null || warn "Apache konnte nicht neu geladen werden – bitte manuell: sudo systemctl reload apache2"
}

apache_conf() {
	say "4/6  Apache einrichten"
	if ! command -v a2enconf >/dev/null; then
		warn "Apache (a2enconf) nicht gefunden. Richte manuell ein:  Alias $URLPATH $WEBROOT  (siehe README)"
		return 0
	fi
	cat > /etc/apache2/conf-available/abiturplaner.conf <<EOF
# Automatisch erzeugt von abiturplaner install.sh
Alias ${URLPATH} ${WEBROOT}
<Directory ${WEBROOT}>
	Options -Indexes -MultiViews
	AllowOverride None
	Require all granted
	DirectoryIndex index.html
	<FilesMatch "^(README\.md)\$">
		Require all denied
	</FilesMatch>
</Directory>
<Directory ${WEBROOT}/tools>
	Require all denied
</Directory>
EOF
	a2enconf abiturplaner >/dev/null
	apache2ctl configtest >/dev/null 2>&1 || die "Apache-Konfigurationstest fehlgeschlagen:  apache2ctl configtest"
	reload_apache
	ok "Apache: ${URLPATH}  ->  ${WEBROOT}"
}

check_http() {
	local base out
	for base in "http://localhost" "https://localhost"; do
		out="$(curl -skL --max-time 8 "${base}${URLPATH}/api.php?a=config" 2>/dev/null || true)"
		case "$out" in *'"register"'*) ok "api.php antwortet ($base${URLPATH}/api.php)"; return 0 ;; esac
	done
	warn "Lokaler Test nicht möglich (evtl. nur über die Domain erreichbar). Bitte im Browser prüfen:"
	warn "https://DEINE-DOMAIN${URLPATH}/api.php?a=config   ->   {\"register\":false}"
	warn "Wird stattdessen Quelltext angezeigt, ist PHP für Apache nicht aktiv (siehe README)."
}

write_conf_and_cron() {
	cat > "$CONF" <<EOF
ZIP_URL="$ZIP_URL"
WEBROOT="$WEBROOT"
URLPATH="$URLPATH"
DATA="$DATA"
EOF
	chmod 644 "$CONF"
	cp "$0" "$SELF" 2>/dev/null && chmod 755 "$SELF" || true
	cat > /etc/cron.d/abiturplaner <<EOF
# Abiturplaner: Sicherung 03:00, Update aus GitHub 03:30
0 3 * * * $WU env ABI_DATA_DIR=$DATA php $WEBROOT/tools/abi.php backup >/dev/null 2>&1
30 3 * * * root $SELF update >/var/log/abiturplaner-update.log 2>&1
EOF
	chmod 644 /etc/cron.d/abiturplaner
	ok "Täglich 03:00 Sicherung, 03:30 Update aus GitHub (Log: /var/log/abiturplaner-update.log)"
}

create_admin() {
	say "5/6  Erstes Konto"
	if [ -n "$(abi list 2>/dev/null)" ]; then
		ok "Es existieren bereits Konten – übersprungen."
		return 0
	fi
	local name="${ABI_ADMIN:-}"
	if [ -z "$name" ]; then
		[ -t 0 ] || { warn "Kein Terminal: Konto später anlegen mit:  sudo -u $WU php $WEBROOT/tools/abi.php adduser NAME"; return 0; }
		read -r -p "Benutzername für dein Konto: " name
	fi
	abi adduser "$name"
}

do_install() {
	safe_webroot
	say "Abiturplaner installieren"
	ask WEBROOT "Zielordner der Seite"
	ask URLPATH "Adresspfad auf deiner Domain (z. B. /abi)"
	safe_webroot
	ensure_packages
	say "2/6  Dateien laden und installieren"
	setup_data
	deploy install
	ok "Dateien in $WEBROOT"
	say "3/6  Datenbank anlegen"
	abi init
	apache_conf
	create_admin
	say "6/6  Automatische Updates und Sicherungen"
	write_conf_and_cron
	say "Test"
	check_http
	cat <<EOF

Fertig. Öffne:  https://DEINE-DOMAIN${URLPATH}/

Neue Version einspielen: ZIP auf GitHub ersetzen (gleicher Dateiname). Der Pi holt sie um 03:30 Uhr
oder sofort mit:  sudo abiturplaner-install update
Weitere Konten:  sudo -u $WU php $WEBROOT/tools/abi.php adduser NAME
EOF
}

do_update() {
	safe_webroot
	[ -d "$DATA" ] || die "Keine Installation gefunden (Datenordner $DATA fehlt). Zuerst:  sudo bash $0"
	ensure_packages >/dev/null
	if deploy update; then
		abi init >/dev/null
		echo "Aktualisiert: $(date '+%F %T')"
	fi
}

do_uninstall() {
	safe_webroot
	say "Abiturplaner entfernen"
	if command -v a2disconf >/dev/null; then a2disconf abiturplaner >/dev/null 2>&1 || true; fi
	rm -f /etc/apache2/conf-available/abiturplaner.conf /etc/cron.d/abiturplaner "$SELF"
	reload_apache
	if [ -f "$WEBROOT/api.php" ]; then find "$WEBROOT" -mindepth 1 -delete; rmdir "$WEBROOT" 2>/dev/null || true; fi
	ok "App, Apache-Konfiguration und Cron-Jobs entfernt."
	if [ "${2:-}" = "--purge" ]; then
		rm -rf "$DATA" "$CONF"
		ok "Datenordner $DATA gelöscht."
	else
		warn "Noten und Konten bleiben erhalten in $DATA  (löschen: sudo bash $0 uninstall --purge)"
	fi
}

case "${1:-install}" in
	install)   do_install ;;
	update)    do_update ;;
	uninstall) do_uninstall "$@" ;;
	*) echo "Verwendung: sudo bash $0 [install|update|uninstall [--purge]]"; exit 1 ;;
esac
