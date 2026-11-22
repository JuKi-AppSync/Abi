#!/usr/bin/env bash
#
# Abiturplaner – Installer / Updater (Apache + PHP + SQLite, Debian/Raspberry Pi OS)
#
#   sudo bash install.sh            # einmalige Installation (fragt nach Ordner, Pfad, Domain, erstem Konto)
#   sudo bash install.sh update     # neueste ZIP-Datei von GitHub einspielen (läuft auch täglich per Cron)
#   sudo bash install.sh uninstall  # App entfernen (Daten bleiben; mit --purge auch Daten löschen)
#
# Die App wird NUR in den VirtualHost der gewählten Domain eingebunden (nicht global).
# Alle anderen Domains/Nextclouds auf diesem Apache bleiben unberührt.
#
# Einstellungen (optional als Umgebungsvariablen):
#   ABI_ZIP      Download-URL oder lokaler Pfad der ZIP-Datei
#   ABI_DOMAIN   Domain, unter der die App erreichbar ist  (Standard: kimpfler.selfhost.eu)
#   ABI_URLPATH  Adresspfad auf dieser Domain               (Standard: /abi)
#   ABI_WEBROOT  Zielordner der App-Dateien                 (Standard: /var/www/abiturplaner)
#   ABI_DATA_DIR Datenordner (Datenbank)                    (Standard: /var/lib/abiturplaner)
#   ABI_ADMIN    Name des ersten Kontos (zusammen mit ABI_PASSWORD ohne Rückfragen)
#
set -euo pipefail

CONF=/etc/abiturplaner.conf
SELF=/usr/local/sbin/abiturplaner-install
CONF_DIR=/etc/abiturplaner
SNIPPET=$CONF_DIR/apache.conf
BACKUP_DIR=$CONF_DIR/backup
MARK_BEGIN='# BEGIN abiturplaner (automatisch erzeugt)'
MARK_END='# END abiturplaner'

# gespeicherte Einstellungen früherer Installation laden (Umgebungsvariablen haben Vorrang)
_env_zip="${ABI_ZIP:-}"; _env_web="${ABI_WEBROOT:-}"; _env_url="${ABI_URLPATH:-}"; _env_data="${ABI_DATA_DIR:-}"; _env_dom="${ABI_DOMAIN:-}"
[ -f "$CONF" ] && . "$CONF"
ZIP_URL="${_env_zip:-${ZIP_URL:-https://github.com/JuKi-AppSync/Abi/raw/main/abiturplaner-web.zip}}"
WEBROOT="${_env_web:-${WEBROOT:-/var/www/abiturplaner}}"
URLPATH="${_env_url:-${URLPATH:-/abi}}"
DATA="${_env_data:-${DATA:-/var/lib/abiturplaner}}"
DOMAIN="${_env_dom:-${DOMAIN:-kimpfler.selfhost.eu}}"

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
FPM_SOCK=""

ask() { # ask VARNAME "Frage"  – nur interaktiv
	local cur="${!1}" in=""
	if [ -t 0 ] && [ -z "${ABI_ASSUME_DEFAULTS:-}" ]; then
		read -r -p "$2 [$cur]: " in || true
		[ -n "$in" ] && printf -v "$1" '%s' "$in"
	fi
	return 0
}

