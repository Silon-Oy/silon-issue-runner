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
sen **yksisuuntainen peili**, jonka historia on uudelleenkirjoitettu ilman noita nimiä (osio 6.11).
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
| `jq` | `brew install jq` |
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
  exit-koodin 4 — se ei kaada agenttien ja komentojen asennusta (osio 6.9).
- `~/.claude/scripts/run-issues` — **ehdollinen** sidonta. Jos polku jo toimii, se jätetään
  rauhaan. Jos sitä ei ole ja asentaja voi omistaa sen, luodaan symlink paketin juureen.
- `~/Library/LaunchAgents/` — vain `--with-launchagents`. Kaavio:
  [`docs/diagrams/install-plan-apply-flow.mmd`](docs/diagrams/install-plan-apply-flow.mmd).

### Asentimen exit-koodit

Oma avaruus. **Älä sekoita** orkestraattorin tai PR-vahdin koodeihin (osio 9).

| Koodi | Merkitys |
|---|---|
| 0 | Onnistui (tai `--dry-run` valmis) |
| 1 | Käyttövirhe (tuntematon lippu) |
| 2 | **Kieltäydytty — mitään ei muutettu.** Kohdepolku on jonkun muun omistama |
| 3 | Apply epäonnistui kesken (odottamaton tiedostojärjestelmävirhe); uusi ajo konvergoi |
| 4 | Valmis, mutta vieras tiedosto varjostaa paketin toimittamaa nimeä — mitään ei ylikirjoitettu |

**Exit 2 ei ole vika vaan haluttu turvakäyttäytyminen.** Se tarkoittaa, että asentaja löysi
polun jonka omistaa joku muu, ja jätti koko puun koskematta: nolla muutosta, ei
puoliasennusta. Korjaus on siirtää vieras tiedosto pois tieltä ja ajaa asennus uudelleen.

Yksi erikoistapaus kannattaa tunnistaa: jos `~/.claude/commands` on **kokonainen
hakemistosymlinkki** (dotfiles-asetelma, jossa koko hakemisto tulee muualta), asentaja
kieltäytyy aina. Korjaus kuuluu kyseiseen dotfiles-repoon: hakemisto korvataan tavallisella
hakemistolla, jossa on per-tiedosto-symlinkit. **Puhtaalla koneella** hakemistot ovat
tavallisia hakemistoja tai puuttuvat, jolloin asennus menee läpi normaalisti.

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
| Lukot `~/Library/Application Support/` | `RUN_ISSUES_LOCK_ROOT` |
| Lokit `~/Library/Logs/` | `RUN_ISSUES_LOG_DIR` |
| Status-välimuisti | Hoidettu — `XDG_CACHE_HOME` |
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
| `RUN_ISSUES_CLAUDE_CMD` | `npx --no-install @anthropic-ai/claude-code` | Claude-CLI:n kutsu |
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
| `RUN_ISSUES_POLLER_HOSTS` | *(ei oletusta — pakollinen)* | Glob-kuviot, joita verrataan `hostname -s`:ään. `*` sallii kaikki. Ei osumaa ⇒ poller exittaa 0. Asettamatta poller ei aja millään koneella, ja kertoo siitä yhdellä rivillä |
| `RUN_ISSUES_WATCHLIST` | *(tyhjä)* | Watchlistin polku; asetettuna ainoa ehdokas |
| `RUN_ISSUES_LOG_DIR` | `$HOME/Library/Logs` | Pollerien lokihakemisto |
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
   tai siivoamattomalle ajolle (ks. 6.4). **Assignaatio ei ole poimintaehto:** käsin assignattu
   issue lähtee ajoon normaalisti.
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
labelin nimi ei ole kovakoodattu poimintaan** — `auto-run` on pelkkä konventio. Poiminta on
**pollerin** tehtävä: orkestraattori ei enää poimi (ei `poll`-tilaa, ei `RUN_ISSUES_LABELS_CSV`ää),
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

#### Epicit — usean issuen ketjun ajaminen `auto-run`illa

Kun kokonaisuus koostuu monesta issuesta, voit koota ne **epic-issueen** ja ajaa koko ketjun
yhdellä signaalilla. Epic on GitHub-issue jolla on **`epic`-label**; sen alaissueet liitetään
GitHubin natiivilla **sub-issue**-toiminnolla (vanhoissa epiceissä rungon task-lista
`- [ ] Otsikko #123` toimii varamuotona). Ajojärjestys tulee alaissueiden keskinäisistä
`blocked_by`-riippuvuuksista aivan kuten yllä.

Rakenteen voi koota käsin GitHubin UI:ssa tai komennolla **`/issue-runner:new-epic <kuvaus kokonaisuudesta>`**,
joka pilkkoo kuvauksen epiciksi ja alaissueiksi, linkittää lapset sub-issueiksi, merkitsee
riippuvuudet ja labeloi **vain epicin** ajoon — tuossa järjestyksessä, koska ajolabeli ennen
riippuvuuksia päästäisi ketjun ajoon väärässä järjestyksessä. Komento ei aja mitään: sen jälkeen
ketjun käynnistää poller tai `/issue-runner:run-epic`.

- **Epic ei koskaan itse aja.** `epic`-label pitää epicin poiminnan ulkopuolella (sama tapa kuin
  `waiting`/`wip`), ja lukon jälkeinen S2c-portti varmistaa saman autoritatiivisesti — epicin
  "toteutus" on sen alaissueiden toteutus, ei epicin runko.
- **`auto-run` epicillä propagoituu alaissueille.** Lisää `auto-run` (ja mahdolliset muut repon
  vaatimat ajolabelit) **epiciin**, niin poller lisää ne epicin **avoimille** alaissueille joka
  tikki. Jo labeloidut, suljetut ja `wip`-merkityt lapset ohitetaan. Propagointi on jatkuvaa:
  myöhemmin lisätty alaissue saa labelin seuraavalla tikillä.
- **Jätä yksittäinen alaissue ajon ulkopuolelle `wip`illä** — älä poista siltä `auto-run`ia
  (propagointi palauttaisi sen).
- **Jumittunut alaissue nostetaan näkyviin.** Kun alaissue päätyy `needs-human`-tilaan, epiciin
  postataan **kerran** kommentti joka nimeää lapsen, ja epic saa suodatettavan
  `epic-attention`-labelin. Riippumattomat haarat jatkavat normaalisti.
- **Valmistuminen näkyy, sulkeminen jää sinulle.** Kun epicin **kaikki** alaissueet ovat kiinni,
  epic saa **kerran** yhteenvetokommentin (listaa alaissueet ja niiden PR:t) ja
  `epic-complete`-labelin. **Runner ei sulje epiciä** — tarkista epicin hyväksyntäkriteerit ja
  sulje itse (tai anna GitHubin natiivin auto-closen hoitaa se, jos repo on niin konfiguroitu).

Labelit `epic`, `epic-attention` ja `epic-complete` ovat kiinteitä nimiä.

- **Cross-repo-alaissueet ovat tuettuja.** Alaissue voi olla toisessa repossa kuin epic-issue
  itse (natiivi sub-issue toisesta repossa tai `owner/repo#N`-viittaus task-listassa). Runner
  käsittelee jokaisen lapsen sen **omassa repossa**: ajolabelit lisätään sinne, eskalaatio- ja
  valmiuskommentti nimeävät lapsen `owner/repo#N`-muodossa, ja valmius vaatii **kaikkien** lasten
  sulkeutumista repoista riippumatta. Jokainen lapsi ajetaan silti omassa repossaan omana
  ajonaan ja omana PR:nään — yhden ajon lukot ja worktree eivät ylitä repo-rajaa. **Huomaa:**
  lapsen ajaa vain kone, jonka watchlist kattaa kyseisen repon; `/issue-runner:run-epic`-raportti varoittaa
  erikseen lapsista, joiden repo ei ole tämän koneen watchlistissä (labelit lisätään, mutta
  mikään paikallinen poller ei aja niitä). Vieraan **organisaation** lapseen kirjoitus tapahtuu
  henkilökohtaisella identiteetillä tai epäonnistuu näkyvästi — GitHub App -tunnistautuminen on
  org-kohtainen (ei laajenneta).

