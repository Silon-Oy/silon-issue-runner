# Ajokone Fly.io Spritessä — ikkunamalli

> **Tila:** todennettu käytännössä 27.8.2026 pystyttämällä `claude-issue-runner`-niminen
> Sprite ajamaan kohderepoa. Kaikki tämän dokumentin komennot on ajettu oikeaa Spriteä
> vasten, ei suunniteltu paperilla.

Sprite on ~8 CPU / 8 GB / 100 GB Firecracker-VM, joka **nukahtaa noin 30 sekunnin
käyttämättömyyden jälkeen** ja maksaa nukkuvana käytännössä nolla. Se sopii ajokoneeksi
hyvin, mutta **ei pollerimallilla**: runnerin 300 s poller herättäisi koneen ikuisesti,
jolloin maksaisi jatkuvasti päällä olevasta koneesta.

Siksi Spritessä ei asenneta pollereita lainkaan. Malli on **ikkuna**: kone herätetään, se
tyhjentää jonon, ja nukahtaa itsestään. `drain-queue.sh` toteuttaa tämän — se kutsuu samaa
`pick_oldest_candidate`-funktiota kuin poller, ja **tyhjä paluuarvo lopettaa silmukan
heti** sen sijaan että jäätäisiin odottamaan seuraavaa kierrosta.

## Mitä Spritessä on valmiina ja mitä ei

Todettu tuoreesta Spritestä:

| | Tila |
|---|---|
| `node` | ✅ v24.18.0 |
| `pnpm` | ✅ 11.23.0 |
| `claude` | ✅ `~/.local/bin/claude` — **autentikointi tehtävä erikseen** |
| `gh` | ✅ `/.sprite/bin/gh` — **autentikointi tehtävä erikseen** |
| Playwright-selaimet | ⚠️ asennettuina (`~/.cache/ms-playwright`), mutta **Chromium kaatuu** — E2E ei aja, ks. alla |
| `sudo` | ✅ ilman salasanaa |
| `apt-get` | ✅ |
| **Docker** | ⚠️ Docker 29 + Compose 2.40 asennettuina, mutta **daemon ei ole käynnissä** — `docker run` kaatuu puuttuvaan `/var/run/docker.sock`iin kunnes `sudo dockerd` on käynnistetty, ks. alla |
| **PostgreSQL-palvelin** | ❌ vain `postgresql-client-18`, ei `postgres`-binääriä |

Kaksi viimeistä ovat ne, jotka yllättävät. **Docker toimii, kunhan daemon käynnistetään
ikkunan alussa** (ks. alla) — ensimmäinen versio tästä dokumentista luki `docker run
hello-world`in kaatumisen "Docker ei toimi Spritessä" -tulokseksi, vaikka syy oli vain
käynnistämätön daemon. Postgres sen sijaan on asennettava käsin, jos kohderepo tarvitsee
tietokannan.

## Pystytys

### 1. Sprite ja tunnistautumiset

```bash
sprite create claude-issue-runner        # tai: sprite list, jos on jo olemassa
sprite console -s claude-issue-runner
```

Spriten sisällä:

```bash
claude setup-token     # Claude Code -tunnistautuminen
gh auth login          # GitHub-tunnistautuminen
bash -lc 'node -v'     # ≥ 22.13, koska pnpm vaatii sen
```

Kaikki tämän dokumentin komennot voi ajaa myös ulkopuolelta ilman konsolia:

```bash
sprite exec -s claude-issue-runner -- bash -lc '<komento>'
sprite file push -s claude-issue-runner ./paikallinen /home/sprite/kohde
```

**Käytä `bash -lc`:tä.** Login-shell lataa `nvm`:n ja projektin `node_modules/.bin`in;
ilman sitä osuu helposti väärään Node-versioon.

### 2. Runner asennettuna

```bash
git clone git@github.com:Silon-Oy/claude-issue-runner.git ~/projektit/claude-issue-runner
~/projektit/claude-issue-runner/install.sh
```

**Ilman `--with-launchagents`** — plistit ovat macOS-kohtaisia, eikä ikkunamallissa
asenneta pollereita lainkaan. (systemd ei todennäköisesti toimi Spritessä, jolla on oma
palvelunhallintansa; tässä mallissa sillä ei ole väliä.)

