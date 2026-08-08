# claude-issue-runner

Itsenäisesti asennettava paketti `/run-issues`-orkestraattorille: GitHub-issuesta valmiiseen
pull requestiin ilman ihmistä silmukassa, sekä PR-vahti, joka vie PR:n merge-tilaan asti.

Tämä README on **ihmiselle**: asennus, turvamalli ja perustelut sille miksi järjestelmä
käyttäytyy kuten käyttäytyy. [`CLAUDE.md`](CLAUDE.md) on **agentille**: täysi tekninen
referenssi. Jos sama fakta on molemmissa, `CLAUDE.md` on lähde.

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

- **Interaktiivinen** — Claude Coden slash-komennot `/run-issues #N` ja `/pr-watch` omalla
  koneella, ihminen katsoo vierestä.
- **Poller** — `poller.sh` ja `pr-watch-poller.sh` LaunchAgenteina, jotka käyvät watchlistin
  repot läpi määrävälein ilman ihmistä. Tämä on se tila, jossa turvamallin kysymykset ovat
  aidosti kiinnostavia.

Paketti ei sisällä henkilökohtaista konfiguraatiota: ei watchlistiä (vain skeemaesimerkki
[`examples/`](examples)-hakemistossa), ei koneistokohtaisia env-tiedostoja, ei salaisuuksia.

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

- `~/.claude/agents/` ja `~/.claude/commands/` — per-tiedosto-symlink jokaiselle paketin
  `*.md`-tiedostolle. Lähdejoukko on glob, joten uusi agentti tulee asennukseen pelkällä
  nimeämisellä. Paketin omistamat symlinkit, joita paketti ei enää toimita, siivotaan.
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

Yksi erikoistapaus kannattaa tunnistaa: jos `~/.claude/agents` on **kokonainen
hakemistosymlinkki** (dotfiles-asetelma, jossa koko hakemisto tulee muualta), asentaja
kieltäytyy aina. Tämä on paketin alkuperäisen ylläpitäjän ympäristön tapaus, ja sen korjaus
kuuluu kyseiseen dotfiles-repoon. **Puhtaalla koneella** hakemistot ovat tavallisia
hakemistoja tai puuttuvat, jolloin asennus menee läpi normaalisti.

Kaksi rajoitetta:

- `--with-launchagents` **ei kutsu `launchctl`ia** — se deployaa plist-tiedostot ja tulostaa
  `launchctl`-komennot, jotka ajat itse. Perustelu: `CLAUDE.md` §11.
- `install.sh --uninstall` **puuttuu**. Paketin omistamat symlinkit poistetaan toistaiseksi
  käsin.

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

Ympäristömuuttuja voittaa aina tiedoston. Puuttuva tiedosto on no-op.

---

## 5. Ympäristömuuttujat (asennus- ja konfigurointiaika)

Alla vain ne muuttujat, jotka ihminen tosiasiassa asettaa ennen ensimmäistä ajoa. **Täysi
lista kaikista muuttujista on [`CLAUDE.md`](CLAUDE.md) §7:ssä** — sitä ei toisteta tässä,
jotta kaksi listaa ei ajaudu erilleen.

