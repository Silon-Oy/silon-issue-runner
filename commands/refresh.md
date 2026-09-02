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
lopussa). Jos konfigia ei ole, **PHASE 0b tutkii repon ja luo sen kerran** — komento ei
jää arvaamaan porttia ajosta toiseen.

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

   - Jos JSON luettiin → se on **CONFIG**. Käytä sen `start`, `services`, `buildHints` ja
     (jos kenttä on) `migrations`. Jos `CONFIG.migrations` on määritelty, aseta
     `MIGRATIONS_CONFIGURED=1` — se ratkaisee kumpi vaihe omistaa migraatiot (PHASE 3c
     omistaa, PHASE 3a ohitetaan).
   - Jos `EI-KONFIGIA` → **etene PHASE 0b:hen** (tutkinta + luonti). Älä jatka PHASE 1:een
     ilman konfigia: aiempi pysyvä FALLBACK-tila arvasi portin (5173/3000) identtisesti
     joka ajolla, ja juuri portti on se kohta jossa arvaus maksaa eniten — väärä portti
     tarkoittaa joko turhaa 45 s health-pollia tai väärää "jo käynnissä" -päätöstä
     PHASE 4:ssä.

**Konfigin olemassaolo ratkaistaan tässä, ennen kuin mikään muu vaihe ajaa.** Olemassa
olevaa konfigia **ei koskaan ylikirjoiteta** — luonti on kertaluontoinen teko puuttuvalle
tiedostolle, ja toinen ajo lukee sen tästä samasta kohdasta eikä palaa PHASE 0b:hen.

---

## PHASE 0b — Konfigin tutkinta ja luonti (vain jos konfig puuttuu)

Puuttuva konfig ei voi rikkoa mitään olemassa olevaa, ja tiedosto on paikallinen
(PHASE 3b gitignoroi sen) ⇒ **luonti tehdään**. Olemassa oleva konfig sen sijaan sisältää
käsin viritettyä tietoa, jota tämä komento ei voi päätellä uudelleen ⇒ sitä vain
**ehdotetaan** muutettavaksi (PHASE 3e). Luonti ja muutos ovat siis eri tekoja.

### 1. Tutkinta — rajattu lista, ei ennustusta

Tutki **vain nämä** lähteet, ja vain siltä osin kuin ne repossa oikeasti ovat. Älä päättele
kenttää, jolle repo ei tarjoa katetta — puuttuva kenttä on parempi kuin arvattu.

```bash
cd "$REPO_ROOT"
echo "--- package.json scripts"; cat package.json 2>/dev/null | sed -n '1,200p'
echo "--- lockfiles"; ls -1 pnpm-lock.yaml yarn.lock package-lock.json bun.lock bun.lockb 2>/dev/null
echo "--- workspaces"; ls -1 pnpm-workspace.yaml 2>/dev/null; ls -1d apps/*/package.json packages/*/package.json 2>/dev/null
echo "--- dev-server config"; ls -1 vite.config.* next.config.* svelte.config.* astro.config.* nuxt.config.* webpack.config.* 2>/dev/null
echo "--- compose"; ls -1 docker-compose*.yml compose*.yml 2>/dev/null
echo "--- prisma"; ls -1 prisma/schema.prisma 2>/dev/null
echo "--- env-esimerkki"; ls -1 .env.example .env.sample 2>/dev/null
```

| Lähde | Mitä siitä luetaan |
|---|---|
| `package.json` → `scripts` | `start`-komennon skripti järjestyksessä `dev` → `start` → `serve` (ensimmäinen löytyvä voittaa) |
| Lockfile | Package manager: `pnpm-lock.yaml` → `pnpm`, `yarn.lock` → `yarn`, `package-lock.json` → `npm`, `bun.lock`/`bun.lockb` → `bun`. Yhdistettynä: esim. `pnpm dev` |
| Dev-serverin konfigi (`vite.config.*`, `next.config.*`, vastaava) | **Portti** `server.port` / `--port`-lipusta. Jos porttia ei ole asetettu, käytä frameworkin dokumentoitua oletusta (Vite 5173, Next/Nuxt 3000, Astro 4321) — tämä on frameworkin oletus, ei arvaus |
| `docker-compose*.yml` | Julkaistut portit (`ports: - "3001:3001"`) → omat palvelunsa, jos ne ovat *tämän* repon dev-palveluita |
| `prisma/schema.prisma` + `package.json`:n migraatioskriptit | **Vain havainto raportille.** Ks. kohta 3 — luonti ei kirjoita `migrations`-kenttää |
| Workspace-rakenne (`pnpm-workspace.yaml`, `workspaces`, `apps/*`, `packages/*`) | Monorepo ⇒ **useampi `services`-rivi**: jokainen erikseen käynnistyvä dev-palvelu omana palvelunaan |

Lue portti lähteestä, älä muistista:

```bash
grep -rn "port" vite.config.* next.config.* 2>/dev/null | head -20
grep -n -A3 "ports:" docker-compose*.yml compose*.yml 2>/dev/null | head -40
grep -nE "PORT" .env.example 2>/dev/null | head
```

### 2. STOP, jos repo ei ole dev-server-repo

Jos `start`ia **ei voi johtaa** (ei `package.json`:ia, tai siinä ei ole `dev`/`start`/`serve`
-skriptiä eikä muuta tunnistettavaa dev-käynnistystä) → raportoi
"Ei refresh.json-konfigia eikä tunnistettavaa dev-skriptiä — repo ei ole dev-server-repo"
ja **STOP**. **Älä kirjoita tyhjää tai arvattua konfigia.** Tämä paketti itse on esimerkki
reposta, johon `refresh.json` ei kuulu.

### 3. Kokoa konfig — pakolliset kentät ja mitä jätetään pois

Luodun konfigin on täytettävä **vähintään** `start` ja `services` (`name`, `port`,
`portFallbackRange`, `healthPath`, `primaryUrl`) — eli täsmälleen ne, joita vanha
FALLBACK-tila arvasi. Muut kentät **vain jos repo tarjoaa niille katteen**:

- **`buildHints`** — vain löydetylle lockfilelle (esim. `pnpm-lock.yaml` → `pnpm install`).
  Älä keksi hintejä tiedostoille, joita repossa ei ole.
- **`processMatch`** — jätä pois (oletus = repo-juuri riittää).
- **`prismaGenerate`** — jätä pois. PHASE 3d päättelee komennon `package.json`:sta, ja
  skeemadokumentaatio ohjaa asettamaan tämän vain jos päättely osuu väärin.