Testit Linuxilla ajetaan env-eristyksellä, koska kolme testiä vuotaa koneellisen
env-tiedoston ilman sitä:

```bash
RUN_ISSUES_ENV_FILE=/nonexistent bash ~/projektit/claude-issue-runner/tests/run-all.sh
```

### 3. Kohderepo ja konfiguraatio

```bash
git clone git@github.com:Silon-Oy/<repo>.git ~/projektit/<repo>
```

**`~/.config/run-issues/env`** — koneelliset asetukset. macOS-oletukset eivät päde
Linuxissa, joten lokki- ja lokipolut on asetettava:

```bash
export RUN_ISSUES_CLAUDE_CMD=/home/sprite/.local/bin/claude   # ei npx-polulla
export RUN_ISSUES_LOCK_ROOT="$HOME/.local/state/run-issues/locks"
export RUN_ISSUES_LOG_DIR="$HOME/.local/state/run-issues/logs"

# Vain jos kohderepo tarvitsee Postgresin:
export PGHOST="127.0.0.1"
export PGPORT="5433"
export PGUSER="<db-user>"
export PGPASSWORD="<salasana>"
```

**`~/.config/run-issues/watchlist.json`** — kopioi `examples/`-mallista. Poimintalabel on
se, joka erottaa tämän koneen muista ajokoneista:

```json
{
  "default_labels": ["auto-run-ilkka"],
  "global_max_concurrent": 1,
  "repos": [
    { "path": "/home/sprite/projektit/myrepo",
      "labels": ["auto-run-ilkka"], "remotes": ["origin"] }
  ]
}
```

Labelit **ANDataan**, joten `["auto-run"]`-konetta vahtiva poller ja `["auto-run-ilkka"]`
-Sprite poimivat erilliset joukot. `global_max_concurrent: 1` aluksi — rinnakkaisuus on
helppo nostaa, vaikeampi perua.

> **Watchlist ei ole versionhallinnassa.** Se on koneellinen konfiguraatio
> `~/.config/run-issues/`:ssä. Jos Sprite luodaan uudelleen, se on kirjoitettava uudestaan
> — tämä dokumentti on sen ainoa muisti.

### 4. PostgreSQL (jos kohderepo tarvitsee)

Spritessä on vain client. Palvelin asennetaan ja klusteri siirretään sille portille, jota
`~/.config/run-issues/env` lupaa:

```bash
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-18

sudo sed -i 's/^port = 5432/port = 5433/' /etc/postgresql/18/main/postgresql.conf
sudo pg_ctlcluster 18 main start

sudo -u postgres psql -p 5433 -c \
  "CREATE ROLE <db-user> LOGIN SUPERUSER CREATEDB PASSWORD '<salasana>';"

PGPASSWORD='<salasana>' psql -h 127.0.0.1 -p 5433 -U <db-user> -d postgres -c 'select 1'
```

Asennus tulostaa `invoke-rc.d: policy-rc.d denied execution of start` — se on odotettua
(kontissa ei ole runlevelia) eikä estä mitään; `pg_ctlcluster` käynnistää klusterin
käsin.

**Viimeinen komento on se, joka ratkaisee.** Provision-hookin on tavoitettava kanta
**TCP:n yli käyttäjänä, jonka `PGUSER`/`PGPASSWORD` nimeävät** — paikallinen
`sudo -u postgres` -yhteys ei todista mitään hookin polusta.

#### Docker: daemon käynnistetään ikkunan alussa

Spritessä on Docker 29 ja Compose 2.40 valmiina, mutta **`dockerd` ei käynnisty koneen
mukana** eikä palaa checkpoint/restore-syklistä — sama ilmiö kuin Postgres-klusterilla.
Ilman daemonia jokainen `docker`-komento kaatuu riviin `failed to connect to the docker API
at unix:///var/run/docker.sock`, mikä näyttää siltä kuin Docker ei toimisi lainkaan.