**Yhden komennon käynnistys — `/issue-runner:run-epic`.** Sen sijaan että lisäisit `auto-run`in epiciin käsin
ja odottaisit tikkiä, `/issue-runner:run-epic #N` (skripti `run-epic.sh`) tekee sen heti: se **validoi**
epicin rakenteen (avoin, alaissueita on, `blocked_by`-graafi on syklitön) **ennen mitään
kirjoitusta**, lisää `epic`-labelin jos se puuttuu, propagoi ajolabelit avoimille alaissueille
(**sama jaettu propagointi** kuin pollerilla, kukin lapsen omaan repoon), ja raportoi **lapset
repoittain**: mikä alaissue ajaa ensin, mitkä ovat estettyjä ja minkä takana, kuinka pitkä ketju
on, ja mitkä lapset ovat repossa jota tämä kone ei aja. `--dry-run` tulostaa saman raportin
kirjoittamatta mitään; `--start-now` käynnistää ensimmäisen ajokelpoisen lapsen heti (hyödyllinen
koneella jolla poller ei aja). Ks. exit-koodit osiossa 9 ja ohje
[`commands/issue-runner/run-epic.md`](commands/issue-runner/run-epic.md).

**Epicin keskeytys — `/issue-runner:run-epic #N --stop`.** Symmetrinen käynnistyksen kanssa ja samalla
suunnittele–sovella-jaolla. Se tekee kaksi asiaa olemassa olevalla koneistolla: (1) pysäyttää
epicin **elävät lapsiajot** delegoimalla `stop-run.sh`:lle (turvakriittistä lopetuslogiikkaa ei
monisteta — sama periaate kuin `stop-run.sh` ↔ `lib/run-terminate.sh`), ja (2) vapauttaa
**jonossa olevat** poistamalla ajolabelit **ensin epiciltä, sitten avoimilta lapsilta** (toisin
päin poller ehtisi propagoida labelit takaisin kesken operaation). Raportti kertoo mitkä ajot
pysäytettiin, mitkä lapset vapautettiin, ja mitkä jäivät koskematta ja miksi (suljettu / vieras
kone / `wip` / terminaalitila). Se **ei pakota** terminaalitilan ajoa (avoin PR -kontekstin
repiminen ei ole keskeytys) eikä koske vieraan koneen ajoon — molemmat raportoidaan ja tekevät
kokonaisexitistä osittaisen (6). `--stop --dry-run` tulostaa saman suunnitelman kirjoittamatta.
Keskeytys **ei siivoa** worktreetä/haaraa/run-diriä (se ei ole cleanup — käytä `cleanup-run.sh`ia
tai `auto-clean`-labelia).

### 6.6 Käyttötapaukset

Kahdeksan tilannetta, joissa ihmistä tarvitaan tai kannattaa tietää mitä tapahtuu.

**a) Tavallinen automaattiajo.** Kirjoita issue, lisää `auto-run` (ja `auto-merge`, jos
haluat mergen ilman erillistä hyväksyntää). Poller poimii sen viiden minuutin sisällä. Saat
PR:n, jonka rungossa on katselmoinnin ja evoluution tulokset sekä `Closes #<N>`. Jos toteutus
jäi osittaiseksi, **PR avataan draftina** — se on tarkoituksellinen signaali, ja PR-vahti ei
mergeä draftia.

**b) Katselmointiportti käsiajossa.** Interaktiivisessa ajossa (`/issue-runner:run-issue #N` ilman
auto-tilaa) orkestraattori pysähtyy katselmoinnin jälkeen ja exittaa koodilla **10**. Ajo,
lukko ja assignaatio jäävät elämään. Jatka:

```bash
"$HOME/.claude/scripts/run-issues/orchestrate.sh" --resume <run-dir> --decision PROCEED
"$HOME/.claude/scripts/run-issues/orchestrate.sh" --resume <run-dir> --decision CANCEL
```

`CANCEL` päättää ajon siististi, vapauttaa assignaation ja **jättää worktreen ja haaran
paikoilleen** tarkastelua varten. Pollerin ajoissa porttia ei ole: se päättää itse.

**c) Tarkennuskysymys — tärkein ihmisen vuoro.** Jos katselmointi ei saa issuesta selvää, ajo
päättyy tilaan `awaiting_clarification`: issuelle tulee `waiting`-label ja kommentti, jossa on
kysymys ja pyyntö vastata. Kommentissa on näkymätön tunnistemerkki, jonka aikaleima on
vastauksen raja.

Vastaa **yhdellä kommentilla**. Poimintasääntö on kolmiosainen ja tiukka:

- Vain **markerin jälkeen** kirjoitetut kommentit lasketaan.
- Niistä otetaan **vain uusin**. Jos pilkot vastauksen kolmeen kommenttiin, kaksi ensimmäistä
  katoavat.
- Vastaus katkaistaan **8000 merkkiin**.

Sääntö on rakenteellinen, ei tyylisuositus: botti ja ihminen voivat käyttää samaa
GitHub-tiliä, joten kirjoittaja ei kelpaa erottimeksi — vain markerin aikaleima kelpaa.
Poller huomaa vastauksen seuraavalla tikillä, poistaa `waiting`-labelin ja jatkaa ajoa
(`--continue`) vastaus kontekstina. Kierroksia on enintään `RUN_ISSUES_MAX_CLARIFICATIONS`
(oletus 3); katon täytyttyä ajo päättyy tilaan `blocked/clarification_loop_exhausted` ja saa
`needs-human`-labelin. Kaavio:
[`docs/diagrams/run-issues-clarification-loop.mmd`](docs/diagrams/run-issues-clarification-loop.mmd).

**d) Ajo aikakatkaistiin.** Yksittäinen Claude-kutsu ylitti aikabudjetin (exit 7, tila
`timed_out`). Poller yrittää itse uudelleen `--restart`-ajolla, jossa timeout on
`perus × (1 + yritysten määrä)` kattoon `RUN_ISSUES_CLAUDE_TIMEOUT_MAX` asti. Yrityksiä on
`RUN_ISSUES_MAX_RETRIES` (oletus 1). Budjetin loputtua ajo jää odottamaan ihmistä. Sinä et
tee mitään ensimmäisen aikakatkaisun jälkeen — odota yksi tikki.

**e) Ajo estyi ennen toteutusta tai sen aikana** (exit 5). Syyn erottaa `run.json`-statuksen
syykentästä, ja jokainen niistä tuottaa issuelle `needs-human`-labelin ja kommentin, jossa on
tuloste:

| Syykenttä | Mitä tapahtui |
|---|---|
| `worktree_base_unresolved` | Feature-haaran base-refiä ei saatu ratkaistua: remotella on refejä mutta ei symbolista HEADia eikä `base_branch`ia ole asetettu. Korjaus: `git remote set-head <remote> -a` kohderepossa |
| `worktree_leftover_branch` | Saman issuen edellisestä ajosta jäi paikallinen haara (suljettu PR `--delete-branch`illa poistaa vain remote-haaran). Korjaus: `cleanup-run.sh --repo <polku> --issue <N>` |
| `worktree_create_failed` | Muu `git worktree add` -virhe (olemassa oleva worktree-hakemisto, levytila, oikeudet). Syytä ei arvata — gitin oma virheviesti on ajon lokissa |
| `env_bootstrap_failed` / `env_bootstrap_timeout` | Riippuvuuksien asennus kaatui — tyypillisesti puuttuva `GITHUB_TOKEN` yksityiselle riippuvuudelle |
| `provision_test_env_failed` | Repon oma testiympäristöhook kaatui |
| `db_clone_rc_<n>` | Db-kloonaus epäonnistui |
| toteuttaja palautti `BLOCKED` | Agentti ei pystynyt toteuttamaan issueta |

Korjaa syy, siivoa ajo (`/issue-runner:cleanup-run`) ja päästä issue takaisin poimintaan.

**f) Ajo jäi jumiin.** Jos ajon viimeisin tapahtuma on vanhempi kuin
`RUN_ISSUES_STALE_AFTER` (oletus 3600 s), poller tappaa sen tmux-session, merkitsee ajon
tilaan `blocked/stalled_in_<vaihe>`, lisää `needs-human`-labelin ja kommentoi issueen. Tämä
on turvaverkko roikkuvalle Claude-kutsulle — erityisesti jos `timeout`-binääri puuttuu
(osio 2).

**g) Issue ei lähde uudelleen liikkeelle epäonnistumisen jälkeen.** Odotettua: varaus
(`auto-claimed`) on yhä voimassa (6.4). Siivoa ajo sillä koneella, jossa se tapahtui:

