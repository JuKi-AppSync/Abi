# Abiturplaner BW – Web-Version mit Login und Server-Speicherung

Statische Seite (HTML/JS/CSS) + kleines PHP-Backend (`api.php`, SQLite).

## Schnellinstallation (Apache, Raspberry Pi)

1. Lade `abiturplaner-web.zip` **und** `install.sh` ins GitHub-Repo hoch (Hauptverzeichnis, Repo öffentlich).
2. Auf dem Pi (einmalig):
   ```bash
   wget -O /tmp/install.sh https://github.com/JuKi-AppSync/Abi/raw/main/install.sh
   sudo bash /tmp/install.sh
   ```
   Das Skript fragt nach Zielordner, Adresspfad (Standard `/abi`) und deinem Benutzernamen und Passwort. Es installiert fehlende PHP-Pakete,
   legt Datenbank und Apache-Konfiguration an und richtet tägliche Sicherung (03:00) und Update aus GitHub (03:30) ein.
3. Öffnen: `https://DEINE-DOMAIN/abi/`

**Neue Version einspielen:** ZIP im Repo ersetzen (gleicher Dateiname). Der Pi holt sie nachts oder sofort mit `sudo abiturplaner-install update`.
Deine Noten und Konten liegen in `/var/lib/abiturplaner` und bleiben bei Updates unberührt.

Weitere Befehle: `sudo bash /tmp/install.sh uninstall` (Daten bleiben) bzw. `... uninstall --purge` (alles löschen).
Eine andere ZIP-Adresse: `sudo ABI_ZIP=https://... bash /tmp/install.sh`.

---

## Manuelle Einrichtung (statt Schnellinstallation)
Benutzer, Sitzungen und Noten liegen **außerhalb des Webroots** (Standard `/var/lib/abiturplaner`),
deshalb überschreibt dein täglicher Git-Updater niemals Daten.

## Voraussetzungen
- Webserver mit PHP (>= 8.0) für diese Domain (Apache mit PHP oder nginx mit PHP-FPM)
- PHP-Erweiterung `pdo_sqlite`:  `php -m | grep -i sqlite`  (sonst: `sudo apt install php-sqlite3`, danach PHP-FPM/Apache neu starten)
- HTTPS (Passwörter!) – ohne HTTPS nur im Heimnetz verwenden

## Einrichtung (einmalig, auf dem Pi)
```bash
# 1. Datenordner außerhalb des Webroots
sudo mkdir -p /var/lib/abiturplaner
sudo chown www-data:www-data /var/lib/abiturplaner
sudo chmod 750 /var/lib/abiturplaner

# 2. Datenbank und Konfiguration anlegen (im Ordner der Webseite, www-data = Benutzer des Webservers)
cd /PFAD/ZUR/WEBSEITE
sudo -u www-data php tools/abi.php init

# 3. Ersten Benutzer anlegen (Passwort wird abgefragt, mind. 10 Zeichen)
sudo -u www-data php tools/abi.php adduser DEIN_NAME
```
Test im Browser: `https://DEINE-DOMAIN/api.php?a=config` muss `{"register":false}` anzeigen.
Danach `https://DEINE-DOMAIN/` öffnen und anmelden.

## Weitere Benutzer
```bash
sudo -u www-data php tools/abi.php adduser freund1        # anlegen
sudo -u www-data php tools/abi.php passwd freund1         # Passwort zurücksetzen
sudo -u www-data php tools/abi.php deluser freund1        # Konto samt Daten löschen
sudo -u www-data php tools/abi.php list                   # alle Konten
```
**Selbstregistrierung (optional):** in `/var/lib/abiturplaner/config.php`
`'allow_register' => true` und `'invite_code' => 'GEHEIMER-CODE'` setzen. Wer den Code kennt, kann ein Konto anlegen.

## Sicherung
```bash
sudo -u www-data php tools/abi.php backup            # -> /var/lib/abiturplaner/backups (letzte 14 bleiben)
```
Täglich automatisch (`/etc/cron.d/abiturplaner`):
```
0 3 * * * www-data php /PFAD/ZUR/WEBSEITE/tools/abi.php backup
```
Kopiere die Sicherungen zusätzlich auf ein anderes Gerät.

## Webserver-Hinweise
- **nginx:** `tools/` sperren (Apache nutzt die mitgelieferte `.htaccess`; das Skript bricht über das Web ohnehin ab):
  ```
  location ^~ /tools/ { deny all; }
  ```
- **Hinter einem Reverse-Proxy:** in `config.php` `'trust_proxy' => true` setzen (nur dann!), sonst zählt die Fehlversuch-Sperre die Proxy-IP.
- Falls PHP `open_basedir` nutzt: `/var/lib/abiturplaner` freigeben.

## Sicherheit (Kurzfassung)
Passwörter als bcrypt/argon2-Hash, zufällige Sitzungs-Token (nur Hash gespeichert, HttpOnly-Cookie, SameSite=Lax, Secure bei HTTPS),
CSRF-Schutz per Pflicht-Header, Sperre nach 8 Fehlversuchen / 15 Minuten, Größenlimit 1 MB.
Der Server-Admin kann Noten technisch einsehen. Kein E-Mail-Reset: Passwörter setzt der Admin per `passwd` zurück.

## Update
Dateien ersetzen bzw. per Git-Updater holen – Daten bleiben erhalten (liegen in `/var/lib/abiturplaner`).
Bei Änderungen an der Datenstruktur migriert die App alte Daten automatisch.