### Orkestraattori

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_ENV_FILE` | `$HOME/.config/run-issues/env` | Salaisuustiedoston polku |
| `RUN_ISSUES_CLAUDE_CMD` | `npx --no-install @anthropic-ai/claude-code` | Claude-CLI:n kutsu |
| `RUN_ISSUES_CLAUDE_TIMEOUT` | `3600` | Aikabudjetti per claude-kutsu |
| `RUN_ISSUES_LABELS_CSV` | *(tyhjä)* | Poimintalabelit käsiajon poll-tilassa. Kaikkien oltava issuella (6.2) |
| `RUN_ISSUES_PR_LABELS_CSV` | `auto-merge` | Issuelta PR:lle kopioitavat labelit (6.3) |
| `RUN_ISSUES_MAX_RETRIES` | `1` | Montako kertaa aikakatkaistu ajo yritetään uudelleen (6.6 d) |
| `RUN_ISSUES_MAX_CLARIFICATIONS` | `3` | Tarkennuskierrosten katto (6.6 c) |
| `RUN_ISSUES_AUTO` | `0` | `1` = ei interaktiivisia kehotteita (ks. osio 7.3) |
| `RUN_ISSUES_SKIP_PREFLIGHT` | `0` | `1` = ohita S0-portti. Hätävara |

### Poller

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `RUN_ISSUES_POLLER_ENV_FILE` | `$HOME/.config/run-issues/poller.env` | Konfiguraatiotiedoston polku |
| `RUN_ISSUES_POLLER_HOSTS` | *(sisäänrakennettu legacy-lista)* | Glob-kuviot, joita verrataan `hostname -s`:ään. `*` sallii kaikki. Ei osumaa ⇒ poller exittaa 0 |
| `RUN_ISSUES_WATCHLIST` | *(tyhjä)* | Watchlistin polku; asetettuna ainoa ehdokas |
| `RUN_ISSUES_LOG_DIR` | `$HOME/Library/Logs` | Pollerien lokihakemisto |
| `RUN_ISSUES_CLEAN_LABEL` | `auto-clean` | Label, joka laukaisee siivouksen |
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

Asentimen kaksi muuttujaa ovat olemassa yhtä syytä varten: **testit eivät saa koskea oikeaan
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
| Poiminta | poller / orkestraattori | issue **assignoituu** sinulle |
| Katselmointi (S6) | Claude | ei mitään — tai tarkennuskysymys kommenttina |
| Toteutus (S8–S9) | Claude | committeja haaralla `auto-run/<repo-slug>-issue-<N>-<slug>` |
| PR (S11) | orkestraattori | PR, jonka rungossa on `Closes #<N>` |
| Merge | PR-vahti | PR mergetty, **issue sulkeutuu** `Closes`-viittauksesta |
| Siivous | PR-vahti | worktree, haara, lukko ja assignaatio poistuvat |

Ihmisen tehtävä on kaksi asiaa: **kirjoittaa issue riittävän tarkasti** ja **katselmoida PR**.
Kaikki muu ihmiskosketus (tarkennuskysymys, `needs-human`, siivous) on poikkeustilanne, jonka
käsittely on kuvattu kohdassa 6.6.

### 6.2 Milloin issue lähtee ajoon

Poiminta on **yksi GitHub-haku**, ja sen ehdot ovat sanatarkasti nämä (`lib/issue.sh`
orkestraattorille, sama lauseke `poller.sh`:ssa):

```
is:open no:assignee
-is:blocked -label:waiting -label:wip -label:auto-clean
label:"<jokainen konfiguroitu label>"
sort:created-asc  →  ensimmäinen osuma
```

Issue lähtee siis ajoon **täsmälleen kun kaikki nämä pätevät**:

1. Issue on **avoin**.
2. Issuella **ei ole yhtään assigneeta** — ei sinua, ei ketään muuta (ks. 6.4).
3. Issue **ei ole estetty** GitHubin natiivissa riippuvuusgraafissa (`-is:blocked`, ks. 6.5).
4. Issuella **ei ole** labelia `waiting`, `wip` eikä `auto-clean`.
5. Issuella on **kaikki** konfiguroidut poimintalabelit (oletus: `auto-run`).
6. Se on vanhin ehdot täyttävä issue — **yksi issue per tikki per remote**.

Viides kohta on se, joka useimmiten yllättää: **labelit yhdistyvät JA-ehdolla, eivät
TAI-ehdolla.** Jos watchlistin `labels`-listassa on kaksi labelia, issue tarvitsee molemmat.
Ja koska `auto-clean` on aina poissuljettu, **sen listaaminen poimintalabeliksi tekee reposta
pysyvästi tyhjän** — haku sisältäisi silloin sekä `label:"auto-clean"` että
`-label:auto-clean`. Tulos on nolla osumaa, eikä siitä synny virhettä eikä lokiriviä.