```bash
"$HOME/.claude/scripts/run-issues/cleanup-run.sh" --list          # mitä ajoja on
"$HOME/.claude/scripts/run-issues/cleanup-run.sh" --issue <N> --yes
```

Siivous poistaa assignaation ja `needs-human`-labelin, purkaa worktreen, haaran, mahdollisen
db-kloonin ja lukon, ja arkistoi olennaiset artefaktit hakemistoon
`.claude/run-issues-archive/<run-id>/`. Sen jälkeen issue täyttää poimintaehdot uudelleen.
**Valmiiksi ajettuja ajoja (`completed`) ei siivota ilman `--force`-lippua**, koska niillä on
yleensä avoin PR.

**h) Haluat siivota issuen ajojäänteet automaattisesti.** Lisää issuelle `auto-clean`-label.
Poller huomaa sen ennen muuta työtä, ajaa siivouksen, **sulkee issuen**, poistaa labelin ja
kommentoi yhteenvedon. Jos issuella on `completed`-ajo (todennäköisesti avoin PR) tai jos
ajoja ei löydy tältä koneelta, siivous jättää issuen rauhaan ja lisää
`auto-clean-skipped`-labelin, jotta se ei yritä samaa joka viides minuutti. Kaavio:
[`docs/diagrams/run-issues-auto-clean-flow.mmd`](docs/diagrams/run-issues-auto-clean-flow.mmd).

**i) Haluat ajaa issuen alusta.** Lisää issuelle `auto-reset`-label (tai paina Ohjaamosta
*Nollaa*). Poller purkaa ajojäänteet **täsmälleen kuten `auto-clean`** — samat turvaportit,
sama `cleanup-run.sh` — mutta **jättää issuen auki**. Koska purku poistaa myös assignaation ja
`auto-claimed`/`needs-human`-labelit, issue täyttää poimintaehdot heti kun `auto-reset`-label
on poistettu, ja poller aloittaa ajon alusta puhtaasta basesta seuraavalla tikillä. Nollaus ei
käynnistä ajoa itse eikä avaa suljettua issueta.

Ero `auto-clean`iin on **vain lopputulos**: siivous on lopetusverbi (issue sulkeutuu), nollaus
on uudelleenajoverbi. Portit ovat kirjaimellisesti samat rivit (`lib/teardown.sh`). Jos issuella
on `completed`-ajo, jonka PR on yhä auki, nollaus kieltäytyy ja lisää `auto-reset-skipped`in —
muuten samalle issuelle syntyisi toinen PR. Sulje PR ensin.

**j) PR on auki — mitä auto-merge vaatii.** PR-vahti mergeää vain, kun **kaikki kolme**
toteutuu: PR:llä on `auto-merge`-label, CI on vihreä ja GitHub raportoi PR:n mergettäväksi.
Draft ei ole mergettävä. Vanhentuneen tai konfliktisen PR:n rebase tehdään feature-haaran
omassa worktreessä, ja CI on ajettava uudelleen vihreäksi ennen mergeä (osio 7.4). Punaisen
CI:n voi pollerin ajama vahti myös yrittää korjata AI-agentilla samassa worktreessä — mutta
vain todellista virhettä korjaten, ei testiä poistaen, ja CI on aina revalidoitava vihreäksi
ennen mergeä (osio 7.5). Itse merge yritetään ensin rebasena
(`gh pr merge --rebase --delete-branch`); jos GitHub torjuu sen — näin käy aina, kun
feature-haaralla on merge-commit, esimerkiksi konfliktin ratkaisusta — vahti tekee
merge-commitin (`--merge`). Ilman tätä varapolkua PR ei mergeytyisi koskaan, koska haaran muoto
ei muutu itsestään. Molempien yritysten virheteksti kirjataan lokiin, joten aito merge-esto
kertoo syynsä. Mergen
jälkeen vahti ajaa repon valinnaisen `.claude/post-merge-migrate.sh`-skriptin ja siivoaa
ajojäänteet — mutta **vain saman koneen ajot**; muille koneille se tulostaa lokiin valmiin
siivouskomennon.

**Kuvat issuessa.** Issuen rungon ja kommenttien kuvat ladataan paikallisesti ennen ajoa,
jotta agentti näkee ne (enintään 10 kuvaa, 10 MiB kukin). Ruutukaappaus on siis kelvollinen
osa speksiä. Epäonnistunut lataus ei kaada ajoa — agentti jää vain ilman kuvaa.

### 6.7 Slash-komennot

Claude Codessa, kohderepon juuressa:

| Komento | Argumentit | Mitä tekee |
|---|---|---|
| `/issue-runner:run-issue` | `[#N]` | Ajaa orkestraattorin nimetylle issuelle; ilman argumenttia poimii vanhimman ehdot täyttävän (6.2). Ohje: [`commands/issue-runner/run-issue.md`](commands/issue-runner/run-issue.md) |
| `/issue-runner:run-epic` | `[#N] [--dry-run] [--start-now] [--stop]` | Validoi ja käynnistää epicin: propagoi ajolabelit alaissueille ja raportoi ketjun tilan. `--stop` keskeyttää epicin (6.5). Ohje: [`commands/issue-runner/run-epic.md`](commands/issue-runner/run-epic.md) |
| `/issue-runner:new-issue` | `<kuvaus tehtävästä>` | Kirjoittaa kuvauksesta yhden ajon kokoisen issuen, joka täyttää kaikki poimintaehdot: paketin oma runko ja tämän koneen poimintalabelit (6.2). Luonnos vahvistetaan ennen kirjoitusta; epicin kokoinen kuvaus vain ehdotetaan eskaloitavaksi. Kysyy kohderepon kielimäärittelyn ja kirjaa sen repon `CLAUDE.md`:hen, jos se puuttuu. Ei aja mitään. Ohje: [`commands/issue-runner/new-issue.md`](commands/issue-runner/new-issue.md) |
| `/issue-runner:new-epic` | `<kuvaus kokonaisuudesta>` | Pilkkoo kuvauksen epiciksi ja alaissueiksi: luo issuet, linkittää sub-issueiksi, merkitsee `blocked_by`-riippuvuudet ja labeloi vain epicin ajoon (6.5). Kysyy kohderepon kielimäärittelyn kuten `/issue-runner:new-issue`. Ei aja mitään. Ohje: [`commands/issue-runner/new-epic.md`](commands/issue-runner/new-epic.md) |
| `/issue-runner:problem` | `<ongelma omin sanoin>` | Triagee kuvatun ongelman repon koodista ja lokeista, kysyy puuttuvat toistoaskeleet ja tarkistaa duplikaatit avoimista issueista. Päätyy yhteen kolmesta: korjausohje ilman issueta, issue `/issue-runner:new-issue`n kautta, tai kokonaisuus `/issue-runner:new-epic`in kautta. Ei korjaa eikä aja mitään. Ohje: [`commands/issue-runner/problem.md`](commands/issue-runner/problem.md) |
| `/issue-runner:pr-watch` | `[#PR \| scan]` | PR-vahti yhdelle PR:lle tai kaikille tämän koneen valmiille ajoille. Ohje: [`commands/issue-runner/pr-watch.md`](commands/issue-runner/pr-watch.md) |
| `/issue-runner:cleanup-run` | `[<run-id> \| --list \| --issue <N> \| --all]` | Siivoaa keskenjääneen ajon worktreen, haaran, run-dirin, lukon ja assignaation. Ohje: [`commands/issue-runner/cleanup-run.md`](commands/issue-runner/cleanup-run.md) |
| `/issue-runner:refresh` | — | Tuo repon ajan tasalle ja varmistaa että dev-server pyörii. Ohje: [`commands/issue-runner/refresh.md`](commands/issue-runner/refresh.md) |

Slash-komennot ovat ohjeita Claude Codelle, eivät skriptejä: agentti lukee ohjeen, ajaa
tarvittavat komennot ja tulkitsee tulokset. Siksi ne toimivat vain Claude Coden sisällä —
automaatio (poller) kutsuu skriptejä suoraan.

### 6.8 Skriptit ja apuvälineet

Kaikki paketin skriptit ovat ajettavissa suoraan polusta `$HOME/.claude/scripts/run-issues/`.
Tätä tarvitset silloin, kun olet toisella koneella ssh:n päässä tai kun Claude Code ei ole
käytettävissä.

