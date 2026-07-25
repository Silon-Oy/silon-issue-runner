---
argument-hint: (ei argumentteja)
description: Hae origin/main-muutokset, aja tarvittavat buildit agenttisesti ja käynnistä dev-server taustalle vain jos ei jo käynnissä.
---

# /refresh

Geneerinen "tuo repo ajan tasalle ja varmista että dev pyörii" -komento. Sinä toimit
**päätöksentekijänä**: et aja valmista skriptiä, vaan etenet vaiheittain (PHASE 0..6),
ajat alla annetut bash-snippetit Bash-työkalulla ja tulkitset tulokset. Jokaisella
vaiheella on **STOP-ehtoja** — kun jokin täyttyy, raportoi syy ja lopeta heti, älä jatka
seuraavaan vaiheeseen.

Komento on repo-agnostinen: kaikki projektikohtainen tieto luetaan
`$REPO_ROOT/.claude/refresh.json`-konfigista (skeema dokumentoitu tämän tiedoston
lopussa). Jos konfigia ei ole, vaihe 0 päättelee järkevän fallbackin.

---

## PHASE 0 — Repo-juuri ja konfig

1. Selvitä repo-juuri. Jos ei git-repo → STOP.

   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
   if [ -z "$REPO_ROOT" ]; then echo "EI-GIT-REPO"; fi
   echo "REPO_ROOT=$REPO_ROOT"
   ```

   Jos tuloste on `EI-GIT-REPO` → raportoi "Ei git-repo — /refresh vaatii repon" ja **STOP**.

2. Lue konfig:

   ```bash
   cat "$REPO_ROOT/.claude/refresh.json" 2>/dev/null || echo "EI-KONFIGIA"
   ```

   - Jos JSON luettiin → se on **CONFIG**. Käytä sen `start`, `services`, `buildHints`.
   - Jos `EI-KONFIGIA` → **FALLBACK-tila**:
     - Lue `$REPO_ROOT/package.json` ja päättele `start`-komento `scripts`-lohkosta
       järjestyksessä `dev` → `start` → `serve` (ensimmäinen löytyvä voittaa).
     - Päättele package manager lockfilestä: `pnpm-lock.yaml` → `pnpm`,
       `yarn.lock` → `yarn`, `package-lock.json` → `npm`. Esim. `pnpm dev`.
     - Jos `package.json`:ssa ei ole yhtäkään noista skripteistä → raportoi
       "Ei refresh.json-konfigia eikä tunnistettavaa dev-skriptiä" ja **STOP**.
     - Fallback-tilassa ei ole `services`-tietoa → käytä detektiossa ja health-pollissa
       parasta arvausta (yleinen dev-portti, esim. 5173/3000) ja **varoita raportissa**
       että ajetaan ilman konfigia (savutesti 6).

---

## PHASE 1 — Likainen työpuu → STOP

Älä koskaan pullaa committaamattomien muutosten päälle.

```bash
# Salli työpuu, jonka AINOA muutos on .gitignore — refresh ylläpitää sitä itse
# (PHASE 3b), eikä komento saa pysähtyä omaan huoltoonsa.
NON_GITIGNORE_DIRTY=$(git -C "$REPO_ROOT" status --porcelain | grep -v '\.gitignore$' || true)
echo "NON_GITIGNORE_DIRTY=[$NON_GITIGNORE_DIRTY]"
```

Jos tuloste on **ei-tyhjä** → työpuussa on muita committaamattomia muutoksia kuin
`.gitignore`. Aja `git -C "$REPO_ROOT" status -sb`, näytä sen tuloste maintainerlle ja **STOP**
("Työpuu likainen — committaa tai stashaa ensin, en pullaa muutosten päälle"). Älä etene
PHASE 2:een. (Pelkkä `.gitignore`-muutos ei pysäytä — se kannetaan ff-pullin läpi ja
PHASE 3b täydentää sen.)

---

## PHASE 2 — Hae ja pullaa (ff-only)

```bash
BEFORE=$(git -C "$REPO_ROOT" rev-parse HEAD)
git -C "$REPO_ROOT" fetch origin
BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
BEHIND=$(git -C "$REPO_ROOT" rev-list --count "HEAD..origin/$BRANCH")
echo "BEFORE=$BEFORE BRANCH=$BRANCH BEHIND=$BEHIND"
```

- Jos `BEHIND == 0` → repo on jo ajan tasalla, **ei pull-diffiä eikä PHASE 3:n buildeja**.
  **Hyppää suoraan PHASE 3a:han** — pending-migraatiotarkistus ja gitignore-huolto (PHASE 3b)
  ajetaan silti aina, vaikka mitään ei pullattu.
- Muuten pullaa fast-forward-only:

  ```bash
  git -C "$REPO_ROOT" pull --ff-only origin "$BRANCH"
  ```

  - Jos pull **epäonnistuu** (esim. haarat ovat hajaantuneet / ff ei mahdollinen, tai
    paikallinen committaamaton `.gitignore`-muutos törmää originin `.gitignore`-muutokseen) →
    näytä virhe ja **STOP** ("Pull ei ff-only-onnistunut — selvitä manuaalisesti").
  - Onnistuessa:

    ```bash
    AFTER=$(git -C "$REPO_ROOT" rev-parse HEAD)
    echo "AFTER=$AFTER"
    ```

---

## PHASE 3 — Agenttinen build (vain jos pullattiin)

Selvitä mitkä tiedostot muuttuivat pullissa:

```bash
git -C "$REPO_ROOT" diff --name-only "$BEFORE..$AFTER"
```

Sovella CONFIG.buildHints + yleissäännöt **päätöspuuna** muuttuneeseen tiedostolistaan.
Aja kukin build vain kerran (älä toista `pnpm install`:ia jos useampi hint osuu siihen).
Aja komennot repo-juuressa, esim. `(cd "$REPO_ROOT" && pnpm install)`.

| Muuttui | Toimenpide |
|---|---|
| `pnpm-lock.yaml` | `pnpm install` |
| `apps/*/package.json` | `pnpm install` (jos ei jo ajettu lockfilen takia) |
| `prisma/schema.prisma` | `pnpm db:generate` (regeneroi Prisma Client) — aseta `SCHEMA_CHANGED=1` |
| vain `.ts` / `.tsx` (lähdekoodi) | ei buildia — dev-server (Vite/tsx watch) hoitaa hot-reloadin |

Fallback-tilassa (ei CONFIG) käytä vain yllä olevia yleissääntöjä.

> **Migraatioita ei sovelleta tässä vaiheessa.** Pull-diffissä näkyvä uusi
> `prisma/migrations/<...>/`-kansio **ei** enää laukaise `migrate deploy`ta täällä — se on
> väärä signaali (diff kertoo *tuliko* migraatio, ei *onko kanta ajan tasalla*). Migraatiot
> hoitaa **PHASE 3a**, joka tarkistaa kannan todellisen tilan ja ajaa `migrate deploy`n
> **kerran** riippumatta siitä näkyikö migraatio tämän ajon diffissä.

Raportoi **jokaisesta** ajetusta buildista mitä ajettiin ja **miksi** (mikä muuttunut
tiedosto laukaisi sen). Jos jokin build **failaa** → tulosta sen stderr ja **STOP**
(älä käynnistä dev-serveriä rikkinäisen riippuvuustilan päälle).

---

## PHASE 3a — Pending-migraatioiden tarkistus (ajetaan aina)

Diff kertoo vain *tuliko* migraatio tässä pullissa — ei sitä *onko paikallinen kanta ajan
tasalla*. Migraatio on voinut tulla repoon aiemmassa commitissa mutta jäädä soveltamatta
paikalliseen kantaan; jos `BEHIND == 0`, pull-diff ei näytä sitä lainkaan. Oikea kysymys on
**tila, ei tapahtuma**: onko kannassa kaikki migraatiot sovellettuna.

Tämä vaihe ajetaan siksi **aina** — myös kun `BEHIND == 0` (kuten PHASE 3b) — ja aina
**ennen PHASE 4:ää**. Se on migraatioiden **ainoa** soveltaja (PHASE 3 ei enää aja
`migrate deploy`ta), joten sama migraatio ei sovelleta kahdesti.

**Autodetektio (ei konfigimuutosta olemassa oleviin `refresh.json`-tiedostoihin):** aja
vaihe vain jos repo-juuressa on Prisma-skeema. Muuten **ohita hiljaa** — ei virhettä, ei
mainintaa raportissa.

```bash
if [ ! -f "$REPO_ROOT/prisma/schema.prisma" ]; then
  echo "PHASE-3a: ei prisma/schema.prisma — ohitetaan hiljaa"
else
  echo "PHASE-3a: prisma/schema.prisma löytyi — tarkistetaan migraatiotila"
fi
```

(Monorepo, jossa `prisma/`-kansio ei ole repo-juuressa → autodetektio ei osu; tämä on
hyväksytty rajaus, samoin kuin PHASE 3:n yleissäännöt olettavat juuritason lockfilet.)

Kun skeema löytyi, tarkista kannan tila. Aja **`migrate status`** repo-juuressa:

```bash
MIGRATE_STATUS=$(cd "$REPO_ROOT" && pnpm prisma migrate status --schema=./prisma/schema.prisma 2>&1)
MIGRATE_RC=$?
printf '%s\n' "$MIGRATE_STATUS"
echo "MIGRATE_RC=$MIGRATE_RC"
```

Tulkitse tuloste (päätöspuu — `migrate status` palauttaa rc≠0 sekä pending-migraatioista
että yhteysvirheestä, joten teksti ratkaisee):

- Tuloste sisältää **`Database schema is up to date`** → kanta on ajan tasalla, **ei
  toimenpiteitä**. Etene PHASE 3b:hen (`SCHEMA_CHANGED` jää asettamatta).
- Tuloste viittaa **yhteysvirheeseen** (kanta alhaalla — esim. `Can't reach database
  server`, `P1001`, `ECONNREFUSED`) → tulosta virhe, huomauta että **`pnpm db:up`**
  käynnistää PostgreSQL-kontin, ja **STOP**. Älä käynnistä dev-serveriä migratoimattoman
  kannan päälle (sama käytös kuin PHASE 3:n aiemmalla db-down-ohjeella).
- Muuten (**pending-migraatioita on** — esim. `Following migrations have not yet been
  applied`) → sovella ne, ks. alla.

### Migraatiot — `migrate deploy`, ei `migrate dev`

Migraatio on jo *luotu* originissa ja paikallisesti pitää vain *soveltaa* se. Aja
**`prisma migrate deploy`** — ei `pnpm db:migrate` (= `prisma migrate dev`). Ero on
kriittinen:

- `migrate deploy` soveltaa vain pending-migraatiot non-interaktiivisesti. Ei koskaan
  resetoi kantaa, ei kysy, ei luo uusia migraatioita. Tämä on automaattiajolle turvallinen.
- `migrate dev` on tarkoitettu migraatioiden *luomiseen* kehityksessä ja **voi resetoida
  kannan** jos se havaitsee driftin — destruktiivista automaattiajossa.

Aja `migrate deploy`, sitten `db:generate` (tässä järjestyksessä — `migrate deploy` **ei**
regeneroi Prisma Clientiä), ja aseta `SCHEMA_CHANGED=1`:

```bash
(cd "$REPO_ROOT" && pnpm prisma migrate deploy --schema=./prisma/schema.prisma) \
  && (cd "$REPO_ROOT" && pnpm db:generate)
SCHEMA_CHANGED=1
```

`SCHEMA_CHANGED=1` saa PHASE 4:n käynnistämään käynnissä olevan dev-serverin uudelleen
(PHASE 4b) — `tsx watch` ei seuraa `node_modules/.prisma/`-muutoksia, joten pelkkä
migraatio + generate ei riitä käynnissä olevalle prosessille. Jos `migrate deploy` tai
`db:generate` **failaa** → tulosta stderr ja **STOP** (älä käynnistä dev-serveriä
rikkinäisen kantatilan päälle).

---

## PHASE 3b — .gitignore-huolto (ajetaan aina)

Varmista että `/refresh`:n **omat artefaktit** on gitignorattu projektissa, jottei
henkilökohtainen konfig tai runtime-loki vahingossa päädy versionhallintaan. Tämä vaihe
ajetaan **aina** — myös kun `BEHIND == 0` — ja **ennen PHASE 5:tä**, koska PHASE 5
kirjoittaa lokin (`.claude/refresh-dev.log`); loki pitää olla ignorattu ennen kirjoitusta.

Huoltosäännöt:

- **`.claude/refresh-dev.log`** — runtime-loki, **aina** ignorattava.
- **`.claude/refresh.json`** — henkilökohtainen konfig. Ignoroi vain jos se on olemassa,
  **ei trackattu** ja ei jo ignorattu. Jos tiedosto on jo committattu (trackattu), maintainer on
  tietoisesti valinnut versioida sen → **älä taistele sitä vastaan**, jätä rauhaan.

Idempotentti — lisää rivi vain jos `git check-ignore` ei jo kata sitä, joten vakiotilassa
ei synny muutosta:

```bash
GITIGNORE="$REPO_ROOT/.gitignore"
GI_ADDED=""

ensure_ignored() {
  entry="$1"
  # Jo efektiivisesti ignorattu (mikä tahansa sääntö kattaa)? → ei toimenpidettä.
  git -C "$REPO_ROOT" check-ignore -q "$entry" 2>/dev/null && return 0
  # Literaalirivi jo olemassa? → ei duplikaattia.
  [ -f "$GITIGNORE" ] && grep -qxF "$entry" "$GITIGNORE" && return 0
  printf '%s\n' "$entry" >> "$GITIGNORE"
  GI_ADDED="$GI_ADDED $entry"
}

ensure_ignored ".claude/refresh-dev.log"

# refresh.json: vain jos olemassa eikä trackattu.
if [ -f "$REPO_ROOT/.claude/refresh.json" ] \
   && ! git -C "$REPO_ROOT" ls-files --error-unmatch .claude/refresh.json >/dev/null 2>&1; then
  ensure_ignored ".claude/refresh.json"
fi

echo "GI_ADDED=[$GI_ADDED]"
```

Jos `GI_ADDED` on ei-tyhjä → huomioi PHASE 6:n raportissa, että `.gitignore` sai uusia
rivejä ja ne kannattaa committaa. **Älä committaa automaattisesti.** (Seuraava ajo ei
pysähdy tähän, koska PHASE 1 sietää pelkkää `.gitignore`-muutosta.)

---

## PHASE 4 — Dev-serverin detektio

Tarkista kunkin CONFIG.services-palvelun osalta, kuunteleeko portti jo ja onko se
**tämän** repon prosessi. Skannaa portit `port .. port + portFallbackRange`.

```bash
# Esimerkki yhdelle portille; toista jokaiselle service/portille.
PORT=5173
PIDS=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null)
echo "PORT=$PORT PIDS=$PIDS"
for PID in $PIDS; do
  CMD=$(ps -p "$PID" -o command= 2>/dev/null)
  echo "PID=$PID CMD=$CMD"
done
```

Luokittele jokainen löydetty kuunteleva PID:

- **RUNNING_HERE** — prosessin cmdline (tai sen cwd) viittaa **tähän** repo-juureen.
  Matchaa `$REPO_ROOT` **polkurajalla** (esim. `grep -F "$REPO_ROOT/"` tai täsmälleen
  `$REPO_ROOT` jota seuraa `/` tai rivin loppu). **Varo matchaamasta worktree-alipolkuja**:
  jos cmdline sisältää `$REPO_ROOT/.claude/worktrees/...`, se on **toisen worktreen**
  prosessi, ei tämä → luokittele FOREIGN, älä RUNNING_HERE (A5).
- **FOREIGN** — portti on varattu mutta cmdline ei viittaa tähän repo-juureen (toinen
  projekti, toinen worktree, tai muu ohjelma).
- **FREE** — portti ei kuuntele (PIDS tyhjä).

Päätökset:

- Jos **kaikki `primaryUrl: true` -palvelut** ovat RUNNING_HERE:
  - **ja `SCHEMA_CHANGED` ei ole asetettu** → dev pyörii jo ajantasaisella koodilla. **STOP**
    ja raportoi primary-URL(t) (savutesti 3). Älä käynnistä toista instanssia.
  - **ja `SCHEMA_CHANGED=1`** → käynnissä oleva prosessi käyttää **vanhentunutta Prisma
    Clientiä** (`tsx watch` ei seuraa `node_modules/.prisma/`-muutoksia, joten pelkkä
    migraatio + generate ei riitä — prosessi pitää käynnistää uudelleen, muuten
    skeemariippuvaiset endpointit heittävät `PrismaClientValidationError`). **Etene
    PHASE 4b:hen** (uudelleenkäynnistys), älä pysähdy.
- Jos **API-palvelun** (ei-primary, portFallbackRange 0) portti on **FOREIGN** → **STOP**
  (C1: web-proxy osoittaa kiinteään API-porttiin; vieras prosessi siinä portissa
  rikkoisi proxyn ja antaisi hiljaa väärää dataa). Raportoi mikä PID/komento varaa portin.
- Jos **webin** primary-portti on FOREIGN mutta API on vapaa/oma → **varoita** että
  primary-portti on varattu ja Vite auto-inkrementoi seuraavaan vapaaseen porttiin, mutta
  **jatka** PHASE 5:een (luetaan todellinen URL lokista).
- Muuten (kaikki tarvittavat FREE) → etene PHASE 5:een normaalisti.

---

## PHASE 4b — Uudelleenkäynnistys (vain jos RUNNING_HERE **ja** SCHEMA_CHANGED)

Käynnissä oleva dev-server pitää pysäyttää ja käynnistää uudelleen, jotta se lataa
juuri regeneroidun Prisma Clientin. Pysäytä koko dev-prosessiryhmä (turbo + sen lapset
web/api), ei vain yhtä lehteä.

Kerää PHASE 4:n RUNNING_HERE-PID:t. Selvitä niiden uniikit prosessiryhmät (PGID) ja
lähetä koko ryhmälle ensin SIGTERM, odota porttien vapautumista, ja SIGKILL vasta jos
ei vapaudu:

```bash
# RUNNING_PIDS = PHASE 4:ssä tähän repoon luokitellut kuuntelevat PID:t (web + api).
PGIDS=$(for PID in $RUNNING_PIDS; do ps -o pgid= -p "$PID" 2>/dev/null; done | tr -d ' ' | sort -u)
echo "PGIDS=$PGIDS"

for PGID in $PGIDS; do kill -TERM -"$PGID" 2>/dev/null || true; done

# Odota max 10 s että portit vapautuvat (käytä PHASE 4:n portteja).
DEADLINE=$((SECONDS+10))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  STILL=$(lsof -nP -iTCP:5173 -iTCP:3001 -sTCP:LISTEN -t 2>/dev/null)
  [ -z "$STILL" ] && break
  sleep 1
done

# SIGKILL-fallback jos jokin yhä elossa.
for PGID in $PGIDS; do kill -KILL -"$PGID" 2>/dev/null || true; done
```

> **Huom:** jos dev-server oli käynnissä omassa terminaalissasi (ei aiemman `/refresh`:n
> taustaprosessina), tämä pysäyttää sen — se käynnistyy uudelleen **taustalle** (PHASE 5)
> eikä enää siihen terminaaliin. Raportoi tämä PHASE 6:ssa selvästi.

Kun portit ovat vapaat → etene PHASE 5:een (normaali taustakäynnistys + health-poll).

---

## PHASE 5 — Käynnistä dev-server taustalle

Käynnistä `start`-komento niin että se **jää eloon** työkalukutsun palatessa.

**Ensisijainen tapa — Bash-työkalun `run_in_background: true` -moodi.** Aja start-komento
Bash-työkalulla `run_in_background: true` -parametrilla ja ohjaa tuloste lokiin **komennon
sisällä**, jotta `.claude/refresh-dev.log` säilyy raportoitavana polkuna. Tämä on
alustariippumaton eikä nojaa util-linuxin `setsid`iin (jota macOS:ssä ei ole):

```bash
cd "$REPO_ROOT" && pnpm dev > "$REPO_ROOT/.claude/refresh-dev.log" 2>&1
```

(Korvaa `pnpm dev` CONFIG.start-arvolla. `run_in_background: true` pitää prosessin elossa
työkalukutsun palatessa; loki menee aina `$REPO_ROOT/.claude/refresh-dev.log`-tiedostoon.
Ota talteen työkalun palauttama taustatehtävän tunniste elossaolotarkistusta varten.)

**Etualan fallback** (jos et voi käyttää `run_in_background`-moodia). `setsid` **ei kuulu
macOS:n perusasennukseen** — älä käytä sitä ehdoitta (`command not found` → dev-server ei
käynnisty). Pelkkä `nohup … & disown` riittää macOS:llä; `setsid` lisätään vain
saatavuustarkistuksen takaa:

```bash
command -v setsid >/dev/null 2>&1 && SETSID=setsid || SETSID=""
cd "$REPO_ROOT" && $SETSID nohup pnpm dev > "$REPO_ROOT/.claude/refresh-dev.log" 2>&1 &
DEV_PID=$!
disown "$DEV_PID" 2>/dev/null || true
echo "DEV_PID=$DEV_PID LOG=$REPO_ROOT/.claude/refresh-dev.log"
```

**Elossaolotarkistus ennen health-pollia.** Käynnistys voi epäonnistua hiljaa: `&`-taustaan
ajettu rivi (tai `run_in_background`-tehtävä) "onnistuu" heti vaikka komento ei löytyisi, ja
vasta 45 s health-poll paljastaisi ettei mitään käynnistynyt. Tarkista siksi **ennen**
pollia että prosessi on elossa eikä loki sisällä käynnistysvirhettä — jos kuollut, tulosta
lokin häntä ja **STOP heti**, älä odota 45 s turhaan:

```bash
sleep 1
DEAD=0
# Etualan fallback: DEV_PID asetettu → tarkista prosessi. run_in_background-moodissa
# käytä sen sijaan työkalun palauttamaa taustatehtävän tilaa (completed/failed = kuollut).
if [ -n "$DEV_PID" ] && ! kill -0 "$DEV_PID" 2>/dev/null; then DEAD=1; fi
# Molemmissa moodeissa: käynnistysvirhe lokissa on varma kuolleen prosessin signaali.
if grep -qE 'command not found|Cannot find module|No such file|EADDRINUSE' \
     "$REPO_ROOT/.claude/refresh-dev.log" 2>/dev/null; then DEAD=1; fi
echo "DEAD=$DEAD"
```

Jos `DEAD=1` (tai `run_in_background`-tehtävä on jo päättynyt) → tulosta lokin häntä ja
**STOP**, älä etene health-polliin:

```bash
tail -40 "$REPO_ROOT/.claude/refresh-dev.log"
```

**Health-poll** — odota kunkin palvelun terveeksi tuloa enintään ~45 s, pollaten 1 s
välein. Käytä CONFIG.services[].healthPath:ia. Jos healthPath ei ole `/`, palvelu
tarjoaa varsinaisen healthcheck-endpointin → käytä `curl -fsS` (vaadi onnistunut
HTTP-status). Jos healthPath on `/`, riittää että **portti vastaa** mitä tahansa
(myös 404) → curl **ilman** `-f`-flagia, tarkista vain että yhteys aukeaa.

```bash
# Esimerkki: health-endpoint (healthPath != "/")
PORT=3001; HEALTHPATH="/health"; DEADLINE=$((SECONDS+45)); OK=0
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if curl -fsS "http://localhost:$PORT$HEALTHPATH" >/dev/null 2>&1; then OK=1; break; fi
  sleep 1
done
echo "api OK=$OK"

# Esimerkki: pelkkä portti vastaa (healthPath == "/")
PORT=5173; DEADLINE=$((SECONDS+45)); OK=0
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if curl -sS -o /dev/null "http://localhost:$PORT/" 2>/dev/null; then OK=1; break; fi
  sleep 1
done
echo "web OK=$OK"
```

**Webin fallback-portit:** jos primary-portti ei vastaa annetussa ajassa ja
`portFallbackRange > 0`, palvelin saattoi auto-inkrementoida. Skannaa
`port .. port+portFallbackRange` ja/tai lue todellinen URL lokista:

```bash
grep -Eo 'http://localhost:[0-9]+' "$REPO_ROOT/.claude/refresh-dev.log" | tail -5
```

Jos jokin palvelu ei tule terveeksi timeoutissa → tulosta lokin häntä ja **STOP**:

```bash
tail -40 "$REPO_ROOT/.claude/refresh-dev.log"
```

---

## PHASE 6 — Raportti

Kun dev on terve (tai ohitettiin koska jo käynnissä), raportoi tiivisti:

1. **Pull-yhteenveto**: oltiinko ajan tasalla vai pullattiinko, BRANCH, BEFORE→AFTER
   (lyhyet hashit), montako committia.
2. **Ajetut buildit + syyt**: lista (komento ← laukaiseva tiedosto). Jos PHASE 3a sovelsi
   pending-migraatiot (`migrate deploy`) ja/tai Prisma Client regeneroitiin (`db:generate`),
   mainitse se tässä samalla tavalla kuin muut buildit — myös silloin kun migraatio ei
   näkynyt tämän ajon pull-diffissä (tai mitään ei pullattu).
3. **Uudelleenkäynnistys**: jos PHASE 4b ajettiin, kerro että käynnissä ollut dev-server
   pysäytettiin ja käynnistettiin uudelleen vanhentuneen Prisma Clientin takia (vanha
   PID → uusi `DEV_PID`), ja että se ajaa nyt taustalla.
4. **.gitignore-huolto**: jos `GI_ADDED` oli ei-tyhjä, kerro mitkä rivit lisättiin
   `.gitignore`:en ja että ne kannattaa committaa.
5. **Dev-URL(t)**: primary ensin (esim. `http://localhost:5173`), sitten muut.
6. **Taustaprosessi**: `DEV_PID` ja lokipolku `.claude/refresh-dev.log`.
7. **Muistutus**: dev-server jää taustalle — pysäytä `kill <DEV_PID>` kun et tarvitse.

---

## refresh.json — skeemadokumentaatio

Repo-juuren `.claude/refresh.json` ohjaa tätä komentoa. Kentät:

- **`start`** *(string, pakollinen)* — dev-serverin käynnistyskomento, esim. `"pnpm dev"`.
  Ajetaan repo-juuressa, taustalle.
- **`services`** *(array)* — palvelut, joiden portteja detektoidaan ja pollataan.
  Jokainen objekti:
  - `name` *(string)* — palvelun nimi raportointia varten (esim. `"web"`, `"api"`).
  - `port` *(number)* — primary-portti, jossa palvelu yleensä kuuntelee.
  - `portFallbackRange` *(number)* — montako porttia primaryn yli skannataan, jos
    primary on varattu. `0` = ei fallbackia (kiinteä portti; tyypillinen API:lle, jonka
    portti on kovakoodattu proxyyn). Webille esim. `10`, koska Vite auto-inkrementoi.
  - `healthPath` *(string)* — health-poll-polku. `"/"` = mikä tahansa HTTP-vastaus
    (myös 404) riittää "portti vastaa" -signaaliksi (curl ilman `-f`). Muu arvo
    (esim. `"/health"`) = varsinainen healthcheck-endpoint, jolta vaaditaan onnistunut
    status (`curl -f`).
  - `primaryUrl` *(boolean, valinnainen)* — `true` = tämä palvelu on käyttäjälle näkyvä
    sovellus-URL ja sen RUNNING_HERE-tila ratkaisee "jo käynnissä" -päätöksen (PHASE 4).
- **`processMatch`** *(string | null)* — valinnainen lisäpattern cmdline-matchaukseen, jos
  pelkkä repo-juuripolku ei riitä prosessin tunnistamiseen. `null` = käytä repo-juurta.
- **`buildHints`** *(array)* — ohjeet PHASE 3:n päätöspuulle. Jokainen objekti:
  - `whenChanged` *(string, glob)* — tiedostopolku/glob, jonka muutos diffissä laukaisee.
  - `run` *(string)* — ajettava komento.
  - `note` *(string, valinnainen)* — lisähuomio maintainerlle (esim. milloin harkita migraatiota).

---

## Verifiointi — savutestiskenaariot (regressiosuoja)

Nämä skenaariot dokumentoivat odotetun käytöksen. Jos muutat tätä komentoa,
varmista että kukin pätee yhä:

1. **Likainen työpuu → STOP.** Jos `git status --porcelain` palauttaa rivejä, komento
   tulostaa `git status -sb`:n ja pysähtyy PHASE 1:ssä **eikä pullaa**.
2. **Behind + puhdas → pull + oikeat buildit.** Puhtaalla puulla, kun `BEHIND > 0`,
   komento pullaa ff-only, sitten ajaa **vain ne** buildit jotka diffin muuttuneet
   tiedostot laukaisevat (esim. lockfile-muutos → `pnpm install`, pelkkä `.ts`-muutos →
   ei buildia).
3. **RUNNING_HERE → STOP + URL.** Jos kaikki primary-palvelut pyörivät jo tästä reposta,
   komento pysähtyy PHASE 4:ssä ja raportoi olemassa olevan dev-URL:n — ei toista instanssia.
4. **API-portti FOREIGN → STOP.** Jos API:n kiinteä portti on vieraan prosessin varaama,
   komento pysähtyy PHASE 4:ssä (proxy hajoaisi) ja kertoo mikä prosessi varaa portin.
5. **Free + puhdas + ajan tasalla → käynnistä + poll + raportti.** Puhtaalla, ajan
   tasalla olevalla repolla ja vapailla porteilla komento ohittaa buildit, käynnistää
   dev-serverin taustalle, pollaa health-endpointit terveeksi ja raportoi PID:n + URL:t.
6. **Ei konfigia → fallback + varoitus.** Ilman `.claude/refresh.json`:ia komento
   päättelee `start`-komennon `package.json`:n skripteistä (dev→start→serve) ja
   lockfilestä, ja **varoittaa** raportissa että ajetaan ilman konfigia.
7. **Pending-migraatio → migrate deploy + generate (myös ilman pullia).** PHASE 3a ajaa
   `prisma migrate status`in **aina** kun `prisma/schema.prisma` on repo-juuressa — myös
   kun `BEHIND == 0` eikä mitään pullattu. Jos kanta ei ole ajan tasalla — vaikka migraatio
   olisi tullut repoon aiemmassa commitissa eikä näy tämän ajon diffissä — komento ajaa
   `prisma migrate deploy` (**ei** `migrate dev`) ja `pnpm db:generate`, asettaa
   `SCHEMA_CHANGED=1`, ja jos dev-server pyöri jo tästä reposta, käynnistää sen uudelleen
   (PHASE 4b), jottei jää vanhentuneen Prisma Clientin varaan. Migraatio sovelletaan
   **kerran** (PHASE 3 ei enää aja `migrate deploy`ta). Jos dev-kanta on alhaalla, komento
   pysähtyy ja neuvoo `pnpm db:up`. Repo ilman `prisma/schema.prisma` ohittaa PHASE 3a:n
   hiljaa — ei virhettä eikä mainintaa raportissa.
8. **gitignore-huolto on idempotentti.** PHASE 3b varmistaa että `.claude/refresh-dev.log`
   (aina) ja `.claude/refresh.json` (jos olemassa eikä trackattu) ovat ignorattuja. Kun
   rivit ovat jo olemassa → ei muutosta eikä likaista työpuuta. Trackattua `refresh.json`:ia
   ei ignoroida. Pelkkä `.gitignore`-muutos ei laukaise PHASE 1:n STOP:ia seuraavalla ajolla.
9. **setsid-vapaa käynnistys + elossaolotarkistus.** PHASE 5:n ensisijainen käynnistystapa
   on Bash-työkalun `run_in_background: true` -moodi eikä käytä `setsid`iä; etualan fallback
   toimii macOS:llä sellaisenaan (`setsid` vain saatavuustarkistuksen takaa, kopioi–liitä ei
   tuota `command not found`). Jos käynnistys epäonnistuu (prosessi kuolee heti tai loki
   sisältää `command not found`), komento tulostaa lokin hännän ja pysähtyy **ennen** 45 s
   health-pollia — ei odota turhaan.