Todennettu 27.8.2026 `iraudasoja/putkiwelho`n pystytyksessä (Docker Compose -pohjainen
WordPress-repo, jonka implementer ajaa `bin/up && bin/install`in Spritessä):

```bash
sudo dockerd >/tmp/dockerd.log 2>&1 &
docker run --rm alpine:3.20 echo docker-ok           # → docker-ok
docker run -d --name t -p 18080:80 nginx:alpine
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/   # → 200
docker rm -f t
```

Konttien ajo, kuvien lataus, `-p`-porttijulkaisu ja `curl localhost:<portti>` toimivat —
siis kaikki, mitä Compose-pohjaisen repon savutesti tarvitsee. Vartija kuuluu
`wake-run.sh`:ään Postgres-vartijan rinnalle (ks. osio 5): jos `docker info` ei vastaa,
käynnistä `sudo dockerd` taustalle ja odota enintään 30 s ennen kuin drain alkaa.

Kohderepon hookin ei silti kannata **olettaa** Dockeria: kestävä
`.claude/provision-test-env.sh` yrittää **TCP:tä ensin** ja `docker exec`-yhteyttä vasta
varamekanismina, jolloin se toimii natiivilla Postgresilla myös koneella, jolla daemon on
jäänyt käynnistämättä. Jos hook osaa vain `docker exec`in, lisää sille TCP-polku
tai Docker-vartija (daemon ei vastaa → skip, ei rc≠0) — **CI on silti laatuportti**, ja
`pr-watch` mergeää vasta kun CI on vihreä, joten menetys on palautesyklin nopeus eikä
lopputuloksen oikeellisuus.

#### E2E ei aja Spritessä — Chromium kaatuu

Playwrightin selaimet ovat imagessa valmiina, mutta **headless Chromium kaatuu jokaisella
spektillä** Spriten hiekkalaatikossa. Todennettu 27.8.2026 ajossa `20260827-072017`
(kohderepon issue): implementer erotti ympäristövian omasta virheestään
toistamalla kaatumisen **koskemattomalla spektillä**, eli vika ei ollut sen kirjoittamissa
testeissä.

Tämä on hyvä tapa varmistaa asia myös itse ennen kuin lähtee korjaamaan sovelluskoodia:
jos jokin spekti kaatuu Spritessä, aja sama koskemattomalla spektillä. Kaatuuko sekin?
Silloin kyse on ympäristöstä.

Käytännön seuraus ajokoneen valintaan:

| Vaihe | Ajaako Spritessä |
|---|---|
| `pnpm typecheck` | ✅ |
| `pnpm test` (unit, kaikki paketit) | ✅ |
| `pnpm test:e2e` (Playwright) | ❌ |

**Tämä on syy, miksi CI on laatuportti eikä muodollisuus.** Ajokoneen testit ovat
implementerin palautesykli, eivät hyväksymiskriteeri: E2E-kattavuus todennetaan vasta
PR:n CI-ajossa, ja `pr-watch` mergeää vasta kun se on vihreä. Älä siis lue Spritessä
onnistunutta ajoa todisteeksi siitä, että E2E menee läpi — sitä tietoa siellä ei
syntynyt lainkaan.

Jos E2E:n saaminen toimimaan Spritessä on joskus tarpeen, lähtökohta on Chromiumin
sandbox-lippujen ja jaetun muistin (`/dev/shm`) tutkiminen — mutta tätä ei ole yritetty,
eikä se ole tarpeen niin kauan kuin CI ajaa spektit.

### 4b. Kohderepon työkaluketju — asenna ennen kuin repo saa lockfilen

Orkestraattorin **S7b env-bootstrap** lukee kohderepon juuren: `composer.lock` → ajaa
`composer install`, `package.json` (+ lockfile) → ajaa `pnpm`/`npm`/`yarn install`
(`lib/env-bootstrap.sh`). Se tekee tämän **fail-fast ennen implementeria**: jos työkalu
puuttuu, ajo päättyy tilaan `env_bootstrap_failed`, issue saa `needs-human`in ja
tilannekommentin, eikä implementer-budjettia kulu. Pollerikoneella tämä on harvinaista, koska
työkalut on asennettu jo projektin takia; Spritessä se osuu heti, kun **jokin aiempi ajo tuo
lockfilen repoon**.

