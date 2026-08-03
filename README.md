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
| `RUN_ISSUES_LABELS_CSV` | *(tyhjä)* | Label-suodatin poll-tilassa |
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

### PR-vahti

| Muuttuja | Oletus | Vaikutus |
|---|---|---|
| `PR_WATCH_MERGE_LABEL` | `auto-merge` | Label, joka sallii auto-mergen |
| `PR_WATCH_ENABLE_CONFLICT_RESOLUTION` | `0` (poller nostaa `1`:ksi) | AI-avusteinen konfliktinratkaisu (ks. osio 7.4) |

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

Slash-komennot Claude Codessa, kohderepon juuressa:

| Komento | Mitä tekee | Ohje |
|---|---|---|
| `/run-issues [#N]` | Ajaa orkestraattorin nimetylle issuelle tai vanhimmalle omistamattomalle | [`commands/run-issues.md`](commands/run-issues.md) |
| `/pr-watch [#PR \| scan]` | PR-vahti yhdelle PR:lle tai kaikille tämän koneen ajoille | [`commands/pr-watch.md`](commands/pr-watch.md) |
| `/cleanup-run` | Siivoaa keskenjääneen ajon worktreen, haaran, run-dirin ja lukon | [`commands/cleanup-run.md`](commands/cleanup-run.md) |
| `/refresh` | Tuo repon ajan tasalle ja varmistaa että dev-server pyörii | [`commands/refresh.md`](commands/refresh.md) |
| `/factory-run <spec>` | Agenttitehtaan pipeline yhdelle speksille | [`commands/factory-run.md`](commands/factory-run.md) |
| `/factory-metrics` | Näyttää agenttitehtaan ajojen mittarit | [`commands/factory-metrics.md`](commands/factory-metrics.md) |

**`/factory-run`-rajoite:** ohje kehottaa alustamaan `.factory/`-hakemiston skriptillä
`templates/factory-init.sh`, jota **ei ole tässä repossa**. Alustus on toistaiseksi tehtävä
käsin. Ks. [`CLAUDE.md`](CLAUDE.md) §12.

### Labelit

Labelit jakautuvat **kolmeen luokkaan**, ja luokan tunteminen säästää turhan etsinnän:

| Label | Luokka | Merkitys |
|---|---|---|
| `waiting`, `wip` | kovakoodattu suodatin | issue jätetään poimimatta |
| `needs-human` | kovakoodattu | poller merkitsee ajon ihmistä vaativaksi |
| `auto-clean` | overridattava (`RUN_ISSUES_CLEAN_LABEL`) | laukaisee ajon siivouksen |
| `auto-merge` | overridattava (`PR_WATCH_MERGE_LABEL`) | sallii auto-mergen |
| `auto-run` | **konfiguraatiosta** | ei ole kovakoodattu mihinkään; tulee watchlistin `default_labels`-oletuksesta tai `RUN_ISSUES_LABELS_CSV`:stä |

**Estot luetaan GitHubin natiivista riippuvuudesta, ei labelista.** Poimintahaku suodattaa
estetyt issuet kvalifikaattorilla `-is:blocked`, joka lukee `blocked_by`-graafin suoraan — ei
`blocked`-labelia eikä synkronointiskriptiä.

### Riippuvuudet toisiin issueihin

Kun issuen pitää odottaa toista, merkitse riippuvuus GitHubin **"Mark as blocked by"**
-toiminnolla — siinä kaikki. Ei labelia lisättäväksi eikä skriptiä ajettavaksi. Poiminta
ohittaa estetyn issuen automaattisesti, ja kun viimeinen estäjä sulkeutuu, issue vapautuu
poimintaan sekunneissa ilman mitään synkronointia. Yksi avoin estäjä riittää pitämään issuen
estettynä.

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

### 7.5 Submodule-pinni on turvaportti

Kun paketti liitetään dotfiles-repoon, se liitetään **pinnattuna** git-submodulena. Pinni ei
ole versionhallintakosmetiikkaa vaan turvaraja.