Poimintalabelit tulevat konfiguraatiosta kolmessa portaassa: watchlistin repokohtainen
`labels` → watchlistin `default_labels` → sisäänrakennettu oletus `["auto-run"]`. Käsiajossa
sama tulee muuttujasta `RUN_ISSUES_LABELS_CSV`. **Mikään labelin nimi ei ole kovakoodattu
poimintaan** — `auto-run` on pelkkä konventio.

**Nimetty ajo ohittaa poimintaehdot.** `/run-issues #N` ja `orchestrate.sh <repo> <N>` eivät
tee hakua lainkaan, joten labelit ja avoimuus eivät estä niitä. Kohta 2 pätee silti: claim
tarkistetaan, ja toiselle assignattu issue kaataa ajon (exit 3).

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
sellaisenaan. Ks. CLAUDE.md §7.

**Tikin sisäinen järjestys** (`poller.sh`, oletusväli 300 s eli 5 min): jumiutuneiden ajojen
liveness-pyyhkäisy koko watchlistiin → `auto-clean`-siivoukset → aikakatkaistujen ajojen
`--restart` → vastattujen tarkennusten `--continue` → **vasta viimeisenä** uuden issuen
poiminta. Keskeneräinen työ menee siis aina uuden edelle.

### 6.3 Labelit

Jokainen label kuuluu tarkalleen yhteen luokkaan sen mukaan **kuka sen kirjoittaa**. Se on
käytännössä tärkein tieto: itse lisättävää labelia ei kannata jäädä odottamaan, eikä
automaation lisäämää labelia kannata poistaa käsin ennen kuin syy on korjattu.

| Label | Kuka lisää | Kuka poistaa | Vaikutus |
|---|---|---|---|
| `auto-run` | **sinä** | sinä | Poimintaehto. Nimi tulee konfiguraatiosta (`default_labels` / `RUN_ISSUES_LABELS_CSV`), ei koodista |
| `waiting` | orkestraattori, kun ajo jää odottamaan vastaustasi | orkestraattori, kun `--continue` jatkaa | Estää poiminnan sillä aikaa kun tarkennus on kesken |
| `wip` | **sinä** | sinä | Estää poiminnan. Tarkoitettu "teen tämän itse" -merkinnäksi |
| `needs-human` | orkestraattori tai poller, kun ajo epäonnistuu; PR-vahti, kun CI-korjaus luovuttaa | `cleanup-run.sh` (myös `/cleanup-run`); PR:ltä **sinä** | Issuella: **ei estä poimintaa** — assignaatio estää; signaali sinulle. PR:llä: **pidättää PR-vahdin**, kunnes poistat sen (7.5) |
| `auto-clean` | **sinä** | `auto-clean.sh` onnistuneen siivouksen jälkeen | Pyytää siivoamaan issuen ajojäänteet ja sulkemaan issuen. Ks. 6.6 h) |
| `auto-clean-skipped` | `auto-clean.sh`, kun se ei voi siivota | **sinä**, kun olet hoitanut asian | Estää siivouksen loputtoman uudelleenyrityksen |
| `auto-merge` | **sinä** issuelle | — | Propagoituu issuelta PR:lle, ja PR-vahti mergeää vain labeloidun PR:n |

Kolme yleistä sekaannusta kannattaa erottaa heti:

- **Estoa ei merkitä labelilla.** Poiminnan estää GitHubin natiivi "blocked by" -riippuvuus
  (6.5), ei mikään label; `run.json`-status `blocked` puolestaan kertoo vain, että yksittäinen
  ajo päättyi virheeseen. Kumpikaan ei aiheuta toista — epäonnistunut ajo **ei** estä issueta.
- **`needs-human` ei estä poimintaa.** Se on pelkkä lippu sinulle. Uuden ajon estää
  assignaatio, joka jää voimaan (6.4). **Poikkeus on PR:lle lisätty `needs-human`**, jonka
  PR-vahti lisää CI-korjauksen luovuttaessa: siinä se on aito pidätyslippu, ja sen poistaminen
  on nimenomaan se toimenpide, joka palauttaa PR:n vahdin käsittelyyn (7.5).
