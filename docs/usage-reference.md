# Käyttö — työkalukohtainen referenssi

Tämä tiedosto on **työkalukohtainen käyttöreferenssi**: sitä ei lueta alusta loppuun vaan
silloin kun tiettyä työkalua tai tilannetta käyttää. Perehtyjän luettava kerronta — *milloin ja
miksi* ajo lähtee liikkeelle (elinkaari, poimintaehdot, labelit, varaus, riippuvuudet) — on
[`README.md`](../README.md) osiossa 6, joka linkittää tänne.

Tämä osio kattaa poiminnan koneiston, epicit, käyttötapaukset (mitä ihminen näkee ja tekee kussakin tilanteessa),
slash-komennot, skriptit ja apuvälineet, `claude-issue-runner`-skillin, `status.sh`:n
kokonaistilanäkymän ja `publish-release.sh`:n julkaisun.

---

## Poiminnan koneisto ja työnjako

Poiminnan *ydinsäännöt* — milloin issue lähtee ajoon — ovat [`README.md`](../README.md)
osiossa 6.2. Tämä osio kokoaa saman poiminnan **koneiston ja työnjaon**: miksi kysely on
REST-listaus, poimintalabelien resolvointi, valinnainen assignee-reititys ja pollerin
sisäinen järjestys.

### Miksi REST eikä `gh issue list`

