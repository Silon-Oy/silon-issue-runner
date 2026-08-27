# Ajokone Fly.io Spritessä — ikkunamalli

> **Tila:** todennettu käytännössä 27.8.2026 pystyttämällä `claude-issue-runner`-niminen
> Sprite ajamaan `Silon-Oy/customer-a-report`ia. Kaikki tämän dokumentin komennot on ajettu
> oikeaa Spriteä vasten, ei suunniteltu paperilla.

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
| Playwright-selaimet | ✅ `~/.cache/ms-playwright` (chromium + headless shell + ffmpeg) |
| `sudo` | ✅ ilman salasanaa |
| `apt-get` | ✅ |
| **Docker** | ❌ `docker run hello-world` epäonnistuu — käyttäjäkoodi ajaa jo konttikerroksessa |
| **PostgreSQL-palvelin** | ❌ vain `postgresql-client-18`, ei `postgres`-binääriä |

Kaksi viimeistä ovat ne, jotka yllättävät. **Docker ei ole este** (ks. alla), mutta
Postgres on asennettava käsin, jos kohderepo tarvitsee tietokannan.

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
export PGUSER="customer-a"
export PGPASSWORD="<salasana>"
```

**`~/.config/run-issues/watchlist.json`** — kopioi `examples/`-mallista. Poimintalabel on
se, joka erottaa tämän koneen muista ajokoneista:

```json
{
  "default_labels": ["auto-run-ilkka"],
  "global_max_concurrent": 1,
  "repos": [
    { "path": "/home/sprite/projektit/customer-a-report",
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
  "CREATE ROLE customer-a LOGIN SUPERUSER CREATEDB PASSWORD '<salasana>';"

PGPASSWORD='<salasana>' psql -h 127.0.0.1 -p 5433 -U customer-a -d postgres -c 'select 1'
```

Asennus tulostaa `invoke-rc.d: policy-rc.d denied execution of start` — se on odotettua
(kontissa ei ole runlevelia) eikä estä mitään; `pg_ctlcluster` käynnistää klusterin
käsin.

**Viimeinen komento on se, joka ratkaisee.** Provision-hookin on tavoitettava kanta
**TCP:n yli käyttäjänä, jonka `PGUSER`/`PGPASSWORD` nimeävät** — paikallinen
`sudo -u postgres` -yhteys ei todista mitään hookin polusta.

#### Miksi Docker ei ole este

`customer-a-report`in `.claude/provision-test-env.sh` yrittää **TCP:tä ensin** ja `docker exec`
-yhteyttä vasta varamekanismina (PR #368). Natiivi Postgres täyttää ensisijaisen polun,
joten S7c ei blokkaa ajoa vaikka Dockeria ei ole.

Jos kohdereposi hook osaa vain `docker exec`in, vaihtoehtoja on kaksi: lisää sille
TCP-polku, tai lisää hookiin Docker-vartija (puuttuva Docker → skip, ei rc≠0). Jälkimmäinen
tarkoittaa ettei implementer aja testejä paikallisesti — **CI on silti laatuportti**, ja
`pr-watch` mergeää vasta kun CI on vihreä, joten menetys on palautesyklin nopeus eikä
lopputuloksen oikeellisuus.

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

export RUN_ISSUES_LABELS_CSV=auto-run-ilkka
exec "$HOME/bin/drain-queue.sh" "$HOME/projektit/customer-a-report"
```

**Label asetetaan käärässä, ei skriptissä.** `drain-queue.sh` kieltäytyy (exit 1) tyhjästä
`RUN_ISSUES_LABELS_CSV`-arvosta tarkoituksella: `pick_oldest_candidate` tulkitsee tyhjän
label-listan *"ei label-suodatinta"* — ei "ei osumia" — ja poimisi silloin repon vanhimman
avoimen issuen labeleista riippumatta.

## Ajon käynnistys

```bash
sprite exec -s claude-issue-runner -- bash -lc '~/bin/wake-run.sh'
```

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
  cd ~/projektit/customer-a-report
  source ~/.claude/scripts/run-issues/lib/issue.sh
  echo "ilkka   -> [$(pick_oldest_candidate "$PWD" "auto-run-ilkka" "Silon-Oy/customer-a-report")]"
  echo "auto-run -> [$(pick_oldest_candidate "$PWD" "auto-run" "Silon-Oy/customer-a-report")]"'

# 2. Preflight nimeää puuttuvat riippuvuudet
sprite exec -s claude-issue-runner -- bash -lc \
  'cd ~/projektit/customer-a-report && ~/.claude/scripts/run-issues/orchestrate.sh'

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

2. **Postgres-klusteri ei nouse itsestään.** Sprite nukkuu ja herää; klusteri ei
   välttämättä palaa mukana. Siksi `wake-run.sh` alkaa `pg_isready`-vartijalla — älä poista
   sitä.

3. **`hostname -s` on omistajuuden perusta.** `run.json.host` ja `cleanup-run.sh`:n
   host-portti nojaavat siihen. Jos Sprite luodaan uudelleen ja nimi muuttuu, edellisen
   inkarnaation keskeneräiset ajot jäävät siivoamatta — `cleanup-run.sh` kieltäytyy
   "vieras host" -perusteella. Todennettu nimi tässä pystytyksessä: `claude-issue-runner`.

4. **Assignaatio ei reititä työtä.** Poiminta suodattaa labeleilla, ei assigneella (#99:n
   jälkeen varaus on `auto-claimed`-label, ja `no:assignee` poistui hausta). Assignattu
   issue lähtee ajoon siinä missä assignoimatonkin. Työnjako koneiden välillä tehdään
   **vain** labeleilla, kunnes reititys on muuta kautta toteutettu.

5. **Nukkuva kone ei tee mitään.** Ikkunamalli tarkoittaa, että labeloitu issue jää
   odottamaan seuraavaa herätystä. Jos issuen pitää lähteä heti, herätä kone käsin.