- **`auto-merge` luetaan PR:ltä, ei issuelta.** Orkestraattori kopioi sen issuelta PR:lle
  (`RUN_ISSUES_PR_LABELS_CSV`, oletus `auto-merge`). Jos lisäät labelin issuelle vasta PR:n
  avaamisen jälkeen, se ei siirry itsestään — lisää se silloin suoraan PR:lle.

Kaksi labelinimeä on vaihdettavissa ympäristömuuttujalla: `auto-clean`
(`RUN_ISSUES_CLEAN_LABEL`) ja `auto-merge` (`PR_WATCH_MERGE_LABEL`). `waiting`, `wip`,
`needs-human` ja `auto-clean-skipped` ovat kovakoodattuja.

Automaation itsensä lisäämät labelit (`waiting`, `needs-human`, `auto-clean-skipped` sekä
PR:lle kopioitavat) luodaan repoon tarvittaessa itsestään. **Sinun lisäämäsi labelit
(`auto-run`, `wip`, `auto-clean`) pitää luoda repoon itse** — GitHub ei salli tuntemattoman
labelin liittämistä.

### 6.4 Issuen omistaja (assignee)

Assignaatio ei ole tässä järjestelmässä kirjanpitoa vaan **varausmekanismi**. Se on ainoa
tila, jonka kaikki koneet näkevät: paikallinen lukkohakemisto suojaa vain yhden koneen
sisällä, GitHub-assignaatio kaikkien välillä.

Kulku on kolmivaiheinen (S2 → S3): ajo ottaa paikallisen lukon, assignoi issuen itselleen,
odottaa hetken ja **tarkistaa että on issuen ainoa assignee**. Jos assigneita on useampi,
kaksi ajoa varasi saman issuen yhtä aikaa — tämä ajo perääntyy, poistaa oman
assignaationsa ja exittaa koodilla 3. GitHub sallii rinnakkaiset assignaatiot, joten
"olenko ainoa" on ainoa luotettava ratkaisija.

Kolme käytännön seurausta:

1. **Käsin assignattu issue ei koskaan lähde automaatioon.** Poimintahaussa on `no:assignee`.
   Jos haluat tehdä issuen itse, assignoi se itsellesi — se on `wip`-labelia vahvempi keino.
2. **Nimetty ajo kaatuu toisen ihmisen issueen.** `/run-issues #N` ohittaa poimintaehdot,
   mutta claim-tarkistus huomaa toisen assigneen ja exittaa koodilla 3 ilman sivuvaikutuksia.
3. **Assignaatio ei vapaudu itsestään, jos ajo epäonnistuu.** Se poistuu vain neljässä
   tilanteessa: hävitty varauskilpailu, `--resume --decision CANCEL`, `cleanup-run.sh`
   (myös `/cleanup-run`) ja PR-vahdin mergenjälkeinen siivous.

Kolmas kohta on tarkoituksellinen: epäonnistunut ajo jättää issuen varatuksi, jotta poller ei
poimi samaa issueta uudelleen ja uudelleen samaan seinään. Hinta on, että **issue palaa
automaatioon vasta siivouksen jälkeen** (6.6 g). Jos ihmettelet miksi korjattu issue ei lähde
liikkeelle, tarkista assignaatio ensin.

### 6.5 Riippuvuudet toisiin issueihin

Kun issuen pitää odottaa toista, merkitse riippuvuus GitHubin **"Mark as blocked by"**
-toiminnolla — siinä kaikki. Ei labelia lisättäväksi eikä skriptiä ajettavaksi: poimintahaku
suodattaa estetyt issuet kvalifikaattorilla `-is:blocked`, joka lukee `blocked_by`-graafin
suoraan.

- Yksi avoin estäjä riittää pitämään issuen poiminnan ulkopuolella.
- Kun viimeinen estäjä sulkeutuu, issue vapautuu poimintaan **seuraavalla tikillä** ilman
  mitään synkronointia — mekanismi lukee graafin joka haussa uudelleen.
- Esto ei näy issuen labeleissa, joten sitä ei myöskään voi vahingossa poistaa labelia
  poistamalla. Vastaavasti: jos issue ei lähde ajoon eikä yksikään estolabeli ole päällä,
  tarkista riippuvuudet issuen omasta näkymästä.