- **`migrations`** — **älä kirjoita luontivaiheessa.** Kentän *olemassaolo* siirtää
  migraatioiden omistajuuden PHASE 3a:lta PHASE 3c:lle. Arvattu `apply`-komento kytkisi
  siis hiljaa pois toimivan Prisma-autodetektion ja korvaisi sen arvauksella — juuri se
  vika, jota tämä muutos muuten korjaa. Jos repossa on `prisma/schema.prisma`, PHASE 3a
  hoitaa migraatiot ilman kenttää. Jos repolla on **muu** migraatiomekanismi (Drizzle,
  Knex, Rails tms.), **mainitse se PHASE 6:n raportissa** käsin lisättäväksi — älä lisää itse.

`portFallbackRange`: `10` palvelulle, joka auto-inkrementoi vapaaseen porttiin (Vite, Next);
`0` palvelulle, jonka portti on kiinteä (proxyyn kovakoodattu API). `healthPath`: `"/"`
jollei repo tarjoa varsinaista health-endpointia; jos tarjoaa (esim. reitti `/health`
lähdekoodissa), käytä sitä. `primaryUrl: true` sille palvelulle, joka on käyttäjälle näkyvä
sovellus-URL — täsmälleen yhdelle, ellei repo aidosti tarjoile kahta erillistä käyttöliittymää.

### 4. Näytä sisältö ennen kirjoitusta

**Tulosta koottu JSON käyttäjälle ja kerro mistä kukin arvo tuli** (esim. "portti 5173 ←
`vite.config.ts: server.port`", "`start` ← `scripts.dev` + `pnpm-lock.yaml`). Pyydä
hyväksyntä. Jos käyttäjä korjaa arvoja, kirjoita korjattu versio. Jos käyttäjä kieltäytyy →
älä kirjoita mitään ja **STOP**.

### 5. Kirjoita ja ignoroi samalla kertaa

Kirjoita `$REPO_ROOT/.claude/refresh.json` — ja **aja PHASE 3b:n `ensure_ignored` heti
kirjoituksen jälkeen**, samalla logiikalla, ei uudella mekanismilla. Syy on PHASE 1:
juuri luotu konfig on trackaamaton tiedosto, ja PHASE 3b ajaa vasta PHASE 1:n **jälkeen** ⇒
ilman tätä seuraava ajo pysähtyisi omaan tuotokseensa. Ignorattuna se ei näy
`git status --porcelain`issa lainkaan, ja `.gitignore`-muutoksen PHASE 1 sietää.

```bash
# Trackattua konfigia ei kirjoiteta automaattisesti — ks. alla.
if git -C "$REPO_ROOT" ls-files --error-unmatch .claude/refresh.json >/dev/null 2>&1; then
  echo "TRACKED-MISSING"
else
  mkdir -p "$REPO_ROOT/.claude"
  cat > "$REPO_ROOT/.claude/refresh.json" <<'JSON'
  ... hyväksytty sisältö ...
JSON

  # Sama ensure_ignored kuin PHASE 3b:ssä — ei uutta mekanismia.
  GITIGNORE="$REPO_ROOT/.gitignore"
  entry=".claude/refresh.json"
  if ! git -C "$REPO_ROOT" check-ignore -q "$entry" 2>/dev/null \
     && ! { [ -f "$GITIGNORE" ] && grep -qxF "$entry" "$GITIGNORE"; }; then
    printf '%s\n' "$entry" >> "$GITIGNORE"
    echo "GI_ADDED_EARLY=$entry"
  fi
  echo "CONFIG_CREATED=1"
fi
```

Myöhempi PHASE 3b on tämän jälkeen **no-op** tälle riville (`check-ignore` kattaa sen jo),
joten sen idempotenssi säilyy.

**Jos tuloste on `TRACKED-MISSING`** — tiedosto on gitissä trackattu mutta puuttuu
työpuusta — **älä kirjoita**. Kirjoitus olisi commit-kelpoinen muutos trackattuun
tiedostoon, joka likaisi työpuun ja pysäyttäisi seuraavan ajon PHASE 1:ssä. Näytä koottu
sisältö, neuvo `git -C "$REPO_ROOT" restore .claude/refresh.json`, ja **STOP**.

Kun konfig on luotu, käytä sitä **tässä samassa ajossa** CONFIGina ja etene PHASE 1:een.
`MIGRATIONS_CONFIGURED` jää asettamatta (luonti ei kirjoita `migrations`-kenttää), joten
PHASE 3a omistaa migraatiot kuten konfiguroimattomassa repossa.

**Idempotenssi:** toinen ajo lukee konfigin PHASE 0:ssa eikä tule tänne lainkaan. Mitään ei
luoda eikä ylikirjoiteta uudelleen.

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
`.gitignore`. Aja `git -C "$REPO_ROOT" status -sb`, näytä sen tuloste käyttäjälle ja **STOP**
("Työpuu likainen — committaa tai stashaa ensin, en pullaa muutosten päälle"). Älä etene
PHASE 2:een. (Pelkkä `.gitignore`-muutos ei pysäytä — se kannetaan ff-pullin läpi ja
PHASE 3b täydentää sen.)

---

## PHASE 2 — Hae ja pullaa (ff-only)

```bash
BEFORE=$(git -C "$REPO_ROOT" rev-parse HEAD)
BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
# Lue haaran upstream-remote configista, fallback origin. `git config --get
# branch.<name>.remote` palauttaa pelkän remoten nimen, joten remote-nimen sisältämä
# `/` ei riko sitä (toisin kuin @{upstream}-parsinta). Multi-remote-repossa, jonka
# haara trackaa muuta kuin originia (esim. partner/main), tämä fetchaa ja pullaa oikeasta
# remotesta eikä pysähdy toisen (hylätyn) remoten hajaantumiseen. Haara jolla ei ole
# upstreamia käyttää originia kuten ennen.
REMOTE=$(git -C "$REPO_ROOT" config --get "branch.$BRANCH.remote" || echo origin)
git -C "$REPO_ROOT" fetch "$REMOTE"
BEHIND=$(git -C "$REPO_ROOT" rev-list --count "HEAD..$REMOTE/$BRANCH")
echo "BEFORE=$BEFORE BRANCH=$BRANCH REMOTE=$REMOTE BEHIND=$BEHIND"
```

- Jos `BEHIND == 0` → repo on jo ajan tasalla, **ei pull-diffiä eikä PHASE 3:n buildeja**.
  **Hyppää suoraan PHASE 3a:han** — pending-migraatiot (PHASE 3a *tai* PHASE 3c) ja
  gitignore-huolto (PHASE 3b) ajetaan silti aina, vaikka mitään ei pullattu: koodi voi olla
  kantaa edellä ilman että tämä komento pullaisi.
- Muuten pullaa fast-forward-only:

  ```bash
  git -C "$REPO_ROOT" pull --ff-only "$REMOTE" "$BRANCH"
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