Ilman pinniä ketju olisi: kollaboraattori pushaa paketin `main`iin → dotfilesin oma
synkronointi hakee muutoksen automaattisesti → symlinkki `~/.claude/scripts` osoittaa uuteen
koodiin → pollerin seuraava tikki ajaa sitä täysin oikeuksin toisen ihmisen koneella. Toisin
sanoen push tähän repoon olisi käytännössä etäkoodinsuoritus jokaisella asennetulla koneella.

Pinni tekee päivityksestä **eksplisiittisen päätöksen**: submodulen viittaus siirretään käsin,
ja siirto näkyy dotfiles-repon diffissä.

### 7.6 Asentaja kieltäytyy koskemasta vieraisiin tiedostoihin

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

Kun katselmointi ei ymmärrä issueta, ajo päättyy tilaan "odottaa tarkennusta" ja jättää
issuelle kysymyksen. Kun vastaat, poller käynnistää ajon uudelleen.

Vastauksesta poimitaan **vain uusin** ei-bottikommentti markerin jälkeen, ja se katkaistaan
**8000 merkkiin** (`lib/issue.sh`). Jos pilkot vastauksesi kolmeen kommenttiin, kaksi
ensimmäistä katoavat.

Sääntö on **rakenteellinen, ei tyylisuositus**: bot ja ihminen käyttävät samaa GitHub-tiliä,
joten kommentin kirjoittaja ei kelpaa erottimeksi. Ainoa luotettava raja on markerin
aikaleima. Silmukalla on lisäksi katto: `RUN_ISSUES_MAX_CLARIFICATIONS`, oletus `3`. Kaavio:
[`docs/diagrams/run-issues-clarification-loop.mmd`](docs/diagrams/run-issues-clarification-loop.mmd).

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

Kolme skriptiä, **kolme erillistä exit-koodiavaruutta**. Sama numero ei tarkoita samaa asiaa
eri skripteissä — tarkista aina, kumpi prosessi exittasi.

### Orkestraattori (`orchestrate.sh`)

| Koodi | Merkitys |
|---|---|
| 0 | Onnistui — PR avattu, tai resume peruttiin siististi |
| 1 | Fataali — virheellinen käyttö tai puuttuva `run.json` resumessa |
| 2 | Ei ehdokasissueta (poll-tila, ei tekemistä) |
| 3 | Lukko-/claim-kilpajuoksu hävitty |
| 4 | Katselmointi esti ajon (vain auto-tila) |
| 5 | Estynyt ennen implementeriä tai implementerissä — db-clone, riippuvuusasennus (S7b), testiympäristön provisiointi (S7c) tai implementer palautti BLOCKED |
| 6 | PR:n avaus epäonnistui |
| 7 | Implementer (S8) aikakatkaistiin — ajo on `--restart`-kelpoinen |
| 8 | **Puuttuva pakollinen riippuvuus** — S0-portti kieltäytyi käynnistämästä ajoa; mitään ei lukittu, claimattu eikä luotu. Virheilmoitus nimeää työkalun ja korjauskomennon |
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

### Mistä lokit löytyvät

- **Pollerit:** `$RUN_ISSUES_LOG_DIR` (oletus `$HOME/Library/Logs`), neljä tiedostoa per
  poller: `.log`, `.runs.log`, `.stdout.log`, `.stderr.log`. Tiedostojen etuliitteet ovat
  `run-issues-poller` ja `pr-watch-poller`.
- **Yksittäinen ajo:** `<kohderepo>/.claude/run-issues/<run-id>/` — `run.json` (tilan
  tilannekuva) ja `state.jsonl` (append-only tapahtumaloki).
- **Lukot:** `$HOME/Library/Application Support/run-issues/locks`.

### Hätävarat

- `RUN_ISSUES_SKIP_PREFLIGHT=1` ohittaa S0-portin. Käytä vain jos portti on väärässä — se ei
  saa koskaan olla syy siihen, ettei ajo käynnisty toimivalla koneella.
- Keskenjäänyt ajo (worktree, haara, run-dir, lukko, assignaatio) siivotaan komennolla
  `/cleanup-run` **sillä koneella, jossa ajo tapahtui**.

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