**Työjärjestys ketjun rakentamiseen:** luo issuet → merkitse riippuvuudet GitHubin omalla
"blocked by" -toiminnolla → lisää jokaiselle `auto-run`. Automaatio etenee ketjussa yksi
lenkki kerrallaan itsestään.

Estotieto tulee GitHubin hakuindeksistä, joten se päivittyy pienellä viiveellä juuri suljetun
estäjän jälkeen. Käytännössä viive mahtuu pollerin 5 minuutin tikkiväliin.

### 6.6 Käyttötapaukset

Kahdeksan tilannetta, joissa ihmistä tarvitaan tai kannattaa tietää mitä tapahtuu.

**a) Tavallinen automaattiajo.** Kirjoita issue, lisää `auto-run` (ja `auto-merge`, jos
haluat mergen ilman erillistä hyväksyntää). Poller poimii sen viiden minuutin sisällä. Saat
PR:n, jonka rungossa on katselmoinnin ja evoluution tulokset sekä `Closes #<N>`. Jos toteutus
jäi osittaiseksi, **PR avataan draftina** — se on tarkoituksellinen signaali, ja PR-vahti ei
mergeä draftia.

**b) Katselmointiportti käsiajossa.** Interaktiivisessa ajossa (`/run-issues #N` ilman
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

Korjaa syy, siivoa ajo (`/cleanup-run`) ja päästä issue takaisin poimintaan.

**f) Ajo jäi jumiin.** Jos ajon viimeisin tapahtuma on vanhempi kuin
`RUN_ISSUES_STALE_AFTER` (oletus 3600 s), poller tappaa sen tmux-session, merkitsee ajon
tilaan `blocked/stalled_in_<vaihe>`, lisää `needs-human`-labelin ja kommentoi issueen. Tämä
on turvaverkko roikkuvalle Claude-kutsulle — erityisesti jos `timeout`-binääri puuttuu
(osio 2).

**g) Issue ei lähde uudelleen liikkeelle epäonnistumisen jälkeen.** Odotettua: assignaatio on
yhä voimassa (6.4). Siivoa ajo sillä koneella, jossa se tapahtui:

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

**i) PR on auki — mitä auto-merge vaatii.** PR-vahti mergeää vain, kun **kaikki kolme**
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
| `/run-issues` | `[#N]` | Ajaa orkestraattorin nimetylle issuelle; ilman argumenttia poimii vanhimman ehdot täyttävän (6.2). Ohje: [`commands/run-issues.md`](commands/run-issues.md) |
| `/pr-watch` | `[#PR \| scan]` | PR-vahti yhdelle PR:lle tai kaikille tämän koneen valmiille ajoille. Ohje: [`commands/pr-watch.md`](commands/pr-watch.md) |
| `/cleanup-run` | `[<run-id> \| --list \| --issue <N> \| --all]` | Siivoaa keskenjääneen ajon worktreen, haaran, run-dirin, lukon ja assignaation. Ohje: [`commands/cleanup-run.md`](commands/cleanup-run.md) |
| `/refresh` | — | Tuo repon ajan tasalle ja varmistaa että dev-server pyörii. Ohje: [`commands/refresh.md`](commands/refresh.md) |
| `/factory-run` | `<spec-polku>` | Agenttitehtaan pipeline yhdelle speksille. Ohje: [`commands/factory-run.md`](commands/factory-run.md) |
| `/factory-metrics` | `[--all \| --last <N>]` | Näyttää agenttitehtaan ajojen mittarit. Ohje: [`commands/factory-metrics.md`](commands/factory-metrics.md) |

Slash-komennot ovat ohjeita Claude Codelle, eivät skriptejä: agentti lukee ohjeen, ajaa
tarvittavat komennot ja tulkitsee tulokset. Siksi ne toimivat vain Claude Coden sisällä —
automaatio (poller) kutsuu skriptejä suoraan.