| Skripti | Tyypillinen kutsu | Mitä tekee |
|---|---|---|
| `orchestrate.sh` | `orchestrate.sh <repo> <N>` | Yksi issue → yksi PR (issuenumero pakollinen). Muut moodit: `--resume <run-dir> --decision …`, `--restart <run-dir>`, `--continue <run-dir>`, `--remote <nimi>` |
| `run-epic.sh` | `run-epic.sh <N> --repo <polku>` | Validoi ja käynnistää epicin: propagoi ajolabelit alaissueille. `--stop` keskeyttää (pysäyttää elävät lapsiajot + poistaa ajolabelit). `--dry-run`, `--start-now`, `--remote`, `--labels` |
| `pr-watch.sh` | `pr-watch.sh <repo> <PR\|scan>` | PR → merge. Idempotentti, ei resume-tilaa |
| `status.sh` | `status.sh --json\|--human` | Kaikkien watchlist-repojen ajojen kokonaistila. Puhtaasti lukeva (ks. 6.10) |
| `stop-run.sh` | `stop-run.sh --repo <polku> --issue <N> --yes` | Yhden elävän ajon hallittu pysäytys (`blocked/stopped_by_operator`). Ei siivoa worktreetä/haaraa/run-diriä. `--run-dir`, `--remote`, `--force`, `--dry-run` |
| `cleanup-run.sh` | `cleanup-run.sh --issue <N> --yes` | Ajojäänteiden purku. `--list`, `--all`, `--force`, `--dry-run`, `--remote` |
| `auto-clean.sh` | *(pollerin kutsuma)* | Label-vetoinen siivous + issuen sulkeminen. Käsin: `--repo <polku> --issue <N>` |
| `auto-reset.sh` | *(pollerin kutsuma)* | Sama purku ilman issuen sulkemista — issue palaa poimintaan. Käsin: `--repo <polku> --issue <N>` |
| `poller.sh` | *(LaunchAgent, 300 s)* | Watchlistin issue-automaatio |
| `pr-watch-poller.sh` | *(LaunchAgent, 300 s)* | Watchlistin PR-automaatio |
| `install.sh` | `bash install.sh --dry-run` | Asennus (osio 3) |
| `publish-release.sh` | `publish-release.sh --target <git-url> --dry-run` | Julkaisu julkiseen peiliin: historia uudelleenkirjoitettuna filter-repolla, kaksi vuotoporttia (ks. 6.11). `--repo`, `--yes`, `--force` |

Kaksi asiaa kannattaa muistaa ajaessa käsin:

- **Siivous on konekohtaista.** Worktree, run-dir ja lukko ovat sillä koneella, jossa ajo
  tapahtui. Väärällä koneella ajettu siivous ei löydä mitään ja raportoi sen.
- **Pollerit ovat konelukittuja.** Ne vertaavat konenimeä muuttujaan
  `RUN_ISSUES_POLLER_HOSTS` ja exittaavat hiljaa nollalla, jos osumaa ei tule (osio 8).
  Muuttujalla ei ole oletusarvoa: asettamatta poller ei aja missään.

### 6.9 Skillit

Skill on **ehdollinen lataaja**: Claude lukee vain sen `description`-kentän ja päättää siitä,
vetääkö rungon mukaan sessioon. Se on oikea muoto silloin kun säännöllä on **aito laukaisuehto**,
ja väärä muoto aina päällä olevalle säännölle — sellainen kuuluu tiedostoon
[`principles/coding.md`](principles/coding.md), joka luetaan ehdoitta. `install.sh` linkittää
jokaisen paketin skillin polkuun `$HOME/.claude/skills/` **per hakemisto** samalla ajolla kuin
agentit ja slash-komennot, joten ne ovat **globaalisti käytettävissä** kaikissa repoissa, ei
vain tässä.

#### `claude-issue-runner` — järjestelmän oma skill

Päätökset järjestelmästä tehdään **kohderepossa**, jossa tätä README:tä ei ole vieressä: siellä
kirjoitetaan ja labeloidaan issue, ja siellä törmätään siihen mitä automaatio on jättänyt
jälkeensä. Sitä hetkeä varten paketti toimittaa skillin
[`skills/claude-issue-runner/SKILL.md`](skills/claude-issue-runner/SKILL.md).

Se latautuu Claude-sessioon progressiivisesti silloin kun näet järjestelmän jäljen (label,
`auto-run/`-haara, `run.json`, markerikommentti, botin avaama PR) ja kattaa kuusi asiaa:
järjestelmän **tunnistamisen**, koko **labelisanaston** omistajuuksineen, **poimintaehdot**,
**riippuvuudet ja epicit**, **ongelmatilanteiden purkamisen** (mitä näet → mitä teet) sekä
**komennot ja skriptit**. Rajanveto tähän dokumenttiin: skill on päätöskriittinen ydin, README
täysi lähde. Skill **ei** kata tilakonetta, exit-koodeja, `lib/`-rakennetta, asennusta,
turvamallia, LaunchAgenteja eikä statussivua — ne ovat tämän paketin anatomiaa ja kuvattu tässä
dokumentissa ja `CLAUDE.md`:ssä.

Sisällön ajantasaisuutta vartioivat `tests/test-skill-labels.sh` (labelisanasto molempiin
suuntiin) ja `tests/test-skill-surface.sh` (komento- ja skriptipinta molempiin suuntiin).

#### Laukeavat skillit

Nämä eivät koske järjestelmää itseään vaan **yhtä työn lajia**, jolla on tunnistettava alkuhetki.
Sisältö on samaa luokkaa kuin `principles/coding.md`:ssä — geneeristä, ei kenenkään
konfiguraatiota — mutta ehdollisena, koska sääntö on merkityksetön silloin kun sitä ei tarvita.

| Skill | Laukeaa kun | Kattaa |
|---|---|---|
| [`e2e-testing`](skills/e2e-testing/SKILL.md) | kirjoitat, korjaat tai katselmoit selainta ajavaa end-to-end-testiä | Playwright oletuksena, web-first assertions käsin kirjoitettujen odotusten sijaan, `data-test`/`data-testid` tekstipohjaisten valitsimien sijaan, ja testitunnukset erillisenä tilinä — ei olemassa olevan käyttäjän salasanaa vaihtamalla |
| [`container-build`](skills/container-build/SKILL.md) | projektin ensimmäinen konttibuild, tai image-buildi on hidas, ei osu cacheen tai epäilyttää sisältönsä puolesta | `.dockerignore` **ennen** ensimmäistä buildia ja mitä build-konteksti ilman sitä imaisee (riippuvuushakemistot, `.git`, `.env*`) |

`tests/test-skill-triggers.sh` vartioi molempia sääntöjä mekaanisesti jokaiselle paketin
skillille: `description` ei saa lukea ehdoitta laukeavana, eikä skill saa nimetä toista
skilliä, jota paketti ei toimita.

#### Kun `$HOME/.claude/skills` on vieras hakemistosymlinkki

Jos `$HOME/.claude/skills` on koneella kokonainen hakemistosymlinkki (jonkin toisen lähteen
omistama hakemisto), skillit eivät asennu automaattisesti: `install.sh` tulostaa siitä
`CONFLICT`-rivin ja exit-koodin 4, mutta linkittää agentit ja komennot normaalisti. Miksi
kieltäytymisen sijaan conflict: [`CLAUDE.md`](CLAUDE.md) §3.

### 6.10 Kokonaistilan katsominen (`status.sh`)

Kun yksi kone ajaa kymmenien repojen orkestrointeja rinnakkain, kokonaistilaa ei näe mistään:
levyllä on satoja run-direjä, joista muutama vaatii ihmistä (blocked, timed_out,
awaiting_clarification, pr_conflicted) hukkuu siivoamattomien valmiiden ajojen joukkoon.
`status.sh` aggregoi kaikkien watchlist-repojen run-dirit yhdeksi näkymäksi. Se on **puhtaasti
lukeva**: ei verkkoa, ei mitään mutaatiota, vain bash + `jq`.

```bash
status.sh                     # --human kun stdout on pääte, muuten --json
status.sh --human             # tiivis yhteenveto: huomiota vaativat, laskurit, siivousjono
status.sh --json | jq …       # versioitu dokumentti (schema_version: 1) putkeen
status.sh --class attention   # näytä kaikki huomiota vaativat ajot (ei 10 rivin kattoa)
status.sh --repo <polku>      # rajaa yhteen watchlist-repoon
status.sh --stale-after 7200  # oma jumiutumisraja (oletus 3600, sama kuin pollerilla)
status.sh --github            # opt-in: rikasta PR-tila GitHubista (TTL-cache)
```