safe_settings() {
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
	[[ "$URLPATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "URL-Pfad enthält ungültige Zeichen: $URLPATH"
	[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Domain enthält ungültige Zeichen: $DOMAIN"
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
		systemctl restart apache2 2>/dev/null || apache2ctl graceful 2>/dev/null || true
		for s in $(systemctl list-units 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}'); do systemctl restart "$s" || true; done
	fi
	has_sqlite || die "PHP-Erweiterung pdo_sqlite fehlt (apt install php-sqlite3)"
	ok "PHP $(php -r 'echo PHP_VERSION;') mit SQLite"
}

# Wie führt Apache PHP aus? Bei PHP-FPM läuft der Code unter dem Benutzer des FPM-Pools (nicht unbedingt Apache-Benutzer).
detect_php_runtime() {
	command -v apache2ctl >/dev/null || return 0
	local mods ver sock f
	mods="$(apache2ctl -M 2>/dev/null || true)"
	if grep -q 'php_module' <<<"$mods"; then
		ok "PHP läuft als Apache-Modul (Benutzer: $WU)"
		return 0
	fi
	if grep -q 'proxy_fcgi_module' <<<"$mods"; then
		ver="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
		sock="/run/php/php${ver}-fpm.sock"
		if [ ! -S "$sock" ]; then sock="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)"; fi
		if [ -n "$sock" ] && [ -S "$sock" ]; then
			FPM_SOCK="$sock"
			for f in /etc/php/*/fpm/pool.d/*.conf; do
				[ -f "$f" ] || continue
				if grep -qF "$sock" "$f"; then
					local pu
					pu="$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$f")"
					[ -n "$pu" ] && WU="$pu"
					break
				fi
			done
			ok "PHP-FPM ($FPM_SOCK), Benutzer: $WU"
			return 0
		fi
	fi
	warn "PHP-Ausführung in Apache nicht eindeutig erkannt – der Test am Ende zeigt, ob es klappt."
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

# ---------------------------------------------------------------- Apache: nur der VirtualHost der Domain
# Ausgabe: "PORT|DATEI|ZEILE" (HTTPS/443 bevorzugt)
find_vhost() {
	local s res pick
	s="$(apache2ctl -S 2>/dev/null || true)"
	res="$(awk -v dom="$DOMAIN" '
		tolower($0) ~ /^ *port [0-9]+ namevhost / {
			port=$2; name=tolower($4); loc=$0
			sub(/.*\(/, "", loc); sub(/\).*/, "", loc)
			n=split(loc, a, ":"); line=a[n]; file=loc; sub(":" line "$", "", file)
			if (name==tolower(dom)) print port "|" file "|" line
			next
		}
		tolower($0) ~ /^ *alias / { if (port != "" && tolower($2)==tolower(dom)) print port "|" file "|" line }
	' <<<"$s")"
	pick="$(grep '^443|' <<<"$res" | head -n1 || true)"
	[ -n "$pick" ] || pick="$(head -n1 <<<"$res")"
	echo "$pick"
}

list_domains() {
	apache2ctl -S 2>/dev/null | awk 'tolower($0) ~ /^ *port [0-9]+ namevhost /{print "    " $4 " (Port " $2 ")"}' | sort -u || true
}

write_snippet() {
	mkdir -p "$CONF_DIR"
	local handler=""
	if [ -n "$FPM_SOCK" ]; then
		handler="	<FilesMatch \"\\.php\$\">
		SetHandler \"proxy:unix:${FPM_SOCK}|fcgi://localhost\"
	</FilesMatch>"
	fi
	cat > "$SNIPPET" <<EOF
# Automatisch erzeugt von abiturplaner install.sh – gilt nur im VirtualHost von ${DOMAIN}
Alias ${URLPATH} ${WEBROOT}
<Directory ${WEBROOT}>
	Options -Indexes -MultiViews
	AllowOverride None
	Require all granted
	DirectoryIndex index.html
	<FilesMatch "^README\.md\$">
		Require all denied
	</FilesMatch>
${handler}
</Directory>
<Directory ${WEBROOT}/tools>
	Require all denied
</Directory>
EOF
	chmod 644 "$SNIPPET"
}

apache_conf() {
	say "4/6  Apache einrichten (nur für $DOMAIN)"
	command -v apache2ctl >/dev/null || { warn "Apache (apache2ctl) nicht gefunden. Binde $SNIPPET manuell in deinen VirtualHost ein (siehe README)."; write_snippet; return 0; }

	local v port file line real end bak
	v="$(find_vhost)"
	if [ -z "$v" ]; then
		warn "Kein VirtualHost für '$DOMAIN' gefunden. Gefundene Domains:"
		list_domains
		die "Domain prüfen (ABI_DOMAIN=...) oder diese Zeile manuell in den richtigen <VirtualHost> setzen:  IncludeOptional $SNIPPET"
	fi
	write_snippet
	IFS='|' read -r port file line <<<"$v"
	real="$(readlink -f "$file")"
	[ "$port" = 443 ] || warn "Kein HTTPS-VirtualHost (443) für $DOMAIN gefunden – nutze Port $port. Passwörter wären unverschlüsselt!"
	ok "VirtualHost: $DOMAIN (Port $port) in $real"

	if grep -qF "$MARK_BEGIN" "$real"; then
		ok "Bereits eingebunden – nur Konfiguration aktualisiert."
	else
		end="$(awk -v s="$line" 'NR>=s && /<\/[Vv]irtual[Hh]ost>/ {print NR; exit}' "$real")"
		[ -n "$end" ] || die "Ende des VirtualHost-Blocks in $real nicht gefunden."
		mkdir -p "$BACKUP_DIR"
		bak="$BACKUP_DIR/$(basename "$real").$(date +%Y%m%d-%H%M%S).bak"
		cp -a "$real" "$bak"
		awk -v e="$end" -v b="$MARK_BEGIN" -v inc="IncludeOptional $SNIPPET" -v z="$MARK_END" \
			'NR==e {print "\t" b; print "\t" inc; print "\t" z} {print}' "$real" > "$TMP/vhost.new"
		cat "$TMP/vhost.new" > "$real"
		if ! apache2ctl configtest >/dev/null 2>&1; then
			cat "$bak" > "$real"
			die "Apache-Konfigurationstest fehlgeschlagen – Änderung zurückgenommen (Sicherung: $bak). Details:  apache2ctl configtest"
		fi
		ok "Eintrag in $real (Sicherung: $bak)"
	fi
	apache2ctl configtest >/dev/null 2>&1 || die "Apache-Konfigurationstest fehlgeschlagen:  apache2ctl configtest"
	reload_apache
	ok "https://$DOMAIN${URLPATH}/  ->  $WEBROOT"
}

check_http() {
	local out scheme port
	for scheme in https http; do
		port=443; [ "$scheme" = http ] && port=80
		out="$(curl -sk --max-time 8 --resolve "$DOMAIN:$port:127.0.0.1" "$scheme://$DOMAIN${URLPATH}/api.php?a=config" 2>/dev/null || true)"
		case "$out" in *'"register"'*) ok "api.php antwortet unter $scheme://$DOMAIN${URLPATH}/"; return 0 ;; esac
	done
	warn "Lokaler Test nicht erfolgreich. Bitte im Browser prüfen:  https://$DOMAIN${URLPATH}/api.php?a=config   ->   {\"register\":false}"
	warn "Wird stattdessen Quelltext angezeigt, führt Apache für diese Domain kein PHP aus (siehe README)."
}