**`/factory-run`-rajoite:** ohje kehottaa alustamaan `.factory/`-hakemiston skriptillä
`templates/factory-init.sh`, jota **ei ole tässä repossa**. Alustus on toistaiseksi tehtävä
käsin. Ks. [`CLAUDE.md`](CLAUDE.md) §12.

### 6.8 Skriptit ja apuvälineet

Kaikki paketin skriptit ovat ajettavissa suoraan polusta `$HOME/.claude/scripts/run-issues/`.
Tätä tarvitset silloin, kun olet toisella koneella ssh:n päässä tai kun Claude Code ei ole
käytettävissä.

| Skripti | Tyypillinen kutsu | Mitä tekee |
|---|---|---|
| `orchestrate.sh` | `orchestrate.sh <repo> <N\|poll>` | Yksi issue → yksi PR. Muut moodit: `--resume <run-dir> --decision …`, `--restart <run-dir>`, `--continue <run-dir>`, `--remote <nimi>` |
| `pr-watch.sh` | `pr-watch.sh <repo> <PR\|scan>` | PR → merge. Idempotentti, ei resume-tilaa |
| `cleanup-run.sh` | `cleanup-run.sh --issue <N> --yes` | Ajojäänteiden purku. `--list`, `--all`, `--force`, `--dry-run`, `--remote` |
| `auto-clean.sh` | *(pollerin kutsuma)* | Label-vetoinen siivous + issuen sulkeminen. Käsin: `--repo <polku> --issue <N>` |
| `poller.sh` | *(LaunchAgent, 300 s)* | Watchlistin issue-automaatio |
| `pr-watch-poller.sh` | *(LaunchAgent, 300 s)* | Watchlistin PR-automaatio |
| `install.sh` | `bash install.sh --dry-run` | Asennus (osio 3) |

Kaksi asiaa kannattaa muistaa ajaessa käsin:

- **Siivous on konekohtaista.** Worktree, run-dir ja lukko ovat sillä koneella, jossa ajo
  tapahtui. Väärällä koneella ajettu siivous ei löydä mitään ja raportoi sen.
- **Pollerit ovat konelukittuja.** Ne vertaavat konenimeä muuttujaan
  `RUN_ISSUES_POLLER_HOSTS` ja exittaavat hiljaa nollalla, jos osumaa ei tule (osio 8).

### 6.9 Skill: `run-issues-workflow`

Poiminta- ja labelointipäätökset (6.2–6.5) tehdään silloin kun issue **luodaan** —
kohderepossa, jossa tätä README:tä ei ole vieressä. Sitä hetkeä varten paketti toimittaa
skillin [`skills/run-issues-workflow/SKILL.md`](skills/run-issues-workflow/SKILL.md), jonka
`install.sh` linkittää polkuun `$HOME/.claude/skills/` samalla ajolla kuin agentit ja
slash-komennot. Skill on siis **globaalisti käytettävissä** kaikissa repoissa, ei vain tässä.

Se latautuu Claude-sessioon progressiivisesti silloin kun teet issue-työtä vieraassa repossa
(näet `auto-run`-labelin, `run.json`-artefaktin tai PR-vahdin) ja kattaa kaksi näkökulmaa:
issuen kirjoittamisen niin että runner poimii sen, ja triagen "miksi issueni ei lähde ajoon".
Se **ei** kata tilakonetta, exit-koodeja eikä `lib/`-rakennetta — ne ovat tämän paketin
anatomiaa ja kuvattu tässä dokumentissa ja `CLAUDE.md`:ssä.

Ylläpitäjän koneella, jolla `$HOME/.claude/skills` on hakemistosymlinkki dotfilesiin, skill ei
asennu automaattisesti: `install.sh` tulostaa siitä `CONFLICT`-rivin ja exit-koodin 4, mutta
linkittää agentit ja komennot normaalisti (ks. [`CLAUDE.md`](CLAUDE.md) §3 ja §12).

---

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
`/refresh`-slash-komennon lukema konfiguraatio, jonka tulkitsee Claude-agentti. Mikään
paketin bash-skripti ei suorita sitä.

