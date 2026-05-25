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
git -C "$REPO_ROOT" status --porcelain
```

Jos tuloste on **ei-tyhjä** → työpuu on likainen. Aja `git -C "$REPO_ROOT" status -sb`,
näytä sen tuloste maintainerlle ja **STOP** ("Työpuu likainen — committaa tai stashaa ensin,
en pullaa muutosten päälle"). Älä etene PHASE 2:een.

---

## PHASE 2 — Hae ja pullaa (ff-only)

```bash
BEFORE=$(git -C "$REPO_ROOT" rev-parse HEAD)
git -C "$REPO_ROOT" fetch origin
BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
BEHIND=$(git -C "$REPO_ROOT" rev-list --count "HEAD..origin/$BRANCH")
echo "BEFORE=$BEFORE BRANCH=$BRANCH BEHIND=$BEHIND"
```

- Jos `BEHIND == 0` → repo on jo ajan tasalla. **Hyppää suoraan PHASE 4:ään** (ei buildeja).
- Muuten pullaa fast-forward-only:

  ```bash
  git -C "$REPO_ROOT" pull --ff-only origin "$BRANCH"
  ```

  - Jos pull **epäonnistuu** (esim. haarat ovat hajaantuneet / ff ei mahdollinen) →
    näytä virhe ja **STOP** ("Pull ei ff-only-onnistunut — haara on hajaantunut, selvitä
    manuaalisesti").
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
| `prisma/schema.prisma` | `pnpm db:generate` **ja** jos `prisma/migrations/` sai uuden kansion (näkyy diffissä uutena `prisma/migrations/<...>/` -polkuna) → **ILMOITA maintainerlle** että `pnpm db:migrate` voi olla tarpeen — **älä aja sitä automaattisesti** (migraatio voi olla destruktiivinen) |
| vain `.ts` / `.tsx` (lähdekoodi) | ei buildia — dev-server (Vite/tsx watch) hoitaa hot-reloadin |

Fallback-tilassa (ei CONFIG) käytä vain yllä olevia yleissääntöjä.

Raportoi **jokaisesta** ajetusta buildista mitä ajettiin ja **miksi** (mikä muuttunut
tiedosto laukaisi sen). Jos jokin build **failaa** → tulosta sen stderr ja **STOP**
(älä käynnistä dev-serveriä rikkinäisen riippuvuustilan päälle).

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

- Jos **kaikki `primaryUrl: true` -palvelut** ovat RUNNING_HERE → dev pyörii jo. **STOP**
  ja raportoi primary-URL(t) (savutesti 3). Älä käynnistä toista instanssia.
- Jos **API-palvelun** (ei-primary, portFallbackRange 0) portti on **FOREIGN** → **STOP**
  (C1: web-proxy osoittaa kiinteään API-porttiin; vieras prosessi siinä portissa
  rikkoisi proxyn ja antaisi hiljaa väärää dataa). Raportoi mikä PID/komento varaa portin.
- Jos **webin** primary-portti on FOREIGN mutta API on vapaa/oma → **varoita** että
  primary-portti on varattu ja Vite auto-inkrementoi seuraavaan vapaaseen porttiin, mutta
  **jatka** PHASE 5:een (luetaan todellinen URL lokista).
- Muuten (kaikki tarvittavat FREE) → etene PHASE 5:een normaalisti.

---

## PHASE 5 — Käynnistä dev-server taustalle

Käynnistä `start`-komento niin että se **jää eloon** työkalukutsun palatessa.

**Kun ajat tämän itse Bash-työkalulla**, käytä Bash-työkalun `run_in_background: true`
-moodia, tai jos ajat etualalla, käytä `setsid` + `disown` -kuoritekniikkaa niin ettei
prosessi kuole kun työkalukutsu palaa:

```bash
cd "$REPO_ROOT" && setsid nohup pnpm dev > "$REPO_ROOT/.claude/refresh-dev.log" 2>&1 &
DEV_PID=$!
disown "$DEV_PID" 2>/dev/null || true
echo "DEV_PID=$DEV_PID LOG=$REPO_ROOT/.claude/refresh-dev.log"
```

(Korvaa `pnpm dev` CONFIG.start-arvolla. Loki menee aina
`$REPO_ROOT/.claude/refresh-dev.log`-tiedostoon.)

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
2. **Ajetut buildit + syyt**: lista (komento ← laukaiseva tiedosto). Jos uusi
   migraatiokansio havaittiin, nosta `pnpm db:migrate` -muistutus tähän.
3. **Dev-URL(t)**: primary ensin (esim. `http://localhost:5173`), sitten muut.
4. **Taustaprosessi**: `DEV_PID` ja lokipolku `.claude/refresh-dev.log`.
5. **Muistutus**: dev-server jää taustalle — pysäytä `kill <DEV_PID>` kun et tarvitse.

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

Nämä kuusi skenaariota dokumentoivat odotetun käytöksen. Jos muutat tätä komentoa,
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
