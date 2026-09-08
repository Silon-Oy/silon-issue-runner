# claude-issue-runner

Itsenäisesti asennettava paketti `/run-issues`-orkestraattorille: GitHub-issuesta valmiiseen
pull requestiin ilman ihmistä silmukassa, sekä PR-vahti, joka vie PR:n merge-tilaan asti.

Tämä README on **ihmiselle**: asennus, turvamalli ja perustelut sille miksi järjestelmä
käyttäytyy kuten käyttäytyy. [`CLAUDE.md`](CLAUDE.md) on **agentille**: invariantit ja mitatut
rajoitteet, ei täyttä referenssiä.

**Lähdejärjestys, kun sama fakta on kahdessa paikassa:** koodi ja skriptin otsikkokommentti
ovat lähde. Tämä README on exit-koodien vartioitu peilaus (`tests/test-readme.sh` johtaa ne
skripteistä) ja `docs/env-reference.md` ympäristömuuttujien peilaus. `CLAUDE.md` on lähde vain
sille, mitä koodista ei voi lukea: invariantit, mitatut rajoitteet ja tietoiset ei-päätökset.

**Lue [turvamalli](#7-turvamalli) ennen kuin ajat `install.sh`:n.** Paketti ajaa Claude Codea
ilman lupakyselyjä ja suorittaa kohderepon omaa shell-koodia. Se on suostumuskysymys, ei
tekninen yksityiskohta.

---

## 1. Mitä tämä paketti on

Kaksi erillistä pipelineä, jotka eivät jaa tilaa keskenään:

- **Orkestraattori** (`orchestrate.sh`) — yksi issue → yksi ajo → yksi PR. Tilakone, joka
  poimii issuen, ottaa lukon, luo worktreen ja haaran, ajaa katselmoinnin ja implementerin,
  ja avaa PR:n. Kaavio: [`docs/diagrams/run-issues-state-machine.mmd`](docs/diagrams/run-issues-state-machine.mmd).
- **PR-vahti** (`pr-watch.sh`) — PR → merge. Odottaa CI:n, ratkoo tarvittaessa
  rebase-konfliktin ja mergeää. Kaavio: [`docs/diagrams/pr-watch-state-machine.mmd`](docs/diagrams/pr-watch-state-machine.mmd).

Kaksi käyttötapaa:

- **Interaktiivinen** — Claude Coden slash-komennot `/issue-runner:run-issue #N` ja
  `/issue-runner:pr-watch` omalla koneella, ihminen katsoo vierestä.
- **Poller** — `poller.sh` ja `pr-watch-poller.sh` LaunchAgenteina, jotka käyvät watchlistin
  repot läpi määrävälein ilman ihmistä. Tämä on se tila, jossa turvamallin kysymykset ovat
  aidosti kiinnostavia.

Paketti ei sisällä henkilökohtaista konfiguraatiota: ei watchlistiä (vain skeemaesimerkki
[`examples/`](examples)-hakemistossa), ei koneistokohtaisia env-tiedostoja, ei salaisuuksia.

Paketin lisenssi on **Apache-2.0** ([`LICENSE`](LICENSE), tekijänoikeus Silon Oy, [`NOTICE`](NOTICE)).
Kehitys tapahtuu yksityisessä repossa, jonka issuet ja PR:t nimeävät asiakkaita; julkinen repo on
sen **yksisuuntainen peili**, jonka historia on uudelleenkirjoitettu ilman noita nimiä ([`docs/usage-reference.md`](docs/usage-reference.md)).
Peiliin avattu issue on tervetullut; peiliin avattu PR siirretään upstreamiin käsin.

---

## 2. Riippuvuudet

Riippuvuuslista **haarautuu käyttötavan mukaan**. Pelkkä interaktiivinen käyttö vaatii
vähemmän kuin poller, ja ero on syytä tietää etukäteen: pollerin puuttuva riippuvuus ei
tuota virhettä vaan hiljaisuutta.

### Interaktiivinen käyttö (pakolliset)

| Työkalu | Asennus |
|---|---|
| `git` | `brew install git` |
| `gh` | `brew install gh` |
| `jq` | `brew install jq` (**Windows: 1.7 tai uudempi**, ks. osio 3.2) |
| `npx` / node | `brew install node` (tai `nvm install --lts`) |
| Claude CLI | `npm i -g @anthropic-ai/claude-code` |
| `gh`-kirjautuminen | `gh auth login` |

Nämä tarkistaa orkestraattorin **S0-preflight-portti** (`lib/preflight.sh`,
`orchestrate.sh`). Puuttuva pakollinen riippuvuus ⇒ **exit 8**, ja portti sijaitsee ennen
kaikkia sivuvaikutuksia: mitään ei lukita, claimata eikä luoda. Virheilmoitus nimeää sekä
puuttuvan työkalun että sen korjauskomennon. Kaavio:
[`docs/diagrams/preflight-gate-failure-map.mmd`](docs/diagrams/preflight-gate-failure-map.mmd).

Claude CLI:tä ei tarkisteta `command -v`:llä vaan aidolla `--version`-kutsulla, koska
oletuskutsu `npx --no-install @anthropic-ai/claude-code` exittaa 127 vaikka `npx` itse on
polulla. `gh`-kirjautuminen tarkistetaan komennolla `gh auth token` eikä `gh auth status`:lla
— jälkimmäinen kutsuu API:a, jolloin verkkokatkosta tulisi uusi tapa estää ajon käynnistyminen.

### Valinnainen

`timeout` / `gtimeout` (`brew install coreutils`). Puuttuessa portti antaa **varoituksen**,
ei virhettä — mutta silloin claude-kutsut ajetaan **ilman aikakattoa** ja voivat jäädä
roikkumaan. Poller nojaa erikseen omaan liveness-rajaansa (`RUN_ISSUES_STALE_AFTER`).

### Pollerikäyttö (edellisten lisäksi)

| Vaatimus | Huomio |
|---|---|
| `tmux` | `brew install tmux` |
| `poller.env` | koneen konfiguraatio, ks. osio 4 |
| watchlist | mitkä repot pollataan, ks. osio 4 |

**`tmux` ei ole S0-portissa.** Se on pollerin oma kova ehto, ja puuttuessaan poller kirjoittaa
rivin lokiin ja **exittaa 0** — eli näyttää onnistuneelta. Sama koskee puuttuvaa tai viallista
watchlistiä ja väärää konenimeä. Jos poller "ei tee mitään", lue loki ennen kuin etsit vikaa
muualta (osio 9).

---

## 3. Asennus

Paketti kloonataan mihin tahansa, ja `install.sh` linkittää sen Claude-assetit
`$HOME/.claude`-hakemistoon tiedosto kerrallaan.

```bash
bash install.sh --dry-run     # tulostaa suunnitelman, ei kirjoita mitään
bash install.sh               # soveltaa suunnitelman
bash install.sh --with-launchagents   # + poller-plistit, vain jos ajat pollereita
```

Mitä asennin tekee:

- `~/.claude/commands/issue-runner/` — per-tiedosto-symlink jokaiselle paketin
  `commands/issue-runner/*.md`-tiedostolle. Alihakemisto on kutsumuodon lähde: Claude Code
  johtaa nimiavaruuden siitä, joten komennot kutsutaan muodossa `/issue-runner:<nimi>` eikä
  yleisnimellä, jonka mikä tahansa muu lähde voi vallata jaetussa hakemistossa. Lähdejoukko on
  glob, joten uusi komento tulee asennukseen pelkällä nimeämisellä. Paketin omistamat
  symlinkit, joita paketti ei enää toimita, siivotaan — myös vanhat litteät linkit suoraan
  `~/.claude/commands/`-hakemistossa, jottei kone kanna sekä `/new-epic`iä että
  `/issue-runner:new-epic`iä. Vieraat tiedostot ja vieraiden lähteiden symlinkit jäävät
  koskematta. Sama siivous kohdistuu myös
  `~/.claude/agents/`-hakemistoon, johon paketti **ei enää asenna mitään**: se toimitti
  aiemmin agenttitehtaan neljä alaagenttia, ja niiden linkit poistetaan koneilta joilla ne
  yhä ovat. Tyhjää hakemistoa ei luoda koneelle, jolla sitä ei ole.
- `~/.claude/skills/` — per-hakemisto-symlink jokaiselle paketin skillille (linkki on
  hakemistotasolla, koska skill on `<nimi>/SKILL.md` liitteineen). Sama omistajuussääntö ja
  siivous kuin yllä, mutta vieras `skills`-hakemisto tuottaa vain `CONFLICT`-rivin ja
  exit-koodin 4 — se ei kaada agenttien ja komentojen asennusta ([`docs/usage-reference.md`](docs/usage-reference.md)).
- `~/.claude/scripts/run-issues` — **ehdollinen** sidonta. Jos polku jo toimii, se jätetään
  rauhaan. Jos sitä ei ole ja asentaja voi omistaa sen, luodaan symlink paketin juureen.
- `~/Library/LaunchAgents/` — vain `--with-launchagents`. Kaavio:
  [`docs/diagrams/install-plan-apply-flow.mmd`](docs/diagrams/install-plan-apply-flow.mmd).

### Asentimen exit-koodit

Oma avaruus. **Älä sekoita** orkestraattorin tai PR-vahdin koodeihin. Taulukko asuu muiden
skriptien exit-koodien kanssa samassa hakuteoksessa:
[`docs/troubleshooting.md`](docs/troubleshooting.md).

**Exit 2 ei ole vika vaan haluttu turvakäyttäytyminen.** Se tarkoittaa, että asentaja löysi
polun jonka omistaa joku muu, ja jätti koko puun koskematta: nolla muutosta, ei
puoliasennusta. Korjaus on siirtää vieras tiedosto pois tieltä ja ajaa asennus uudelleen.

Yksi erikoistapaus kannattaa tunnistaa: jos `~/.claude/commands` on **kokonainen
hakemistosymlinkki** (dotfiles-asetelma, jossa koko hakemisto tulee muualta), asentaja
kieltäytyy aina. Korjaus kuuluu kyseiseen dotfiles-repoon: hakemisto korvataan tavallisella
hakemistolla, jossa on per-tiedosto-symlinkit. **Puhtaalla koneella** hakemistot ovat
tavallisia hakemistoja tai puuttuvat, jolloin asennus menee läpi normaalisti.

Toinen exit 2:n syy ei koske polkua vaan **ympäristöä: `ln -s` ei kaikkialla tuota aitoa
symlinkkiä.** Windowsin Git Bash hyväksyy komennon ja tekee hiljaa kopion, ellei Developer Mode
ole päällä ja `MSYS=winsymlinks:nativestrict` asetettuna. Asentaja koettaa kyvyn
suunnitteluvaiheen alussa väliaikaishakemistossa — ei `$HOME`-puussa — ja kieltäytyy ennen
ainuttakaan kirjoitusta, jos koetus epäonnistuu. Syy on sama omistajuussääntö kuin yllä:
omistajuus luetaan symlinkin kohteesta, joten kopio näyttäisi seuraavalle ajolle vieraalta
tiedostolta ja se kieltäytyisi väärästä syystä toisessa kohdassa. Korjaus:

```bash
# Windows, Git Bash: Developer Mode päälle asetuksista, sitten
MSYS=winsymlinks:nativestrict bash install.sh
```

Onnistuneen koetuksen tulos näkyy myös `--dry-run`-ajossa rivillä `symlink capability: ok`.

Kaksi rajoitetta:

- `--with-launchagents` **ei kutsu `launchctl`ia** — se deployaa plist-tiedostot ja tulostaa
  `launchctl`-komennot, jotka ajat itse. Perustelu: `CLAUDE.md` §10.
- `install.sh --uninstall` **puuttuu**. Paketin omistamat symlinkit poistetaan toistaiseksi
  käsin.

### 3.1 Linux-ajokone (VPS)

> **Tila: verifioimaton.** Tämä osio on johdettu koodista ja plisteistä, ei ajettu läpi
> Linuxilla. Riippuvuustaulukko ja yksikkötiedostot on tarkistettu lähdettä vasten,
> mutta paketilla ei ole Linux-CI:tä eikä `tests/run-all.sh`:ta ole ajettu siellä.
> Ensimmäinen läpiajo saa korjata tätä osiota.

Paketti on kirjoitettu macOS-koneelle, mutta ajokone voi olla Linux-VPS — esimerkiksi
silloin kun useampi kehittäjä haluaa oman ajokapasiteetin. Monikonemalli itsessään on
kunnossa: **assignaatio on koneiden välinen varausmekanismi** (osio 6.4) ja `run.json.host`
host-porttaa siivouksen, joten kaksi konetta voi pollata samoja repoja törmäämättä.

**Mikä eroaa macOS:stä**

| Sidos | Linuxilla |
|---|---|
| `stat -f` | Hoidettu — `uname -s` -haara GNU:n `stat -c`:hen |
| Lukot | Hoidettu — `uname -s` -haara: oletus on `${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/locks`. `RUN_ISSUES_LOCK_ROOT` yhä ohittaa |
| Lokit | Hoidettu — sama haara: oletus on `${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/logs`. `RUN_ISSUES_LOG_DIR` yhä ohittaa |
| Status-välimuisti | Osittain — `XDG_CACHE_HOME` luetaan, mutta asettamattoman varapolku on yhä `$HOME/Library/Caches`. `RUN_ISSUES_STATUS_CACHE_FILE` ohittaa |
| `gtimeout` / coreutils | Helpompi — `timeout` on natiivi |
| **LaunchAgentit + `plutil`** | **Ainoa aito puute.** Korvataan systemd user -yksiköillä, ks. alla. `--with-launchagents` on macOS-polku; älä käytä sitä Linuxilla |

**systemd user -yksiköt.** Mallit: [`examples/systemd/`](examples/systemd/). Ne on johdettu
plisteistä: kolme timeriä (300 s) ja yksi `Restart=always`-palvelu.

```bash
mkdir -p ~/.config/systemd/user && cp examples/systemd/* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now run-issues-poller.timer pr-watch-poller.timer
sudo loginctl enable-linger "$USER"   # PAKOLLINEN
```

`enable-linger` on se, jonka unohtaminen tuottaa hiljaisimman vian: user-yksiköt kuolevat
uloskirjautuessa, poller "ei vain tee mitään", eikä mikään loki kerro miksi.

Yksiköt ajavat `bash -l -c` **tarkoituksella** — login-shelli lataa nvm:n, jotta `npx`
resolvoituu. Tarkista `bash -lc 'node -v'` ennen kuin luotat niihin: jos login-shellin Node
on eri kuin interaktiivisen, claude-kutsut kaatuvat koodilla 127.

**Mitoitus.** Ajo pitää yllä samanaikaisesti Claude CLI:tä, kohderepon buildia ja sen
testiympäristöä. Mitatut luvut yhdestä pnpm-monorepo-kohderepoista: repo + `node_modules`
1,4 GB, oma worktree per rinnakkainen ajo ~0,7 GB, Playwright-selaimet ~1,5 GB (Linux,
pelkkä chromium). Käytännön lähtökohta **4 vCPU / 8 GB / 50 GB** kun
`global_max_concurrent` on 2, tai 2 vCPU / 4 GB kun se on 1. Lisää swap myös isommalle
koneelle — node-buildit piikittävät.

**Verkko.** Default-deny sisään; vain SSH omasta osoitteestasi. Ohjaamon toimintopalvelua
ei tarvitse eikä pidä avata: se hakee bind-osoitteen komennolla `tailscale ip -4` ja
**kieltäytyy käynnistymästä** ilman sitä sen sijaan että putoaisi wildcardiin (osio 7.9).
Tailscale on siksi luonteva myös ssh:lle, jolloin portti 22 voi olla kiinni julkisesta
verkosta.

### 3.2 Windows (interaktiivinen käyttö)

> **Tila: todennettu CI:ssä.** Paketin testipaketti ajetaan `windows-latest`-koneella
> Git Bashissa **pakollisena** PR-porttina siinä missä macOS-ajokin
> ([`.github/workflows/tests.yml`](.github/workflows/tests.yml)). Tämä osio ei siis kanna
> §3.1:n varoitusta. Se, mitä CI ei todenna, on nimetty alla kohdassa "Mitä ei tueta".

Windowsilla tuetaan **interaktiivinen ajo**: Claude Code ajaa paketin skriptit omalla
Bash-työkalullaan, joka Windowsissa on Git Bash. Slash-komennot (`/issue-runner:run-issue`,
`/issue-runner:new-issue`, `/issue-runner:new-epic`, `/issue-runner:pr-watch`) toimivat
samoin kuin macOS:llä. WSL:ää ei tarvita eikä käytetä — kohde on natiivi Claude Code +
Git Bash.

**Esiehdot**

| Vaatimus | Miksi |
|---|---|
| Windows 10 1809+ (tai Windows 11) | Kehittäjätila ja natiivit symlinkit ilman järjestelmänvalvojan oikeuksia |
| [Git for Windows](https://git-scm.com/download/win) | Toimittaa Git Bashin, jonka Claude Code valitsee Bash-työkalukseen |
| Kehittäjätila päälle **ja** `MSYS=winsymlinks:nativestrict` | Ilman näitä `ln -s` tekee hiljaa kopion; asentaja kieltäytyy (exit 2) |
| `gh`, `jq`, Node | `winget install GitHub.cli jqlang.jq OpenJS.NodeJS.LTS` |
| **`jq` 1.7 tai uudempi** | Vain siinä on `--binary`; ks. alla |
| Claude Code | Natiiviasennin tai `npm i -g @anthropic-ai/claude-code` |
| `gh auth login` | S0-portti tarkistaa sen komennolla `gh auth token` |

`jq`-versio on aito vaatimus, ei suositus. Windowsin `jq` on natiivi ohjelma, joka avaa
stdoutin C-ajonaikaisen tekstitilaan: jokainen rivinvaihto lähtee muodossa `\r\n`, ja
`$(...)` poistaa lopun rivinvaihdon mutta **ei** vaunupalautusta. Silloin olemassa oleva
polku testautuu puuttuvaksi ja kelvollinen luku ei-numeeriseksi. Paketti antaa `jq`:lle
`--binary`-lipun ([`lib/jq-binary.sh`](lib/jq-binary.sh)), mutta lippu on jq 1.7:stä alkaen —
sitä vanhempi jq on S0-portille sama asia kuin puuttuva riippuvuus.

**Asennus Git Bashissa** (ei PowerShellissä, ei CMD:ssä)

```bash
git clone <paketin repo-URL> claude-issue-runner
cd claude-issue-runner
MSYS=winsymlinks:nativestrict bash install.sh --dry-run   # tulostaa suunnitelman
MSYS=winsymlinks:nativestrict bash install.sh             # soveltaa sen
```

`--dry-run` tulostaa rivin `symlink capability: ok`, kun kehittäjätila ja `MSYS`-asetus ovat
kunnossa. Jos ne eivät ole, asentaja kieltäytyy **ennen ainuttakaan kirjoitusta** (exit 2);
perustelu on osiossa "Asentimen exit-koodit" yllä.

Asetuksen saa pysyväksi lisäämällä sen Git Bashin profiiliin, jolloin `MSYS=`-etuliitettä ei
tarvitse toistaa:

```bash
echo 'export MSYS=winsymlinks:nativestrict' >> ~/.bash_profile
```

**Mihin asennus linkittää.** Git Bashin `$HOME` on `%USERPROFILE%` (esim.
`C:\Users\<sinä>`), joten kohde on `%USERPROFILE%\.claude` — sama puu, josta Claude Code
lukee komennot ja skillit Windowsissa:

| Polku | Sisältö |
|---|---|
| `%USERPROFILE%\.claude\commands\issue-runner\` | slash-komennot, per tiedosto |
| `%USERPROFILE%\.claude\skills\` | skillit, per hakemisto |
| `%USERPROFILE%\.claude\scripts\run-issues` | symlink paketin juureen |

Lukot ja lokit **eivät** mene `~/Library`-puuhun: `uname -s` osuu MINGW-haaraan, jolloin
oletukset ovat `%USERPROFILE%\.local\state\run-issues\{locks,logs}`
([`lib/paths.sh`](lib/paths.sh)). `RUN_ISSUES_LOCK_ROOT` ja `RUN_ISSUES_LOG_DIR` ohittavat
yhä.

**Claude CLI:n kutsu.** Oletus on `npx --no-install @anthropic-ai/claude-code`, eli se etsii
**npm-pakettia**. Claude Coden natiiviasennin ei asenna npm-pakettia vaan `claude`-komennon
polulle, jolloin oletus exittaa 127 ja S0-portti raportoi puuttuvan Claude CLI:n. Korjaus on
yksi muuttuja:

```bash
export RUN_ISSUES_CLAUDE_CMD=claude
```

Saman muuttujan nimeää S0-portin virheilmoitus, joten vihje on siinä missä vika näkyy.
Vakinaista se joko Git Bashin profiiliin tai koneen omaan env-tiedostoon
(`$HOME/.config/run-issues/env`, osio 4).

**Mitä ei tueta.** Windows-tuki koskee **vain** interaktiivista ajoa. Ulkopuolelle jäävät
tarkoituksella:

| Osa | Miksi ei |
|---|---|
| Pollerit (`poller.sh`, `pr-watch-poller.sh`) | Vaativat `tmux`in, jota Git Bashissa ei ole; ajastus tulee launchd:ltä tai systemd:ltä |
| LaunchAgentit ja `--with-launchagents` | macOS-mekanismi; `plutil`ia ei ole |
| `self-update.sh` | Ajastettu agentti, ks. edellinen rivi |
| Ohjaamo (`action-server.sh`, statussivu) | Tailscale-sidonnainen daemon, ei interaktiivinen työkalu |

Nämä eivät ole rikki Windowsissa vaan poissa: niiden testit ohittavat itsensä `SKIP`-rivillä
ja kertovat syyn. **Jos tarvitset ajokoneen** — koneen, joka poimii issueita itsestään ja
valvoo PR:iä — se ei ole Windows-kone. Lue osio 3.1 (Linux-ajokone) tai käytä macOS-konetta.
Sama repo voi silti olla molempien käytössä: `run.json.host` erottaa koneet toisistaan, joten
Windows-työasemalta ajettu interaktiivinen ajo ja Linux-ajokoneen poller eivät törmää
(osio 6.4).

---

## 4. Konfigurointi

Kaikki konfiguraatio elää repojen **ulkopuolella**, hakemistossa `$HOME/.config/run-issues/`.

### `$HOME/.config/run-issues/env` — salaisuudet

Shell-tiedosto, jonka `orchestrate.sh` ja `pr-watch.sh` sourceavat. Tarkoitettu esimerkiksi
`GITHUB_TOKEN`ille, jota implementer tarvitsee yksityisten riippuvuuksien asennukseen.

```bash
mkdir -p "$HOME/.config/run-issues"
chmod 600 "$HOME/.config/run-issues/env"
```

`chmod 600` ei ole suositus vaan ehto: tiedosto on sourcattavaa shell-koodia ja sisältää
salaisuuksia. Orkestraattori varoittaa löysemmistä oikeuksista. Tiedostoa **ei saa** committoida
mihinkään eikä upottaa plistiin.

**Pollerit eivät lue tätä tiedostoa koskaan.** Ne lokittavat runsaasti, joten salaisuudet
pidetään niiden prosessin ulkopuolella.

**Etuoikeus on päinvastainen kuin `poller.env`issä.** Nimiavaruuksissa `RUN_ISSUES_*` ja
`PR_WATCH_*` **kutsujan** jo asettama arvo voittaa tiedoston (tyhjäksi asettaminen lasketaan
asettamiseksi); muualla — eli salaisuuksissa, joita kukaan ei aseta käsin — tiedosto voittaa.
"Kutsuja" tarkoittaa prosessin ympäristöä sillä hetkellä, kun skripti käynnistyi, ei paketin
omia oletuksia: siksi tiedostosta voi asettaa myös `RUN_ISSUES_CLAUDE_CMD`in,
`RUN_ISSUES_CLAUDE_MODEL`in ja `RUN_ISSUES_CLAUDE_TIMEOUT`in.

### `$HOME/.config/run-issues/poller.env` — koneen konfiguraatio

LaunchAgent ei peri interaktiivisen shellin ympäristöä, joten tämä tiedosto on ainoa kanava,
jolla kone konfiguroi pollerinsa. Se **sourcetaan**, joten **tiedosto voittaa
ympäristömuuttujan**. Malli, joka selittää jokaisen avaimen:
[`examples/run-issues-poller.env.example`](examples/run-issues-poller.env.example) —
kopioi siitä, älä kirjoita ulkomuistista. Kaavio:
[`docs/diagrams/poller-config-resolution.mmd`](docs/diagrams/poller-config-resolution.mmd).

### GitHub App -identiteetti (opt-in) — runnerille oma kiintiö

Oletuksena koko automaatio ajaa ylläpitäjän henkilökohtaisella GitHub-tilillä. Se on ongelma
kahdesta syystä:

1. **Attribuutio.** Botin kommentit, labelit ja PR:t näyttävät GitHubissa ihmisen tekemiltä —
   ihmistä ja automaatiota ei voi erottaa historiasta.
2. **Kiintiö.** GitHubin API-kiintiö on tilikohtainen. Automaatio jakaa saman kiintiön jokaisen
   interaktiivisen Claude-session ja `gh`-käytön kanssa: kun poller täyttää sen, myös käsityö
   pysähtyy — ja päinvastoin. Näin 18 repon ajo jäätyi kerran yli kymmeneksi tunniksi.

Valinnainen **GitHub App** korjaa molemmat. App on istumapaikkaton (ei kuluta maksullista
org-seatia): sen asennus toimii `<app-nimi>[bot]`-identiteettinä ja saa **oman 15 000 kutsua/h
-kiintiönsä**. Kun App-tila on päällä, paketti reitittää sen kautta:

- **kirjoitukset** — kommentit ja labelit (attribuutio: `<app>[bot]`), ja
- **raskaimmat luvut** — poiminta (`pick_oldest_candidate`), assignee-tarkistus claimissa,
  epic-listaus ja siivousskannauksen labelikysely. Nämä ovat per-tikki-listahakuja joka
  watchlist-repolle; identiteetti ei muuta *mitä* ne palauttavat, mutta se ratkaisee **kenen
  kiintiöstä** ne maksetaan. Volyymi kuuluu Appille, ei henkilökohtaiselle tilille
  (issue #127). Claimin `@me`-assignaatio ja `gh api user` pysyvät henkilökohtaisella tilillä —
  GitHub App ei voi olla assignee.

**Konfigurointi.** Kolme muuttujaa + yksityisavaintiedosto (`.pem`, mode 0600):

```bash
RUN_ISSUES_GITHUB_APP_ID=<numero>
RUN_ISSUES_GITHUB_APP_INSTALLATION_ID=<numero>
RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH=$HOME/.config/run-issues/app.pem
```

- `orchestrate.sh` ja `pr-watch.sh` lukevat ne **`env`-tiedostosta** (kirjoitukset + orkestraattorin
  luvut).
- **Pollerin oma poiminta lukee ne `poller.env`istä** — poller ei koskaan sourcea `env`iä
  (salaisuudet + runsas lokitus). Nämä kolme ovat identiteettikonfiguraatiota, eivät salaista
  materiaalia: **varsinainen salaisuus on `.pem`-tiedosto**, joka pysyy levyllä (mode 0600) ja
  johon viitataan vain polulla. Siksi ne saavat olla `poller.env`issä, vaikka tokenit ja avaimet
  eivät saa. Malli: [`examples/run-issues-poller.env.example`](examples/run-issues-poller.env.example).

Puuttuva App-konfiguraatio on **hyvänlaatuinen no-op**: ilman muuttujia (tai jos `.pem` ei ole
luettavissa) kaikki putoaa paljaaseen `gh`:hon täsmälleen kuten ennen — App ei ole asennusehto.
Ei-origin-remote ohittaa Appin aina (App-asennus on org-kohtainen).

### Watchlist — mitkä repot pollataan

Oletuspolku `$HOME/.config/run-issues/watchlist.json`. Skeema ja multi-remote-esimerkki:
[`examples/run-issues-watchlist.example.json`](examples/run-issues-watchlist.example.json).

Huomaa: jos asetat `RUN_ISSUES_WATCHLIST`-muuttujan, se on **ainoa** ehdokas — osumaton
override on virhe, ei fallback vanhaan polkuun.

**Molemmat pollerit lukevat saman watchlistin ja kunnioittavat repo-kohtaista `remotes`-taulukkoa**
(oletus `["origin"]`). `poller.sh` poimii issueita ja `pr-watch-poller.sh` valvoo PR:iä kustakin
listatusta remotesta erikseen, reitittäen `gh`-kutsut oikeaan GitHub-orgiin. Jos issuet ja PR:t
elävät muussa kuin `origin`-remotessa, lisää sen nimi `remotes`-taulukkoon — muuten PR-vahti
katsoisi `origin`ia eikä mergeisi mitään.

### Kohderepon opt-in-konfiguraatio

Kohderepo voi ohjata orkestraattoria tiedostolla `.claude/run-issues.json`:

| Avain | Vaikutus |
|---|---|
| `claude_timeout_seconds` | aikabudjetti per claude-kutsu tässä repossa |
| `base_branch` | pakotettu base-haara worktreelle ja PR:lle |
| `principles_file` | tämän repon oma koodausstandardi paketin oletuksen tilalle (suhteellinen polku tulkitaan repo-juuresta) |

Ympäristömuuttuja voittaa aina tiedoston. Puuttuva tiedosto on no-op.

### Koodausstandardi kohderepoon (`.claude/principles.md`)

[`principles/coding.md`](principles/coding.md) on paketin kanoninen, aina päällä oleva
koodausstandardi. Se latautuu vain sille, jolla **paketti on asennettuna** — mikä jättää katveeseen
juuri sen lukijan, jonka takia standardi kirjoitettiin yhteiseksi: kanssakehittäjän, joka on
kloonannut kohderepon muttei ole ajanut `install.sh`:ta.

Kuluttajia on kolme, eikä niillä ole yhteistä latautumispintaa paketin kautta:

| Kuluttaja | Mitä hänellä on | Mitä paketti tavoittaa |
|---|---|---|
| Orkestroitu agentti | worktree kohderepossa + paketti | tavoittaa |
| Kanssakehittäjän interaktiivinen sessio | **kohderepo, ei välttämättä pakettia** | **ei tavoita** |
| Ylläpitäjän oma sessio | globaali `CLAUDE.md` | tavoittaa |

Ainoa pinta, joka on varmasti kaikilla kolmella, on **kohderepo itse**.

#### Valinta: kopio, ei importtia paketin polkuun

| Vaihtoehto | Kattaa kanssakehittäjän | Ajautuu lähteestä |
|---|---|---|
| `@`-import paketin polkuun (`@~/.claude/scripts/run-issues/principles/coding.md`) | **ei** — edellyttää, että paketti on samalla koneella | ei |
| **Kopio `.claude/principles.md` + `@`-import repon `CLAUDE.md`:stä** | **kyllä** — kulkee repon mukana | kyllä, ja ajautuma hallitaan alla |

Import olisi ajautumaton mutta ratkaisee väärän ongelman: se kaatuu täsmälleen siinä tapauksessa,
jonka takia standardi viedään repotasolle. **Kopio valitaan**, ja sen ainoa haitta — ajautuminen —
on tietoisesti hyväksytty ja hoidetaan ohjeella, ei koneistolla.

Pelkkä tiedosto `.claude/`-hakemistossa ei riitä: Claude Code lataa projektimuistina kohderepon
**`CLAUDE.md`**:n ja sen `@`-importit, ei mielivaltaista tiedostoa `.claude/`-hakemistosta. Kopio
tarvitsee siis myös rivin repon `CLAUDE.md`:hen — muuten se on vain tiedosto, joka ei lataudu.

#### Käyttöönotto kohderepossa

Ajaa se, jolla paketti on koneella. Kohderepon juuressa:

```bash
PKG="$HOME/.claude/scripts/run-issues"
SRC="$PKG/principles/coding.md"
REV="$(git -C "$PKG" log -1 --format=%h -- principles/coding.md 2>/dev/null || echo tuntematon)"

mkdir -p .claude
{
  printf '> **Kopio — älä muokkaa tätä tiedostoa.** Kanoninen lähde on\n'
  printf '> claude-issue-runner -paketin `principles/coding.md` (revisio `%s`).\n' "$REV"
  printf '> Muutokset tehdään lähteeseen; tämä kopio päivitetään sieltä.\n\n'
  cat "$SRC"
} > .claude/principles.md
```

Sitten kohderepon `CLAUDE.md`:hen yksi rivi:

```markdown
@.claude/principles.md
```

Kopion ensimmäiset rivit nimeävät kanonisen lähteen ja kieltävät paikallisen muokkauksen — sama
kaava kuin muuallakin ("muokkaa lähteessä, älä kopiossa"). Revisiotunniste on **luettava fakta, ei
versiotarkistus**: se kertoo yhdellä silmäyksellä, mistä kohtaa lähdettä kopio on otettu.

Molemmat tiedostot ovat kohderepon versionhallinnassa, joten kanssakehittäjä saa standardin
kloonatessaan — ilman asennusvaihetta ja ilman skill-porttia. Sama kopio kattaa myös orkestroidun
agentin, joka työskentelee saman repon worktreessä.

Käyttöönotto on ihmisen katselmoima muutos kohderepossa, joten runner ei tee sitä itse (ks.
[§5:n levitysluku](#päivitysten-levitys-n-repoon)). Se tekee **puuttumisen näkyväksi**: jos
kohderepon `CLAUDE.md`:ssä ei ole olemassa olevaan tiedostoon osoittavaa `@.claude/principles.md`
-importtia, jokainen ajon avaama PR kantaa kuvauksessaan yhden rivin, joka viittaa tähän lukuun.
Rivi on **huomautus, ei este** — ajo etenee normaalisti, eikä huomautus mene issue-kommenttiin
eikä labeliin. Tunnistettu muoto on täsmälleen yllä dokumentoitu muoto; `tests/test-coding-standard-adoption.sh`
vartioi sitä.

#### Päivitysten levitys N repoon

**Levityskoneistoa ei rakenneta — se on jo olemassa, ja se on tämä runner.** Kun
`principles/coding.md` muuttuu, kopiot eivät päivity itsestään. Menettely on tietoisesti
manuaalinen ja eksplisiittinen:

1. Avaa kuhunkin kohderepoon issue (`/issue-runner:new-issue` kelpaa), joka pyytää päivittämään
   `.claude/principles.md`:n paketin nykyisestä `principles/coding.md`:stä yllä olevalla komennolla.
2. Labeloi issue repon poimintalabelilla, jolloin runner tekee muutoksen ja avaa PR:n normaalisti.
3. Repoissa, jotka eivät ole watchlistillä, sama komento ajetaan käsin.

Ajautuma on siis **hallittu ja näkyvä**, ei yllätys: kopion revisiotunniste kertoo mistä se on
otettu, ja päivitys on tavallinen issue kuten mikä tahansa muukin muutos. Cronia, hookia tai bottia
ei lisätä — automaattinen kirjoitus N repoon ohittaisi juuri sen katselmointiportin, jonka varassa
kaikki muukin tämän runnerin tekemä muutos on.

Tämä paketti **ei kirjoita kohderepoihin** käyttöönottoa. Ohje on tässä; käyttöönotto yksittäisessä
repossa on oma työnsä siinä repossa.

---

## 5. Ympäristömuuttujat (asennus- ja konfigurointiaika)

Alla vain ne muuttujat, jotka ihminen tosiasiassa asettaa ennen ensimmäistä ajoa. **Täysi
lista kaikista muuttujista on [`docs/env-reference.md`](docs/env-reference.md):ssä** — sitä ei
toisteta tässä, jotta kaksi listaa ei ajaudu erilleen. Lähde on koodin `${VAR:-oletus}` ja
skriptin `# Env:`-otsikkokommentti.

### Orkestraattori

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_ENV_FILE` | `$HOME/.config/run-issues/env` | Salaisuustiedoston polku |
| `RUN_ISSUES_CLAUDE_CMD` | `npx --no-install @anthropic-ai/claude-code` | Claude-CLI:n kutsu. Natiiviasennin (mm. Windows) ⇒ `claude`, ks. osio 3.2 |
| `RUN_ISSUES_CLAUDE_TIMEOUT` | `3600` | Aikabudjetti per claude-kutsu |
| `RUN_ISSUES_PR_LABELS_CSV` | `auto-merge` | Issuelta PR:lle kopioitavat labelit (6.3) |
| `RUN_ISSUES_MAX_RETRIES` | `1` | Montako kertaa aikakatkaistu ajo yritetään uudelleen (6.6 d) |
| `RUN_ISSUES_MAX_CLARIFICATIONS` | `3` | Tarkennuskierrosten katto (6.6 c) |
| `RUN_ISSUES_AUTO` | `0` | `1` = ei interaktiivisia kehotteita (ks. osio 7.3) |
| `RUN_ISSUES_SKIP_PREFLIGHT` | `0` | `1` = ohita S0-portti. Hätävara |

### Poller

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_POLLER_ENV_FILE` | `$HOME/.config/run-issues/poller.env` | Konfiguraatiotiedoston polku |
| `RUN_ISSUES_POLLER_HOSTS` | *(ei oletusta — pakollinen)* | Glob-kuviot, joita verrataan koneen lyhyeen konenimeen (`runner_host`, `lib/host.sh`). `*` sallii kaikki. Ei osumaa ⇒ poller exittaa 0. Asettamatta poller ei aja millään koneella, ja kertoo siitä yhdellä rivillä |
| `RUN_ISSUES_WATCHLIST` | *(tyhjä)* | Watchlistin polku; asetettuna ainoa ehdokas |
| `RUN_ISSUES_LOG_DIR` | macOS: `$HOME/Library/Logs`; muut: `${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/logs` | Pollerien lokihakemisto. Oletus haarautuu `uname -s`:llä (`lib/paths.sh`) |
| `RUN_ISSUES_CLEAN_LABEL` | `auto-clean` | Label, joka laukaisee siivouksen |
| `RUN_ISSUES_RESET_LABEL` | `auto-reset` | Label, joka laukaisee nollauksen: sama purku kuin siivouksessa, mutta issue jää auki |
| `RUN_ISSUES_PICK_BLOCKED_PROBES` | `20` | Montako poimintaehdokasta enintään tarkistetaan estojen varalta per tikki (#133) |
| `RUN_ISSUES_RATE_LIMIT_BACKOFF` | `1` | `0` poistaa GitHubin kutsurajan perääntymisen käytöstä (#126). Oletuksena pollerit odottavat kasvavan ajan (5→60 min) rajaan törmättyään, koska torjuttu pyyntö pidentää estoa |
| `RUN_ISSUES_CLEAN_SCAN_LIMIT` | `200` | Purkulabelin (`auto-clean` ja `auto-reset`) repo-laajuisen listauksen rivikatto (#124); ylittyessä kattamattomat issuet luetaan yksitellen ja lokiin tulee WARNING |
| `RUN_ISSUES_STALE_AFTER` | `3600` | Kuinka vanha ajo tulkitaan jumiutuneeksi ja tapetaan (6.6 f) |

### PR-vahti

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `PR_WATCH_MERGE_LABEL` | `auto-merge` | Label, joka sallii auto-mergen |
| `PR_WATCH_ENABLE_CONFLICT_RESOLUTION` | `0` (poller nostaa `1`:ksi) | AI-avusteinen konfliktinratkaisu (ks. osio 7.4) |
| `PR_WATCH_ENABLE_CI_REPAIR` | `0` (poller nostaa `1`:ksi) | AI-avusteinen punaisen CI:n korjaus (ks. osio 7.5) |
| `PR_WATCH_MAX_CI_REPAIRS` | `1` | CI-korjauksen yrityskatto per PR |

### Asennin

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_CLAUDE_HOME` | `$HOME/.claude` | Kohdehakemisto agenteille ja komennoille |
| `RUN_ISSUES_LAUNCH_AGENTS_DIR` | `$HOME/Library/LaunchAgents` | Plistien kohdehakemisto |
| `RUN_ISSUES_POLLER_ENV_FILE` | `$HOME/.config/run-issues/poller.env` | **Vain luku:** asennin raportoi tästä tiedostosta host-portin tilan, mutta ei koskaan luo eikä muokkaa sitä |

Asennin tulostaa lopuksi neuvoa-antavan **host-porttiraportin**: jos `poller.env` ei aseta
`RUN_ISSUES_POLLER_HOSTS`:ia, pollerit eivät aja tällä koneella mitään, ja asennin sanoo sen
samalla rivillä jonka poller itse tulostaisi ajossa. Kyse on varoituksesta, ei kieltäytymisestä —
exit-koodi ei muutu, koska `poller.env` saa syntyä vasta asennuksen jälkeen.
`RUN_ISSUES_ACTION_HOSTS`:ista varoitetaan vain jos `RUN_ISSUES_ACTION_BASE` on asetettu.

Ensimmäiset kaksi muuttujaa ovat olemassa yhtä syytä varten: **testit eivät saa koskea oikeaan
`~/.claude`-hakemistoon**, koska sitä käyttää samalla koneella ajava poller. Siksi jokainen
asentajan polku johdetaan `$HOME`:sta tai näistä overrideista, eikä tildelaajennusta käytetä
missään.

`RUN_ISSUES_HOME` on **testien injektiopiste, ei käyttäjäkonfiguraatio — älä aseta sitä.**

---

## 6. Käyttö

Tämä osio on paketin käyttöohje: mistä tilasta issue lähtee liikkeelle, mitä ihminen näkee
matkan varrella, ja mitä hän tekee kussakin tilanteessa.

### 6.1 Elinkaari yhdellä silmäyksellä

Automaattiajossa (poller) yksi issue kulkee tämän ketjun ilman ihmistä:

| Vaihe | Kuka tekee | Mitä ihminen näkee |
|---|---|---|
| Poiminta | poller / orkestraattori | issue **varataan** (`auto-claimed`-label) ja assignoituu sinulle |
| Katselmointi (S6) | Claude | ei mitään — tai tarkennuskysymys kommenttina |
| Toteutus (S8–S9) | Claude | committeja haaralla `auto-run/<repo-slug>-issue-<N>-<slug>` |
| PR (S11) | orkestraattori | PR, jonka rungossa on `Closes #<N>` |
| Merge | PR-vahti | PR mergetty, **issue sulkeutuu** `Closes`-viittauksesta |
| Siivous | PR-vahti | worktree, haara, lukko, assignaatio ja `auto-claimed`-varaus poistuvat |

Ihmisen tehtävä on kaksi asiaa: **kirjoittaa issue riittävän tarkasti** ja **katselmoida PR**.
Kaikki muu ihmiskosketus (tarkennuskysymys, `needs-human`, siivous) on poikkeustilanne, jonka
käsittely on kuvattu kohdassa 6.6.

### 6.2 Milloin issue lähtee ajoon

Poiminta on **yksi REST-listaus ja sen päälle paikallinen suodatus**
(`lib/issue.sh:pick_oldest_candidate`, jota `poller.sh` kutsuu — koko paketissa on vain tämä
yksi poimintakysely):

```
gh api repos/<owner>/<repo>/issues
        ?labels=<jokainen konfiguroitu label>      ← palvelimen suodatin (JA-ehto)
        &state=open&sort=created&direction=asc
  → pudota PR:t sekä issuet, joilla on jokin näistä labeleista:   ← paikallinen suodatin (jq)
    auto-claimed, waiting, wip, epic, auto-clean, auto-reset
  → koeta jäljelle jääneitä vanhimmasta alkaen: onko avoimia blocked_by-estäjiä?
    ensimmäinen estämätön lähtee ajoon
```

**Miksi REST eikä `gh issue list`?** `--label`-suodatettu `gh issue list` kulkee GitHubin
GraphQL-hakuyhteyden kautta, ja **se yhteys voi olla estetty vaikka muu API vastaa
normaalisti** — näin kävi 27 tunnin ajan 2026-08-28/29, jolloin poiminta ei voinut ajaa
lainkaan (#133). REST-listaus ei koske hakuyhteyteen. Sivuhyöty: poissulkuehdot ovat nyt
paikallisia jäsenyystestejä, jotka epäonnistuvat **umpeen** — vanha `-label:x` epäonnistui
auki, eli kirjoitusvirhe vuoti poissuljettuja issueita poimintaan. Mittaus ja
kontrollikoe: CLAUDE.md §5.2.

Issue lähtee siis ajoon **täsmälleen kun kaikki nämä pätevät**:

1. Issue on **avoin**.
2. Issuella **ei ole `auto-claimed`-labelia** — se on automaation oma varaus käynnissä olevalle
   tai siivoamattomalle ajolle (ks. 6.4). **Assignaatio ei ole varaus:** käsin assignattu issue
   lähtee ajoon normaalisti, ellei repo ole ottanut käyttöön watchlistin valinnaista
   `assignees`-rajausta (alempana tässä osiossa).
3. Issue **ei ole estetty** GitHubin natiivissa riippuvuusgraafissa — poiminta lukee graafin
   suoraan riippuvuusrajapinnasta ehdokas kerrallaan (ks. 6.5).
4. Issuella **ei ole** labelia `waiting`, `wip`, `epic`, `auto-clean` eikä `auto-reset`.
5. Issuella on **kaikki** konfiguroidut poimintalabelit (oletus: `auto-run`).
6. Se on vanhin ehdot täyttävä issue — **yksi issue per tikki per remote**.

Viides kohta on se, joka useimmiten yllättää: **labelit yhdistyvät JA-ehdolla, eivät
TAI-ehdolla.** Jos watchlistin `labels`-listassa on kaksi labelia, issue tarvitsee molemmat.
Ja koska `auto-clean` ja `auto-reset` ovat aina poissuljettuja, **kumman tahansa listaaminen
poimintalabeliksi tekee reposta pysyvästi tyhjän** — listaus pyytäisi silloin palvelimelta
`labels=auto-clean` ja paikallinen suodatin pudottaisi jokaisen osuman. Tulos on nolla
ehdokasta, eikä siitä synny virhettä eikä lokiriviä.

`auto-reset`in poissulku ei ole optimointi vaan **korrektiusehto**: nollauksen koko idea on,
että poiminta jatkuu vasta kun purku on ajettu ja label poistettu. Ilman suodatinta poller
voisi varata issuen ennen purkua, ja purku törmäisi issuekohtaiseen lukkoon joka tikillä.

Poimintalabelit tulevat konfiguraatiosta kolmessa portaassa: watchlistin repokohtainen
`labels` → watchlistin `default_labels` → sisäänrakennettu oletus `["auto-run"]`. **Mikään
labelin nimi ei ole kovakoodattu poimintaan** — `auto-run` on pelkkä konventio.

**Valinnainen assignee-rajaus (watchlistin `assignees`).** Kun repon merkintä asettaa
`assignees`-listan, poiminta ottaa vain issuet, jotka on reititetty jollekin listatuista
GitHub-tunnuksista. Avaimen puuttuessa — oletus — assigneita ei katsota lainkaan ja poiminta on
täsmälleen entisellään. Ehto **ANDataan** poimintalabelien kanssa, se ei korvaa niitä.

Issue kelpaa, jos jokin sen assigneista on listalla — **tai**, jos issuella ei ole assigneeta
lainkaan, jos sen **avaaja** on listalla. Avaajafallback on se, jonka ansiosta käsin kirjoitettu
issue lähtee ajoon ilman erillistä assignaatiota; assignee-kenttä on silloin se, jolla työ
siirretään toiselle koneelle. Fallback koskee **vain** assignoimatonta issueta, joten sillä on
tarkoituksellinen kääntöpuoli: **listan ulkopuoliselle assignattu issue jää poimimatta**,
vaikka listalla oleva tunnus olisi sen avannut. Se on ihmisen opt-out ("teen tämän itse") ja
pätee vain niissä repoissa, joissa avain on asetettu. Tyhjä lista tarkoittaa samaa kuin puuttuva
avain: ei suodatusta — ei siis "nolla osumaa ikuisesti".

Tämä on työnjaon **toinen akseli**. Labelit ANDataan, joten työn jakaminen usealle koneelle
labeleilla vaatii koneelle oman labelin (`auto-run-<kone>`) ja työn siirto on labelin vaihto.
Kun ajokone tunnistautuu omalla machine user -tilillään, assignee nimeää koneen suoraan
GitHubin omassa käyttöliittymässä. Assignaatio ei silti ole **varaus** — varaus on yhä
`auto-claimed`-label (6.4). Sekä `poller.sh` että `drain-queue.sh` lukevat avaimen samalla
resolvoijalla, joten ne eivät voi olla eri mieltä siitä, mitä tämä kone poimii. Uusia
API-kutsuja ei synny: assignee- ja avaajatieto on jo poiminnan REST-vastauksessa.

**Käänteinen määritys `not:<tunnus>` (issue #246).** Listan alkio on joko tunnus
(`"maintainer"`, **ALLOW**) tai kielto (`"not:maintainer"`, **DENY**). Issue kelpaa, kun molemmat
pätevät: (1) ALLOW on tyhjä **tai** kohde osuu johonkin ALLOW-tunnukseen, ja (2) kohde ei osu
yhteenkään DENY-tunnukseen. **DENY voittaa ALLOW:n**, jos sama tunnus on molemmissa (fail-closed),
ja useasta assigneesta riittää yksi DENY-osuma. Kohde on tässäkin assignee-joukko tai, sen
puuttuessa, avaaja. `not:` vaatii kaksoispisteen — `notollisaari` on tavallinen ALLOW-tunnus.
Muoto ratkaisee kahden koneen jaon ilman toista repo-oikeuksin varustettua tunnusta:
`["maintainer"]` ja `["not:maintainer"]` osuu jokaiseen issueen täsmälleen kerran, **eikä
DENY-tunnukselta vaadita repo-oikeutta**. **Varoitus:** liian laaja DENY tuottaa **nolla osumaa
yhtä hiljaa kuin väärä poimintalabel** (yllä) — repo lakkaa poimimasta ilman virhettä ja lokia.

Poiminta on **pollerin** tehtävä: orkestraattori ei enää poimi (ei `poll`-tilaa, ei `RUN_ISSUES_LABELS_CSV`ää),
joten koko paketissa on yksi poimintakysely.

**Nimetty ajo ohittaa poimintaehdot.** `/issue-runner:run-issue #N` ja `orchestrate.sh <repo> <N>` eivät
tee hakua lainkaan, joten labelit ja avoimuus eivät estä niitä. Claim tarkistetaan silti:
**käsin assignattu issue lähtee nyt ajoon** (assignaatio ei ole varaus, ks. 6.4), mutta jos
**toinen runner** ehtii varata saman issuen samaan aikaan, tämä ajo perääntyy (exit 3).

**Rinnakkaisuus.** Poller ajaa kerrallaan enintään `global_max_concurrent` ajoa (watchlistin
avain, oletus `2`) kaikkien repojen yli. Katon täyttyessä tikki kirjoittaa lokiin
`at cap (n/m)` eikä käynnistä mitään. Sama issue ei koskaan saa kahta sessiota: duplikaatit
karsitaan repo- ja remote-kohtaisella tmux-session nimellä.

**PR-vahdin poller** (`pr-watch-poller.sh`) käyttää **rotaatiokursoria**, joka jatkaa joka
tikillä siitä repoista mihin edellinen jäi, jotta koko watchlist tulee käytyä eikä hännän
auto-merge-PR jää nälkiintymään. Sillä on myös oma, korkeampi rinnakkaisuuskatto: watchlistin
valinnainen `pr_watch_max_concurrent` (oletus = `global_max_concurrent`) tai ympäristömuuttuja
`PR_WATCH_GLOBAL_MAX`. PR-skannaus on sekuntien työ, joten se voi käydä korkeammalla katolla
ilman että orkestraattoriajojen rinnakkaisuus kasvaa. `poller.sh` säilyttää entisen semantiikan
sellaisenaan. Ks. [`docs/env-reference.md`](docs/env-reference.md).

**Tikin sisäinen järjestys** (`poller.sh`, oletusväli 300 s eli 5 min): jumiutuneiden ajojen
liveness-pyyhkäisy koko watchlistiin → `auto-clean`-siivoukset → **valmiiden ajojen sovitus**
→ aikakatkaistujen ajojen `--restart` → vastattujen tarkennusten `--continue` → **vasta
viimeisenä** uuden issuen poiminta. Keskeneräinen työ menee siis aina uuden edelle.

**Valmiiden ajojen sovitus (`scan_finished`).** Poller purkaa **oman koneensa** ajon, kun sen
issue on GitHubissa suljettu — ilman että sinun tarvitsee lisätä `auto-clean`-labelia. Se on eri
verbi kuin `auto-clean`: sovitus **ei sulje issueta, ei kommentoi eikä lisää labeleita**, vaan
purkaa pelkät jäänteet (worktree, haara, run-dir) — se reagoi sulkemiseen eikä aiheuta sitä.
Tarpeen syy: PR-vahti siivoaa vain silloin kun se **itse** mergesi PR:n, joten käsin mergetty PR
(tai toisen koneen mergeämä, tai PR:ttä vaille jäänyt ajo) jätti jäänteet ikuisesti ja hiljaa —
mitattuna 309 worktreetä ja 166,9 GB. Purku tapahtuu vain kun **kaikki viisi** porttia sallivat:
ajo ei ole käynnissä, se on tämän koneen, issue on varmistetusti kiinni, PR ei ole auki, eikä
haaralla ole pushaamattomia committeja. Yksikin epävarmuus (verkkovirhe, lukukelvoton tila)
estää purun — portit ovat fail-closed. Jokainen päätös, myös ohitus syineen, kirjataan pollerin
lokiin.

### 6.3 Labelit

Jokainen label kuuluu tarkalleen yhteen luokkaan sen mukaan **kuka sen kirjoittaa**. Se on
käytännössä tärkein tieto: itse lisättävää labelia ei kannata jäädä odottamaan, eikä
automaation lisäämää labelia kannata poistaa käsin ennen kuin syy on korjattu.

| Label | Kuka lisää | Kuka poistaa | Vaikutus |
|---|---|---|---|
| `auto-run` | **sinä** | sinä | Poimintaehto. Nimi tulee watchlistin konfiguraatiosta (`default_labels` tai repon `labels`), ei koodista |
| `waiting` | orkestraattori, kun ajo jää odottamaan vastaustasi | orkestraattori, kun `--continue` jatkaa | Estää poiminnan sillä aikaa kun tarkennus on kesken |
| `wip` | **sinä** | sinä | Estää poiminnan. Tarkoitettu "teen tämän itse" -merkinnäksi |
| `auto-claimed` | orkestraattori, kun ajo varaa issuen (S3) | orkestraattori, kun ajo perääntyy; `cleanup-run.sh` (myös `/issue-runner:cleanup-run`) siivouksessa | **Varausmerkintä** (6.4): estää poiminnan käynnissä olevan tai siivoamattoman ajon ajaksi. Kiinteä nimi. **Vain automaatio kirjoittaa** — älä lisää tai poista käsin |
| `needs-human` | orkestraattori tai poller, kun ajo epäonnistuu; PR-vahti, kun CI-korjaus luovuttaa | `cleanup-run.sh` (myös `/issue-runner:cleanup-run`); PR:ltä **sinä** | Issuella: **ei estä poimintaa** — varaus (`auto-claimed`) estää; signaali sinulle. PR:llä: **pidättää PR-vahdin**, kunnes poistat sen (7.5) |
| `auto-clean` | **sinä** | `auto-clean.sh` onnistuneen siivouksen jälkeen | Pyytää siivoamaan issuen ajojäänteet ja sulkemaan issuen. Ks. 6.6 h) |
| `auto-clean-skipped` | `auto-clean.sh`, kun se ei voi siivota | **sinä**, kun olet hoitanut asian | Estää siivouksen loputtoman uudelleenyrityksen |
| `auto-reset` | **sinä** tai Ohjaamon *Nollaa* | `auto-reset.sh` onnistuneen purun jälkeen | Pyytää purkamaan issuen ajojäänteet **sulkematta issueta**: ajo alkaa alusta puhtaasta basesta. Ks. 6.6 i) |
| `auto-reset-skipped` | `auto-reset.sh`, kun se ei voi purkaa | **sinä**, kun olet hoitanut asian | Estää nollauksen loputtoman uudelleenyrityksen. Oma labelinsa, jottei kahden purkuverbin tila mene sekaisin |
| `auto-merge` | **sinä** issuelle | — | Propagoituu issuelta PR:lle, ja PR-vahti mergeää vain labeloidun PR:n |

Kolme yleistä sekaannusta kannattaa erottaa heti:

- **Estoa ei merkitä labelilla.** Poiminnan estää GitHubin natiivi "blocked by" -riippuvuus
  (6.5), ei mikään label; `run.json`-status `blocked` puolestaan kertoo vain, että yksittäinen
  ajo päättyi virheeseen. Kumpikaan ei aiheuta toista — epäonnistunut ajo **ei** estä issueta.
- **`needs-human` ei estä poimintaa.** Se on pelkkä lippu sinulle. Uuden ajon estää
  varaus (`auto-claimed`), joka jää voimaan (6.4). **Poikkeus on PR:lle lisätty `needs-human`**,
  jonka PR-vahti lisää CI-korjauksen luovuttaessa: siinä se on aito pidätyslippu, ja sen
  poistaminen on nimenomaan se toimenpide, joka palauttaa PR:n vahdin käsittelyyn (7.5).
- **`auto-merge` luetaan PR:ltä, ei issuelta.** Orkestraattori kopioi sen issuelta PR:lle
  (`RUN_ISSUES_PR_LABELS_CSV`, oletus `auto-merge`). Jos lisäät labelin issuelle vasta PR:n
  avaamisen jälkeen, se ei siirry itsestään — lisää se silloin suoraan PR:lle.

Kolme labelinimeä on vaihdettavissa ympäristömuuttujalla: `auto-clean`
(`RUN_ISSUES_CLEAN_LABEL`), `auto-reset` (`RUN_ISSUES_RESET_LABEL`) ja `auto-merge`
(`PR_WATCH_MERGE_LABEL`). `waiting`, `wip`, `auto-claimed`, `needs-human`,
`auto-clean-skipped` ja `auto-reset-skipped` ovat kovakoodattuja.

Automaation itsensä lisäämät labelit (`waiting`, `auto-claimed`, `needs-human`,
`auto-clean-skipped`, `auto-reset-skipped` sekä PR:lle kopioitavat) luodaan repoon tarvittaessa
itsestään. **Sinun lisäämäsi labelit (`auto-run`, `wip`, `auto-clean`, `auto-reset`) pitää luoda
repoon itse** — GitHub ei salli tuntemattoman labelin liittämistä.

### 6.4 Varaus (`auto-claimed`) ja assignaatio

**Varaus on `auto-claimed`-label, assignaatio on kirjanpitoa.** Varaus tarkoittaa yhtä asiaa:
käynnissä oleva tai siivoamaton ajo pois poiminnasta. Se on ainoa tila, jonka kaikki koneet
näkevät — paikallinen lukkohakemisto suojaa vain yhden koneen sisällä, GitHub-label kaikkien
välillä. Label on **automaation omistama**: automaatio luo, lisää ja poistaa sen; ihminen ei
lisää sitä koskaan.

Aiemmin tämän roolin kantoi assignaatio (`no:assignee` poimintaehtona). Ongelma: ajo assignoi
`@me`:n eli **saman tilin, jolla ihminenkin assignoi issueita**, joten "ihmisen assignaatio" ja
"runnerin varaus" eivät olleet erotettavissa. Nyt varaus on erillinen label, ja assignaatio jää
pelkäksi kirjanpidoksi.

Kulku on kolmivaiheinen (S2 → S3): ajo ottaa paikallisen lukon, assignoi issuen itselleen ja
lisää `auto-claimed`in, odottaa hetken ja **tarkistaa että assignee-joukko on ennallaan +
`@me`**. Jos joukossa on ylimääräinen tili, toinen runner varasi saman issuen yhtä aikaa — tämä
ajo perääntyy, poistaa oman assignaationsa ja varauksensa ja exittaa koodilla 3. GitHub sallii
rinnakkaiset assignaatiot, joten joukkovertailu on ainoa luotettava ratkaisija.

Kolme käytännön seurausta:

1. **Käsin assignattu issue lähtee ajoon normaalisti.** Assignaatio ei ole poimintaehto eikä
   varaus. Jos haluat tehdä issuen itse, käytä **`wip`-labelia** — se on nyt ainoa "teen tämän
   itse" -opt-out.
2. **Nimetty ajo ei enää kaadu toisen ihmisen issueen.** `/issue-runner:run-issue #N` ohittaa poimintaehdot,
   ja claim-tarkistus hyväksyy etukäteen tehdyn assignaation (joukko ennen ∪ `@me`). Vasta
   **toisen runnerin** kilpaileva varaus samassa 5 sekunnin ikkunassa kaataa ajon (exit 3).
3. **Varaus ei vapaudu itsestään, jos ajo epäonnistuu.** `auto-claimed` poistuu vain neljässä
   tilanteessa: hävitty varauskilpailu, `--resume --decision CANCEL`, `cleanup-run.sh`
   (myös `/issue-runner:cleanup-run`) ja PR-vahdin mergenjälkeinen siivous. Estynyt tai jumiutunut ajo pitää
   varauksen (ja assignaation) siivoukseen asti.

Kolmas kohta on tarkoituksellinen: epäonnistunut ajo jättää issuen varatuksi, jotta poller ei
poimi samaa issueta uudelleen ja uudelleen samaan seinään. Hinta on, että **issue palaa
automaatioon vasta siivouksen jälkeen** (6.6 g). Jos ihmettelet miksi korjattu issue ei lähde
liikkeelle, tarkista `auto-claimed`-label ensin.

### 6.5 Riippuvuudet toisiin issueihin

Kun issuen pitää odottaa toista, merkitse riippuvuus GitHubin **"Mark as blocked by"**
-toiminnolla — siinä kaikki. Ei labelia lisättäväksi eikä skriptiä ajettavaksi: poiminta lukee
`blocked_by`-graafin suoraan GitHubin riippuvuusrajapinnasta ja ohittaa estetyt issuet. (Ennen
#133:a saman teki hakukvalifikaattori `-is:blocked`; se poistui, kun poiminta siirtyi REST:iin.)

- Yksi avoin estäjä riittää pitämään issuen poiminnan ulkopuolella.
- Kun viimeinen estäjä sulkeutuu, issue vapautuu poimintaan **seuraavalla tikillä** ilman
  mitään synkronointia — mekanismi lukee graafin joka tikillä uudelleen.
- Ehdokkaita koetetaan vanhimmasta alkaen ja pysähdytään ensimmäiseen estämättömään.
  Koetusten katto per tikki on `RUN_ISSUES_PICK_BLOCKED_PROBES` (oletus 20), jottei kokonaan
  estetty backlog polta koko tikkiä; katon täyttyessä tikki ei poimi mitään ja seuraava yrittää
  uudelleen. Tavallinen hinta on yksi koetus: riippuvuusketjussa vanhin lapsi on se ajettava.
- Esto ei näy issuen labeleissa, joten sitä ei myöskään voi vahingossa poistaa labelia
  poistamalla. Vastaavasti: jos issue ei lähde ajoon eikä yksikään estolabeli ole päällä,
  tarkista riippuvuudet issuen omasta näkymästä.

**Työjärjestys ketjun rakentamiseen:** luo issuet → merkitse riippuvuudet GitHubin omalla
"blocked by" -toiminnolla → lisää jokaiselle `auto-run`. Automaatio etenee ketjussa yksi
lenkki kerrallaan itsestään.

Estotieto tulee GitHubin hakuindeksistä, joten se päivittyy pienellä viiveellä juuri suljetun
estäjän jälkeen. Käytännössä viive mahtuu pollerin 5 minuutin tikkiväliin.

**Epicit — usean issuen ketju.** Kun kokonaisuus koostuu monesta issuesta, ne voi koota
**epic-issueen** (`epic`-label) ja ajaa koko ketjun yhdellä `auto-run`-signaalilla, joka
propagoituu alaissueille. Epicin rakenteen kokoaminen, propagointi, cross-repo-alaissueet sekä
ketjun käynnistys ja keskeytys komennolla `/issue-runner:run-epic` on kuvattu tiedostossa
[`docs/usage-reference.md`](docs/usage-reference.md).

### 6.6 Työkalukohtainen referenssi

Tähän asti kuvattu kerronta riittää issuen kirjoittamiseen ja ajon seuraamiseen. Yksittäisten
työkalujen syväsukellukset — käyttötapaukset (katselmointiportti, tarkennuskysymys, timeout,
esto, jumiutuminen, siivous, auto-merge, kuvat issuessa), slash-komennot, skriptit ja
apuvälineet, `claude-issue-runner`-skill, kokonaistilanäkymä (`status.sh`) ja julkaisu
julkiseen peiliin (`publish-release.sh`) — on koottu erilliseen hakuteokseen, joka luetaan
silloin kun kyseistä työkalua käyttää:

- [`docs/usage-reference.md`](docs/usage-reference.md)

Claude Codessa yleisimmät komennot ovat `/issue-runner:run-issue`, `/issue-runner:new-issue`,
`/issue-runner:new-epic`, `/issue-runner:run-epic`, `/issue-runner:pr-watch` ja
`/issue-runner:cleanup-run`; niiden argumentit ja koko slash-komentotaulukko ovat samassa
tiedostossa.

## 7. Turvamalli

Tämä osio kertoo, mihin suostut ottaessasi paketin käyttöön. Lue se kokonaan.

### 7.1 Claude ajetaan ilman lupakyselyjä

Jokainen orkestroitu claude-kutsu — katselmointi, implementer, evoluutio ja
konfliktinratkaisu — ajetaan lipulla `--dangerously-skip-permissions`
(`lib/claude-call.sh`). Agentti ei siis kysy lupaa yksittäisiin tiedostomuutoksiin,
komentoihin tai verkkokutsuihin sen jälkeen kun ajo on käynnistetty.

Tämä on koko paketin toimintaperiaate, ei asetus: ihmistä ei ole silmukassa, joten
lupakysely jäisi vastaamatta ja ajo jäisi roikkumaan. Rajoittimet ovat muualla: ajo tapahtuu
omassa git-worktreessään omalla feature-haarallaan, ja PR on ihmisen katselmoitavissa ennen
mergeä.

### 7.2 Kohderepon oma shell-koodi ajetaan

Orkestraattori ja PR-vahti suorittavat **kohderepon** toimittamaa koodia viidessä kohdassa.
Kaikki ovat opt-in: puuttuva tiedosto on hyvänlaatuinen no-op, ei virhe.

| Mekanismi | Milloin | Mitä ajetaan |
|---|---|---|
| `.claude/db-clone.json` | S5, ennen implementeriä | konfiguraation osoittama backend-skripti kloonaa tietokannan ajon ajaksi |
| pakettimanagerin `install` | S7b | repon `pnpm`/`npm`/`composer install` — **ja siten sen postinstall-skriptit** |
| `.claude/provision-test-env.sh` | S7c | repon oma skripti, joka pystyttää testiympäristön |
| `.claude/post-merge-migrate.sh` | PR-vahti mergen jälkeen | repon oma migraatioskripti mainissa |
| `.claude/run-issues.json` | S1 / S8 | **dataa, ei koodia** — luetaan `jq`:lla |

Käytännön seuraus: **jos ajat pakettia repolle, luotat sen `.claude/`-hakemistoon ja
riippuvuuspuuhun samalla tasolla kuin luottaisit siihen ajaessasi `npm install`in käsin.**
Vieraan repon ajaminen on sama päätös kuin vieraan repon asentaminen.

Yksi poikkeus listalla ei ole shell-mekanismi lainkaan: `.claude/refresh.json` on
`/issue-runner:refresh`-slash-komennon lukema konfiguraatio, jonka tulkitsee Claude-agentti. Mikään
paketin bash-skripti ei suorita sitä.

### 7.3 `RUN_ISSUES_AUTO=1` -rajat

Automaattiajossa agentti saa tehdä muutoksia ilman erillistä lupakyselyä. Sopimus siitä, mitä
tuo lupa kattaa ja mitkä ovat sen rajat, on **yhtenä tekstinä paketissa**:
[`principles/auto-run-contract.md`](principles/auto-run-contract.md). Lue rajat sieltä — tässä
osiossa niitä ei toisteta, jotta kahta rinnakkaista sanamuotoa ei pääse syntymään.

Toimitus on rakenteellinen, ei ohjeistettu: `lib/claude-call.sh` liittää sopimuksen
**jokaiseen** orkestroituun claude-kutsuun `--append-system-prompt-file`-lipulla — cycle
review, toteutus, evoluutiovaihe sekä PR-vahdin konfliktinratkaisu ja CI-korjaus. Mitään ei siis
tarvitse kopioida omaan `CLAUDE.md`-tiedostoon, eikä sopimus ole kiinni siitä, mitä ajokoneen
käyttäjätason muisti sattuu sisältämään.

Sopimus kulkee samassa järjestelmäkehotteessa kuin koodausstandardi (§5, `principles_file`),
mutta se on **eri tiedosto tarkoituksella**: kohderepon `principles_file`-korvaus ja
`RUN_ISSUES_PRINCIPLES_FILE=""` -opt-out koskevat vain koodausstandardia. Kumpikaan ei voi
pudottaa sopimusta, koska kohderepo ei saa pystyä poistamaan runnerin omia toimintarajoja.

Ajon feature-haaran nimi on repo-nimiavaruudella varustettu
(`auto-run/<repo-slug>-issue-<N>-<slug>`), jotta kahden repon issue #5 eivät törmää samassa
kloonissa. Ei-`origin`-remotelle nimeen tulee lisäksi remoten nimi.

### 7.4 AI-konfliktinratkaisu on oletuksena pois

`pr-watch.sh` pitää muuttujan `PR_WATCH_ENABLE_CONFLICT_RESOLUTION` arvossa `0`. **Poller
nostaa sen päälle** watchlistin repoille, jotta auto-merge pääsee rebase-konfliktin läpi ilman
ihmistä. Eli: käsin ajettu PR-vahti ei koskaan ratko konflikteja itse, pollerin ajama ratkoo.

Rajoittimet:

- Rebase tehdään **feature-haaran omassa worktreessä**, ei koskaan mainissa
  ([`prompts/04-conflict-resolution.md`](prompts/04-conflict-resolution.md)).
- **CI-revalidointi on pakollinen** ratkaisun jälkeen. Punainen CI ⇒ rebase perutaan tai
  jätetään tarkasteltavaksi, PR kommentoidaan ja vahti exittaa koodilla 6 ihmiselle.

Halutessasi voit pitää sen pois myös pollerissa: `PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0`
`poller.env`-tiedostossa.

### 7.5 AI-CI-korjaus on oletuksena pois

`pr-watch.sh` pitää muuttujan `PR_WATCH_ENABLE_CI_REPAIR` arvossa `0`. **Poller nostaa sen
päälle** watchlistin repoille. Kun auto-merge-PR:n **vaadittu** CI-check menee punaiseksi, PR
jäisi muuten roikkumaan ikuisesti (mikään ei muuta CI:n tulosta). Korjaus päällä vahti ajaa
AI-agentin, joka korjaa virheen ja pushaa — muuten sama malli kuin konfliktinratkaisussa.

Turvamalli:

- Korjaus tehdään **feature-haaran omassa worktreessä**, ei koskaan mainissa
  ([`prompts/05-ci-repair.md`](prompts/05-ci-repair.md)).
- Agentti korjaa **todellisen virheen**. Se **ei saa** viherryttää CI:tä huijaamalla: testin
  poistaminen, assertion löysääminen, `skip`/`only`/`continue-on-error`, timeoutin kasvatus tai
  CI-workflown muokkaus ovat kiellettyjä. Jos oikea korjaus ei ole yksiselitteinen, oikea
  lopputulos on **luovutus ihmiselle, ei vihreä CI** — väärin korjattu punainen CI on huonompi
  kuin korjaamaton.
- **CI-revalidointi on pakollinen** korjauksen jälkeen (sama portti kuin konfliktipolussa).
  Punainen CI, committamaton yritys tai täyttynyt yrityskatto (`PR_WATCH_MAX_CI_REPAIRS`,
  oletus `1`) ⇒ `needs-human`-label, PR-kommentti ja exit 8.
- Yrityskatto johdetaan run-dirin tapahtumalogista, joten tilaton vahti ei jää silmukkaan.
- `UNSTABLE`-tila (vaaditut checkit vihreitä, vain ei-vaadittu punainen) ei laukaise korjausta,
  eikä estä mergeä. `DIRTY`+punainen rebasetaan ensin.
- **Agentin käynnistyvyys tarkistetaan ennen korjausyritystä.** Jos claude-CLI ei ole
  käytettävissä — tyypillisesti oletuskutsun `npx --no-install` -ansa, jossa `npx` on polulla
  mutta pakettia ei ole asennettu — korjauspäätös alennetaan pelkäksi CI-odotukseksi. Yrityskatto
  ei siis kulu agenttiin joka ei koskaan käynnisty, ja PR palaa tarkasteluun seuraavalla tikillä.
- **Käynnistysvirhe raportoidaan käynnistysvirheenä.** Jos agenttikutsu silti epäonnistuu
  käynnistyksessä, PR-kommentti kertoo ettei agenttia voitu käynnistää — ei harhaanjohtavasti,
  että agentti tutki CI-virheen eikä löytänyt korjausta.

**Luovutus ei jäädytä PR:ää.** Luovutus finalisoi ajon tilaan `blocked/ci_repair_failed_pr_<n>`,
mutta skannaus poimii **juuri nämä** blocked-ajot uudelleen (muut blocked-tilat, kuten
`stalled_in_*`, jäävät skannauksen ulkopuolelle kuten ennenkin). `needs-human` toimii PR:llä
**pidätyslippuna**: sen ollessa paikallaan vahti ohittaa PR:n hiljaa eikä kommentoi uudelleen
joka tikillä. **Kun poistat labelin, ajo palaa käsittelyyn** ja PR mergetään heti kun CI on
vihreä — juuri niin kuin luovutuskommentti lupaa. Aiemmin luovutettu PR jäi käsin
mergettäväksi, vaikka CI olisi myöhemmin vihertynyt.

Halutessasi voit pitää sen pois myös pollerissa: `PR_WATCH_ENABLE_CI_REPAIR=0`
`poller.env`-tiedostossa.

### 7.6 Submodule-pinni on turvaportti

Kun paketti liitetään dotfiles-repoon, se liitetään **pinnattuna** git-submodulena. Pinni ei
ole versionhallintakosmetiikkaa vaan turvaraja.

Ilman pinniä ketju olisi: kollaboraattori pushaa paketin `main`iin → dotfilesin oma
synkronointi hakee muutoksen automaattisesti → symlinkki `~/.claude/scripts` osoittaa uuteen
koodiin → pollerin seuraava tikki ajaa sitä täysin oikeuksin toisen ihmisen koneella. Toisin
sanoen push tähän repoon olisi käytännössä etäkoodinsuoritus jokaisella asennetulla koneella.

Pinni tekee päivityksestä **eksplisiittisen päätöksen**: submodulen viittaus siirretään käsin,
ja siirto näkyy dotfiles-repon diffissä.

### 7.7 Asentaja kieltäytyy koskemasta vieraisiin tiedostoihin

Asentimen kantava invariantti on **INV-OWN**: se saa luoda, korvata tai poistaa vain polun,
joka **puuttuu** tai on **symlinkki, jonka kohde resolvoituu paketin juuren sisään**. Kaikki
muu on vierasta ja koskematonta.

Kolme seurausta:

1. **Omistajuus luetaan levyltä, ei manifestista.** Vanhentunut manifest antaisi
   poisto-oikeuden tiedostoon, jota paketti ei enää toimita. Symlinkin kohde ei voi valehdella.
2. **Suunnittelu ja soveltaminen ovat eri vaiheet.** Yksikin kieltäytyminen ⇒ **nolla
   muutosta**, ei puoliasennettua puuta.
3. **Asentaja ei kutsu `launchctl`ia.** Se ei mutatoi elävää käyttäjäsessiota puolestasi.

Käytännön ohje: aja aina `--dry-run` ensin ja lue suunnitelma. Se kertoo tarkalleen jokaisen
polun, johon kosketaan.

### 7.8 Statussivun web-esitys on uusi altistuspinta

[`status-render.sh`](status-render.sh) muuntaa `status.sh`:n JSONin selainpohjaiseksi
web-esitykseksi (`index.html` + `status.json`) hakemistoon `RUN_ISSUES_STATUS_OUT_DIR` (oletus
`${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/www`). `index.html` on itsenäinen
selainsovellus, joka hakee `status.json`in `fetch`illä; **molemmat tiedostot tarjoillaan samasta
hakemistosta ja ovat siis saman pääsynhallinnan takana.** Valinnainen LaunchAgent
`com.claude-issue-runner.status-render.plist` regeneroi rungon 300 s välein.

**Paketti tuottaa vain tiedostot. Se ei koskaan päätä, miten sivu altistetaan** — ei vhostia,
ei domainia, ei tunnelia. Altistuspäätös (Caddy-vhost, Tailscale-bind, todennettu proxy) on
koneen omistajan konfiguraatiota, ei tämän repon sisältöä. Syy on vuotoraja: **datassa on
repo-slugit, issue-numerot, PR-URLit ja haaranimet** — ja haaranimet ja repo-slugit paljastavat
rutiininomaisesti asiakasnimiä ja sisäistä projektirakennetta. Julkisen tunnelin takana ilman
pääsynhallintaa ne olisivat maailmanlaajuisesti luettavissa.

Kaksi rakenteellista suojaa pienentää vuotoa jo lähteellä:

- **Kenttävalkolista, ei mustalista.** `status.sh` kokoaa jokaisen `runs[]`-objektin nimetyistä
  kentistä, ja selain-JS lukee vain noita nimettyjä kenttiä eikä koskaan itereoi run- tai
  `github`-objektia. Kielletyt kentät — issuen **runko**, agenttien tuloste, lokit, promptit,
  absoluuttiset polut — eivät koskaan päädy `runs[]`iin eivätkä sivulle. Mustalista vuotaisi
  aina myöhemmin skeemaan lisätyn kentän; valkolista ei voi.
- **Turvallinen DOM-insertointi.** Selain-JS insertoi jokaisen datamerkkijonon `textContent`illä
  (ei koskaan `innerHTML`illä), joten `<script>`-niminen haara tai issue-otsikko renderöityy
  tekstinä, ei suoritettavana koodina.

**Issue-otsikot ovat opt-in-poikkeus tähän (#78).** Kun `RUN_ISSUES_RENDER_GITHUB=1`, sivulle
tulee issuen **otsikko** (`gh`-datana, `runs[].github.issue_title`-kentässä — ei ajon päätasolla,
jotta provenienssi säilyy) rivin pääteksinä, sekä avoimen PR:n CI-tila ja mergevalmius. Otsikko on
tietoinen valinta: se paljastaa asiakas- ja projektikontekstia selväsanaisemmin kuin repo-slug tai
haaranimi, joten **se on sallittu vain niin kauan kuin sivu on pelkässä tailnetissä.** Ilman lippua
(oletus `0`) sivu on bitilleen kuin ennen: ei otsikoita, vain V1-näkymä. Otsikoiden näyttäminen
nostaa siis julkisen altistuksen rimaa entisestään — älä kytke sivua julkisen tunnelin taakse.

Mutta valkolista ei korvaa pääsynhallintaa: **`index.html` ei sisällä autentikointia.**
Verkkokerros on ainoa suoja. [`examples/status-caddy.example`](examples/status-caddy.example)
sitoo palvelimen Tailscale-osoitteeseen ja nimeää julkisen altistuksen riskin; älä kytke sitä
julkisen tunnelin taakse ilman todennettua pääsynhallintaa.

### 7.9 Ohjaamon toimintopalvelu on mutaatiokanava — turvamalli sitova

Statussivu on lähtökohtaisesti **luku-pinta**. Kun asennat Ohjaamon toimintopalvelun
([`action-server.sh`](action-server.sh)), sivulle tulee viisi toimintonappia (Pysäytä / Siivoa / Nollaa /
Salli auto-merge / Jatka), joista jokainen on ohut kuori olemassa olevan skriptin tai labelin
päälle — mutta se on myös **kirjoitusrajapinta**, joten turvamalli on tiukempi kuin sivulla.
Kaikki alla oleva on **sitovaa**, ei suositus.

**Palvelu on opt-in kolmella portaalla, joista jokainen puuttuessaan pitää sivun V1-lukupintana:**

1. **Palvelua ei ole asennettu.** Ilman `action-server.sh`-daemonia napit yrittäisivät POSTata
   olemattomaan palveluun ja disabloituvat viestillä "toimintopalvelu ei tavoitettavissa". Sivu
   toimii täysin lukutilassa (turvamalli 6: sivun tarjoilu on eri prosessi, eri portti).
2. **Sivulla ei ole base-URLia.** `status-render.sh` upottaa toimintonapit ja jaetun tokenin vain
   kun `RUN_ISSUES_ACTION_BASE` on asetettu. Ilman sitä sivu on bitilleen V1 — ei nappeja, ei tokenia.
3. **Host-portti.** Palvelu (kuten pollerit) exittaa hiljaa koneella, joka ei matchaa
   `RUN_ISSUES_ACTION_HOSTS`:ia.

**Neljä sitovaa turvaperiaatetta:**

- **Vain Tailscale-osoite, ei koskaan wildcard.** Palvelu bindaa `tailscale ip -4`:n osoitteeseen
  (portti 8081; 8080 on Caddyn). Jos Tailscale-osoitetta ei ratkea, palvelu **kieltäytyy
  bindaamasta** (exit 3, launchd yrittää uudelleen) — se ei koskaan putoa `0.0.0.0`:aan.
- **Identiteetti luetaan socketin peer-IP:stä `tailscale whois`illa, fail-closed.** Tuntematon
  kutsuja, tyhjä tulos tai jäsennysvirhe → 403. **Palvelua ei saa laittaa reverse proxyn taakse:**
  proxy korvaisi peer-IP:n omallaan, jolloin whois muuttuisi tautologiaksi. Palvelu **ei koskaan**
  lue forwardattuja headereita — peer-IP tulee aina socketista.
- **Luottamusraja on tailnet-käyttäjä, ei laite.** Sallittujen oletus on tämän noden oma
  tailnet-omistaja; myös sama käyttäjä puhelimesta ja läppäriltä läpäisee (haluttu — Ohjaamoa
  käytetään puhelimesta). Laajenna `RUN_ISSUES_ACTION_ALLOWED_USERS`illa.
- **CSRF-suoja kolmena kerroksena.** `tailscale whois` todentaa *laitteen*, ei *sivua*: mikä
  tahansa selaimessa avattu nettisivu voisi POSTata palveluun. Suoja: (1) pakollinen,
  valkolistattu `Origin`; (2) pakotettu preflight (custom-header + JSON-content-type, jotka
  vievät selaimen CORS-preflightiin); (3) jaettu token, jonka `status-render.sh` upottaa sivuun ja
  palvelu vaatii joka pyynnössä — sivua lukematon kutsuja ei saa tokenia. Token on bearer-salaisuus:
  se elää vain `index.html`issä (tailnet-only) eikä koskaan `status.json`issa tai audit-lokissa.

**Jokainen toimenpide — myös hylätty — kirjataan audit-lokiin**
(`$RUN_ISSUES_LOG_DIR/run-issues-action.audit.log`): aikaleima, LoginName, node, peer-IP, toiminto,
kohde, lopputulos. Mutatoivat napit vaativat selaimessa vahvistuksen, joka **nimeää seuraukset**
("Worktree, haara ja run-dir…"); massatoiminto (Siivoa kaikki N) nimeää lukumäärän. Delegoitava
komento ratkaisee lopun: jos se puuttuu tai epäonnistuu, virhe näytetään sellaisenaan — palvelu ei
yritä itse.

Kuten statussivu, myös toimintopalvelu **on pidettävä vain tailnetissä** — sen napit mutatoivat
tuotanto-orkestraatiota. Sen deploy: `install.sh --with-launchagents` (ks. §7.7 ja
`examples/run-issues-poller.env.example`).

### 7.10 Self-update pitää paketin ajan tasalla — luottamusraja on PR-katselmointi

[`self-update.sh`](self-update.sh) on LaunchAgent (tunnin välein), joka pitää **asennetun
paketin** itsestään ajan tasalla, jotta uudet ja poistuneet agentit, komennot ja skillit
linkittyvät ja pruneutuvat ilman käsiajoa. Se sulkee aukon, jossa koneen dotfiles-synkka soveltaa
submodule-pinnin muttei aja asentajaa. Kaksi ympäristöä eroavat **vain pull-vaiheessa:**

- **Kehittäjäkone** (klooni missä tahansa): vartioitu `git pull --ff-only origin/main`, sitten
  `install.sh`.
- **Ylläpitäjän kone** (klooni on dotfiles-submodule): pull ohitetaan **aina** — pinnin omistaa
  dotfilesin `bump-run-issues`-CI, eikä self-update koskaan liikuta sitä. Vain asennusvaihe ajetaan.

Pull on **vartioitu ja ei-destruktiivinen:** se ajetaan vain kun klooni ei ole submodule, HEAD on
`main` ja työpuu on puhdas, ja veto on aina `git pull --ff-only` — ei koskaan rebasea eikä resetiä,
joten paikallista työtä ei tuhota. Minkä tahansa vartion tai vedon kaatuminen (esim. verkkovirhe
tai jäljessä oleva `main`) on lokirivi, ei virhe; asennusvaihe ajetaan silti. **Idle-portti** edeltää
tikkiä: jos koneella on elävä ajo (`run.json`, tila `initialized`, host == tämä kone), koko tikki
ohitetaan — koodia ei liikuteta elävän ajon alta.

**Arkistointivaihe (run-dirien elinkaari).** Asennuksen jälkeen tikki siirtää kunkin watchlistin
repon **terminaalitilaiset, ikääntyneet ja PR:ttä vailla olevat** ajohakemistot pois aktiivisesta
`.claude/run-issues/`-hakemistosta repo-kohtaiseen arkistoon `.claude/run-issues-archive/`. Run-dirit
eivät ennen poistuneet koskaan itsestään, ja niiden määrä kasvatti jokaista skannausta joka luki
hakemistoja tai issueita ajoa kohti (`scan_clean`, `status.sh`). Arkistointi **ei poista** mitään —
ajohistoria säilyy levyllä, se vain lakkaa maksamasta kuumilla poluilla. Siirretään vain
`completed`/`merged`-tila (elävä `initialized` sekä vastausta odottavat `blocked`/
`awaiting_clarification` jätetään rauhaan), ja `completed`-ajo jonka PR on paikallisen tilan mukaan
yhä auki suojataan (tarkistus tehdään ilman gh-kutsua). Ikäraja on `RUN_ISSUES_ARCHIVE_AFTER_DAYS`
(oletus 30 vrk; `0` tai alle poistaa arkistoinnin käytöstä). Siirto on atominen `mv` samalla levyllä,
idempotentti ja keskeytyskestävä. Tämä elää self-updatessa — ei pollerin kiintiökriittisessä tikissä —
juuri siksi että se on jo tunnittainen ja idle-portitettu.

**Käyttöönotto** on sama kuin muillakin LaunchAgenteilla: `install.sh --with-launchagents` linkittää
plistin ja **tulostaa** `launchctl bootstrap gui/<uid> <plist>` -komennon, jonka ajat käsin.
self-update **ei koskaan kutsu `launchctl`ia** itse (samat syyt kuin asentajalla, §7.7); jos se
linkittää uuden plistin, se kirjoittaa lokiin NOTE-rivin muistuttamaan bootstrapista. Opt-in on siis
se, että operaattori bootstrappaa agentin — **ei host-porttia**. **Kill-switch:**
`RUN_ISSUES_SELF_UPDATE=0` `poller.env`issä ohittaa tikin.

**Luottamusraja on eksplisiittinen ja sitova:** valvomaton pull ajaa `main`iin **mergetyn** koodin
seuraavalla tikillä ja `install.sh` linkittää sen tälle koneelle. Portti on siis **PR-katselmointi,
ei asennushetki** — samalla tavalla kuin `RUN_ISSUES_AUTO=1` (§7.3) siirtää luottamuksen issueen ja
katselmointiin. Kehittäjäkoneella tämä tarkoittaa: jokainen `main`iin mergetty commit ajautuu
koneellesi tunnin sisällä. Jos et halua sitä, älä bootstrappaa self-update-agenttia — tai aja klooni
submodulena, jolloin pull ohitetaan ja päivitys on eksplisiittinen pinnin nosto.

---

## 8. Perehdytys — miksi se käyttäytyy noin

Viisi asiaa, jotka selittävät ensimmäisen viikon yllätykset.

### Tarkennuskysymykseen vastataan **yhdellä** kommentilla

Vastauksesta poimitaan vain uusin markerin jälkeinen ei-bottikommentti, ja se katkaistaan 8000
merkkiin. Sääntö on **rakenteellinen, ei tyylisuositus**: bot ja ihminen käyttävät samaa
GitHub-tiliä, joten kommentin kirjoittaja ei kelpaa erottimeksi — ainoa luotettava raja on
markerin aikaleima. Koko kulku: kohta 6.6 c).

### Assignaatio on varaus, ei kirjanpitoa

Automaatio poimii vain issueita, joilla ei ole yhtään assigneeta, ja epäonnistunut ajo
**jättää assignaationsa voimaan**. Se on tarkoituksellinen jarru: ilman sitä poller ajaisi
saman issuen samaan seinään viiden minuutin välein. Vapautus tapahtuu siivouksessa (6.4).

### Exit-koodeja on kolme erillistä avaruutta

Sama numero tarkoittaa eri asiaa orkestraattorissa, asentimessa ja PR-vahdissa.
Ks. [`docs/troubleshooting.md`](docs/troubleshooting.md).

### Poller on host-portattu

Poller vertaa koneen lyhyttä konenimeä (`runner_host`) muuttujaan `RUN_ISSUES_POLLER_HOSTS` ja **exittaa 0** jos
osumaa ei tule. Väärällä koneella se ei siis kerro mitään — se vain ei tee mitään. Sama
hiljainen `exit 0` seuraa puuttuvasta `tmux`ista, puuttuvasta watchlististä ja viallisesta
watchlist-JSONista.

**Muuttujalla ei ole oletusarvoa, ja asettamatta jättäminen on eri asia kuin osumattomuus.**
Asettamatta poller ei aja millään koneella (fail-closed kuten muutkin portit), mutta se ei
vaikene: se kirjoittaa yhden rivin, joka nimeää muuttujan, `poller.env`-polun ja tämän koneen
nimen. Rivi menee **sekä stderriin että pollerin omaan lokiin** (`run-issues-poller.log`,
`pr-watch-poller.log`, `run-issues-action.stderr.log`) — pelkkä stderr ei riitä, koska portti
ajetaan ennen kuin skripti on avannut lokinsa, eivätkä plistit kanna `StandardErrorPath`-avainta
(osio 8), joten LaunchAgent-ajossa rivi katoaisi. Lokiin se kirjoitetaan **kerran**: tikki toistuu
viiden minuutin välein, ja toisto vaietaan vertaamalla lokin viimeiseen riviin.

Osumaton *asetettu* lista sen sijaan pysyy hiljaa eikä luo levylle mitään — se on vieras kone,
ja hiljaisuus on koko portin tarkoitus. Sama koskee `RUN_ISSUES_ACTION_HOSTS`:ia.

Käytännön seuraus: kone, jonka **ei** kuulu ajaa pollereita, kannattaa silti asettaa —
anna sille sen koneen nimi, jonka kuuluu ajaa. Silloin se on tietoinen no-op eikä
konfiguroimaton, eikä sen lokiin tule riviä.

### Ihmiseen viitataan roolilla, ei nimellä

Promptit, slash-komennot ja koodikommentit puhuvat ihmisestä **roolilla** —
"issuen kirjoittaja", "käyttäjä", "ylläpitäjä", "ihminen" — eivät nimellä. Nimi oli aiemmin
kovakoodattu 33 tiedostoon, mikä sitoi paketin yhteen henkilöön (#153).

Parametrisointia ei silti tehty: promptien sijoitusmekanismi kattaa vain
[`prompts/`](prompts)-hakemiston, kun taas `commands/`-tiedostot lukee Claude Code suoraan
levyltä. Roolisanamuoto toimii molemmissa ilman mekanismia, joten puoliksi parametrisoitu
`{{HUMAN}}` olisi ollut huonompi kuin kumpikaan puhdas vaihtoehto.
Ks. [`CLAUDE.md`](CLAUDE.md) §13.

Valinta on **kosmeettinen eikä vaikuta toimintaan**: bot ja ihminen erotellaan markerin
aikaleimalla, ei nimellä.

### Legacy-jäänteitä, joihin törmää

- Watchlistillä on toissijainen fallback vanhaan `~/dotfiles`-puuhun. Se ei laukea, jos
  ensisijainen polku osuu.

Se on kirjattu tietoiseksi shimmiksi: [`CLAUDE.md`](CLAUDE.md) §13. Host-portin
sisäänrakennettu konenimilista (`POLLER_HOSTS_LEGACY_DEFAULT`) oli toinen, ja se on
poistettu (#152): `RUN_ISSUES_POLLER_HOSTS` on nyt pakollinen konfiguraatio.

---

## 9. Vianetsintä

### Oirekartta

Yleisimmät tilanteet siinä järjestyksessä, jossa niihin törmää.

| Oire | Todennäköinen syy | Korjaus |
|---|---|---|
| Issue ei lähde ajoon, vaikka `auto-run` on | Assignee (myös oma) estää poiminnan | Poista assignaatio tai siivoa vanha ajo: `cleanup-run.sh --issue <N> --yes` |
| — sama, mutta assigneeta ei ole | Jokin estolabeli päällä: `waiting`, `wip`, `auto-clean` | Poista label |
| — sama, eikä estolabeleita ole | Issue on estetty natiivilla "blocked by" -riippuvuudella — esto ei näy labeleissa (6.5) | Sulje edeltäjä tai poista riippuvuus issuen näkymästä |
| — sama, eikä riippuvuuksia ole | Repo ei ole watchlistissä, tai poimintalabelien JA-ehto ei täyty (6.2) | Tarkista watchlist ja repon `labels`-lista |
| Yksittäinen issue ei lähde ajoon, vaikka labelit ovat oikein | Repolla on watchlistin `assignees`-rajaus, ja issue on assignattu listan ulkopuoliselle tunnukselle (6.2) | Assignaa listatulle tunnukselle, poista assignee kokonaan tai laajenna `assignees`-listaa |
| Kokonainen repo ei koskaan poimi mitään | `auto-clean` on listattu poimintalabeliksi ⇒ haku on itsensä kanssa ristiriidassa | Poista se watchlistin `labels`-listasta |
| Poller ei tee mitään eikä kerro miksi | Väärä konenimi, puuttuva `tmux`, puuttuva tai viallinen watchlist — kaikki exittaavat hiljaa nollalla | Lue pollerin loki; ks. "Mistä lokit löytyvät" |
| Ajo alkoi mutta mitään ei tapahdu | Rinnakkaisuuskatto täynnä | Lokissa `at cap (n/m)`; nosta `global_max_concurrent` tai odota |
| Vastasin tarkennuskysymykseen, mutta mitään ei tapahtunut | Vastaus ennen markeria, tai useampi kommentti (vain uusin luetaan) | Kirjoita vastaus uudelleen **yhtenä** kommenttina (6.6 c) |
| PR on auki, CI vihreä, mutta ei mergeydy | `auto-merge`-label puuttuu **PR:ltä**, tai PR on draft | Lisää label PR:lle; draft merkitään valmiiksi käsin |
| Ajo epäonnistui, korjasin syyn, issue ei palaa | Assignaatio ja `needs-human` jäivät | `/issue-runner:cleanup-run` tai `cleanup-run.sh --issue <N> --yes` |
| Siivous ei löydä ajoa | Ajo tapahtui toisella koneella | Aja siivous siellä; PR-vahti tulostaa lokiin valmiin komennon |

### Ajon tilat (`run.json`)

`status`-kenttä kertoo, mihin yksittäinen ajo päättyi. `reason`-kenttä tarkentaa syyn.

| Status | Merkitys | Mitä tapahtuu seuraavaksi |
|---|---|---|
| `completed` | PR avattu | PR-vahti hoitaa mergen |
| `awaiting_review` | Katselmointiportti käsiajossa | Odottaa `--resume`-päätöstäsi |
| `awaiting_clarification` | Katselmointi kysyi tarkennusta | Poller jatkaa, kun vastaat issueen |
| `timed_out` | Claude-kutsu ylitti aikabudjetin | Poller yrittää `--restart`, jos budjetti riittää |
| `blocked` | Ajo pysähtyi virheeseen | `needs-human`-label + kommentti; vaatii ihmisen |
| `lost_race` | Toinen ajo ehti varata issuen | Ei toimenpiteitä — normaalia rinnakkaisuutta |
| `cancelled` | Peruttu katselmointiportissa | Worktree ja haara jätettiin paikoilleen |

`blocked`-tilan tavalliset syyt: `cycle_review_BLOCKER`, `origin_fetch_failed`,
`worktree_base_unresolved`, `worktree_leftover_branch`, `worktree_create_failed`,
`env_bootstrap_failed`, `env_bootstrap_timeout`, `provision_test_env_failed`,
`implementer_BLOCKED`, `clarification_loop_exhausted`, `git_push_failed`,
`pr_create_failed`, `stalled_in_<vaihe>`. Näistä kaikki jättävät issuelle
`needs-human`-labelin; kolme S4-syytä on avattu korjauskomentoineen kohdassa (e) yllä.
Poikkeus on `blocked_by_dependency` (exit 9), joka on odotustila eikä labeloi mitään —
ajo jatkuu itsestään kun estäjä sulkeutuu.

### Exit-koodit

Useita skriptejä, **kukin oma erillinen exit-koodiavaruutensa**. Sama numero ei tarkoita samaa
asiaa eri skripteissä — tarkista aina, kumpi prosessi exittasi.

Täydet taulukot kaikille neljälletoista skriptille ovat omassa hakuteoksessaan:
[`docs/troubleshooting.md`](docs/troubleshooting.md). Se on skriptikohtainen diagnostiikka,
jota luetaan hakusanalla — skriptin nimellä tai koodilla — eikä alusta loppuun.

### Mistä lokit löytyvät

- **Pollerit:** `$RUN_ISSUES_LOG_DIR` (oletus macOS:llä `$HOME/Library/Logs`, muualla
  `${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/logs`), neljä tiedostoa per
  poller: `.log`, `.runs.log`, `.stdout.log`, `.stderr.log`. Tiedostojen etuliitteet ovat
  `run-issues-poller` ja `pr-watch-poller`.
- **Self-update:** sama `$RUN_ISSUES_LOG_DIR`, etuliite `run-issues-self-update` (`.log`,
  `.stdout.log`, `.stderr.log`). Rotatoituu `RUN_ISSUES_LOG_MAX_BYTES`illa kuten pollerit.
- **Yksittäinen ajo:** `<kohderepo>/.claude/run-issues/<run-id>/` — `run.json` (tilan
  tilannekuva) ja `state.jsonl` (append-only tapahtumaloki).
- **Lukot:** `$RUN_ISSUES_LOCK_ROOT` — oletus macOS:llä
  `$HOME/Library/Application Support/run-issues/locks`, muualla
  `${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/locks`.

### Siivous

Keskenjäänyt ajo jättää jälkeensä viisi asiaa: worktreen, paikallisen haaran, run-dirin,
paikallisen lukon ja GitHub-assignaation (sekä mahdollisen db-kloonin ja
`needs-human`-labelin). Kaikki puretaan yhdellä komennolla **sillä koneella, jossa ajo
tapahtui**:

```bash
# Claude Codessa, kohderepon juuressa:
/issue-runner:cleanup-run --list
/issue-runner:cleanup-run --issue <N>

# tai suoraan, esim. ssh:n yli poller-koneella:
"$HOME/.claude/scripts/run-issues/cleanup-run.sh" --list
"$HOME/.claude/scripts/run-issues/cleanup-run.sh" --issue <N> --yes
"$HOME/.claude/scripts/run-issues/cleanup-run.sh" --issue <N> --force --yes   # myös completed-ajot
```

Kolme sääntöä:

- **`--dry-run` ensin**, jos et ole varma mitä hakemistossa on. Se tulostaa jokaisen
  toimenpiteen tekemättä mitään.
- **`--force` vain kun PR on mergetty tai suljettu.** Ilman sitä `completed`-ajot jätetään
  rauhaan, koska niillä on yleensä avoin PR — sen worktreen purku katkaisisi PR-vahdin työn.
- **Olennaiset artefaktit arkistoidaan** hakemistoon `.claude/run-issues-archive/<run-id>/`
  ennen purkua, joten siivous ei hävitä tutkittavaa jälkeä.

Vaihtoehto ilman komentoriviä: lisää issuelle `auto-clean`-label, jolloin poller tekee saman
ja sulkee issuen (6.6 h) — tai `auto-reset`, jolloin poller tekee saman purun mutta jättää
issuen auki, ja ajo alkaa alusta puhtaasta basesta (6.6 i).

### Hätävarat

- `RUN_ISSUES_SKIP_PREFLIGHT=1` ohittaa S0-portin. Käytä vain jos portti on väärässä — se ei
  saa koskaan olla syy siihen, ettei ajo käynnisty toimivalla koneella.
- `RUN_ISSUES_CLAUDE_TIMEOUT` nostaa yksittäisen Claude-kutsun aikabudjettia, jos ajo
  aikakatkeaa toistuvasti samassa vaiheessa.
- Automaation saa kokonaan seis purkamalla LaunchAgentit
  (`launchctl bootout gui/$(id -u)/com.claude-issue-runner.run-issues-poller` ja sama
  `pr-watch-poller`-agentille). Kesken olevat ajot jäävät tmux-sessioihin elämään.

---

## 10. Testit

```bash
bash tests/run-all.sh        # paketin juuresta
bash tests/test-<nimi>.sh    # yksittäinen testi
```

Plain bash, ei testiframeworkia. Jokainen `test-*.sh` exittaa 0 = pass, ≠0 = fail. Kun esiehto
puuttuu (ei `jq`:ta, ei paikallista tietokantaa, väärä host), testi tulostaa `SKIP: <syy>` ja
exittaa **0** — paketti on siis testattavissa ilman alkuperäisen ylläpitäjän ympäristöä.

### Rinnakkaisajo

Ajuri ajaa testitiedostot rinnakkain, oletuksena **kaksi kertaa ytimien verran** (katto 32).
Kerroin kaksi on mitattu, ja sen hyöty riippuu siitä mitä odottaminen on: siellä missä
estynyt työntekijä jättää ytimensä tyhjäkäynnille se maksaa itsensä takaisin (macOS-runner
111 s → 74 s, 14-ytiminen kone 34 s → 30 s), ja siellä missä "odottaminen" on itse
prosessorityötä se ei tee mitään (Windows-runner 1015 s → 1020 s, koska MSYS emuloi
`fork()`:in kopioimalla prosessitilan — kaksi ydintä ei voi tehdä sitä enempää). Myös
rinnakkaisuuden syy on mitattu: paketti ei kuormita prosessoria vaan käynnistää prosesseja
— samat 92 tiedostoa veivät yhdessä CI-ajossa macOS:llä 4,1 min ja Windowsissa 20,3 min, ja
ne 63 tiedostoa jotka macOS suoritti alle sekunnissa veivät Git Bashissa keskimäärin 6,3 s.
Kun kustannus osuu tiedostoon joka ei tee mitään, kyse ei ole tiedoston työstä vaan
käynnistyksen hinnasta (MSYS emuloi `fork()`:in), eikä ajuri voi tehdä käynnistyksestä
halvempaa — vain limittää odottamisen.

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_TEST_JOBS` | 2 × ytimet, väliltä 2–32 | Montako testitiedostoa ajetaan yhtä aikaa. `1` = sarjassa **ja** live-tuloste |

Rinnakkaisajossa tiedoston tuloste kerätään talteen ja tulostetaan yhtenä lohkona vasta kun
tiedosto valmistuu, joten lohkot pysyvät ehjinä mutta valmistumisjärjestyksessä. Kun jokin
testi jumittaa, aja se sarjassa (`RUN_ISSUES_TEST_JOBS=1`) — silloin tuloste virtaa
puskuroimattomana ja näet mihin kohtaan se pysähtyi. Keskeytys (Ctrl-C) nimeää ne tiedostot,
jotka olivat vielä kesken.

Rinnakkaisuus on turvallista, koska testit ovat hermeettisiä: jokainen rakentaa oman
`mktemp`-puunsa, osoittaa `HOME`:n ja `RUN_ISSUES_*`-polut sen sisään ja pyytää ytimeltä
efemeerin portin silloin kun se sitoo sellaisen. **Uuden testin on täytettävä sama ehto** —
kiinteä polku tai kiinteä portti näkyy satunnaisena punaisena rivinä, ei suorana virheenä.

Testit **eivät koske oikeaan `~/.claude`-hakemistoon**: asentimen polut johdetaan
`RUN_ISSUES_CLAUDE_HOME`- ja `RUN_ISSUES_LAUNCH_AGENTS_DIR`-overrideista, ja
`tests/test-install-portability.sh` vartioi tätä. Se ei ole tyylisääntö vaan ehto sille, että
testit voi ajaa samalla koneella jolla poller pyörii.

### CI-ajo

Kaksi workflow'ta, joilla on eri tehtävä:

| Workflow | Laukaisin | Alusta | Rooli |
|---|---|---|---|
| `.github/workflows/tests.yml` | jokainen pull request ja `main`-push | `macos-latest` (+ `brew install coreutils`) ja `windows-latest` (Git Bash, `MSYS=winsymlinks:nativestrict`) | **portti** — PR:n ainoat checkit; punainen ajo estää mergen |
| `.github/workflows/portability.yml` | `main`-push ja käsin (`workflow_dispatch`) | `ubuntu-latest` | **mittaus** — tulokset luetaan Actions-välilehdeltä |

Portissa on kaksi alustaa, koska tuettuja ajotapoja on kaksi: macOS ajaa pollerit ja
LaunchAgentit, Windows ajaa interaktiivisen polun (osio 3.2). Ubuntu on yhä mittaus, koska
Linux-ajokoneen polkua ei ole ajettu läpi kertaakaan (osio 3.1) — siellä punainen rivi on
löydös, ei regressio.

**Neuvoa-antavaa jobia ei voi laittaa PR-workflow'hun.** PR-vahti lukee PR:n check-rollupin
eikä koskaan mergeä punaisella tai keskeneräisellä rollupilla: job-tason `continue-on-error`
**ei** tee epäonnistuneesta jobista `success`ia checks-API:ssa (vain workflow-ajo säästyy),
ja hidas job pitäisi rollupin PENDING-tilassa koko kestonsa. Kumpikin parkkeeraisi jokaisen
PR:n `WAIT_CI`-tilaan. Siksi alusta siirtyy `portability.yml`:stä `tests.yml`:ään vasta kun
se on vihreä ja sen on määrä pysyä vihreänä — se on migraation viimeinen askel, ei lipun
kääntö. Molemmilla workflow'illa on `timeout-minutes`, jottei jumiin jäänyt testi pidä ajoa
kuutta tuntia.

Repon juuren `.gitattributes` (`* text=auto eol=lf`) pitää työpuun rivinvaihdot LF:nä myös
Windowsissa — CRLF rikkoisi `#!`-rivit ja jättäisi `\r`:n jokaiseen `$(...)`-kaappaukseen
hiljaa. `tests/test-package-layout.sh` vartioi tiedostoa.

---

## 11. Viittaukset

- [`CLAUDE.md`](CLAUDE.md) — agentin konteksti: invariantit, mitatut rajoitteet ja tietoiset
  ei-päätökset. §5 = mitatut rajoitteet, §13 = tunnetut avoimet asiat.
- [`docs/env-reference.md`](docs/env-reference.md) — kaikki ympäristömuuttujat.
- [`docs/usage-reference.md`](docs/usage-reference.md) — työkalukohtainen
  käyttöreferenssi: epicit, käyttötapaukset, slash-komennot, skriptit, `claude-issue-runner`-skill,
  `status.sh`:n kokonaistilanäkymä ja `publish-release.sh` (osio 6 on ihmisen luettava
  *milloin ja miksi*).
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — skriptikohtainen vianetsintä:
  jokaisen skriptin exit-koodit omina erillisinä taulukoinaan (osio 9 on ihmisen oirekartta).
- [`docs/design-history.md`](docs/design-history.md) — issue-kohtainen suunnitteluhistoria
  2026-09-01 asti (historiallinen, ei ylläpidetty).
- [`db-clone/README.md`](db-clone/README.md) — tietokannan kloonaus (S5).
- [`provision-test-env.README.md`](provision-test-env.README.md) — testiympäristön
  provisiointihook (S7c).
- [`docs/sprite-runner.md`](docs/sprite-runner.md) — ajokone Fly.io Spritessä
  (ikkunamalli pollerin sijaan): pystytys, Postgres ilman Dockeria, työnjako labeleilla.
- [`docs/local-llm-runner.md`](docs/local-llm-runner.md) — ajokone paikallisella mallilla
  (ToshLLM + Claude Code Intel-Macilla): mitatut rajat, kääreskripti, sudenkuopat.
- [`docs/diagrams/`](docs/diagrams) — mermaid-kaaviot tilakoneista, poluista ja
  konfiguraation resolvoinnista.
- [`examples/`](examples) — watchlistin ja `poller.env`:n itsedokumentoivat mallit.