Jos `CONFIG.buildHints` puuttuu tai on tyhjä (tyypillistä juuri luodulle konfigille) →
käytä vain yllä olevia yleissääntöjä.

> **Migraatioita ei sovelleta tässä vaiheessa.** Pull-diffissä näkyvä uusi
> `prisma/migrations/<...>/`-kansio **ei** enää laukaise `migrate deploy`ta täällä — se on
> väärä signaali (diff kertoo *tuliko* migraatio, ei *onko kanta ajan tasalla*). Migraatiot
> hoitaa **PHASE 3a** (Prisma-autodetektio) tai **PHASE 3c** (`CONFIG.migrations`) — kumpikin
> tarkistaa kannan todellisen tilan ja soveltaa pendingit **kerran** riippumatta siitä
> näkyikö migraatio tämän ajon diffissä.

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
**ennen PHASE 4:ää**. PHASE 3 ei enää aja `migrate deploy`ta, joten sama migraatio ei
sovelleta kahdesti.

> **Omistajuus — PHASE 3a vs. PHASE 3c:** jos `CONFIG.migrations` on määritelty, **ohita koko
> PHASE 3a** — silloin migraatiot omistaa **PHASE 3c** (config-vetoinen, ORM-agnostinen).
> PHASE 3a on nollakonfiguraation Prisma-polku repoille, joilla `migrations`-lohkoa ei ole.
> Vaiheet ovat toisensa poissulkevat, joten migraatioita ei yritetä soveltaa kahdesti.

**Autodetektio (ei konfigimuutosta olemassa oleviin `refresh.json`-tiedostoihin):** aja
vaihe vain jos `CONFIG.migrations` **puuttuu** ja repo-juuressa on Prisma-skeema. Muuten
**ohita hiljaa** — ei virhettä, ei mainintaa raportissa.

```bash
# MIGRATIONS_CONFIGURED=1 jos CONFIG.migrations on määritelty (→ PHASE 3c omistaa).
if [ "$MIGRATIONS_CONFIGURED" = 1 ]; then
  echo "PHASE-3a: CONFIG.migrations määritelty — PHASE 3c omistaa migraatiot, ohitetaan"
elif [ ! -f "$REPO_ROOT/prisma/schema.prisma" ]; then
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
  **ei trackattu** ja ei jo ignorattu. Jos tiedosto on jo committattu (trackattu), käyttäjä on
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

## PHASE 3c — Pending-migraatiot (ajetaan aina)

`/refresh` on **"täsmää kanta koodin skeemaan"** -komento, ei vain *"sovella se mitä tässä
pullissa tuli"*. Migraatiot voivat päätyä työpuuhun **ohi komennon oman pullin**: manuaalinen
merge/rebase/checkout, `/run-issues`-orkestraattori, cherry-pick tai paikallisesti generoitu
migraatio. Kaikissa näissä `BEHIND == 0` voi olla tosi vaikka **koodi on kantaa edellä** —
skeemariippuvaiset endpointit kaatuvat silloin ajossa (esim. `SQLITE_ERROR: no such column`).
Siksi pending-migraatioiden sovellus ajetaan **aina** — myös kun `BEHIND == 0` — ja **ennen
PHASE 5:tä** (dev-serverin käynnistystä), jottei dev nouse migratoimattoman kannan päälle.

Vaihe ajetaan **vain jos** `CONFIG.migrations` on määritelty (valinnainen kenttä). Ilman
sitä tämä vaihe on **no-op** — täysi taaksepäinyhteensopivuus repoille, jotka nojaavat
PHASE 3a:n Prisma-autodetektioon tai eivät migratoi lainkaan. Kun kenttä **on** määritelty,
PHASE 3c on migraatioiden ainoa soveltaja ja **PHASE 3a ohitetaan** (ks. sen
omistajuushuomio) — sama migraatio ei siis sovelleta kahdesti.

**Repo-agnostisuus:** `check`- ja `apply`-komennot tulevat **kokonaan**
`CONFIG.migrations`-kentästä — komento ei ole kovakoodattu mihinkään ORM:ään. Sovelluskomento
itse hoitaa oikean Node-ABI:n (`nvm use` → oikea `better-sqlite3`-binääri), ORM-valinnan
(Drizzle `db:migrate` / Prisma `migrate deploy` / muu) ja schema-polun. Aja komennot
repo-juuressa **login-shellissä** (`bash -lc`), jotta `nvm` ja projektin `node_modules/.bin`
latautuvat.

**Päätöspuu — check-then-apply (robustein), fallback always-apply:**

- Jos `CONFIG.migrations.check` on määritelty → aja se **ensin**. Exit-koodi ratkaisee:
  - **exit 0** = pendingiä on → aja `apply`.
  - **exit ≠ 0** = ei sovellettavaa (tai kanta ei ole tavoitettavissa, esim. Postgres alhaalla)
    → **skip apply siististi**, ei muutosyritystä, ei STOP. `check` on siten myös suojaportti,
    joka estää turhan sovellusyrityksen alhaalla olevaa kantaa vasten.
- Jos `CONFIG.migrations.check` **puuttuu** → fallback **always-apply**: aja `apply` suoraan.
  Nojaa siihen että sovelluskomento on **idempotentti** (Drizzlen `db:migrate` ja Prisman
  `migrate deploy` soveltavat vain pendingit, turvallinen re-run). Riski: kannan pitää olla
  pystyssä joka ajossa (ok SQLitelle jonka kanta on tiedosto; Postgresille suosittele `check`).

```bash
# CHECK ja APPLY luetaan CONFIG.migrations-kentästä (CHECK voi olla tyhjä).
CHECK='...'   # CONFIG.migrations.check tai tyhjä
APPLY='...'   # CONFIG.migrations.apply

RUN_APPLY=1
if [ -n "$CHECK" ]; then
  if (cd "$REPO_ROOT" && bash -lc "$CHECK"); then
    echo "MIGRATIONS_PENDING=1"; RUN_APPLY=1
  else
    echo "MIGRATIONS_PENDING=0 (check exit≠0 → ei sovelleta)"; RUN_APPLY=0
  fi