Todennettu 27.8.2026 (`iraudasoja/putkiwelho`): CI-issuen PR toi `composer.json` +
`composer.lock`in `main`iin, ja seuraava ajo kaatui ennen toteutusta lokiin

```
timeout: failed to execute process: No such file or directory (os error 2)
```

— `timeout` ei löytänyt `composer`-binääriä (rc 127). Spritessä ei ollut PHP:tä lainkaan.
Korjaus on asentaa työkaluketju etukäteen ja **todeta se samalla komennolla, jota
env-bootstrap käyttää**:

```bash
# PHP-projektit (WordPress, Laravel, phpcs …)
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y php-cli php-xml php-mbstring php-curl composer
cd ~/projektit/<repo> && composer install --no-interaction   # sama komento kuin S7b:ssä

# Node-projektit: node ja pnpm ovat imagessa valmiina (ks. valmiustaulukko),
# mutta `bash -lc` on pakollinen, jotta nvm:n Node on PATHissa.
```

Ubuntun `php-cli` on tällä hetkellä 8.5 — kelpaa dev-riippuvuuksien (phpcs, wpcs) ajoon
vaikka CI lukitsisi toisen version, koska Spritessä PHP:tä käytetään vain lintaukseen; itse
sovellus ajaa kontissa omalla PHP:llään.

**Kun este on poistettu, Spritessä ei ole polleria, joka tekisi luvatun "kommentoi issueen —
ajo yritetään uudelleen" -kierroksen.** Siivoa ajo käsin (`cleanup-run.sh --issue N --force
--yes` poistaa `auto-claimed`in ja `needs-human`in) ja herätä kone — seuraava drain poimii
issuen normaalisti.

### 5. Ajuriskripti ja herätyskäärä

`drain-queue.sh` ei kuulu runner-pakettiin (se asuu ylläpitäjän dotfileissa), joten se
kopioidaan Spriteen:

```bash
sprite file push -s claude-issue-runner ~/.dotfiles/bin/drain-queue.sh \
  /home/sprite/bin/drain-queue.sh
sprite exec -s claude-issue-runner -- bash -lc 'chmod +x ~/bin/drain-queue.sh'
```

Sen rinnalle `~/bin/wake-run.sh`, joka tekee yhden ajoikkunan:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Klusteri ei nouse itsestään checkpoint/restore-syklin jälkeen, ja provision-hook
# tavoittaa kannan TCP:llä — varmista se ennen kuin ajo alkaa.
pg_isready -h 127.0.0.1 -p 5433 -q || sudo pg_ctlcluster 18 main start
pg_isready -h 127.0.0.1 -p 5433 -q

# Docker-daemon ei myöskään nouse itsestään. Compose-pohjainen kohderepo tarvitsee sen
# ennen kuin implementer ajaa bin/up:n — käynnistä ja odota, kaadu jos se ei nouse.
if ! docker info >/dev/null 2>&1; then
  sudo dockerd >/tmp/dockerd.log 2>&1 &
  for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
fi
docker info >/dev/null   # kova virhe, jos daemon ei noussut — syy on /tmp/dockerd.log:ssa

# Label per repo: drain-queue.sh kieltäytyy tyhjästä RUN_ISSUES_LABELS_CSV:stä (ks. alla),
# ja eri repoilla voi olla eri poimintalabel. Epäonnistunut drain ei saa ohittaa seuraavaa.
rc=0
RUN_ISSUES_LABELS_CSV=auto-run-ilkka "$HOME/bin/drain-queue.sh" "$HOME/projektit/myrepo" || rc=$?
RUN_ISSUES_LABELS_CSV=auto-run       "$HOME/bin/drain-queue.sh" "$HOME/projektit/myapp"  || rc=$?
exit "$rc"
```

Koska Spritessä ei ole `pr-watch`-polleria, ikkunan kannattaa myös skannata valmiit ajot
(`pr-watch.sh <repo> scan`) ennen drainia — edellisen ikkunan vihreät PR:t mergeytyvät ja
ketjun seuraava lenkki vapautuu — ja drainin jälkeen uusintayrityksin niin kauan kuin
`pr-watch` palauttaa 4 (CI kesken). Muuten `auto-merge`-PR:t jäävät odottamaan ihmistä.