write_conf_and_cron() {
	cat > "$CONF" <<EOF
ZIP_URL="$ZIP_URL"
WEBROOT="$WEBROOT"
URLPATH="$URLPATH"
DATA="$DATA"
DOMAIN="$DOMAIN"
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
	say "5/6  Erstes Konto (optional – Registrierung im Browser ist ohnehin offen)"
	if [ -n "$(abi list 2>/dev/null)" ]; then
		ok "Es existieren bereits Konten – übersprungen."
		return 0
	fi
	local name="${ABI_ADMIN:-}"
	if [ -z "$name" ]; then
		[ -t 0 ] || { warn "Kein Terminal: Konto später anlegen mit:  sudo -u $WU php $WEBROOT/tools/abi.php adduser NAME"; return 0; }
		read -r -p "Benutzername für dein Konto (leer lassen = später im Browser registrieren): " name
		[ -n "$name" ] || { ok "Übersprungen – Konten können sich selbst auf der Seite registrieren."; return 0; }
	fi
	abi adduser "$name"
}

do_install() {
	safe_settings
	say "Abiturplaner installieren"
	ask DOMAIN  "Domain, unter der die App erreichbar sein soll"
	ask URLPATH "Adresspfad auf dieser Domain (z. B. /abi)"
	ask WEBROOT "Zielordner der App-Dateien"
	safe_settings
	ensure_packages
	detect_php_runtime
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

Fertig. Öffne:  https://${DOMAIN}${URLPATH}/

Neue Version einspielen: ZIP auf GitHub ersetzen (gleicher Dateiname). Der Pi holt sie um 03:30 Uhr
oder sofort mit:  sudo abiturplaner-install update
Registrierung: Jeder kann sich auf der Seite selbst ein Konto anlegen.
  aus-/einschalten:  sudo -u $WU php $WEBROOT/tools/abi.php register off|on
Konten per Hand:   sudo -u $WU php $WEBROOT/tools/abi.php adduser NAME
EOF
}

do_update() {
	safe_settings
	[ -d "$DATA" ] || die "Keine Installation gefunden (Datenordner $DATA fehlt). Zuerst:  sudo bash $0"
	ensure_packages >/dev/null
	detect_php_runtime >/dev/null
	if deploy update; then
		abi init >/dev/null
		echo "Aktualisiert: $(date '+%F %T')"
	fi
}

do_uninstall() {
	safe_settings
	say "Abiturplaner entfernen"
	local f real
	# Eintrag aus dem VirtualHost entfernen (nur unsere markierten Zeilen)
	for f in $(grep -rlF "$MARK_BEGIN" /etc/apache2/sites-available/ 2>/dev/null || true); do
		real="$(readlink -f "$f")"
		sed -i '/# BEGIN abiturplaner/,/# END abiturplaner/d' "$real"
		ok "Eintrag entfernt aus $real"
	done
	# Reste einer älteren, globalen Einrichtung
	if command -v a2disconf >/dev/null; then a2disconf abiturplaner >/dev/null 2>&1 || true; fi
	rm -f /etc/apache2/conf-available/abiturplaner.conf /etc/cron.d/abiturplaner "$SELF"
	rm -rf "$CONF_DIR"
	if command -v apache2ctl >/dev/null; then
		apache2ctl configtest >/dev/null 2>&1 && reload_apache || warn "Apache-Konfigurationstest fehlgeschlagen – bitte prüfen:  apache2ctl configtest"
	fi
	if [ -f "$WEBROOT/api.php" ]; then find "$WEBROOT" -mindepth 1 -delete; rmdir "$WEBROOT" 2>/dev/null || true; fi
	ok "App, Apache-Eintrag und Cron-Jobs entfernt."
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