fi

if [ "$RUN_APPLY" = 1 ]; then
  if (cd "$REPO_ROOT" && bash -lc "$APPLY"); then
    echo "MIGRATIONS_APPLIED=1"
    SCHEMA_CHANGED=1
  else
    echo "MIGRATION_FAILED — STOP ennen PHASE 5:tä"
    # STOP — ks. alla
  fi
fi
```

**Jos `apply` failaa** (rc ≠ 0 — esim. dev-kanta alhaalla always-apply-tilassa, tai varsinainen
migraatiovirhe) → tulosta komennon stderr ja **STOP ennen PHASE 5:tä**, täsmälleen kuten
PHASE 3:n build-fail-käytäntö. Älä käynnistä dev-serveriä migratoimattoman kannan päälle.
Neuvo tarkistamaan että kanta on pystyssä (Postgres: `pnpm db:up`; SQLite: tiedosto-oikeudet).

**Jos migraatioita sovellettiin, aseta `SCHEMA_CHANGED=1`** — sama signaali kuin PHASE 3a:lla,
jotta PHASE 4b käynnistää jo pyörivän dev-serverin uudelleen eikä se jää vanhentuneen
skeema- tai client-tilan varaan.

Raportoi PHASE 6:ssa sovellettiinko migraatioita ja millä komennolla.

---

## PHASE 3d — Vanhentunut generoitu ORM-client (ajetaan aina)

Migraatiovaiheet (3a/3c) vastaavat kysymykseen *"onko kanta koodin skeeman tasalla"*.
Ne eivät vastaa kysymykseen *"onko generoitu client skeeman tasalla"* — ja se on eri
kysymys, koska generoitu client on **kolmas** tila kannan ja skeematiedoston rinnalla:

| Taso | Mistä päivittyy |
|---|---|
| Postgres/SQLite-kanta | migraatioiden ajo (PHASE 3a/3c) |
| `prisma/schema.prisma` | git pull |
| Generoitu client (`node_modules/.prisma/`, `generated/`) | **vain** `prisma generate` |

Nämä voivat olla epäsynkassa pareittain. Erityisesti kanta ja skeema voivat olla
molemmat täysin ajan tasalla, mutta client vanhentunut — jolloin sovellus kaatuu
ajonaikaisesti (`Unknown field ... for select statement`) vaikka `migrate status`
sanoo *"up to date"* ja `BEHIND == 0`.

Aiemmin generate ajettiin vain kahdessa tilanteessa, ja kumpikin on **tapahtuma**,
ei tila:

1. buildHint `prisma/schema.prisma` — vaatii että tiedosto muuttui **tässä** pullissa;
2. `CONFIG.migrations.apply` — vaatii että migraatioita oli sovellettavana.

Kumpikaan ei laukea, kun skeema tuli koneelle aiemmassa pullissa ja generate jäi
ajamatta, kun `node_modules` on asennettu uudelleen skeeman päivityksen jälkeen, tai
kun koodi saapui työpuuhun ohi komennon oman pullin (merge, rebase, `/run-issues`,
cherry-pick). Oikea kysymys on jälleen **tila, ei tapahtuma**: onko generoitu client
vanhempi kuin skeema.

Vaihe ajetaan siksi **aina** — myös kun `BEHIND == 0` — ja **ennen PHASE 4:ää**, jottei
dev-server nouse vanhentuneen clientin varaan.

**Autodetektio, ei konfigia.** Aja vaihe vain jos repo-juuressa on `prisma/schema.prisma`.
Muuten **ohita hiljaa** — ei virhettä, ei mainintaa raportissa. (Monorepo, jossa
`prisma/` ei ole repo-juuressa, jää detektion ulkopuolelle; sama hyväksytty rajaus
kuin PHASE 3a:lla.)

Generoitu client ei ole aina samassa paikassa: Prisma 7:ssä `output` on tyypillisesti
eksplisiittinen (esim. `generated/prisma`), vanhemmissa se on oletuksena
`node_modules/.prisma/client`. Lue polku skeeman `generator`-lohkosta ja käytä
oletusta vain jos `output`ia ei ole.

```bash
SCHEMA="$REPO_ROOT/prisma/schema.prisma"
if [ ! -f "$SCHEMA" ]; then
  echo "PHASE-3d: ei prisma/schema.prisma — ohitetaan hiljaa"