**Label asetetaan käärässä, ei skriptissä.** `drain-queue.sh` kieltäytyy (exit 1) tyhjästä
`RUN_ISSUES_LABELS_CSV`-arvosta tarkoituksella: `pick_oldest_candidate` tulkitsee tyhjän
label-listan *"ei label-suodatinta"* — ei "ei osumia" — ja poimisi silloin repon vanhimman
avoimen issuen labeleista riippumatta.

## Ajon käynnistys

```bash
sprite exec -s claude-issue-runner -- bash -lc '~/bin/wake-run.sh'
```

**Komento on synkroninen tarkoituksella — yhteyden on pysyttävä auki ikkunan loppuun.**
"Käyttämättömyys", josta Sprite nukahtaa, tarkoittaa *ulkoisen yhteyden* puuttumista, ei
CPU:n joutilaisuutta: kone jäätyy noin 30 s kuluttua siitä, kun viimeinen `sprite exec`-
tai `console`-sessio sulkeutuu, **vaikka sisällä olisi prosesseja kesken**. `nohup`/`setsid`-
irrotettu `wake-run.sh` näyttää `pgrep`issä käynnissä olevalta, mutta etenee vain niinä
sekunteina, kun joku sattuu avaamaan yhteyden.

Todennettu 27.8.2026 (`iraudasoja/putkiwelho` #11): irrotettu ajo tuotti `state.jsonl`:ään
tapahtumat 16:39:37, 16:44:35 ja 16:49:25 — täsmälleen kolmen käsin tehdyn `sprite exec`
-tarkistuksen hetket, muuten ei mitään 15 minuuttiin. Kun rinnalle avattiin yhteys, joka
pysyy auki niin kauan kuin orkestraattori elää, ajo eteni saman tien viisi vaihetta:

```bash
# Keepalive jo irrotetulle ajolle — poistuu, kun orkestraattori päättyy
sprite exec -s claude-issue-runner -- bash -lc \
  'while pgrep -f orchestrate.sh >/dev/null; do sleep 20; done'
```

Sama pätee ulkoiseen herätykseen: cron-job ei voi olla fire-and-forget-kutsu, vaan sen on
pidettävä sessio auki siihen asti, että `wake-run.sh` palaa.

#### Katkennut yhteys tappaa ikkunan, ellei sitä irroteta sessiosta

Jäätyminen ei ole katkoksen pahin seuraus. Kun kone myöhemmin herätetään, **kuolleen session
SIGHUP purkautuu viiveellä** ja osuu kaikkeen, mitä `sprite exec` käynnisti: `wake-run.sh`,
`drain-queue.sh` ja orkestraattori kuolevat, ja jäljelle jää **orpo implementer-prosessi,
jonka tulosta kukaan ei lue**. Vaiheen sisällä kuollut ajo ei ole jatkettavissa (ks.
sudenkuoppa 7) — vain worktreen commitit säilyvät.

Todennettu kahdesti 27.8.2026 (`iraudasoja/putkiwelho`, verkkovirheet
`read tcp …: operation timed out` ja `i/o timeout`): ensimmäisellä kerralla ajo #6 menetettiin
S8:n keskeltä, toisella kerralla ajo #10 oli 150 työkalukutsun päässä valmiista ja jouduttiin
viimeistelemään käsin sen worktreessä.

Korjaus on `wake-run.sh`:n alussa — **kaksi riviä, jotka irrottavat ikkunan kutsujan
sessiosta ilman että lokitulostus katoaa**:

```bash
set -euo pipefail

trap "" HUP
if [ "${WAKE_RUN_DETACHED:-0}" != "1" ] && command -v setsid >/dev/null 2>&1; then
  export WAKE_RUN_DETACHED=1
  exec setsid -w "$0" "$@"     # oma sessio; -w odottaa, joten exit-koodi ja loki säilyvät
fi
```

`setsid -w` antaa ikkunalle oman session ja prosessiryhmän, `trap "" HUP` suojaa itse
skriptin, ja `-w` pitää `sprite exec`in edelleen synkronisena: näet lokin ja saat exit-koodin
kuten ennenkin. Katkoksen jälkeen ajo on yhä käynnissä — kiinnitä keepalive takaisin, älä
siivoa. Vartija `WAKE_RUN_DETACHED` estää ikuisen uudelleen-exec-silmukan.

Tarkista asennuksen jälkeen, että irrotus todella tapahtui — pid:n on oltava oma sid, ja
`SigIgn`-maskin bitin 0 (SIGHUP) on oltava asetettu:

```bash
ps -eo pid,sid,args | grep "[w]ake-run.sh"     # pid == sid → oma sessio
grep SigIgn /proc/<pid>/status                 # …0005 → HUP ignoroitu
```

Lapsiprosessien (orkestraattori, `claude`) on oltava samassa sidissä; vain lokia kirjoittava
`tee` jää kutsujan sessioon, ja senkin kuolema on harmiton.

Ikkuna ajaa `RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto` -tilassa kuten poller — muuten
ajo pysähtyisi review-porttiin eikä kukaan olisi vastaamassa. Rajat: `DRAIN_BUDGET_SECONDS`
(3600) ei keskeytä kesken olevaa ajoa vaan estää uuden aloittamisen, `DRAIN_MAX_RUNS` (20)
on takaportti, ja kolme peräkkäistä exit 9:ää (avoin riippuvuus) lopettaa repon.

**Ulkoinen herätys on viimeinen askel, ei ensimmäinen.** Aja ensin vähintään yksi valvottu
päästä-päähän-ajo yllä olevalla komennolla. Vasta sen jälkeen automaattinen herätys
(GitHub Actions -cron tai launchd-job, joka kutsuu Spriten APIa).

## Verifiointi

```bash
# 1. Poimintahaku toimii ja työnjako pitää
sprite exec -s claude-issue-runner -- bash -lc '
  cd ~/projektit/myrepo
  source ~/.claude/scripts/run-issues/lib/issue.sh
  echo "ilkka   -> [$(pick_oldest_candidate "$PWD" "auto-run-ilkka" "Silon-Oy/myrepo")]"
  echo "auto-run -> [$(pick_oldest_candidate "$PWD" "auto-run" "Silon-Oy/myrepo")]"'

# 2. Preflight nimeää puuttuvat riippuvuudet
sprite exec -s claude-issue-runner -- bash -lc \
  'cd ~/projektit/myrepo && ~/.claude/scripts/run-issues/orchestrate.sh'

# 3. Claude-CLI vastaa sillä komennolla, jonka env nimeää
sprite exec -s claude-issue-runner -- bash -lc \
  'source ~/.config/run-issues/env && $RUN_ISSUES_CLAUDE_CMD --version'
```

Testin 1 pitää antaa oman labelin kohdalla issuenumero ja toisen koneen labelin kohdalla
tyhjä. **Tämä on koko työnjaon perusta** — jos molemmat palauttavat saman numeron, koneet
kilpailevat samasta työstä.

## Sudenkuopat

1. **GitHubin hakuindeksi laahaa.** Vastalabeloitu issue ei näy poiminnassa heti — mitattu
   viive noin 25 s. Tyhjä tulos välittömästi labeloinnin jälkeen **ei** tarkoita että
   poiminta on rikki. Odota ja kysy uudelleen.

2. **Postgres-klusteri ja Docker-daemon eivät nouse itsestään.** Sprite nukkuu ja herää;
   kumpikaan ei välttämättä palaa mukana. Siksi `wake-run.sh` alkaa `pg_isready`- ja
   `docker info` -vartijoilla — älä poista niitä. Puuttuva daemon näkyy rivinä
   `failed to connect to the docker API at unix:///var/run/docker.sock`, ei "Docker ei
   toimi Spritessä" -tuloksena.

3. **`hostname -s` on omistajuuden perusta.** `run.json.host` ja `cleanup-run.sh`:n
   host-portti nojaavat siihen. Jos Sprite luodaan uudelleen ja nimi muuttuu, edellisen
   inkarnaation keskeneräiset ajot jäävät siivoamatta — `cleanup-run.sh` kieltäytyy
   "vieras host" -perusteella. Todennettu nimi tässä pystytyksessä: `claude-issue-runner`.

4. **Assignaatio ei reititä työtä.** Poiminta suodattaa labeleilla, ei assigneella (#99:n
   jälkeen varaus on `auto-claimed`-label, ja `no:assignee` poistui hausta). Assignattu
   issue lähtee ajoon siinä missä assignoimatonkin. Työnjako koneiden välillä tehdään
   **vain** labeleilla, kunnes reititys on muuta kautta toteutettu.

5. **Nukkuva kone ei tee mitään — eikä irrotettu prosessi pidä sitä hereillä.** Ikkunamalli
   tarkoittaa, että labeloitu issue jää odottamaan seuraavaa herätystä. Jos issuen pitää
   lähteä heti, herätä kone käsin, ja pidä yhteys auki ikkunan loppuun: `nohup`-irrotettu
   `wake-run.sh` jäätyy ~30 s kuluttua yhteyden sulkeuduttua (ks. "Ajon käynnistys"). Jumiin
   näyttävä ajo, jonka `state.jsonl`-aikaleimat osuvat omiin `sprite exec` -kutsuihisi, on
   tämä ilmiö, ei runnerin vika.

   **Katkos ei kuitenkaan vain jäädytä: herätessä kuolleen session SIGHUP tappaa ikkunan**,
   ellei `wake-run.sh` irrota itseään (`trap "" HUP` + `setsid -w`, ks. "Ajon käynnistys").
   Ilman sitä jäljelle jää orpo `claude`-prosessi, jonka tulosta kukaan ei lue, ja ajo on
   menetetty — vaiheen sisällä kuollut ajo ei ole jatkettavissa (sudenkuoppa 7).

6. **Selain-OAuth-istunto ei kelpaa ajokoneelle — käytä `claude setup-token`ia.**
   `claude`-CLI:n tavallinen istunto umpeutuu vuorokaudessa. Ajokoneella se tarkoittaa, että
   ajo kaatuu **vasta S6:ssa** riviin `Failed to authenticate: OAuth session expired and
   could not be refreshed` — siis claimin, worktreen ja haaran luonnin jälkeen. Pitkäikäinen
   token (`setup-token`, voimassa vuoden) menee `~/.config/run-issues/env`:iin muodossa
   `export CLAUDE_CODE_OAUTH_TOKEN=…`, jonka orkestraattori sourcaa ennen jokaista vaihetta.

   **S0-preflight ei suojaa tältä:** `claude check: have` perustuu `--version`-kutsuun, joka
   onnistuu myös tunnistautumattomalla CLI:llä. Todellinen tarkistus on kutsu, joka vaatii
   tunnistautumisen:

   ```bash
   source ~/.config/run-issues/env
   echo "sano tasan sana: OK" | $RUN_ISSUES_CLAUDE_CMD -p
   ```

   Aja tämä aina tokenin vaihdon jälkeen ja aina kun ajo kaatuu selittämättä S6:ssa.

7. **Vaiheen sisällä kuollut ajo ei ole jatkettavissa.** `--restart` vaatii tilan
   `timed_out`, `--continue` tilan `awaiting_clarification` ja `--resume` review-portin.
   Kesken vaihetta kaatunut ajo jää tilaan `initialized`, johon mikään lipuista ei osu:
   ainoa ulospääsy on `cleanup-run.sh --issue N --force --yes` ja uusi ajo alusta.

8. **Lockfile repossa = työkalu Spritessä.** Heti kun jokin ajo tuo `composer.lock`in tai
   `package.json`in kohderepoon, env-bootstrap vaatii vastaavan työkalun jokaisessa
   seuraavassa ajossa. Puuttuva `composer` näkyy rivinä `timeout: failed to execute process`
   (rc 127) — ei "composer install epäonnistui". Asenna työkaluketju etukäteen (osio 4b) ja
   muista, että `needs-human`-tilan purku on Spritessä käsityötä: `cleanup-run.sh --force`
   ja uusi herätys.