`--json` on vakaa rajapinta: myöhemmät inkrementit (sähköpostikooste, HTML-sivu) lukevat samaa
dokumenttia. Jokainen ajo luokitellaan viiteen luokkaan — `running`, `stalled`, `attention`,
`pr_in_flight`, `cleanup` — pelkän paikallisen datan perusteella, ilman GitHub-kutsuja.
Tuntematon PR-tila kallistuu aina elävään suuntaan (`pr_in_flight`), ei siivottavaksi.
Yksittäinen rikkinäinen `run.json` ei kaada luentaa: se eristetään `read_errors`-listaan ja
skripti poistuu koodilla 3 muun datan silti ollessa validia. Exit-koodit ovat osiossa 9. Ne
ovat oma avaruutensa — sama numero tarkoittaa eri asiaa kuin orkestraattorissa tai
PR-vahdissa.

**Opt-in GitHub-rikastus (`--github`).** `run.json` jäätyy `completed`-tilaan PR:n
avaushetkellä; PR:n loppuelämä (draft, mergeability, CI, labelit, katselmointi) elää vain
GitHubissa. `--github` täyttää jokaisen ajon `github`-aliobjektin hakemalla avoimet PR:t
`gh pr list`illä **kerran per owner/repo** TTL-cachella (`RUN_ISSUES_STATUS_CACHE_TTL`, oletus
300 s; `--no-cache` ohittaa, `--cache-ttl <s>` säätää). CI-tila ja PR-vahdin verdict tulevat
PR-vahdin omista funktioista, joten näkymä ja vahti eivät ole eri mieltä PR:n vihreydestä.
Rikastus on **fail-soft**: yhden repon verkkovirhe vie sen `enrichment.repos_failed`-listaan,
sen ajot jäävät `github: null`, muut repot rikastuvat ja exit-koodi on ennallaan. Ilman lippua
käytös on bitilleen kuin ennen (`github: null` joka ajossa). Tekninen referenssi: CLAUDE.md §9.