else
  # `output = "..."` generator-lohkosta; suhteellinen polku on suhteessa schema-tiedostoon.
  OUT=$(sed -n 's/^[[:space:]]*output[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$SCHEMA" | head -1)
  if [ -n "$OUT" ]; then
    case "$OUT" in
      /*) CLIENT_DIR="$OUT" ;;
      *)  CLIENT_DIR="$REPO_ROOT/prisma/$OUT" ;;
    esac
  else
    CLIENT_DIR="$REPO_ROOT/node_modules/.prisma/client"
  fi

  # Puuttuva client on aina vanhentunut. Muuten vertaa tuoreimman generoidun
  # tiedoston mtimeä skeeman mtimeen: `-nt` yksin ei riitä, koska hakemiston oma
  # mtime ei muutu kun sen sisällä olevia tiedostoja kirjoitetaan uusiksi.
  if [ ! -d "$CLIENT_DIR" ]; then
    CLIENT_STALE=1
  else
    NEWEST=$(find "$CLIENT_DIR" -type f \( -name '*.js' -o -name '*.ts' -o -name '*.node' \) \
               -exec stat -f '%m %N' {} + 2>/dev/null \
             || find "$CLIENT_DIR" -type f -printf '%T@ %p\n' 2>/dev/null)
    NEWEST_TS=$(printf '%s\n' "$NEWEST" | sort -rn | head -1 | cut -d' ' -f1)
    SCHEMA_TS=$(stat -f '%m' "$SCHEMA" 2>/dev/null || stat -c '%Y' "$SCHEMA" 2>/dev/null)
    if [ -z "$NEWEST_TS" ] || [ "${NEWEST_TS%%.*}" -lt "${SCHEMA_TS%%.*}" ]; then
      CLIENT_STALE=1
    else
      CLIENT_STALE=0
    fi
  fi
  echo "PHASE-3d: CLIENT_DIR=$CLIENT_DIR CLIENT_STALE=$CLIENT_STALE"
fi
```

Jos `CLIENT_STALE=1` → aja generate. Komento tulee `CONFIG.prismaGenerate`-kentästä jos
se on määritelty; muuten `package.json`:n `prisma:generate`- tai `db:generate`-skriptistä
(ensimmäinen löytyvä, ajettuna PHASE 0:ssa päätellyllä package managerilla); viimeisenä
fallbackina `npx prisma generate`. Aja repo-juuressa login-shellissä, jotta `nvm` ja
projektin `node_modules/.bin` latautuvat:

```bash
if [ "$CLIENT_STALE" = 1 ]; then
  (cd "$REPO_ROOT" && bash -lc "$GENERATE_CMD") || {
    echo "GENERATE_FAILED — STOP ennen PHASE 4:ää"
    # STOP — ks. alla
  }
  SCHEMA_CHANGED=1
fi
```

**Jos generate failaa** → tulosta stderr ja **STOP ennen PHASE 4:ää**, samoin kuin PHASE 3:n
build-fail-käytäntö. Älä käynnistä dev-serveriä vanhentuneen clientin päälle: se kaatuisi
vasta ensimmäisellä skeemariippuvaisella pyynnöllä, mistä syy on paljon vaikeampi nähdä
kuin tästä.

**Jos generate ajettiin, aseta `SCHEMA_CHANGED=1`** — käynnissä oleva dev-server ei seuraa
generoidun clientin hakemistoa, joten PHASE 4b:n uudelleenkäynnistys on pakollinen, muuten
prosessi jää juuri korjatun vanhentuneen clientin varaan.

Raportoi PHASE 6:ssa ajettiinko generate ja miksi (client vanhempi kuin skeema / puuttui).

---

## PHASE 3e — Konfigiehdotus pull-diffistä (vain jos pullattiin)

Konfig kirjoitetaan kerran ja **ajautuu**: uusi palvelu, vaihtunut portti, vaihtunut
pakettimanageri tai ilmestynyt `prisma/schema.prisma` jättää `refresh.json`:in vanhaksi
hiljaa. Signaali on jo käsillä — PHASE 3:n lukema `BEFORE..AFTER`-diff kertoo myös milloin
konfig on jäänyt jälkeen.

**Tämä vaihe ei kirjoita mitään eikä ole STOP-ehto.** Se kerää tekstin PHASE 6:n raporttia
varten; dev-server käynnistyy ja raportti valmistuu normaalisti riippumatta siitä
löytyikö ehdotuksia. Ohita vaihe kokonaan, jos `BEHIND == 0` (ei diffiä) tai jos konfig
**luotiin tässä ajossa** PHASE 0b:ssä (se on jo nykytilan mukainen).

**Ehdotus johdetaan tämän ajon pullatuista commiteista, ei repon nykytilan ja konfigin
vertailusta.** Ero on tarkoituksellinen: diffipohjainen ehdotus **vaimenee itsestään** —
seuraavalla ajolla diff on eri eikä ehdotus toistu. Nykytilavertailu toistaisi saman rivin
joka ajolla, kunnes se hyväksytään, mikä on juuri sitä lokikohinaa jota tässä paketissa
vältetään. **Älä siksi rakenna tälle tilatiedostoa, muistia tai vaimennuslaskuria** —
itsevaimeneva diffipohjaisuus on koko mekanismi.

```bash
CHANGED=$(git -C "$REPO_ROOT" diff --name-only "$BEFORE..$AFTER")
printf '%s\n' "$CHANGED"
```

Laukaisevat signaalit — käy nämä läpi muuttuneesta tiedostolistasta:

| Signaali diffissä | Ehdotettava muutos |
|---|---|
| Lockfile vaihtui (`pnpm-lock.yaml` ↔ `package-lock.json` ↔ `yarn.lock` ↔ `bun.lock*`; lisäys tai poisto) | `start`-kentän pakettimanageri ei enää vastaa repoa |
| `package.json`:n `scripts.dev` muuttui eikä vastaa enää `CONFIG.start`ia | `start` osoittaa vanhaan skriptiin |
| Uusi palvelu tai portti: `docker-compose*.yml`, dev-serverin konfigi (`vite.config.*`, `next.config.*`, …), `.env.example`:n PORT-muuttuja | uusi `services`-rivi tai muuttunut `port` |
| `prisma/schema.prisma` ilmestyi **eikä** `CONFIG.migrations`-kenttää ole | migraatiotarve syntyi — PHASE 3a hoitaa Prisman, mutta muu ORM vaatii `migrations`-kentän |
| Uusi workspace (`pnpm-workspace.yaml`, `workspaces`-lohko, uusi `apps/*/package.json` tai `packages/*/package.json`) | uusi erikseen käynnistyvä palvelu `services`-taulukkoon |

Kun signaali osuu, **lue muuttunut tiedosto ja vertaa sitä konfigin nykyiseen arvoon** —
älä raportoi pelkkää tiedostonimeä. Ehdotus ohitetaan, jos konfig on jo linjassa muutoksen
kanssa (esim. portti muuttui arvoon, joka konfigissa jo on).

Nimeä **commit joka signaalin laukaisi**:

```bash
git -C "$REPO_ROOT" log --oneline "$BEFORE..$AFTER" -- <polku> | head -3
```

Ehdotuksen on oltava **konkreettinen JSON-katkelma tai diff** — ei "harkitse konfigin
päivittämistä" -tyylinen yleismaininta. Esimerkkimuoto:

```
Konfigiehdotus — laukaisi a1b2c3d "chore: switch to npm"
  pnpm-lock.yaml poistui, package-lock.json ilmestyi ⇒ start-kentän manageri vanhentui
  -  "start": "pnpm dev"
  +  "start": "npm run dev"
```

**Ehdotusta ei kirjoiteta tiedostoon ilman käyttäjän lupaa.** Se elää raportissa
(PHASE 6, kohta 4b). Jos käyttäjä hyväksyy sen, hän voi pyytää muutosta erikseen.

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

Käynnistä `start`-komento niin että se **jää eloon työkalukutsua ja sessiota pidemmäksi
ajaksi** — dev-serverin tarkoitettu elinkaari on sessiota pidempi: käyttäjä jatkaa
työskentelyä ja pysäyttää sen itse `kill <DEV_PID>`:llä (PHASE 6).

**Ensisijainen tapa — `nohup … & disown`.** Irrota prosessi kokonaan sessiosta, jotta se
säilyy hengissä myös työkalukutsun ja session jälkeen. `setsid` **ei kuulu macOS:n
perusasennukseen** — älä käytä sitä ehdoitta (`command not found` → dev-server ei käynnisty).
Pelkkä `nohup … & disown` riittää macOS:llä; `setsid` lisätään vain saatavuustarkistuksen
takaa. Loki ohjataan **komennon sisällä** `.claude/refresh-dev.log`-tiedostoon, jotta se
säilyy raportoitavana polkuna:

```bash
command -v setsid >/dev/null 2>&1 && SETSID=setsid || SETSID=""
cd "$REPO_ROOT" && $SETSID nohup pnpm dev > "$REPO_ROOT/.claude/refresh-dev.log" 2>&1 &
DEV_PID=$!
disown "$DEV_PID" 2>/dev/null || true
echo "DEV_PID=$DEV_PID LOG=$REPO_ROOT/.claude/refresh-dev.log"
```

(Korvaa `pnpm dev` CONFIG.start-arvolla. `nohup … & disown` irrottaa prosessin sessiosta,
joten se jää eloon myös silloin kun harness lopettaa taustatehtäviä; loki menee aina
`$REPO_ROOT/.claude/refresh-dev.log`-tiedostoon. `DEV_PID` on elossaolotarkistusta ja
PHASE 6:n raporttia varten.)

**Toissijainen tapa — Bash-työkalun `run_in_background: true` -moodi** (vain jos et voi ajaa
edellä olevaa etualan käynnistystä). Aja start-komento Bash-työkalulla
`run_in_background: true` -parametrilla ja ohjaa tuloste lokiin **komennon sisällä**, jotta
`.claude/refresh-dev.log` säilyy raportoitavana polkuna:

```bash
cd "$REPO_ROOT" && pnpm dev > "$REPO_ROOT/.claude/refresh-dev.log" 2>&1
```

**Varaus — elinkaarisidos.** `run_in_background: true` pitää prosessin elossa vain
**työkalukutsun palatessa**, ei sessiota pidempään: prosessi on sidottu harnessin
taustatehtävän elinkaareen, ja harness voi pysäyttää tehtävän
(`<task-notification> status: killed`) ennen dev-serverin tarkoitettua elinkaarta. Silloin
portti vapautuu eikä mikään kuuntele, vaikka PHASE 6 on jo raportoinut URL:n ja PID:n. Jos
käytät tätä tapaa, ota talteen työkalun palauttama taustatehtävän tunniste
elossaolotarkistusta varten **ja** mainitse PHASE 6:n raportissa, että prosessi voi kuolla
taustatehtävän mukana.

**Elossaolotarkistus ennen health-pollia.** Käynnistys voi epäonnistua hiljaa: `&`-taustaan
ajettu rivi (tai `run_in_background`-tehtävä) "onnistuu" heti vaikka komento ei löytyisi, ja
vasta 45 s health-poll paljastaisi ettei mitään käynnistynyt. Tarkista siksi **ennen**
pollia että prosessi on elossa eikä loki sisällä käynnistysvirhettä — jos kuollut, tulosta
lokin häntä ja **STOP heti**, älä odota 45 s turhaan:

```bash
sleep 1
DEAD=0
# Ensisijainen tapa (nohup): DEV_PID asetettu → tarkista prosessi. run_in_background-moodissa
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

1. **Pull-yhteenveto**: oltiinko ajan tasalla vai pullattiinko, BRANCH, käytetty REMOTE
   (haaran upstream configista, fallback `origin`), BEFORE→AFTER (lyhyet hashit), montako
   committia. Raportoi REMOTE **aina**, jotta väärästä lähteestä pullaaminen näkyy heti —
   erityisesti multi-remote-repossa, jonka haara ei tracka originia.
2. **Ajetut buildit + syyt**: lista (komento ← laukaiseva tiedosto). Jos PHASE 3a sovelsi
   pending-migraatiot (`migrate deploy`) ja/tai Prisma Client regeneroitiin (`db:generate`),
   mainitse se tässä samalla tavalla kuin muut buildit — myös silloin kun migraatio ei
   näkynyt tämän ajon pull-diffissä (tai mitään ei pullattu).
2b. **Pending-migraatiot (PHASE 3c)**: jos repolla on `CONFIG.migrations`, kerro
   sovellettiinko `apply`-komento vai ohitettiinko se (`check` totesi ei pendingiä). Tämä on
   PHASE 3a:n Prisma-polun vaihtoehto — kumpikin ajetaan myös kun `BEHIND == 0`.
2c. **Generoitu client (PHASE 3d)**: jos generate ajettiin, kerro miksi — client oli
   vanhempi kuin `prisma/schema.prisma`, tai puuttui kokonaan. Tämä on eri asia kuin
   migraatiot: kanta voi olla täysin ajan tasalla ja client silti vanhentunut.
3. **Uudelleenkäynnistys**: jos PHASE 4b ajettiin, kerro että käynnissä ollut dev-server
   pysäytettiin ja käynnistettiin uudelleen vanhentuneen Prisma Clientin takia (vanha
   PID → uusi `DEV_PID`), ja että se ajaa nyt taustalla.
4. **.gitignore-huolto**: jos `GI_ADDED` (tai PHASE 0b:n `GI_ADDED_EARLY`) oli ei-tyhjä,
   kerro mitkä rivit lisättiin `.gitignore`:en ja että ne kannattaa committaa.
4b. **Konfigi**:
   - **Luotiin (PHASE 0b)**: jos `CONFIG_CREATED=1`, kerro että `.claude/refresh.json`
     luotiin, mistä lähteistä `start` ja `services` johdettiin, ja mitkä kentät jäivät
     käsin asetettaviksi (erityisesti `migrations`, jos repolla on muu kuin Prisma-pohjainen
     migraatiomekanismi).
   - **Ehdotukset (PHASE 3e)**: jos pull-diffistä löytyi konfigia koskettavia muutoksia,
     listaa kukin ehdotus omana kohtanaan: laukaissut commit, mikä muuttui, ja konkreettinen
     JSON-katkelma tai diff. Sano eksplisiittisesti, että **mitään ei kirjoitettu** — ehdotus
     odottaa hyväksyntää. Jos ehdotuksia ei ole, älä mainitse osiota lainkaan.
5. **Dev-URL(t)**: primary ensin (esim. `http://localhost:5173`), sitten muut.
6. **Taustaprosessi**: `DEV_PID` ja lokipolku `.claude/refresh-dev.log`.
7. **Muistutus**: dev-server jää taustalle — pysäytä `kill <DEV_PID>` kun et tarvitse.

---

## refresh.json — skeemadokumentaatio

Repo-juuren `.claude/refresh.json` ohjaa tätä komentoa. Tiedosto joko on olemassa tai
PHASE 0b luo sen kerran — mutta **luonti ei täytä kaikkia kenttiä**, koska osa niistä
sisältää tietoa, jota repo ei kerro:

| Kenttä | Täyttääkö PHASE 0b |
|---|---|
| `start` | **Kyllä** — pakollinen; ilman sitä luonti ei tapahdu vaan komento pysähtyy |
| `services` (`name`, `port`, `portFallbackRange`, `healthPath`, `primaryUrl`) | **Kyllä** — pakollinen |
| `buildHints` | Vain löydetylle lockfilelle; muuten tyhjä ja käsin täydennettävä |
| `processMatch` | Ei — jätetään pois, oletus (repo-juuri) riittää |
| `prismaGenerate` | Ei — PHASE 3d päättelee komennon; aseta vain jos päättely osuu väärin |
| `migrations` | **Ei koskaan** — kentän olemassaolo siirtäisi omistajuuden PHASE 3a:lta 3c:lle, ja arvattu `apply` kytkisi hiljaa pois toimivan autodetektion. Muun kuin Prisman käyttäjä lisää tämän käsin |

Kentät:

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
  - `note` *(string, valinnainen)* — lisähuomio käyttäjälle (esim. milloin harkita migraatiota).
- **`prismaGenerate`** *(string, valinnainen)* — komento, jolla generoitu ORM-client
  rakennetaan uudelleen, esim. `"npm run prisma:generate"`. PHASE 3d käyttää tätä kun se
  havaitsee clientin olevan skeemaa vanhempi. Ilman kenttää komento päätellään
  `package.json`:n `prisma:generate`- tai `db:generate`-skriptistä, ja viimeisenä
  fallbackina `npx prisma generate`. Aseta tämä vain jos automaattinen päättely osuu väärin
  (esim. monorepo, jossa generate ajetaan workspace-lipulla).
- **`migrations`** *(object, valinnainen)* — pending-migraatioiden sovellus, jonka PHASE 3c
  ajaa **aina** (myös kun `BEHIND == 0`), riippumatta siitä pullasiko komento. Repo-agnostinen:
  komennot annetaan tässä, ei kovakoodattuna ORM:ään. Kentät:
  - `apply` *(string, pakollinen)* — komento joka soveltaa pending-migraatiot. **Oltava
    idempotentti** (soveltaa vain pendingit, turvallinen re-run). Ajetaan repo-juuressa
    login-shellissä, joten se voi hoitaa `nvm use`:n oikean Node-ABI:n varmistamiseksi. Esim.
    `"source ~/.nvm/nvm.sh && nvm use >/dev/null && npm run db:migrate"`.
  - `check` *(string, valinnainen)* — komento joka päättää onko sovellettavaa: **exit 0** =
    pendingiä on → `apply` ajetaan; **exit ≠ 0** = ei mitään (tai kanta ei tavoitettavissa) →
    `apply` ohitetaan siististi ilman muutosyritystä. Ilman `check`:iä fallback on **always-apply**
    (`apply` ajetaan aina; nojaa idempotenssiin). Suositeltu erityisesti Postgresille, jotta
    alhaalla oleva kanta ei aiheuta STOP:ia joka `/refresh`-ajossa.
  - `note` *(string, valinnainen)* — vapaa muistiinpano (esim. idempotenssin peruste).

  Jos `migrations` on määritelty, **PHASE 3a:n Prisma-autodetektio ohitetaan kokonaan**
  kaksinkertaisen sovelluksen välttämiseksi — PHASE 3c omistaa silloin migraatiot. Esim.:

  ```jsonc
  "migrations": {
    // Aja PHASE 3c:ssä AINA (BEHIND-tilasta riippumatta).
    "apply": "source ~/.nvm/nvm.sh && nvm use >/dev/null && npm run db:migrate",
    "note": "db:migrate on idempotentti — soveltaa vain pendingit, turvallinen re-run"
  }
  ```

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
6. **Ei konfigia → tutkinta + luonti, ei pysyvää arvausta.** Ilman
   `.claude/refresh.json`:ia komento ei jatka arvatulla portilla vaan haarautuu
   PHASE 0b:hen: tutkii rajatun lähdelistan (`package.json`:n `scripts`, lockfile,
   dev-serverin konfigi, `docker-compose*.yml`, `prisma/schema.prisma`, workspace-rakenne),
   näyttää kootun JSONin lähteineen ja kirjoittaa sen vasta hyväksynnän jälkeen. Luotu
   konfig täyttää vähintään `start`in ja `services`-taulukon — eli poistaa täsmälleen sen
   arvauksen, jonka vanha FALLBACK-tila teki.
7. **Pending-migraatio → migrate deploy + generate (myös ilman pullia).** PHASE 3a ajaa
   `prisma migrate status`in **aina** kun `prisma/schema.prisma` on repo-juuressa — myös
   kun `BEHIND == 0` eikä mitään pullattu. Jos kanta ei ole ajan tasalla — vaikka migraatio
   olisi tullut repoon aiemmassa commitissa eikä näy tämän ajon diffissä — komento ajaa
   `prisma migrate deploy` (**ei** `migrate dev`) ja `pnpm db:generate`, asettaa
   `SCHEMA_CHANGED=1`, ja jos dev-server pyöri jo tästä reposta, käynnistää sen uudelleen
   (PHASE 4b), jottei jää vanhentuneen Prisma Clientin varaan. Migraatio sovelletaan
   **kerran** (PHASE 3 ei enää aja `migrate deploy`ta). Jos dev-kanta on alhaalla, komento
   pysähtyy ja neuvoo `pnpm db:up`. Repo ilman `prisma/schema.prisma` — tai repo jolla on
   `CONFIG.migrations` (silloin PHASE 3c omistaa migraatiot, ks. skenaario 10) — ohittaa
   PHASE 3a:n hiljaa: ei virhettä eikä mainintaa raportissa.
8. **gitignore-huolto on idempotentti.** PHASE 3b varmistaa että `.claude/refresh-dev.log`
   (aina) ja `.claude/refresh.json` (jos olemassa eikä trackattu) ovat ignorattuja. Kun
   rivit ovat jo olemassa → ei muutosta eikä likaista työpuuta. Trackattua `refresh.json`:ia
   ei ignoroida. Pelkkä `.gitignore`-muutos ei laukaise PHASE 1:n STOP:ia seuraavalla ajolla.
9. **setsid-vapaa käynnistys + elossaolotarkistus.** PHASE 5:n ensisijainen käynnistystapa
   on `nohup … & disown`, joka irrottaa prosessin sessiosta niin että se jää eloon sessiota
   pidemmäksi ajaksi; se toimii macOS:llä sellaisenaan (`setsid` vain saatavuustarkistuksen
   takaa, kopioi–liitä ei tuota `command not found`). Toissijainen `run_in_background: true`
   -moodi sitoo prosessin harnessin taustatehtävään ja voi kuolla sen mukana, joten sitä
   käytetään vain jos etualan käynnistystä ei voi ajaa. Jos käynnistys epäonnistuu (prosessi
   kuolee heti tai loki sisältää `command not found`), komento tulostaa lokin hännän ja
   pysähtyy **ennen** 45 s health-pollia — ei odota turhaan.
10. **Koodi edellä kantaa + `BEHIND == 0` → pending-migraatiot sovelletaan silti.** Kun
   migraatiot ovat päätyneet työpuuhun ohi komennon oman pullin (manuaalinen merge/checkout,
   `/run-issues`, cherry-pick tms.) ja `origin/main == HEAD` (`BEHIND == 0`), komento **ei**
   hyppää dev-serverin käynnistykseen kanta koodia jäljessä. Jos repolla on
   `CONFIG.migrations`, PHASE 3c ajaa sen (check-then-apply, fallback always-apply) ja
   soveltaa pendingit **ennen PHASE 5:tä**, joten `gift_message`-tyyppinen `no such column`
   -500 ei toistu; ilman konfigia sama tehtävä on PHASE 3a:n Prisma-autodetektiolla
   (skenaario 7). Jos `apply` failaa (esim. dev-kanta alhaalla always-apply-tilassa) →
   komento pysähtyy PHASE 3c:ssä eikä käynnistä dev-serveriä.
11. **Upstream ei ole `origin` → pull oikeasta remotesta.** Repossa jonka haara trackaa
   muuta kuin `origin`ia (esim. `partner/main`), PHASE 2 lukee remoten
   `branch.<name>.remote`-configista ja fetchaa + laskee `BEHIND`in + pullaa **siitä**
   remotesta eikä pysähdy toisen (hylätyn) remoten hajaantumiseen. Repoissa joissa upstream
   on `origin` — eli valtaosassa — käytös on ennallaan (fallback osuu). Haara jolla ei ole
   upstreamia lainkaan käyttää `origin`ia kuten ennenkin. PHASE 6:n pull-yhteenveto raportoi
   käytetyn remoten aina.

12. **Kanta ajan tasalla, client vanhentunut → generate + uudelleenkäynnistys.** Kun
   `prisma/schema.prisma` on kantaa vastaava (`migrate status` sanoo *"up to date"* tai
   `CONFIG.migrations.check` toteaa ei-pendingiä) mutta generoitu client on skeemaa vanhempi
   — skeema tuli aiemmassa pullissa ja generate jäi ajamatta, `node_modules` asennettiin
   uudelleen, tai koodi saapui työpuuhun ohi komennon pullin — PHASE 3d havaitsee sen
   mtime-vertailulla ja ajaa generaten **ennen PHASE 4:ää**, myös kun `BEHIND == 0`.
   `SCHEMA_CHANGED=1` saa PHASE 4b:n käynnistämään käynnissä olevan dev-serverin uudelleen.
   Ilman tätä sovellus nousee vanhentuneella clientillä ja kaatuu vasta ensimmäiseen
   skeemariippuvaiseen pyyntöön (`Unknown field ... for select statement`), vaikka sekä
   kanta että skeema ovat kunnossa. Repo ilman `prisma/schema.prisma`:aa ohittaa vaiheen
   hiljaa. Jos generate failaa → STOP, ei dev-serveriä.

13. **Luonti on kertaluontoinen eikä pysäytä seuraavaa ajoa.** Kun repossa ei ole
   `.claude/refresh.json`:ia mutta `start` on johdettavissa, PHASE 0b kirjoittaa konfigin
   ja ajaa **saman `ensure_ignored`-huollon heti kirjoituksen jälkeen**, joten tuore
   trackaamaton konfig ei näy `git status --porcelain`issa eikä PHASE 1 pysähdy komennon
   omaan tuotokseen seuraavalla ajolla. Toinen ajo lukee konfigin PHASE 0:ssa eikä palaa
   PHASE 0b:hen — mitään ei luoda eikä ylikirjoiteta uudelleen, ja PHASE 3b on tälle
   riville no-op. Jos `start`ia **ei** voi johtaa (repo ei ole dev-server-repo, kuten tämä
   paketti itse) → STOP eikä tiedostoa kirjoiteta. Jos `refresh.json` on trackattu mutta
   puuttuu työpuusta → sisältö näytetään, mitään ei kirjoiteta, ja komento neuvoo
   `git restore`n. Luonti **ei** kirjoita `migrations`-kenttää, joten PHASE 3a:n
   Prisma-autodetektio säilyy toimivana.
14. **Konfigia koskettava commit → ehdotus raportissa, ei kirjoitusta, ei STOP:ia.** Kun
   pullatut commitit (`BEFORE..AFTER`) koskettavat konfigin kattamaa asiaa — lockfile tai
   pakettimanageri vaihtui, `scripts.dev` ei vastaa enää `start`-kenttää, uusi palvelu tai
   portti ilmestyi (`docker-compose*.yml`, dev-serverin konfigi, `.env.example`),
   `prisma/schema.prisma` ilmestyi ilman `migrations`-kenttää, tai repoon tuli uusi
   workspace — PHASE 3e tuottaa **konkreettisen JSON-katkelman tai diffin** ja nimeää
   **commitin joka sen laukaisi**. Ehdotus elää PHASE 6:n raportissa: tiedostoa ei
   kirjoiteta, dev-server käynnistyy ja raportti valmistuu normaalisti. Ehdotus **vaimenee
   itsestään** — seuraavalla ajolla diff on eri eikä sama rivi toistu, joten mekanismi ei
   tarvitse tilatiedostoa, muistia eikä vaimennuslaskuria. Kun `BEHIND == 0` tai konfig
   luotiin tässä ajossa, vaihe ohitetaan kokonaan.