### 7.3 `RUN_ISSUES_AUTO=1` -rajat

Automaattiajossa agentti saa tehdä muutoksia ilman erillistä lupakyselyä. Rajat asetetaan
[`prompts/02-implementer.md`](prompts/02-implementer.md):ssä, ja sama sopimus kannattaa
kirjata omaan globaaliin `~/.claude/CLAUDE.md`-tiedostoosi, jotta se pätee myös silloin kun
ajat agenttia käsin. Kopioi:

```markdown
## Poikkeus — `RUN_ISSUES_AUTO=1`

Kun ympäristömuuttuja `RUN_ISSUES_AUTO=1` on asetettu, olet `/run-issues`-orkestraattorin
ajamana ja saat tehdä muutoksia ilman erillistä lupakyselyä. Rajat tässä tilassa:

- **Älä koskaan committaa tai pushaa `main`-haaraan** — orkestraattori on luonut feature-haaran
  (`auto-run/<repo-slug>-issue-<N>-<slug>`); pysy siinä.
- **Älä lisää salaisuuksia** (API-avaimet, salasanat, tokenit) committeihin, prompteihin,
  lokeihin tai PR-kommentteihin.
- **Älä aja destruktiivisia komentoja prodiin** (drop database, force push remoteen,
  `rm -rf` repon ulkopuolelle, tuotantopalvelinten muutokset). Käytä kloonattua kantaa,
  jos sellainen on annettu.
- **Jos issue-speksi on epäselvä tai ristiriidassa havaitun koodin kanssa**: pysähdy,
  committaa siihen mennessä syntynyt työ, avaa PR **draftina** ja kirjoita PR-kuvaukseen
  tarkka kysymys — älä arvaa.
```

Haaranimen muoto on repo-nimiavaruudella varustettu, jotta kahden repon issue #5 eivät
törmää samassa kloonissa. Ei-`origin`-remotelle nimeen tulee lisäksi remoten nimi.

**Jos muutat lohkoa, muuta `prompts/02-implementer.md` samalla.** Muuten agentin ajonaikaiset
säännöt ja globaali `CLAUDE.md` ajautuvat erilleen, ja agentti noudattaa promptia.

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

### "maintainer" esiintyy prompteissa ja komennoissa

Ihmisroolin nimi on kirjoitettu suoraan useaan promptiin, slash-komentoon ja
agenttimäärittelyyn. Se on **kosmeettista eikä vaikuta toimintaan**: bot ja ihminen erotellaan
markerin aikaleimalla, ei nimellä.

Parametrisointia ei tehty tietoisesti: promptien sijoitusmekanismi kattaa vain
[`prompts/`](prompts)-hakemiston, kun taas `commands/`- ja `agents/`-tiedostot lukee Claude
Code suoraan levyltä. Puoliksi parametrisoitu järjestelmä olisi huonompi kuin kumpikaan puhdas
vaihtoehto. Ks. [`CLAUDE.md`](CLAUDE.md) §12.

### Legacy-jäänteitä, joihin törmää

- `lib/poller-config.sh` sisältää sisäänrakennetun oletuslistan konenimistä
  (`POLLER_HOSTS_LEGACY_DEFAULT`). Aseta oma `RUN_ISSUES_POLLER_HOSTS` `poller.env`iin, niin
  lista ei koske sinua.
- Watchlistillä on toissijainen fallback vanhaan `~/dotfiles`-puuhun. Se ei laukea, jos
  ensisijainen polku osuu.

Molemmat on kirjattu tietoisiksi shimmeiksi: [`CLAUDE.md`](CLAUDE.md) §12.

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
| Ajo epäonnistui, korjasin syyn, issue ei palaa | Assignaatio ja `needs-human` jäivät | `/cleanup-run` tai `cleanup-run.sh --issue <N> --yes` |
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

Neljä skriptiä, **neljä erillistä exit-koodiavaruutta**. Sama numero ei tarkoita samaa asiaa
eri skripteissä — tarkista aina, kumpi prosessi exittasi.