**Selainpohjainen web-esitys.** [`status-render.sh`](status-render.sh) on JSONin ensimmäinen
kuluttaja: se kirjoittaa `index.html`in ja `status.json`in atomisesti hakemistoon
`RUN_ISSUES_STATUS_OUT_DIR` (oletus `${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/www`),
ilman ulkoisia resursseja. `index.html` on **itsenäinen selainsovellus**: staattinen runko +
inline-CSS + inline-JS, joka hakee `status.json`in `fetch`illä 60 s välein ja renderöi näkymän
selaimessa — ryhmittely repoittain, suodatinchipit, järjestysvalinta, suomenkieliset
tilaselitteet ja vaalea/tumma teema. Kaikki datateksti insertoidaan `textContent`illä, joten
sivu on turvallinen tarjoiltavaksi. Valinnainen LaunchAgent
`com.claude-issue-runner.status-render.plist` regeneroi rungon 300 s välein (itse data päivittyy
selaimessa 60 s välein). Sivun altistaminen verkkoon on koneen omistajan asia — lue turvamallin
osio [7.8](#78-statussivun-web-esitys-on-uusi-altistuspinta) ja `examples/status-caddy.example`
ennen kuin tarjoilet sitä mistään.

**Valinnainen gh-rikastus (#78).** Ympäristömuuttujalla `RUN_ISSUES_RENDER_GITHUB=1`
`status-render.sh` ajaa LaunchAgent-polulla `status.sh --github`in, jolloin sivulle tulee issuen
**otsikko** rivin pääteksinä (`github.issue_title`) sekä avoimen PR:n **CI-tila** ja
**mergevalmius** chippeinä. Fail-soft: jos rikastus epäonnistuu, sivu renderöityy paikallisella
datalla kuten ennen. Oletus `0` = pelkkä paikallinen näkymä. **Otsikot paljastavat
asiakaskontekstia — pidä sivu tailnetissä, älä altista julkisesti (osio
[7.8](#78-statussivun-web-esitys-on-uusi-altistuspinta)).**

**Epic-rollup (#79).** gh-rikastus (`--github`) tuottaa myös top-level-listan `epics[]` —
avoimet `epic`-labeloidut issuet ja niiden alaissueet (ensisijaisesti GitHubin natiivista
sub-issues-rajapinnasta, fallbackina epicin rungon `- [ ] … #N` -task-listasta). Sivu renderöi
per epic **epic-kaistan** sen repo-ryhmän sisään: edistymispalkki (suljetut/kaikki alaissueet),
ajossa oleva alaissue korostettuna, jonossa olevat riippuvuusjärjestyksessä estäjineen
("jonossa · estäjä #N") ja suljetut alaissueet yliviivattuina kuittausriveinä niin kauan kuin
epic on auki. Alaissueen ajo näkyy vain kerran — kaistalla, ei irtorivinä. Ilman `--github`iä
`epics[]` on tyhjä ja näkymä on entisellään. Epic- ja alaissue-otsikot ovat samaa
tailnet-rajattua otsikkopolkua kuin #78. Skeema ja tekninen referenssi: [`docs/design-history.md`](docs/design-history.md).

**Runnerin versiotila (#105).** `status.sh` emittoi top-level-objektin `runner`, joka tekee ajossa
olevan runner-version tilan luettavaksi Ohjaamosta. Se on **paikallista git-tietoa** — saatavilla
**ilman** `--github`iä eikä siihen liity uutta verkkokutsua (`behind_origin` on yhtä tuore kuin
viimeisin pollerin `git fetch`). Kentät: `version` (lyhyt HEAD-sha), `behind_origin` (montako
committia jäljessä `origin/main`ia, `null` jos ei tiedossa), `pinned_version` (emo-repon tallentama
pinni tälle työpuulle, `null` kun paketti ei ole submodule), `update_state` ja `pin_age_seconds`
(kuinka kauan pinni on odottanut, `null` jos committia ei ole paikallisesti). `update_state` on yksi
neljästä:

| Tila | Merkitys | Toimenpide |
|---|---|---|
| `up_to_date` | Pinni == työpuu ja ajan tasalla (tai ei submodule) | — |
| `pin_pending` | Emo-repon pinni eroaa työpuusta — sync lykkää nostoa (ajo elossa) | **Ei mitään.** Korjaantuu itsestään ensimmäisellä idle-hetkellä |
| `behind_upstream` | Pinni == työpuu, mutta yläjuoksu on edennyt | Odota pinnin nostoa (CI) tai nosta se |
| `unknown` | Ajautumaa ei voitu laskea (ei originia / fetch tekemättä / pinni lukukelvoton) | — |

Sama objekti kertoo myös **GitHubin kutsurajan** tilan (#126): `rate_limited_until` (perääntymisen
takaraja) ja `rate_limit_backoff_seconds` (paljonko sitä on jäljellä). Molemmat ovat `null`, ellei
perääntyminen ole juuri nyt voimassa, joten vanha häiriö ei jää roikkumaan näkymään. Sivu näyttää
kutsurajabannerin **myös silloin kun `update_state` on `up_to_date`** — runner voi olla ajan tasalla ja
silti lukittuna ulos API:sta. Sama tieto nostaa myös sähköpostikoosteen otsikkoriville.

Sivu näyttää versiotilan yläosassa **vain kun se ei ole `up_to_date`**, suomenkielisin selittein. `pin_pending`
on **neutraali**, ei varoitus: sen sanamuoto kertoo että tila korjaantuu itsestään. Erottelu on
olemassa siksi, että ennen kaikki kolme muuta-kuin-tasan-tilaa tuottivat saman pollerilokirivin, joka
johti kerran väärään "5 vuorokautta jäljessä" -diagnoosiin ja aikeeseen tehdä käsin checkout elävän ajon
alta (#32). Skeema ja tekninen referenssi: [`docs/design-history.md`](docs/design-history.md).

### 6.11 Julkaisu julkiseen peiliin (`publish-release.sh`)

Paketti julkaistaan **julkiseen peilirepoon** (Apache-2.0, osio 1) historioineen. Upstreamin
historia ei kelpaa sellaisenaan: commit-viestit, diffit ja polut nimeävät asiakkaita, koneita ja
ylläpitäjän tunnuksia. `publish-release.sh` kirjoittaa siksi historian uusiksi **julkaisuputkessa**
`git filter-repo`lla, tuoreessa kloonissa `mktemp`-hakemistossa. Upstreamia ei kosketa: sen SHA:t,
dotfiles-submodulen pinni ja kaikki kloonit pysyvät ennallaan.

```bash
publish-release.sh --target git@github.com:org/peili.git --dry-run   # kaikki portit ja uudelleenkirjoitus paikallisesti
publish-release.sh --target git@github.com:org/peili.git             # julkaise (kysyy vahvistuksen)
publish-release.sh --target git@github.com:org/peili.git --force     # säännöt muuttuneet: korvaa peilin historia
```

**Uudelleenkirjoitus on deterministinen.** Commitin SHA on tiiviste sisällöstä, vanhemmista ja
metatiedosta, eikä putki lisää mitään ajankohtaista, joten sama lähde ja samat säännöt tuottavat
aina täsmälleen saman historian (mitattu: kaksi riippumatonta ajoa tästä reposta antoivat saman
HEAD-SHA:n). Siitä seuraa kolme asiaa. Toistuva julkaisu samasta lähteestä on no-op: ei pushia,
ei tagia. Uuden upstream-commitin julkaisu on **fast-forward**, joten peilin kloonaaja voi pullata
ja `self-update.sh` toimii peiliä vasten. Sääntöjen (denylist, mailmap, rajaukset) muutos kirjoittaa
koko historian uusiksi, jolloin push ei ole fast-forward ja vaatii `--force` — tarkoituksella, koska
sääntömuutos on tietoinen päätös eikä sivuvaikutus. Yksisuuntaisuus on rakenteellinen: peilin
commitit eivät ole upstreamin committeja, joten yhteistä esivanhempaa ei ole eikä kaksisuuntaista
synkkaa voi vahingossa syntyä. Peiliin tuleva kontribuutio siirretään upstreamiin käsin
(cherry-pick; puut ovat nimiä lukuun ottamatta identtiset).

**Skriptin tärkein osa on kaksi vuotoporttia, ei julkaisu.** Portti työpuuhun kertoo kehittäjälle
`tiedosto:rivi`-muodossa, mitä korjata, ja ajetaan ennen hitaampaa uudelleenkirjoitusta.
Historiaportti tarkistaa **lopputuloksen** — jokaisen commit-viestin, polun ja blobin — samalla
skannerilla eikä luota korvaussääntöihin, joten rikkinäinen tai ohitettu työkalu ei voi tuottaa
vuotoa. Osuma etsitään **sanan alusta** ja kirjainkoosta riippumatta. Sanaraja vaaditaan vain
termin *edeltä*, ei perästä, ja tämä epäsymmetria on tarkoituksellinen: edeltävä raja karsii väärät
osumat (`polling`, `pakollinen`), kun taas perässä vaadittu raja päästäisi läpi juuri sen luokan
vuotoja, jonka portti on olemassa estämään — suomi taivuttaa päätteellä (`Nimen`, `Nimelle`) ja
tunnisteet ketjuttavat (`nimi_lock`, `wp_nimi`). Denylist-rivi on `termi` tai `termi==>korvaus`:
portit lukevat termin, ja uudelleenkirjoitus korvaa osumat **pisimmästä termistä lyhimpään**,
jottei tunnuksen puolikas jää jäljelle. Sama sääntöjoukko ajetaan viesteihin, blobeihin ja
tiedostonimiin, koska tiedosto nimeltä `<nimi>-notes.md` vuotaa nimen sisältämättä sitä. Lista on
skriptin oma vakio, ei konfiguraatiotiedosto. Julkaisijan oma nimi ei ole listalla: peili on
julkaisijan organisaation alla omalla nimellään, joten nimi on julkaisija eikä vuoto.

Portteja on viisi ja kaikki ovat fail-closed, plan-then-apply -järjestyksessä kuten
[`install.sh`](install.sh)ssa — **yksikin kieltäytyminen ⇒ nolla kirjoitusta**, eikä yksikään
portti ota yhteyttä kohteeseen:

| Portti | Vaatimus | Exit |
|---|---|---|
| Lähdepuu | git-repo, puhdas työpuu, `HEAD == origin/main` (paikallinen ref, ei fetchiä), `LICENSE` seurattuna HEADissä | 2 |
| Denylist | luettavissa ja epätyhjä; yksikään korvaus ei sisällä kiellettyä termiä | 3 |
| Vuotoportti | yksikään kielletty termi ei esiinny HEADin puussa eikä sen poluissa | 3 |
| Työkalu | `git filter-repo` on käytettävissä ja uudelleenkirjoitus onnistuu | 6 |
| Historiaportti | uudelleenkirjoitetun historian yksikään viesti, polku tai blob ei sisällä kiellettyä termiä | 4 |

Kolme asiaa, jotka on helppo ymmärtää väärin:

- **Nimiluettelon kantavat tiedostot poistetaan koko historiasta eivätkä mene skannaukseen.**
  Tiedosto, jonka *tehtävä* on luetella kiellettyjä nimiä, osuu määritelmällisesti omaan listaansa:
  ilman rajausta portti kieltäytyisi ikuisesti. Sama piirre tekee tiedostosta itsessään vuodon, jos
  se päätyy peiliin. Rajattuja on kaksi: `publish-release.sh` (ylläpitäjän työkalu, jonka denylist on
  lista asiakkaiden nimiä) ja `tests/test-principles-neutrality.sh` (`principles/coding.md`:n
  neutraaliusvartija, jonka kielletty sanasto sisältää ylläpitäjän ja koneiden nimet hakukuvioina).
  Lista on skriptin `EXCLUDED_FROM_RELEASE` ja se on eksplisiittinen, ei tiedostosta johdettu:
  johdettu rajaus tekisi vuotoportista ohitettavan yhdellä kommenttirivillä. Poisto koko historiasta
  tehdään filter-repon `--invert-paths`-valinnalla, joten peilissä ei ole yhtäkään committia, jossa
  tiedosto olisi ollut.
- **Tekijäidentiteetit eivät kuulu porttien piiriin.** Julkisen repon tekijä on julkinen, ja
  attribuutio on lisenssin tarkoitus. Henkilökohtaiset sähköpostiosoitteet normalisoidaan sen sijaan
  `--mailmap`illa (sisäänrakennettu lista), ja `--dry-run`in suunnitelma listaa uudelleenkirjoitetun
  historian identiteetit, jotta ne näkee ennen julkaisua.
- **Lisenssiä ei generoida.** Peili saa upstreamin seuratun `LICENSE`-tiedoston sellaisenaan; sen
  puuttuminen HEADistä on kieltäytyminen, ei oletusarvo.

Skripti **ei koske paikalliseen repoon**: lähdepuussa ajetaan vain lukevia git-komentoja, ja klooni,
uudelleenkirjoitus ja push tapahtuvat `mktemp`-hakemistossa (siivotaan trapilla myös virhepolulla).
`--dry-run` ajaa kaikki viisi porttia ja uudelleenkirjoituksen paikallisesti ja tulostaa suunnitelman
**ottamatta yhteyttä kohteeseen** — julkaisu on siis todennettavissa verkotta, ja suunnitelman SHA on
täsmälleen se, joka pushattaisiin. Ensimmäinen yhteys kohteeseen on apply-vaiheen `ls-remote`, joka
päättää, onko kyseessä no-op, fast-forward vai `--force`a vaativa sääntömuutos. Kun peilin `main`
liikkuu, kohteeseen jää pysyvä `release/<UTC-aikaleima>`-tagi. Kohderepon on oltava olemassa ennen
ajoa; skripti ei luo sitä eikä konfiguroi sen asetuksia. Ajastusta ei ole: julkaisu on tietoinen
ihmisen toimenpide.

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

Sama numero tarkoittaa eri asiaa orkestraattorissa, asentimessa ja PR-vahdissa. Ks. osio 9.

### Poller on host-portattu

Poller vertaa `hostname -s`:ää muuttujaan `RUN_ISSUES_POLLER_HOSTS` ja **exittaa 0** jos
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

### Orkestraattori (`orchestrate.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Onnistui — PR avattu, tai resume peruttiin siististi |
| 1 | Fataali — virheellinen käyttö tai puuttuva `run.json` resumessa. **Myös `poll`-argumentti** (issue #99): automaattinen poiminta on pollerin tehtävä, ei orkestraattorin. Koodi 2 (ei ehdokasta) poistui käytöstä |
| 3 | Lukko-/claim-kilpajuoksu hävitty |
| 4 | Katselmointi esti ajon (vain auto-tila) |
| 5 | Estynyt ennen implementeriä tai implementerissä — worktreen luonti (S4), db-clone, riippuvuusasennus (S7b), testiympäristön provisiointi (S7c) tai implementer palautti BLOCKED. Tarkan syyn ja sen korjauksen kertoo `run.json`-statuksen syykenttä, ks. vianetsinnän kohta (e) |
| 6 | PR:n avaus epäonnistui |
| 7 | Implementer (S8) aikakatkaistiin — ajo on `--restart`-kelpoinen |
| 8 | **Puuttuva pakollinen riippuvuus** — S0-portti kieltäytyi käynnistämästä ajoa; mitään ei lukittu, claimattu eikä luotu. Virheilmoitus nimeää työkalun ja korjauskomennon |
| 9 | **Issue on estetty avoimella `blocked_by`-riippuvuudella** — S2b-portti kieltäytyi lukon ja claimin välissä ennen assignaatiota; ajo viimeisteltiin `blocked`-tilaan ja lukko vapautettiin. Portti lukee riippuvuusgraafin suoraan (hakuindeksin sijaan) ja on fail-closed. Issue **ei** saa `needs-human`-labelia: se on odotustila, joka jatkuu itsestään kun estäjä sulkeutuu. Nimetyn ajon voi pakottaa `--force`-lipulla |
| 10 | Odottaa ihmisen katselmointia — jatka komennolla `--resume` |
| 11 | Odottaa tarkennusta — vastaa issuelle, poller jatkaa `--continue`-ajolla |
| 12 | **Issue kantaa `epic`-labelia** — S2c-portti kieltäytyi lukon ja claimin välissä ennen assignaatiota (issue #81). Epic kokoaa ajettavat alaissueet mutta ei ole itse ajettava; ajo viimeisteltiin `blocked`-tilaan (`is_epic_not_runnable`, tai `epic_check_failed` jos labelit lukukelvottomat) ja lukko vapautettiin. Portti lukee labelin suoraan (hakuindeksin sijaan) ja on fail-closed. Issue **ei** saa `needs-human`-labelia (claimia edeltävä portti kuten S2b). Nimetyn ajon voi pakottaa `--force`-lipulla |

### Asennin (`install.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Onnistui (tai `--dry-run` valmis) |
| 1 | Käyttövirhe |
| 2 | Kieltäydytty — kohdepolku on jonkun muun omistama, mitään ei muutettu |
| 3 | Apply epäonnistui odottamatta |
| 4 | Valmis, mutta vieras tiedosto varjostaa paketin toimittamaa nimeä |

### PR-vahti (`pr-watch.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Merge + siivous OK, tai ei tekemistä |
| 1 | Käyttövirhe |
| 2 | Skannaus ei löytänyt ehdokasta |
| 3 | Lukkokilpailu hävitty (toinen vahti tai orkestraattori pitää issueta) |
| 4 | Ei vielä mergettävissä (turvallista yrittää seuraavalla kierroksella) |
| 5 | Merge epäonnistui |
| 6 | Konflikti vaatii ihmisen — AI ei ratkaissut tai CI punainen |
| 7 | Merge-jälkeinen migraatio epäonnistui |
| 8 | Punainen CI vaatii ihmisen — AI ei korjannut, CI jäi punaiseksi tai yrityskatto täyttyi (`needs-human`-label + kommentti) |

### Kokonaistila (`status.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Luenta onnistui |
| 1 | Käyttövirhe (tuntematon lippu tai kelvoton arvo) |
| 2 | Ei watchlistiä, ei yhtään levyllä olevaa repoa, tai `jq` puuttuu |
| 3 | Vajaa luenta — yksi tai useampi `run.json` oli lukukelvoton/virheellinen; dokumentti on silti validi ja täydellinen muun osan osalta (`degraded: true`), ja rikkinäiset polut on listattu `read_errors`-kentässä |

### Statussivun renderöinti (`status-render.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Renderöity — `index.html` ja `status.json` kirjoitettu atomisesti |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva arvo) |
| 2 | Syöte kelvoton — `status.sh` ei tuottanut validia JSONia tai `schema_version` on tuntematon; vanha sivu jää paikoilleen |
| 3 | Kirjoitus epäonnistui (levy täynnä / oikeudet); temp-tiedostot siivotaan, vanha sivu jää ehjäksi |

### Label-vetoinen siivous (`auto-clean.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Siivottu, issue suljettu, `auto-clean`-label poistettu |
| 1 | Käyttövirhe tai remotea ei voitu selvittää |
| 3 | Issuen lukko on toisella ajolla — turvallista yrittää seuraavalla tikillä |
| 4 | Issuen `completed`-ajolla on **avoin** (tai selvittämätön) PR — ei siivottu, `auto-clean-skipped` lisätty. Mergetyn/suljetun PR:n ajo siivotaan normaalisti |
| 5 | Tältä koneelta ei löydy ajoja tälle issuelle — `auto-clean-skipped` lisätty ja kommenttiin kirjattu konekohtainen ohje |
| 6 | Purku (`cleanup-run.sh`) epäonnistui |

Koodit 4 ja 5 eivät ole virheitä vaan **kieltäytymisiä**: siivous ei koske avoimen PR:n ajoon
eikä arvaile toisen koneen tilaa. `completed`-ajon PR-tila luetaan run.jsonin `pr_url`ista
(`gh pr view --json state`): vain aidosti `OPEN` — tai selvittämätön tila (fail-closed) —
kieltäytyy, `MERGED`/`CLOSED` siivotaan ja issue suljetaan. `auto-clean-skipped` on
silmukkasuoja — poista se käsin, kun olet hoitanut asian, jos haluat siivouksen yrittävän
uudelleen.

### Label-vetoinen nollaus (`auto-reset.sh`)

Oma avaruutensa, ei siivouksen jatke — numerot sattuvat osumaan yhteen, mutta niitä ei ole
yhtenäistetty eikä pidä yhtenäistää.

| Koodi | Merkitys |
|---|---|
| 0 | Purettu, **issue jätetty auki**, `auto-reset`-label poistettu — issue palaa poimintaan |
| 1 | Käyttövirhe tai remotea ei voitu selvittää |
| 3 | Issuen lukko on toisella ajolla — turvallista yrittää seuraavalla tikillä |
| 4 | Issuen `completed`-ajolla on **avoin** (tai selvittämätön) PR — ei purettu, `auto-reset-skipped` lisätty. Nollaus tuottaisi samalle issuelle toisen PR:n, joten sulje PR ensin |
| 5 | Tältä koneelta ei löydy ajoja tälle issuelle — `auto-reset-skipped` lisätty ja kommenttiin kirjattu konekohtainen ohje |
| 6 | Purku (`cleanup-run.sh`) epäonnistui |

Portit ovat kirjaimellisesti samat rivit kuin siivouksessa (`lib/teardown.sh`), joten myös
kieltäytymiset osuvat samoihin kohtiin. Ero on lopputuloksessa: **issueta ei suljeta eikä avata
uudelleen**, ja onnistuneen purun jälkeen issue täyttää poimintaehdot heti.

### Yksittäisen ajon pysäytys (`stop-run.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Pysäytetty (tai `--dry-run` tulosti suunnitelman) |
| 1 | Käyttövirhe (tuntematon lippu, puuttuva tai ristiriitainen kohde) |
| 2 | Kohdetta ei löytynyt (myös arkistoon osoittava `--run-dir`) |
| 3 | `--issue` osui useampaan ajoon — tarkenna `--run-dir`illä |
| 4 | Vieras host — ajo kuuluu toiselle koneelle; mihinkään ei koskettu |
| 5 | Terminaalitilassa oleva ajo — käytä `--force`ia; mihinkään ei koskettu |

`stop-run.sh` pysäyttää **yhden** elävän ajon hallitusti: tappaa tmux-session, viimeistelee ajon
`blocked/stopped_by_operator`-tilaan, lisää `needs-human`-labelin ja tilannekommentin. Se **ei
ole siivous** — worktree, haara ja run-dir jäävät koskematta (purku jää `cleanup-run.sh`ille tai
`auto-clean`-labelille). Ei `--all`-lippua eikä oletuskohdetta: massapysäytys on koko
orkestraattorin pysäyttäminen (`launchctl`), ei tämän skriptin asia.

### Epicin käynnistys ja keskeytys (`run-epic.sh`)

Koodit 1/2/3/5 ovat yhteisiä molemmille moodeille; 4 on vain käynnistys, 6 vain `--stop`.

| Koodi | Merkitys |
|---|---|
| 0 | Käynnistys: validoitu + propagoitu. `--stop`: epic kokonaan pysäytetty (kaikki elävät lapsiajot pysäytetty, ajolabelit poistettu). Tai `--dry-run` tulosti suunnitelman |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva tai epäkelpo epic-numero / `--stop` yhdessä `--start-now`n kanssa) |
| 2 | Epic-issueta ei löytynyt tai se ei ole avoin |
| 3 | Epic ilman alaissueita — ei propagoitavaa/pysäytettävää |
| 4 | Käynnistys: syklinen `blocked_by`-graafi alaissueiden välillä — sykli nimetään, mitään ei kirjoiteta |
| 5 | Lukuvirhe — lapsijoukkoa tai `blocked_by`-graafia ei saatu luettua (fail-closed) |
| 6 | `--stop`: osittainen — epic vapautettiin poiminnasta mutta ≥1 elävää lapsiajoa ei voitu pysäyttää (vieras kone / terminaalitila ilman `--force`ia / moniselitteinen / delegoitu `stop-run.sh` epäonnistui). Muu käsiteltiin; täysi pysäytys on 0 |

`run-epic.sh` validoi epicin rakenteen **ennen mitään kirjoitusta** (suunnittele–sovella kuten
`install.sh`) ja propagoi sitten ajolabelit alaissueille **samalla jaetulla funktiolla** kuin
pollerin epic-skannaus. `--dry-run` tulostaa raportin kirjoittamatta; `--start-now` käynnistää
ensimmäisen ajokelpoisen alaissueen heti. `--stop` **keskeyttää** epicin: se pysäyttää elävät
lapsiajot delegoimalla `stop-run.sh`:lle ja vapauttaa jonossa olevat poistamalla ajolabelit
**ensin epiciltä, sitten avoimilta lapsilta** (järjestys estää pollerin re-propagoinnin).

### Julkaisu julkiseen peiliin (`publish-release.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Julkaistu tai ajan tasalla, tai `--dry-run` tulosti suunnitelman, tai vahvistus peruttiin |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva `--target`) |
| 2 | Lähdepuu ei ole julkaistavissa: ei git-repo, likainen työpuu, puuttuva `origin/main`, `HEAD != origin/main` tai `LICENSE` puuttuu. Mitään ei kirjoitettu |
| 3 | Vuotoportti kieltäytyi: kielletty termi löytyi työpuusta (osumat `tiedosto:rivi`-muodossa), denylist oli tyhjä/lukukelvoton tai korvaus sisältää kielletyn termin. Mitään ei kirjoitettu |
| 4 | Historiaportti kieltäytyi: uudelleenkirjoitettu historia sisältää yhä kielletyn termin viestissä, polussa tai blobissa. Mitään ei kirjoitettu |
| 5 | Julkaisu epäonnistui: kohteeseen ei saatu yhteyttä, tai push ei ollut fast-forward eikä `--force` annettu. Paikallinen repo on silti muuttumaton |
| 6 | `git filter-repo` puuttuu tai uudelleenkirjoitus kaatui — työkaluvirhe, ei sisällön kieltäytyminen |

`publish-release.sh` julkaisee paketin julkiseen peiliin **historia uudelleenkirjoitettuna** (osio
6.11). Viisi fail-closed-porttia ajetaan ennen mitään kirjoitusta; kaksi niistä on vuotoportteja,
joista toinen tarkistaa työpuun ja toinen uudelleenkirjoitetun historian jokaisen viestin, polun ja
blobin.

### Self-update (`self-update.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Tikki valmis, tai siististi ohitettu (idle-portti / kill-switch / pull-vartio). Pull on aina fail-soft: verkkovirhe tai jäljessä oleva `main` on NOTE, ei virhe — seuraava tikki yrittää uudelleen |
| 1 | Käyttövirhe (tuntematon lippu) |
| 2 | Asennusvaihe epäonnistui odottamatta (asentajan exit ei ∈ {0,2,4}); lokitettu, seuraava tikki yrittää uudelleen. Asentajan oma refuse (2) / conflict (4) on NOTE eikä yllä tänne |

`self-update.sh` pitää asennetun paketin ajan tasalla (§7.10): kehittäjäkoneella vartioitu
`git pull --ff-only` + `install.sh`, ylläpitäjän submodule-koneella vain `install.sh` (pull
ohitetaan aina). Idle-portti ohittaa koko tikin, jos koneella on elävä ajo. Kill-switch:
`RUN_ISSUES_SELF_UPDATE=0`.

### Ohjaamon toimintopalvelu (`action-server.sh`)

Kääre omistaa elinkaaren ja delegoi socketin `lib/action-service.py`:lle `exec`illä, joten
**Pythonin exit-koodi on prosessin exit-koodi** — siksi koodit jakautuvat siihen, mitä kääre
päättää ennen `exec`iä (1/2) ja mitä palvelu päättää (0/3/4).

| Koodi | Merkitys |
|---|---|
| 0 | Puhdas exit — host-portti no-op, `--check` OK, tai palvelu pysähtyi SIGTERMiin |
| 1 | Käyttövirhe (tuntematon lippu) |
| 2 | Puuttuva pakollinen riippuvuus (`python3` / `jq` / Tailscale-CLI) — ennen `exec`iä |
| 3 | Bind epäonnistui — ei Tailscale-osoitetta johon sitoa (ei koskaan wildcard), tai portti varattu. launchd `KeepAlive` yrittää uudelleen — tämä on boot-ennen-tailnetiä-toipuminen |
| 4 | Konfiguraatio kieltäytyy — ei sallittua identiteettiä, tokenia eikä originia (fail-closed) |

### Ohjaamon toiminnon delegointi (`action-dispatch.sh`)

Ohut kuori: jokainen neljästä toiminnosta delegoi olemassa olevalle skriptille tai labelille
eikä toteuta purku-, merge- tai restart-logiikkaa itse.

| Koodi | Merkitys |
|---|---|
| 0 | Delegoitu komento onnistui |
| 1 | Käyttövirhe (tuntematon toiminto / puuttuva tai virheellinen selektori) |
| 2 | Delegoitu komento **epäonnistui** — sen tuloste on stdout/stderrissä sellaisenaan (turvamalli §7.9: näytä virhe, älä yritä itse) |
| 3 | Delegoitava puuttuu (skripti ei suoritettavissa, tmux puuttuu restartista) |

### Kooste (`status-digest.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Lähetetty, tai ei lähetystarvetta (muuttumaton tilanne ilman `--force`) |
| 1 | Käyttö- tai syötevirhe |
| 2 | Tuntematon `schema_version` — ei lähetystä |
| 3 | Lähetys epäonnistui; runko on silti stdoutissa |

### Mistä lokit löytyvät

- **Pollerit:** `$RUN_ISSUES_LOG_DIR` (oletus `$HOME/Library/Logs`), neljä tiedostoa per
  poller: `.log`, `.runs.log`, `.stdout.log`, `.stderr.log`. Tiedostojen etuliitteet ovat
  `run-issues-poller` ja `pr-watch-poller`.
- **Self-update:** sama `$RUN_ISSUES_LOG_DIR`, etuliite `run-issues-self-update` (`.log`,
  `.stdout.log`, `.stderr.log`). Rotatoituu `RUN_ISSUES_LOG_MAX_BYTES`illa kuten pollerit.
- **Yksittäinen ajo:** `<kohderepo>/.claude/run-issues/<run-id>/` — `run.json` (tilan
  tilannekuva) ja `state.jsonl` (append-only tapahtumaloki).
- **Lukot:** `$HOME/Library/Application Support/run-issues/locks`.

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

Testit **eivät koske oikeaan `~/.claude`-hakemistoon**: asentimen polut johdetaan
`RUN_ISSUES_CLAUDE_HOME`- ja `RUN_ISSUES_LAUNCH_AGENTS_DIR`-overrideista, ja
`tests/test-install-portability.sh` vartioi tätä. Se ei ole tyylisääntö vaan ehto sille, että
testit voi ajaa samalla koneella jolla poller pyörii.

---

## 11. Viittaukset

- [`CLAUDE.md`](CLAUDE.md) — agentin konteksti: invariantit, mitatut rajoitteet ja tietoiset
  ei-päätökset. §5 = mitatut rajoitteet, §13 = tunnetut avoimet asiat.
- [`docs/env-reference.md`](docs/env-reference.md) — kaikki ympäristömuuttujat.
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
