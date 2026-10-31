# Tailscale switch for Kobo

Turns Tailscale on a Kobo e-reader on or off from the Wi-Fi network it is
connected to:

- connected to a foreign network: `tailscale up`
- connected to a home network, or to no network: `tailscale down`

The KOReader plugin reacts only to KOReader's own network events (connected,
disconnecting, resume). There is no timer and no polling, so the battery is
only used while Tailscale itself is on. NickelMenu entries make the same
switch available without KOReader.

*Deutsche Anleitung weiter unten.*

## What is where

| In this repo | On the Kobo | Purpose |
|---|---|---|
| `adds/tailscale-switch/tailscale-switch.sh` | `/mnt/onboard/.adds/tailscale-switch/` | does the work: `up`, `down`, `auto`, `check`, `state`, `status` |
| `adds/tailscale-switch/config.sh.example` | same folder, as `config.sh` | settings, shared by the plugin and the script |
| `koreader/tailscale.koplugin/` | `/mnt/onboard/.adds/koreader/plugins/` | KOReader plugin: automatic switching, menu, settings |
| `adds/nm/tailscale` | `/mnt/onboard/.adds/nm/` | NickelMenu: on, off, by network, status, check |
| `spec/tailscale_test.lua` | not deployed | automated test of the plugin against the real script |
| `deploy.sh` | not deployed | copies the chosen parts over SSH or onto the USB drive |

## Requirements