### Orkestraattori (`orchestrate.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Onnistui — PR avattu, tai resume peruttiin siististi |
| 1 | Fataali — virheellinen käyttö tai puuttuva `run.json` resumessa |
| 2 | Ei ehdokasissueta (poll-tila, ei tekemistä) |
| 3 | Lukko-/claim-kilpajuoksu hävitty |
| 4 | Katselmointi esti ajon (vain auto-tila) |
| 5 | Estynyt ennen implementeriä tai implementerissä — worktreen luonti (S4), db-clone, riippuvuusasennus (S7b), testiympäristön provisiointi (S7c) tai implementer palautti BLOCKED. Tarkan syyn ja sen korjauksen kertoo `run.json`-statuksen syykenttä, ks. vianetsinnän kohta (e) |
| 6 | PR:n avaus epäonnistui |
| 7 | Implementer (S8) aikakatkaistiin — ajo on `--restart`-kelpoinen |
| 8 | **Puuttuva pakollinen riippuvuus** — S0-portti kieltäytyi käynnistämästä ajoa; mitään ei lukittu, claimattu eikä luotu. Virheilmoitus nimeää työkalun ja korjauskomennon |
| 9 | **Issue on estetty avoimella `blocked_by`-riippuvuudella** — S2b-portti kieltäytyi lukon ja claimin välissä ennen assignaatiota; ajo viimeisteltiin `blocked`-tilaan ja lukko vapautettiin. Portti lukee riippuvuusgraafin suoraan (`-is:blocked`-hakuindeksin sijaan) ja on fail-closed. Issue **ei** saa `needs-human`-labelia: se on odotustila, joka jatkuu itsestään kun estäjä sulkeutuu. Nimetyn ajon voi pakottaa `--force`-lipulla |
| 10 | Odottaa ihmisen katselmointia — jatka komennolla `--resume` |
| 11 | Odottaa tarkennusta — vastaa issuelle, poller jatkaa `--continue`-ajolla |

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

### Label-vetoinen siivous (`auto-clean.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Siivottu, issue suljettu, `auto-clean`-label poistettu |
| 1 | Käyttövirhe tai remotea ei voitu selvittää |
| 3 | Issuen lukko on toisella ajolla — turvallista yrittää seuraavalla tikillä |
| 4 | Issuella on `completed`-ajo (todennäköisesti avoin PR) — ei siivottu, `auto-clean-skipped` lisätty |
| 5 | Tältä koneelta ei löydy ajoja tälle issuelle — `auto-clean-skipped` lisätty ja kommenttiin kirjattu konekohtainen ohje |
| 6 | Purku (`cleanup-run.sh`) epäonnistui |

Koodit 4 ja 5 eivät ole virheitä vaan **kieltäytymisiä**: siivous ei koske avoimen PR:n ajoon
eikä arvaile toisen koneen tilaa. `auto-clean-skipped` on silmukkasuoja — poista se käsin,
kun olet hoitanut asian, jos haluat siivouksen yrittävän uudelleen.

### Mistä lokit löytyvät

- **Pollerit:** `$RUN_ISSUES_LOG_DIR` (oletus `$HOME/Library/Logs`), neljä tiedostoa per
  poller: `.log`, `.runs.log`, `.stdout.log`, `.stderr.log`. Tiedostojen etuliitteet ovat
  `run-issues-poller` ja `pr-watch-poller`.
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
/cleanup-run --list
/cleanup-run --issue <N>

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
ja sulkee issuen (6.6 h).

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

- [`CLAUDE.md`](CLAUDE.md) — agentin tekninen referenssi. §7 = kaikki ympäristömuuttujat,
  §12 = tunnetut avoimet asiat.
- [`db-clone/README.md`](db-clone/README.md) — tietokannan kloonaus (S5).
- [`provision-test-env.README.md`](provision-test-env.README.md) — testiympäristön
  provisiointihook (S7c).
- [`docs/diagrams/`](docs/diagrams) — mermaid-kaaviot tilakoneista, poluista ja
  konfiguraation resolvoinnista.
- [`examples/`](examples) — watchlistin ja `poller.env`:n itsedokumentoivat mallit.