**Miksi REST eikä `gh issue list`?** `--label`-suodatettu `gh issue list` kulkee GitHubin
GraphQL-hakuyhteyden kautta, ja **se yhteys voi olla estetty vaikka muu API vastaa
normaalisti** — näin kävi 27 tunnin ajan 2026-08-28/29, jolloin poiminta ei voinut ajaa
lainkaan (#133). REST-listaus ei koske hakuyhteyteen. Sivuhyöty: poissulkuehdot ovat nyt
paikallisia jäsenyystestejä, jotka epäonnistuvat **umpeen** — vanha `-label:x` epäonnistui
auki, eli kirjoitusvirhe vuoti poissuljettuja issueita poimintaan. Mittaus ja
kontrollikoe: CLAUDE.md §5.2.

### Poimintalabelien resolvointi ja `auto-reset`in poissulku

Poimintalabelit tulevat konfiguraatiosta kolmessa portaassa: watchlistin repokohtainen
`labels` → watchlistin `default_labels` → sisäänrakennettu oletus `["auto-run"]`. **Mikään
labelin nimi ei ole kovakoodattu poimintaan** — `auto-run` on pelkkä konventio.

`auto-reset`in poissulku ei ole optimointi vaan **korrektiusehto**: nollauksen koko idea on,
että poiminta jatkuu vasta kun purku on ajettu ja label poistettu. Ilman suodatinta poller
voisi varata issuen ennen purkua, ja purku törmäisi issuekohtaiseen lukkoon joka tikillä.

### Valinnainen assignee-reititys (watchlistin `assignees`)

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
`auto-claimed`-label (README §6.4). Sekä `poller.sh` että `drain-queue.sh` lukevat avaimen samalla
resolvoijalla, joten ne eivät voi olla eri mieltä siitä, mitä tämä kone poimii. Uusia
API-kutsuja ei synny: assignee- ja avaajatieto on jo poiminnan REST-vastauksessa.

**Käänteinen määritys `not:<tunnus>` (issue #246).** Listan alkio on joko tunnus
(`"octocat"`, **ALLOW**) tai kielto (`"not:octocat"`, **DENY**). Issue kelpaa, kun molemmat
pätevät: (1) ALLOW on tyhjä **tai** kohde osuu johonkin ALLOW-tunnukseen, ja (2) kohde ei osu
yhteenkään DENY-tunnukseen. **DENY voittaa ALLOW:n**, jos sama tunnus on molemmissa (fail-closed),
ja useasta assigneesta riittää yksi DENY-osuma. Kohde on tässäkin assignee-joukko tai, sen
puuttuessa, avaaja. `not:` vaatii kaksoispisteen — `notoctocat` on tavallinen ALLOW-tunnus.
Muoto ratkaisee kahden koneen jaon ilman toista repo-oikeuksin varustettua tunnusta:
`["octocat"]` ja `["not:octocat"]` osuu jokaiseen issueen täsmälleen kerran, **eikä
DENY-tunnukselta vaadita repo-oikeutta**. **Varoitus:** liian laaja DENY tuottaa **nolla osumaa
yhtä hiljaa kuin väärä poimintalabel** (README §6.2) — repo lakkaa poimimasta ilman virhettä ja lokia.

### Pollerin sisäinen järjestys ja rinnakkaisuus

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
sellaisenaan. Ks. [`env-reference.md`](env-reference.md).

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

## Epicit — usean issuen ketjun ajaminen `auto-run`illa

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
[`commands/issue-runner/run-epic.md`](../commands/issue-runner/run-epic.md).

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

## Käyttötapaukset

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
[`docs/diagrams/run-issues-clarification-loop.mmd`](diagrams/run-issues-clarification-loop.mmd).

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
[`docs/diagrams/run-issues-auto-clean-flow.mmd`](diagrams/run-issues-auto-clean-flow.mmd).

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
(`gh pr merge --rebase`); jos GitHub torjuu sen — näin käy aina, kun
feature-haaralla on merge-commit, esimerkiksi konfliktin ratkaisusta — vahti tekee
merge-commitin (`--merge`). Ilman tätä varapolkua PR ei mergeytyisi koskaan, koska haaran muoto
ei muutu itsestään. Jos ensimmäinen yritys virheestä huolimatta mergesi PR:n, vahti huomaa sen
ja jatkaa eteenpäin varapolkua laukaisematta. Molempien yritysten virheteksti kirjataan lokiin,
joten aito merge-esto kertoo syynsä.

**Merge-kutsussa ei ole `--delete-branch`ia.** Lippu poistaisi myös *paikallisen* haaran, jota
ajon oma worktree pitää tässä vaiheessa yhä varattuna — worktree puretaan vasta siivousvaiheessa.
Git kieltäytyisi, `gh` palauttaisi virheen, ja jo tapahtunut merge luettaisiin epäonnistuneeksi:
ajo jäisi `needs-human`-tilaan eikä mergen jälkeisiä vaiheita ajettaisi lainkaan, joten juuri se
worktree jäisi levylle. Remote-haara poistetaan siksi erikseen heti mergen jälkeen
(`gh api --method DELETE …/git/refs/heads/<haara>`, best-effort) ja paikallinen vasta siivouksessa,
jossa worktree puretaan ensin. Mergen
jälkeen vahti ajaa repon valinnaisen `.claude/post-merge-migrate.sh`-skriptin ja siivoaa
ajojäänteet — mutta **vain saman koneen ajot**; muille koneille se tulostaa lokiin valmiin
siivouskomennon.

**Kuvat issuessa.** Issuen rungon ja kommenttien kuvat ladataan paikallisesti ennen ajoa,
jotta agentti näkee ne (enintään 10 kuvaa, 10 MiB kukin). Ruutukaappaus on siis kelvollinen
osa speksiä. Epäonnistunut lataus ei kaada ajoa — agentti jää vain ilman kuvaa.

## Slash-komennot

Claude Codessa, kohderepon juuressa:

| Komento | Argumentit | Mitä tekee |
|---|---|---|
| `/issue-runner:run-issue` | `#N` | Ajaa orkestraattorin nimetylle issuelle. Issuenumero on pakollinen; ilman sitä komento tulostaa usage-viestin eikä kutsu orkestraattoria — automaattinen poiminta on pollerin tehtävä (6.2). Ohje: [`commands/issue-runner/run-issue.md`](../commands/issue-runner/run-issue.md) |
| `/issue-runner:run-epic` | `[#N] [--dry-run] [--start-now] [--stop]` | Validoi ja käynnistää epicin: propagoi ajolabelit alaissueille ja raportoi ketjun tilan. `--stop` keskeyttää epicin (6.5). Ohje: [`commands/issue-runner/run-epic.md`](../commands/issue-runner/run-epic.md) |
| `/issue-runner:new-issue` | `<kuvaus tehtävästä>` | Kirjoittaa kuvauksesta yhden ajon kokoisen issuen, joka täyttää kaikki poimintaehdot: paketin oma runko ja tämän koneen poimintalabelit (6.2). Luonnos vahvistetaan ennen kirjoitusta; epicin kokoinen kuvaus vain ehdotetaan eskaloitavaksi. Kysyy kohderepon kielimäärittelyn ja kirjaa sen repon `CLAUDE.md`:hen, jos se puuttuu. Ei aja mitään. Ohje: [`commands/issue-runner/new-issue.md`](../commands/issue-runner/new-issue.md) |
| `/issue-runner:new-epic` | `<kuvaus kokonaisuudesta>` | Pilkkoo kuvauksen epiciksi ja alaissueiksi: luo issuet, linkittää sub-issueiksi, merkitsee `blocked_by`-riippuvuudet ja labeloi vain epicin ajoon (6.5). Kysyy kohderepon kielimäärittelyn kuten `/issue-runner:new-issue`. Ei aja mitään. Ohje: [`commands/issue-runner/new-epic.md`](../commands/issue-runner/new-epic.md) |
| `/issue-runner:problem` | `<ongelma omin sanoin>` | Triagee kuvatun ongelman repon koodista ja lokeista, kysyy puuttuvat toistoaskeleet ja tarkistaa duplikaatit avoimista issueista. Päätyy yhteen kolmesta: korjausohje ilman issueta, issue `/issue-runner:new-issue`n kautta, tai kokonaisuus `/issue-runner:new-epic`in kautta. Ei korjaa eikä aja mitään. Ohje: [`commands/issue-runner/problem.md`](../commands/issue-runner/problem.md) |
| `/issue-runner:pr-watch` | `[#PR \| scan]` | PR-vahti yhdelle PR:lle tai kaikille tämän koneen valmiille ajoille. Ohje: [`commands/issue-runner/pr-watch.md`](../commands/issue-runner/pr-watch.md) |
| `/issue-runner:cleanup-run` | `[<run-id> \| --list \| --issue <N> \| --all]` | Siivoaa keskenjääneen ajon worktreen, haaran, run-dirin, lukon ja assignaation. Ohje: [`commands/issue-runner/cleanup-run.md`](../commands/issue-runner/cleanup-run.md) |
| `/issue-runner:refresh` | — | Tuo repon ajan tasalle ja varmistaa että dev-server pyörii. Ohje: [`commands/issue-runner/refresh.md`](../commands/issue-runner/refresh.md) |

Slash-komennot ovat ohjeita Claude Codelle, eivät skriptejä: agentti lukee ohjeen, ajaa
tarvittavat komennot ja tulkitsee tulokset. Siksi ne toimivat vain Claude Coden sisällä —
automaatio (poller) kutsuu skriptejä suoraan.

## Skriptit ja apuvälineet

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

## Skillit

Skill on **ehdollinen lataaja**: Claude lukee vain sen `description`-kentän ja päättää siitä,
vetääkö rungon mukaan sessioon. Se on oikea muoto silloin kun säännöllä on **aito laukaisuehto**,
ja väärä muoto aina päällä olevalle säännölle — sellainen kuuluu tiedostoon
[`principles/coding.md`](../principles/coding.md), joka luetaan ehdoitta. `install.sh` linkittää
jokaisen paketin skillin polkuun `$HOME/.claude/skills/` **per hakemisto** samalla ajolla kuin
agentit ja slash-komennot, joten ne ovat **globaalisti käytettävissä** kaikissa repoissa, ei
vain tässä.

### `claude-issue-runner` — järjestelmän oma skill

Päätökset järjestelmästä tehdään **kohderepossa**, jossa tätä README:tä ei ole vieressä: siellä
kirjoitetaan ja labeloidaan issue, ja siellä törmätään siihen mitä automaatio on jättänyt
jälkeensä. Sitä hetkeä varten paketti toimittaa skillin
[`skills/claude-issue-runner/SKILL.md`](../skills/claude-issue-runner/SKILL.md).

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

### Laukeavat skillit

Nämä eivät koske järjestelmää itseään vaan **yhtä työn lajia**, jolla on tunnistettava alkuhetki.
Sisältö on samaa luokkaa kuin `principles/coding.md`:ssä — geneeristä, ei kenenkään
konfiguraatiota — mutta ehdollisena, koska sääntö on merkityksetön silloin kun sitä ei tarvita.

| Skill | Laukeaa kun | Kattaa |
|---|---|---|
| [`e2e-testing`](../skills/e2e-testing/SKILL.md) | kirjoitat, korjaat tai katselmoit selainta ajavaa end-to-end-testiä | Playwright oletuksena, web-first assertions käsin kirjoitettujen odotusten sijaan, `data-test`/`data-testid` tekstipohjaisten valitsimien sijaan, ja testitunnukset erillisenä tilinä — ei olemassa olevan käyttäjän salasanaa vaihtamalla |
| [`container-build`](../skills/container-build/SKILL.md) | projektin ensimmäinen konttibuild, tai image-buildi on hidas, ei osu cacheen tai epäilyttää sisältönsä puolesta | `.dockerignore` **ennen** ensimmäistä buildia ja mitä build-konteksti ilman sitä imaisee (riippuvuushakemistot, `.git`, `.env*`) |

`tests/test-skill-triggers.sh` vartioi molempia sääntöjä mekaanisesti jokaiselle paketin
skillille: `description` ei saa lukea ehdoitta laukeavana, eikä skill saa nimetä toista
skilliä, jota paketti ei toimita.

### Kun `$HOME/.claude/skills` on vieras hakemistosymlinkki

Jos `$HOME/.claude/skills` on koneella kokonainen hakemistosymlinkki (jonkin toisen lähteen
omistama hakemisto), skillit eivät asennu automaattisesti: `install.sh` tulostaa siitä
`CONFLICT`-rivin ja exit-koodin 4, mutta linkittää agentit ja komennot normaalisti. Miksi
kieltäytymisen sijaan conflict: [`CLAUDE.md`](../CLAUDE.md) §3.

## Kokonaistilan katsominen (`status.sh`)

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

**Selainpohjainen web-esitys.** [`status-render.sh`](../status-render.sh) on JSONin ensimmäinen
kuluttaja: se kirjoittaa `index.html`in ja `status.json`in atomisesti hakemistoon
`RUN_ISSUES_STATUS_OUT_DIR` (oletus `${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/www`),
ilman ulkoisia resursseja. `index.html` on **itsenäinen selainsovellus**: staattinen runko +
inline-CSS + inline-JS, joka hakee `status.json`in `fetch`illä 60 s välein ja renderöi näkymän
selaimessa — ryhmittely repoittain, suodatinchipit, järjestysvalinta, suomenkieliset
tilaselitteet ja vaalea/tumma teema. Kaikki datateksti insertoidaan `textContent`illä, joten
sivu on turvallinen tarjoiltavaksi. Valinnainen LaunchAgent
`com.claude-issue-runner.status-render.plist` regeneroi rungon 300 s välein (itse data päivittyy
selaimessa 60 s välein). Sivun altistaminen verkkoon on koneen omistajan asia — lue turvamallin
osio [7.8](../README.md#78-statussivun-web-esitys-on-uusi-altistuspinta) ja `examples/status-caddy.example`
ennen kuin tarjoilet sitä mistään.

**Valinnainen gh-rikastus (#78).** Ympäristömuuttujalla `RUN_ISSUES_RENDER_GITHUB=1`
`status-render.sh` ajaa LaunchAgent-polulla `status.sh --github`in, jolloin sivulle tulee issuen
**otsikko** rivin pääteksinä (`github.issue_title`) sekä avoimen PR:n **CI-tila** ja
**mergevalmius** chippeinä. Fail-soft: jos rikastus epäonnistuu, sivu renderöityy paikallisella
datalla kuten ennen. Oletus `0` = pelkkä paikallinen näkymä. **Otsikot paljastavat
asiakaskontekstia — pidä sivu tailnetissä, älä altista julkisesti (osio
[7.8](../README.md#78-statussivun-web-esitys-on-uusi-altistuspinta)).**

**Epic-rollup (#79).** gh-rikastus (`--github`) tuottaa myös top-level-listan `epics[]` —
avoimet `epic`-labeloidut issuet ja niiden alaissueet (ensisijaisesti GitHubin natiivista
sub-issues-rajapinnasta, fallbackina epicin rungon `- [ ] … #N` -task-listasta). Sivu renderöi
per epic **epic-kaistan** sen repo-ryhmän sisään: edistymispalkki (suljetut/kaikki alaissueet),
ajossa oleva alaissue korostettuna, jonossa olevat riippuvuusjärjestyksessä estäjineen
("jonossa · estäjä #N") ja suljetut alaissueet yliviivattuina kuittausriveinä niin kauan kuin
epic on auki. Alaissueen ajo näkyy vain kerran — kaistalla, ei irtorivinä. Ilman `--github`iä
`epics[]` on tyhjä ja näkymä on entisellään. Epic- ja alaissue-otsikot ovat samaa
tailnet-rajattua otsikkopolkua kuin #78. Skeema ja tekninen referenssi: [`docs/design-history.md`](design-history.md).

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
alta (#32). Skeema ja tekninen referenssi: [`docs/design-history.md`](design-history.md).

## Julkaisu julkiseen peiliin (`publish-release.sh`)

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
[`install.sh`](../install.sh)ssa — **yksikin kieltäytyminen ⇒ nolla kirjoitusta**, eikä yksikään
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