- `tailscale` and `tailscaled` installed on the Kobo, with `tailscaled`
  running (or a start command for it entered in the plugin). One way to get
  there, used as the example here, is
  [videah/kobo-tailscale](https://github.com/videah/kobo-tailscale), which
  follows the udev approach from
  [this MobileRead thread](https://www.mobileread.com/forums/showthread.php?p=4173169).
- The node logged in once by hand, for example over SSH with
  `tailscale up --login-server=https://... --accept-routes`. The plugin
  repeats exactly that call afterwards with the values from `config.sh`.
- For the SSH way of installing: SSH access to the Kobo, for example
  KOReader's SSH server on port 2222. USB works without it.

## Installation

Three ways, all ending with the same files on the Kobo. Pick the parts you
want with `--koreader` (the plugin), `--nickelmenu` (the entries) or neither
for both. The switch script is always installed, both parts need it.

**Over SSH**, for example to KOReader's SSH server on port 2222:

```sh
./deploy.sh <kobo-ip>                 # both parts
./deploy.sh --koreader <kobo-ip>      # only the KOReader plugin
./deploy.sh --nickelmenu <kobo-ip>    # only the NickelMenu entries
```

**Over USB**: connect the Kobo, let it mount, and point the script at the
drive:

```sh
./deploy.sh --usb /run/media/$USER/KOBOeReader
./deploy.sh --nickelmenu --usb /Volumes/KOBOeReader     # macOS, menu only
```

**By hand**, no script at all: the `adds` folder in this repo mirrors the
hidden `.adds` folder on the Kobo's USB drive.

1. Copy `adds/tailscale-switch` into `.adds/` on the drive, so that
   `.adds/tailscale-switch/tailscale-switch.sh` exists.
2. For the KOReader plugin, copy `koreader/tailscale.koplugin` into
   `.adds/koreader/plugins/`.
3. For NickelMenu, copy `adds/nm/tailscale` into `.adds/nm/`.
4. Optionally copy `config.sh.example` to `config.sh` in the same folder and
   fill in your values; otherwise the plugin writes the file on first use.

Keep the files as they are: the script and the NickelMenu file need Unix
line endings, so do not open and save them with Notepad. On Windows, show
hidden folders to see `.adds`.

An existing `config.sh` is never overwritten by the script. Afterwards
restart KOReader; NickelMenu reads its folder when the menu opens. The
plugin's settings are under Menu > Network > Tailscale:

- **Tailscale**: on or off by hand. A long press on the menu entry toggles directly.
- **Switch by Wi-Fi network**: the automatic mode.
- **Home networks**: opens a list to tick: the connected network (once as the
  exact access point with its BSSID, once by name), every network KOReader
  has saved, and "Edit as text" for entries by hand. Nothing has to be typed,
  which matters for network names you cannot type on the device.
- **Login server** and **Flags for tailscale up**: the values from your
  usual `tailscale up` call.
- **Command to start tailscaled**: only needed when the daemon does not run anyway.
- **Show Tailscale status**: the output of `tailscale status`.

Everything is stored in `/mnt/onboard/.adds/tailscale-switch/config.sh`; the
file can also be edited by hand (see `config.sh.example`). Two actions are
available for gestures and profiles: "Toggle Tailscale" and "Tailscale: switch
by Wi-Fi network".

### Home network entries

`HOME_NETWORKS` is a comma separated list; an entry has one of three forms:

| Entry | Meaning |
|---|---|
| `Home` | any network with this name |
| `a1:b2:c3:d4:e5:f6` | this access point (BSSID), whatever its name |
| `Home@a1:b2:c3:d4:e5:f6` | this access point, only under this name |

The third form is what the list stores for "this access point", so another
router that happens to use the same name does not count as home. A mesh with
several access points has one BSSID per access point: tick each one while
connected to it, or choose "any network with this name".

## Without KOReader (NickelMenu)

`adds/nm/tailscale` adds five entries to Nickel's main menu: Tailscale on,
Tailscale off, Tailscale by network (decides from the current Wi-Fi, name and
BSSID come from `wpa_cli`), Tailscale status and Tailscale check network (shows
what "by network" would do). They use the same script and the same
`config.sh`. To have them in the reader as well, copy the lines and replace
`:main` with `:reader`.

## Interaction with udev hooks

Installers like the one above add udev rules that run `tailscale up`
whenever the Wi-Fi interface appears and `tailscale down` when it goes away.
Together with this plugin the end state is still right (the plugin decides
after the connection is up), but Tailscale is briefly on at home each time.
To make the hook itself decide by network, replace the contents of the
installer's `on-wlan-up.sh` with:

```sh
#!/bin/sh
# wait up to 30 s for the Wi-Fi association, then decide by network
for i in $(seq 1 30); do
    wpa_cli -i wlan0 status 2>/dev/null | grep -q '^wpa_state=COMPLETED' && break
    sleep 1
done
sh /mnt/onboard/.adds/tailscale-switch/tailscale-switch.sh auto
```

## Troubleshooting

- `/mnt/onboard/.adds/tailscale-switch/last.log` records every call with the
  output of `tailscale`.
- If `tailscale up` complains that `--reset` is required, the flags changed
  since the last call: run it once over SSH with `--reset` and the new flags.
- If the script cannot find `tailscale`, set `TAILSCALE_BIN='/path/to/tailscale'`
  in `config.sh`. Otherwise the PATH, `/usr/bin`, `/usr/local/bin`,
  `/opt/tailscale` and `/mnt/onboard/.adds/tailscale` are searched.

## Tests

```sh
luajit spec/tailscale_test.lua <folder with fake tailscale, pidof, pgrep, wpa_cli>
```

The test runs the plugin against the real script with a fake `tailscale`.

## License

MIT, see `LICENSE`.

---

# Deutsch

Schaltet Tailscale auf einem Kobo mit KOReader automatisch nach WLAN:
verbunden mit einem fremden WLAN `tailscale up`, verbunden mit einem Heimnetz
oder gar nicht verbunden `tailscale down`. Das KOReader-Plugin reagiert nur
auf die Netzwerk-Events von KOReader (verbunden, trennen, aufwachen). Es
läuft kein Timer und kein Polling, der Akku wird also nur belastet, wenn
Tailscale selbst an ist. Dazu gibt es Einträge für NickelMenu, damit es auch
ohne KOReader geht.

## Teile

| Datei | Ziel auf dem Kobo | Zweck |
|---|---|---|
| `adds/tailscale-switch/tailscale-switch.sh` | `/mnt/onboard/.adds/tailscale-switch/` | macht die Arbeit (`up`, `down`, `auto`, `check`, `state`, `status`) |
| `adds/tailscale-switch/config.sh.example` | gleicher Ordner, als `config.sh` | Einstellungen, von Plugin und Skript gemeinsam gelesen |
| `koreader/tailscale.koplugin/` | `/mnt/onboard/.adds/koreader/plugins/` | KOReader-Plugin: Automatik, Menü, Einstellungen |
| `adds/nm/tailscale` | `/mnt/onboard/.adds/nm/` | NickelMenu: an, aus, nach Netz, Status, Prüfen |
| `spec/tailscale_test.lua` | bleibt am Rechner | automatischer Test des Plugins gegen das echte Skript |
| `deploy.sh` | bleibt am Rechner | kopiert die gewählten Teile per SSH oder auf das USB-Laufwerk |

## Voraussetzungen

- `tailscale` und `tailscaled` sind auf dem Kobo installiert, `tailscaled`
  läuft (oder du trägst im Plugin einen Startbefehl dafür ein). Ein Weg
  dorthin, hier nur als Beispiel genannt, ist
  [videah/kobo-tailscale](https://github.com/videah/kobo-tailscale).
- Der Knoten ist einmal von Hand angemeldet worden, zum Beispiel per SSH mit
  `tailscale up --login-server=https://... --accept-routes`. Das Plugin
  wiederholt danach genau diesen Aufruf mit den Werten aus `config.sh`.

## Installation

Drei Wege, am Ende liegen immer dieselben Dateien auf dem Kobo. Die Teile
wählst du mit `--koreader` (das Plugin), `--nickelmenu` (die Einträge) oder
ohne Angabe für beides. Das Schalter-Skript wird immer installiert, beide
Teile brauchen es.

**Per SSH**, zum Beispiel zu KOReaders SSH-Server auf Port 2222:

```sh
./deploy.sh <kobo-ip>                 # beides
./deploy.sh --koreader <kobo-ip>      # nur das KOReader-Plugin
./deploy.sh --nickelmenu <kobo-ip>    # nur die NickelMenu-Einträge
```

**Per USB**: Kobo anstecken, einhängen lassen, dem Skript das Laufwerk nennen:

```sh
./deploy.sh --usb /run/media/$USER/KOBOeReader
./deploy.sh --nickelmenu --usb /Volumes/KOBOeReader     # macOS, nur das Menü
```

**Von Hand**, ganz ohne Skript: der Ordner `adds` hier entspricht dem
versteckten Ordner `.adds` auf dem USB-Laufwerk des Kobo.

1. `adds/tailscale-switch` nach `.adds/` auf dem Laufwerk kopieren, sodass
   `.adds/tailscale-switch/tailscale-switch.sh` existiert.
2. Für das KOReader-Plugin `koreader/tailscale.koplugin` nach
   `.adds/koreader/plugins/` kopieren.
3. Für NickelMenu `adds/nm/tailscale` nach `.adds/nm/` kopieren.
4. Optional `config.sh.example` im selben Ordner zu `config.sh` kopieren und
   die Werte eintragen; sonst schreibt das Plugin die Datei beim ersten Mal.

Die Dateien unverändert lassen: Skript und NickelMenu-Datei brauchen
Unix-Zeilenenden, also nicht mit Notepad öffnen und speichern. Unter Windows
versteckte Ordner einblenden, sonst ist `.adds` unsichtbar.

Eine vorhandene `config.sh` überschreibt das Skript nie. Danach KOReader neu
starten; NickelMenu liest seinen Ordner beim Öffnen des Menüs. Die
Einstellungen des Plugins stehen unter Menü > Netzwerk > Tailscale:

- **Tailscale**: an oder aus von Hand (langer Druck auf den Menüpunkt schaltet direkt).
- **Switch by Wi-Fi network**: die Automatik.
- **Home networks**: öffnet eine Liste zum Anhaken: das gerade verbundene
  WLAN (einmal als genauer Access Point mit BSSID, einmal als Name), alle in
  KOReader gespeicherten WLANs, und zuletzt "Edit as text" für Einträge von
  Hand. Nichts muss getippt werden, auch bei Namen mit Sonderzeichen nicht.
- **Login server** und **Flags for tailscale up**: die Werte deines bisherigen
  `tailscale up`-Aufrufs.
- **Command to start tailscaled**: nur nötig, wenn der Daemon nicht ohnehin läuft.
- **Show Tailscale status**: die Ausgabe von `tailscale status`.

Alles landet in `/mnt/onboard/.adds/tailscale-switch/config.sh`, die Datei
kann auch von Hand bearbeitet werden (siehe `config.sh.example`). Für Gesten
oder Profile gibt es die Aktionen "Toggle Tailscale" und "Tailscale: switch by
Wi-Fi network".

### Heimnetz-Einträge

`HOME_NETWORKS` ist eine Liste mit Komma, jeder Eintrag hat eine von drei Formen:

| Eintrag | Bedeutung |
|---|---|
| `Zuhause` | jedes WLAN mit diesem Namen |
| `a1:b2:c3:d4:e5:f6` | dieser Access Point (BSSID), egal unter welchem Namen |
| `Zuhause@a1:b2:c3:d4:e5:f6` | nur dieser Access Point unter diesem Namen |

Die dritte Form ist das, was die Liste beim Anhaken des verbundenen WLANs als
"this access point" speichert. Damit zählt eine fremde Fritzbox mit zufällig
gleichem Namen nicht als Heimnetz. Bei einem Mesh mit mehreren Access Points
hat jeder eine eigene BSSID: dann entweder jeden einmal anhaken, wenn man mit
ihm verbunden ist, oder "any network with this name" wählen.

## Ohne KOReader (NickelMenu)

`adds/nm/tailscale` legt im Hauptmenü von Nickel fünf Einträge an:
Tailscale on, Tailscale off, Tailscale by network (entscheidet nach dem
aktuellen WLAN, Name und BSSID kommen von `wpa_cli`), Tailscale status und
Tailscale check network (zeigt, was "by network" tun würde). Sie nutzen
dasselbe Skript und dieselbe `config.sh`. Soll das auch im Lesemodus
erscheinen, die Zeilen kopieren und `:main` durch `:reader` ersetzen.

## Zusammenspiel mit udev-Hooks

Installer wie der oben genannte legen udev-Regeln an, die bei jedem
Erscheinen des WLAN-Interfaces `tailscale up` und beim Verschwinden
`tailscale down` ausführen. Zusammen mit dem Plugin stimmt der Endzustand
trotzdem (das Plugin entscheidet, sobald die Verbindung steht), aber zuhause
ist Tailscale jedes Mal kurz an. Soll der Hook selbst nach Netz entscheiden,
den Inhalt von `on-wlan-up.sh` des Installers durch das Skript aus dem
englischen Abschnitt "Interaction with udev hooks" ersetzen.

## Wenn etwas nicht klappt

- `/mnt/onboard/.adds/tailscale-switch/last.log` zeigt jeden Aufruf mit der
  Ausgabe von `tailscale`.
- Meldet `tailscale up`, dass `--reset` nötig sei, haben sich die Flags
  gegenüber dem letzten Aufruf geändert: einmal per SSH mit `--reset` und den
  neuen Flags aufrufen.
- Findet das Skript `tailscale` nicht, den Pfad in `config.sh` als
  `TAILSCALE_BIN='/pfad/zu/tailscale'` eintragen. Gesucht wird sonst im PATH
  sowie unter `/usr/bin`, `/usr/local/bin`, `/opt/tailscale` und
  `/mnt/onboard/.adds/tailscale`.

## Tests

```sh
luajit spec/tailscale_test.lua <ordner mit fake tailscale, pidof, pgrep, wpa_cli>
```

Der Test fährt das Plugin gegen das echte Skript mit einem Fake-`tailscale`.

## Lizenz

MIT, siehe `LICENSE`.
