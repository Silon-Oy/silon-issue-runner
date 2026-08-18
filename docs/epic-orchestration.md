# Epic-ajon arkkitehtuuri

Tämä on **suunnitteludokumentti**, ei toteutus. Se määrittelee, miten `/run-issues`-runner
ajaa kokonaisen *epicin* — usean toisiinsa liittyvän issuen ketjun — ilman ihmistä silmukassa.
Kohdeyleisö on ne toteutusissueet (auto-run epic-tasolla; `/run-epic`-komento), jotka
kirjoitetaan suoraan tämän dokumentin pohjalta. Kaikki *ehdotukset* ja *avoimet päätökset* on
merkitty näkyvästi; lopullinen päätös tehdään PR-katselmoinnissa.

**Lähtökohta.** Runnerilla on jo ajettu kokonaisia epicejä — mm. tämän repon statusnäkymä-epic
(#59–#65) — mutta **käsityönä**: ihminen kirjoittaa alaissueet, luo `blocked_by`-riippuvuudet,
lisää `auto-run`-labelit, ja poller ajaa ketjun oikeassa järjestyksessä S2b-portin (#28)
valvomana. Tämä dokumentti kodifioi tuon konvention ja määrittelee, mitä epic-tason
automaatio (auto-run epicille, `/run-epic`) sen päälle vaatii.

**Suunnittelun johtoajatus on minimimuutos.** Runnerin nykyinen riippuvuusajo — poiminta, lukot,
S2b-esto-portti, PR-vahti — kantaa jo epic-ketjun. Epic-tason automaatio on ohut kerros sen
*päällä*: se ei aja alaissueita itse, vaan **valmistelee ne** niin, että olemassa oleva poller
poimii ne normaalisti. Jokainen kohta alla arvioidaan tätä vasten: mitä tarvitaan aidosti
uutta, ja mikä on jo olemassa.

## Rajaukset

- **Ei cross-repo-epicejä.** Epicin kaikki alaissueet ovat samassa repossa kuin epic-issue
  itse. Toisessa repossa oleva alaissue on virhetilanne (§7), ei tuettu muoto. GitHubin
  sub-issue-relaatio *sallii* cross-repo-lapset, mutta runnerin poiminta, lukot ja worktree
  ovat kaikki repo-kohtaisia, joten cross-repo-ajo vaatisi oman epicinsä eikä kuulu tähän.
- **Ei näkyvyysmuutoksia Ohjaamo-näkymään.** Epicin tila esitetään erikseen Ohjaamon
  V4-näkymäissuessa; tämä dokumentti määrittelee vain *ajon* arkkitehtuurin. Jaettu vaatimus
  molemmille on sama kanoninen muoto ja sama fallback (§1) — tämä dokumentti on siitä
  yksi totuudenlähde.
- **Tämä dokumentti ei sisällä koodia.** Kohdan §6 muutoskohdat on nimetty tiedosto- ja
  funktiotasolla, mutta ne toteutetaan erillisissä issueissa.

## Nykytila-analyysi lyhyesti (§2:n löydös etukäteen)

> **Löydös:** epic-labelillinen issue, jolla on `auto-run` eikä estäjää, **poimitaan tänään
> tavallisena työissuena**. Koodissa ei ole mitään, joka erottaisi epicin lehti-issuesta.
> Tarkka koodianalyysi ja seuraukset §2:ssa.

---

## 1. Epicin kanoninen rakenne

Epic on GitHub-issue, joka **kokoaa** joukon ajettavia alaissueita. Se ei ole itse ajettava:
sen "toteutus" on sen lasten toteutus.

### 1.1 Kanoninen muoto

| Elementti | Vaatimus |
|---|---|
| **`epic`-label** | Pakollinen ja **kanoninen** epicin tunnus. Ihminen (tai `/run-epic`, §5) lisää sen. Tämä on ainoa signaali, jolla runner erottaa epicin lehti-issuesta — labelin nimi on kiinteä (ei konfiguroitava, ks. §6). |
| **Natiivit sub-issuet** | Kanoninen tapa liittää alaissueet epiciin: GitHubin natiivi sub-issue-relaatio (parent → children). Luetaan API:sta `GET /repos/{owner}/{repo}/issues/{N}/sub_issues`; issue-objektissa on myös `sub_issues_summary` (`total`, `completed`, `percent_completed`) ja lapsi-issuessa `parent`-viittaus. |
| **Alaissueiden väliset riippuvuudet** | GitHubin natiivi **`blocked_by`** -relaatio, sama jota S2b-portti (#28) lukee. Riippuvuudet ilmaisevat ajojärjestyksen; ilman niitä alaissueet ovat rinnakkaisia. Riippuvuus **ei** ole sub-issue-relaatio — ne ovat kaksi eri graafia (ks. §1.4). |
| **Epic-issuen runko** | Sisältää: (a) epic-tason **tavoite**, (b) epic-tason **hyväksyntäkriteerit** (milloin koko epic on valmis), (c) keskeiset **päätökset** ja rajaukset. Runko on ihmiselle ja PR-katselmoijalle; runner ei toteuta sitä. |

**Suositus (kanoninen minimi):** epicillä on `epic`-label **ja** ≥1 natiivi sub-issue. Muut
elementit (riippuvuudet, runko-osiot) ovat suositeltuja mutta eivät estä ajoa.

### 1.2 Task-lista-fallback (vanhat epicit)

Ennen natiivien sub-issueiden vakiintumista epicit linkitettiin **rungon task-listalla**:

```markdown
- [ ] Alaissue A → #101
- [ ] Alaissue B → #102
```

Repoissa esiintyy molempia muotoja (esim. customer-c-erp #2 natiivi 14 lapsella; customer-c-erp #101
task-lista). **Päätös: natiivit sub-issuet ovat kanoniset, task-lista luetaan vain
fallbackina.**

**Fallbackin lukusäännöt:**

1. **Etusijajärjestys:** jos issuella on ≥1 natiivi sub-issue, käytä **vain** niitä. Task-listaa
   **ei** lueta lainkaan — se voi olla vanhentunut tai päällekkäinen natiivien kanssa, ja
   kahden lähteen yhdistäminen tuottaisi haamu- tai kaksoislapsia. Natiivi voittaa aina.
2. **Fallback laukeaa vain** kun natiiveja lapsia on nolla. Vasta silloin runko jäsennellään.
3. **Jäsennyssääntö:** poimi rivit, jotka täsmäävät kuvioon `- [ ] … #<N>` tai `- [x] … #<N>`
   (GitHub-checkbox + issue-viittaus). Numero `<N>` on saman repon issue. `[x]` = valmis (ei
   poimita ajoon), `[ ]` = avoin. Rivin muu teksti on kuvaus, ei koneelle.
4. **Cross-repo-viittaukset** (`owner/repo#N`) fallback-listassa ovat rajausten (ks. Rajaukset)
   ulkopuolella: rivi ohitetaan ja kirjataan varoituksena.

> **Avoin päätös A — kirjoittaako fallback natiivit lapset?**
> Vaihtoehdot: (i) fallback on **vain lukusääntö** — runner poimii task-listasta ajettavat
> numerot mutta ei muuta epiciä; (ii) `/run-epic` **migratoituu** kertaalleen kirjoittamalla
> task-listan lapset natiiveiksi sub-issueiksi (`POST …/sub_issues`), minkä jälkeen epic on
> kanonisessa muodossa.
> **Suositus: (i).** Migraatio on sivuvaikutus, joka muuttaa ihmisen kirjoittamaa rakennetta;
> se kuuluu erilliseen, eksplisiittiseen työkaluun, ei ajon sivutuotteeksi. Fallback pysyy
> puhtaana lukusääntönä, jolloin sama koodipolku kelpaa myös pelkkään raportointiin.

### 1.3 Skeemayhteensopivuus Ohjaamon V4-näkymän kanssa

Sama kanoninen muoto ja sama fallback pätevät molemmissa (hyväksyntäkriteeri 4): natiivit
sub-issuet ovat totuudenlähde, task-lista fallback vain kun natiiveja ei ole. Kumpikin kuluttaja
— ajava runner ja näyttävä Ohjaamo — johtaa epicin lapsijoukon **identtisellä** logiikalla,
jotta näkymä ja ajo eivät voi olla eri mieltä siitä, mitkä issuet epiciin kuuluvat. Käytännön
seuraus toteutukselle: lapsijoukon resolvointi (`sub_issues` → fallback) kannattaa toteuttaa
**yhtenä jaettuna funktiona** (`lib/issue.sh`, §6), jota molemmat kutsuvat.

### 1.4 Kaksi eri graafia — älä sekoita

Epicissä on kaksi toisistaan riippumatonta GitHub-relaatiota, ja niiden erottaminen on
arkkitehtuurin ydin:

| Graafi | Relaatio | Kuka lukee | Merkitys |
|---|---|---|---|
| **Kokoava** | parent → sub-issue | epic-tason automaatio (uusi) | *Mitkä* issuet kuuluvat epiciin |
| **Järjestävä** | `blocked_by` | S2b-portti (#28, olemassa) | *Missä järjestyksessä* alaissueet ajetaan |

Epic **ei** ole automaattisesti `blocked_by`-estetty lastensa toimesta — sub-issue-relaatio ei
luo estoa. Tämä on olennaista §2:n löydökselle: mikään olemassa oleva portti ei pidättele
epiciä, koska S2b lukee vain järjestävää graafia.

---

## 2. Tunnistus ja poiminta — nykytila koodia vasten

**Hyväksyntäkriteeri 2 vaatii, että tämä analyysi on tehty koodia vasten, ei arvailtu.** Alla
lainatut kohdat on luettu suoraan repon `main`-tilasta (commit `4ad8d5b`).

### 2.1 Poimintahaku tänään

Poiminta tapahtuu **kahdessa paikassa samalla hakukyselyllä** (tämä duplikaatio on olemassa,
ks. §6):

- `lib/issue.sh` → `pick_oldest_unassigned()`, rivi 108:

  ```
  is:open no:assignee -is:blocked -label:waiting -label:wip -label:${clean_label} sort:created-asc
  ```

  johon lisätään AND-ehtoina konfiguroidut positiiviset labelit (`label:"auto-run"` jne.).

- `poller.sh` inline-poiminta, rivi 775: **sama** merkkijono
  (`is:open no:assignee -is:blocked -label:waiting -label:wip -label:$RUN_ISSUES_CLEAN_LABEL …`).

Suodattimet siis ovat: avoin, ei assigneeta, ei `blocked_by`-estetty, ei `waiting`/`wip`/
`auto-clean`-labelia, ja kaikki konfiguroidut labelit (tyypillisesti `auto-run`) läsnä.

### 2.2 Löydös: epic poimitaan tänään tavallisena issuena

> **`epic`-labelia ei suodateta kummassakaan poimintakyselyssä.** Jos epic-issuelle lisätään
> `auto-run` tänään, ja se on avoin, assignoimaton eikä `blocked_by`-estetty, se **täyttää
> poimintaehdon täsmälleen kuten lehti-issue** ja tulee poimituksi.

Seuraukset, kun näin käy:

1. Orkestraattori etenee normaalisti: lukko (S2), S2b-esto-portti, claim (S3), worktree (S4).
   **S2b ei pidättele epiciä**, koska `count_open_blockers` (`lib/issue.sh:218`) lukee
   `dependencies/blocked_by` -graafia — eikä epic ole estetty *lastensa* toimesta (§1.4).
   Ainoa tapa, jolla S2b pidättelisi epiciä, on jos joku on käsin merkinnyt epicin itsensä
   `blocked_by`-estetyksi, mikä ei ole kanoninen muoto.
2. Implementer (S8) ajetaan epicin runkoa vasten. Runko on kokoava tavoite, **ei konkreettinen
   toteutustehtävä**. Todennäköinen lopputulos: implementer joko tuottaa merkityksettömän PR:n,
   palauttaa `BLOCKED`in, tai polttaa timeout-budjettinsa jäsentäessään tehtävää, jota ei ole.
3. Epic-issue jää assignatuksi (varaus ei vapaudu epäonnistuneesta ajosta, README 6.4), joten
   se ei toistu — mutta ei myöskään etene ilman siivousta.

**Johtopäätös:** epicin poiminnan esto on **pakollinen ennakkoehto** kaikelle epic-tason
automaatiolle. Ilman sitä `epic`-labelin ja `auto-run`in samanaikaisuus on jo nyt
haitallinen. Tämä on §6:n ensimmäinen ja tärkein muutoskohta.

### 2.3 Kuinka erottaa epic poiminnassa

**Suositus:** lisää molempiin poimintakyselyihin negatiivinen kvalifikaattori **`-label:epic`**.
Se on symmetrinen olemassa olevien `-label:waiting -label:wip` -suodattimien kanssa, halpa (ei
lisä-API-kutsua), ja käyttää GitHubin natiivia hakua.

**Varaus — hakuindeksin viive.** Kuten `-is:blocked`, myös `-label:epic` nojaa GitHubin
*eventually consistent* -hakuindeksiin. Tuntematon negatiivinen label-kvalifikaattori **ei
kaada hakua** vaan täsmää kaikkeen (mitattu #28:n yhteydessä: `-is:totallynotreal` palautti
kaikki avoimet). `-label:epic` on kuitenkin *tunnettu* labelisuodatin heti kun `epic`-label on
luotu repoon, joten indeksin viive koskee vain juuri lisättyä labelia — sama luokka viivettä
kuin `-is:blocked`illa, ja `epic`-labelin lisäys edeltää `auto-run`in lisäystä normaalissa
työjärjestyksessä.

> **Avoin päätös B — tarvitaanko autoritatiivinen toinen luku (S2b-tyyliin)?**
> S2b (#28) syntyi, koska hakuindeksin viive päästi 25 estettyä issueta poimintaan. Sama riski
> koskee teoriassa `-label:epic`iä: jos epic-label lisätään ja `auto-run` heti perään, viipyvä
> indeksi voisi päästää epicin poimintaan yhden tikin ajan.
> Vaihtoehdot: (i) luota `-label:epic`iin, kuten `-label:waiting`/`-label:wip`iin luotetaan
> nyt (ei toista lukua); (ii) lisää claimin ja worktreen väliin **autoritatiivinen epic-portti**
> — luetaan issuen labelit suoraan (`gh issue view --json labels` tai `sub_issues_summary`
> ≠ null) ja perääntytään jos issue on epic, S2b:n mallilla (fail-closed, lukko vapautetaan).
> **Suositus: (ii) kevyessä muodossa.** `epic`-labelilla ajaminen on kalliimpi virhe kuin
> estetyllä issuella ajaminen (implementer polttaa timeout-budjetin epic-runkoon), ja portti
> on halpa: yksi label-luku, joka tehdään vasta lukon voittajalle — täsmälleen S2b:n sijainti
> ja hinta. Toteutuksena `_add_needs_human_label`-tyylinen best-effort ei riitä; portin pitää
> perääntyä ennen claimia. Ks. §6.

---

## 3. Auto-run-semantiikka epicille

### 3.1 Mitä `auto-run` epic-issuella tarkoittaa

**Ehdotus (issuen mukainen):** `auto-run` epic-issuella on **propagointisignaali**, ei
ajosignaali. Se tarkoittaa: "aja tämä epic" = "lisää `auto-run` epicin avoimille alaissueille,
joilla sitä ei vielä ole, ja anna pollerin ajaa ketju normaalisti S2b-portin varassa".

Epic-issue itse ei koskaan aja (§2:n esto huolehtii siitä). Sen `auto-run` propagoituu lapsiin;
lasten `auto-run` + `blocked_by`-järjestys tuottaa ajon täsmälleen kuten käsin rakennetussa
ketjussa tänään.

### 3.2 Propagoinnin ajankohta

Propagointi voi tapahtua kolmessa kohdassa:

| Vaihtoehto | Kuka | Milloin |
|---|---|---|
| **P1** | `/run-epic`-komento | Kertaluontoisesti komennon ajohetkellä |
| **P2** | poller | Joka tikillä, kun se kohtaa `auto-run`+`epic`-issuen |
| **P3** | molemmat | `/run-epic` tekee ensilisäyksen, poller ylläpitää |

> **Avoin päätös C — propagoinnin ajankohta.**
> **Suositus: P3, painottuen P2:een.** Perustelu: propagoinnin on oltava **jatkuvaa**, ei
> kertaluontoista, koska alaissueita voidaan lisätä epiciin myöhemmin (uusi sub-issue keskellä
> ajoa). Kertapropagointi (`/run-epic` yksin) jättäisi myöhemmin lisätyn lapsen ilman
> `auto-run`ia. Siksi poller on luonteva ylläpitäjä: se skannaa epic-issuet joka tikillä (uusi
> `scan_epics`-vaihe, §6) ja varmistaa propagoinnin idempotentisti. `/run-epic` tekee saman
> heti, jotta ajo alkaa odottamatta seuraavaa tikkiä. **Kumpikin kutsuu samaa funktiota.**
> Poller skannaa epicit ennen normaalia poimintaa, jotta juuri propagoitu lapsi on
> poimintakelpoinen samalla tikillä.

**Missä poller skannaa epicit:** epic-issuet löytyvät haulla `is:open label:epic` (ei
`no:assignee` — epic ei koskaan ole assignattu automaation toimesta) niiden labelien kera, jotka
watchlist vaatii repolle. Skannaus on halpa (epicejä on vähän), ja se voi jakaa
`pr-watch-poller.sh`:n rotaatiokursorin (#47) hengen, jos epicejä on paljon — mutta oletuksena
se ajetaan joka tikki, koska joukko on pieni.

### 3.3 Idempotenssi

Propagointi **on idempotentti** ja se on kriittinen ominaisuus (poller toistaa sen joka tikki):

1. **Lisää `auto-run` vain lapsille, joilla sitä ei ole.** Luetaan lapsen labelit ensin; jos
   `auto-run` on jo läsnä, ei tehdä mitään. `labels_add` (`lib/labels.sh:85`) on jo
   best-effort-idempotentti REST-API:n kautta, joten kaksinkertainenkin lisäys on vaaraton,
   mutta labelin esitarkistus välttää turhat kirjoitukset ja lokirivit.
2. **Vain avoimille lapsille.** Suljettua alaissuetta ei labeloida (se on jo tehty). `[x]`
   fallback-listassa ohitetaan samoin.
3. **Ei koskaan poista `auto-run`ia.** Propagointi on monotoninen lisäys; ihmisen manuaalinen
   `auto-run`-poisto lapselta (esim. "en halua tätä lasta ajoon") ei kilpaile propagoinnin
   kanssa toistuvasti — **paitsi** jos poller propagoi joka tikki. Ks. avoin päätös D.
4. **`epic`-labelia ei propagoida.** Vain `auto-run` (ja watchlistin muut ajolabelit tarpeen
   mukaan, ks. avoin päätös E) siirtyy; `epic` jää epicille.

> **Avoin päätös D — voiko ihminen jättää lapsen ajon ulkopuolelle?**
> Jos poller propagoi `auto-run`in joka tikki idempotentisti, ihminen ei voi pysyvästi poistaa
> sitä yksittäiseltä lapselta — se palaa seuraavalla tikillä.
> Vaihtoehdot: (i) hyväksy tämä — epicin lapset ajetaan kaikki, poikkeukset hoidetaan `wip`- tai
> `blocked_by`-merkinnällä (jotka poiminta kunnioittaa, joten labeloitu-mutta-`wip` lapsi ei
> aja); (ii) käytä opt-out-labelia (esim. `epic-skip`), jonka läsnäolo estää propagoinnin
> kyseiselle lapselle.
> **Suositus: (i).** `wip` on jo olemassa ja tekee juuri tämän (README 6.3: "teen tämän itse"),
> joten uusi opt-out-label olisi päällekkäinen mekanismi. Dokumentoidaan: "jätä lapsi ajon
> ulkopuolelle `wip`-labelilla tai `blocked_by`-riippuvuudella".

> **Avoin päätös E — mitkä labelit propagoituvat?**
> Watchlist voi vaatia repolle useampia labeleita (esim. `["auto-run", "backend"]`, AND).
> Silloin lapsi tarvitsee **kaikki** ne poimintaan.
> **Suositus:** propagoi täsmälleen se labelijoukko, jonka watchlist vaatii kyseiselle repolle
> (`labels` / `default_labels`). Näin propagoitu lapsi täyttää poimintaehdon riippumatta siitä,
> montako labelia repo vaatii. Yksittäistapaus `["auto-run"]` on tämän erikoistapaus.

---

## 4. Elinkaari

### 4.1 Milloin epic on valmis

**Ehdotus:** epic on valmis, kun **kaikki sen alaissuet ovat suljettuja**. GitHub laskee tämän
valmiiksi: `sub_issues_summary.completed == sub_issues_summary.total` (ja `total > 0`).

> **Avoin päätös F — kuka sulkee epicin?**
> Vaihtoehdot: (i) **runner sulkee automaattisesti** — kun poller havaitsee epicin, jonka kaikki
> lapset ovat kiinni, se sulkee epic-issuen ja postaa yhteenvetokommentin; (ii) **ihminen
> sulkee** — runner vain postaa "kaikki alaissuet valmiit" -kommentin ja jättää sulkemisen
> ihmiselle; (iii) **GitHub sulkee** — jos repossa on käytössä GitHubin "auto-close parent"
> -asetus (sub-issues-ominaisuuden osa), parent sulkeutuu itsestään.
> **Suositus: (ii) oletuksena, (iii) jos repo on konfiguroitu.** Epicin sulkeminen on
> merkityksellinen tila (se kertoo kokonaisuuden valmiiksi ja voi laukaista jatkotyötä), ja
> epic-runko voi sisältää hyväksyntäkriteereitä, jotka ihmisen on tarkistettava — automaattinen
> sulku ohittaisi tarkistuksen. Runner tekee valmiuden **näkyväksi** (kommentti +
> mahdollinen label, esim. `epic-complete`), ihminen tekee sulkupäätöksen. Jos repo käyttää
> GitHubin natiivia auto-closea, se voittaa ja runner vain kunnioittaa lopputilaa.

### 4.2 Kun alaissue päätyy `blocked`/`needs-human`-tilaan

**Ehdotus (issuen mukainen):** epic saa **näkyvän merkinnän**, ja muut riippumattomat haarat
jatkavat.

Tämä nojaa olemassa olevaan käytökseen (§7.1 hyötykäyttönä):

1. **Riippumaton eteneminen on ilmaista.** S2b-portti ajaa vain ne lapset, joiden estäjät ovat
   kiinni. Jos lapsi B on `blocked`/`needs-human`-tilassa mutta lapsi C ei riipu B:stä, C ajetaan
   normaalisti — poller poimii sen, koska sillä on `auto-run` eikä avointa estäjää. **Mitään
   uutta ei tarvita** haarojen rinnakkaiseen etenemiseen: se on riippuvuusajon suora seuraus.
2. **B:stä riippuvat lapset odottavat itsestään.** Jos D on `blocked_by: B`, D ei aja ennen kuin
   B sulkeutuu. Tämä on jo S2b:n käytös.
3. **Näkyvä merkintä epicille:** kun alaissue saa `needs-human`-labelin (mikä tapahtuu jo
   automaattisesti terminaaliselle estolle, CLAUDE.md §4), epic-tason automaatio postaa
   **epic-issuelle** kommentin, joka nimeää jumittuneen lapsen ja linkittää siihen. Näin epicin
   katselija näkee, että ketju on osin pysähtynyt, avaamatta jokaista lasta. Merkintä on
   idempotentti: sama lapsi ei tuota toistuvaa kommenttia (vrt. #65:n `SKIP_CLOSED`-vaimennus —
   luetaan viimeisin kirjattu tila, ei kommentoida uudelleen samasta lapsesta).

> **Avoin päätös G — epic-merkinnän muoto.**
> Kommentti vai label vai molemmat? **Suositus:** kommentti (linkittää lapsen ja syyn) + kevyt
> label epicille (esim. `epic-attention`), jotta jumittunut epic on **suodatettavissa** —
> sama oppi kuin #43:n `needs-human`-label alaissuetasolla: pelkkä kommentti ei ole
> suodatettava, joten pysähtynyt epic näyttäisi terveeltä. Label mahdollistaa "näytä
> huomiota vaativat epicit" -haun.

### 4.3 Keskeytyksen semantiikka

**Ehdotus (issuen mukainen):** epicin keskeytys = **elävän ajon pysäytys + jonossa olevien
vapautus poiminnasta**.

Kaksi osaa, molemmat olemassa olevalla koneistolla:

1. **Elävät ajot:** epicin ne alaissuet, joilla on elävä ajo, pysäytetään `stop-run.sh`:llä
   (#64) — se finalisoi ajon `blocked/stopped_by_operator` ja purkaa lukon
   ei-destruktiivisesti. Epicin keskeytys iteroi elävät lapsiajot ja kutsuu `stop-run.sh`:n
   (tai suoraan `lib/run-terminate.sh`:n `run_terminate`in) kullekin.
2. **Jonossa olevat:** alaissuet, jotka eivät vielä aja, vapautetaan poiminnasta **poistamalla
   `auto-run`** niiltä (propagoinnin käänteisoperaatio). Ilman `auto-run`ia poller ei poimi
   niitä. Vaihtoehtoisesti epiciltä poistetaan `auto-run`, jolloin propagointi lakkaa, mutta jo
   lisätyt lapsilabelit pitää poistaa erikseen — siksi keskeytys poistaa labelit lapsilta
   suoraan.

> **Avoin päätös H — keskeytyskomennon muoto.**
> Onko keskeytys osa `/run-epic`-komentoa (`/run-epic <N> --stop`) vai erillinen
> `/stop-epic <N>`? **Suositus:** `/run-epic <N> --stop` (tai `--cancel`), symmetrinen ajon
> käynnistyksen kanssa, koska molemmat operoivat samaa lapsijoukkoa samalla resolvointilogiikalla.
> Se delegoi elävien ajojen pysäytyksen `stop-run.sh`:lle monistamatta turvakriittistä
> lopetuslogiikkaa (sama periaate kuin #64 ↔ #63).

---

## 5. `/run-epic`-komennon UX

### 5.1 Syöte

`/run-epic <epic-issue-numero> [--stop] [--dry-run] [--repo <path>] [--remote <name>]`

- **`<epic-issue-numero>`** (pakollinen): epic-issuen numero. Komento resolvoi repon
  nykyhakemistosta tai `--repo`:sta, kuten `/run-issues`.
- **`--dry-run`**: tulostaa suunnitelman (mitkä lapset, mikä ajojärjestys, mitä labeleita
  lisättäisiin) kirjoittamatta mitään.
- **`--stop`**: keskeytys (§4.3).

### 5.2 Validointi

Komento validoi **ennen** kuin se koskee mihinkään:

1. **Onko issue epic?** `epic`-label läsnä. Jos ei, komento voi (avoin päätös I) joko
   kieltäytyä tai lisätä `epic`-labelin.
2. **Onko rakenne kanoninen?** ≥1 natiivi sub-issue **tai** (fallback) task-lista, jossa ≥1
   avoin `- [ ] … #N` -rivi. Jos molemmat tyhjiä → virhe (§7: epic ilman alaissueita).
3. **Ovatko riippuvuudet asyklisiä?** Alaissueiden `blocked_by`-graafi ei saa sisältää sykliä
   (§7: syklinen graafi). Validointi rakentaa graafin (`count_open_blockers` / suora
   `blocked_by`-luku per lapsi) ja tarkistaa syklittömyyden ennen ajoa.
4. **Ovatko alaissuet ajokelpoisia?** Jokainen avoin lapsi on samassa repossa (§7: cross-repo).
   Cross-repo-lapsi tuottaa varoituksen ja jää ajon ulkopuolelle, ei kaada koko epiciä.
5. **Onko jollain lapsella jo elävä ajo?** Ei virhe — propagointi on idempotentti ja poller
   hoitaa (§7).

> **Avoin päätös I — lisääkö `/run-epic` puuttuvan `epic`-labelin?**
> **Suositus: lisää se** (idempotentisti), koska komennon nimi ilmaisee jo aikomuksen "aja tämä
> epicinä". Tämä tekee komennosta myös tavan **muuntaa** tavallinen kokoava issue epiciksi
> yhdellä komennolla. `--dry-run` ei lisää.

### 5.3 Mitä komento tekee

> **Avoin päätös J — käynnistääkö komento ajon vai pelkkä labelointi?**
> Vaihtoehdot: (i) **pelkkä labelointi** — komento lisää `epic`-labelin (tarvittaessa) ja
> propagoi `auto-run`in avoimille lapsille, sitten jättää ajon **pollerin varaan**; (ii)
> **labelointi + ensimmäisen ajokelpoisen käynnistys** — komento tekee saman ja lisäksi
> käynnistää heti ensimmäisen estämättömän lapsen (`/run-issues #<lapsi>`), jotta ajo alkaa
> odottamatta seuraavaa pollertikkiä.
> **Suositus: (i) oletuksena, (ii) lipulla `--start-now`.** Perustelu: labelointi + poller on
> **minimimuutos** ja nojaa täysin olemassa olevaan koneistoon — komennon ei tarvitse tietää
> orkestraattorin sisäisistä tiloista. Poller poimii ketjun seuraavalla tikillä. Koneella,
> jolla poller ei ole aktiivinen (esim. kertakäyttö ilman LaunchAgentia), `--start-now` antaa
> synkronisen käynnistyksen. Näin komento on hyödyllinen molemmissa käyttötavoissa ilman että
> oletus monimutkaistuu.

**Oletuspolku (i):**
1. Validoi (§5.2).
2. Lisää `epic`-label epicille jos puuttuu (avoin päätös I).
3. Propagoi ajolabelit (`auto-run` + watchlistin vaatimat, §3.3) epicin avoimille lapsille
   idempotentisti.
4. Raportoi (§5.4).

### 5.4 Raportointi

Komento tulostaa (ja `--dry-run` vain tulostaa, ei kirjoita):

- Epicin numero ja otsikko.
- Lapsijoukko: montako natiivia sub-issuea vs. task-lista-fallback, montako avointa/suljettua.
- Ajojärjestys: `blocked_by`-graafista johdettu topologinen järjestys (mikä ajaa heti, mikä
  odottaa mitä).
- Propagointi: mille lapsille `auto-run` lisättiin (ja mille se oli jo), mitkä ohitettiin
  (`wip`, suljettu, cross-repo).
- Varoitukset: cross-repo-lapset, mahdollinen syklihavainto (joka estää ajon, §7).

---

## 6. Suhde olemassa olevaan — muutoskohdat tiedosto/funktio-tasolla

**Johtoajatus toistettuna:** orkestrointi nojaa jo olemassa olevaan riippuvuusajoon.
Alla erottelu: mikä **riittää sellaisenaan** ja mihin tarvitaan **muutos**.

### 6.1 Riittää sellaisenaan (ei muutosta)

| Koneisto | Miksi riittää |
|---|---|
| **S2b-esto-portti** (`lib/issue.sh:count_open_blockers`, `orchestrate.sh:718`) | Ajaa alaissuet oikeassa järjestyksessä `blocked_by`-graafin varassa. Epic-ketju on täsmälleen se, mille S2b on rakennettu. |
| **Poiminta-ajo** (`pick_oldest_unassigned` + poller inline) | Poimii propagoidut lapset normaalisti. Ainoa muutos on epicin **poissulku** (6.2), ei uusi poimintapolku lapsille. |
| **Lukot** (`lib/locking.sh`) | Issue-kohtaisia; lapsiajot lukkiutuvat itsenäisesti. Epic ei tarvitse omaa lukkoa (se ei aja). |
| **PR-vahti** (`pr-watch.sh`, `pr-watch-poller.sh`) | Kunkin lapsen PR mergetään itsenäisesti. Epic-ketjun merge-järjestys seuraa `blocked_by`sta: estävän lapsen PR mergetään ennen kuin estetty lapsi vapautuu poimintaan. |
| **Terminaalisen eston merkintä** (`_add_needs_human_label`, CLAUDE.md §4) | Antaa jumittuneelle lapselle jo `needs-human`-labelin; epic-merkintä (4.2) *lukee* tämän, ei korvaa. |
| **`stop-run.sh` / `lib/run-terminate.sh`** | Keskeytyksen (4.3) elävien ajojen pysäytys delegoidaan tänne monistamatta. |

### 6.2 Tarvitsee muutoksen

**M1 — Epicin poissulku poiminnasta (pakollinen, §2:n löydös).**
- `lib/issue.sh:pick_oldest_unassigned` (rivi 108): lisää `-label:epic` hakumerkkijonoon.
- `poller.sh` inline-poiminta (rivi 775): **sama lisäys** — nämä kaksi hakua on pidettävä
  synkassa (olemassa oleva duplikaatio; harkitse merkkijonon nostamista jaetuksi vakioksi
  `lib/issue.sh`:ään samalla). Vartija: `tests/test-issue-pick.sh` pinnaa hakumerkkijonon;
  lisää `-label:epic` sen assertioon.

**M2 — (Avoin päätös B) Autoritatiivinen epic-portti claimia ennen.**
- `orchestrate.sh`: uusi portti S2b:n viereen (lukon jälkeen, claimia ennen), joka lukee issuen
  labelit / `sub_issues_summary`n ja perääntyy jos issue on epic. Uusi finalisointisyy esim.
  `blocked/is_epic_not_runnable`, uusi exit-koodi (jatkaa orkestraattorin koodiavaruutta, §5
  CLAUDE.md). Ei `needs-human`-labelia (kuten S2b:n claimia edeltävät portit, CLAUDE.md §4).
- `lib/issue.sh`: uusi `is_epic <repo> <N> [<owner/repo>]` (label-luku, fail-closed samaan
  tapaan kuin `count_open_blockers`).

**M3 — Lapsijoukon resolvointi (jaettu, §1.3).**
- `lib/issue.sh`: uusi `list_epic_children <repo> <N> [<owner/repo>]` — lukee natiivit
  `GET …/issues/{N}/sub_issues`; jos tyhjä, jäsentää rungon task-listan (`- [ ] … #N`).
  Palauttaa lapsi-issuenumerot + tilan. Sama funktio palvelee ajoa **ja** Ohjaamon näkymää
  (hyväksyntäkriteeri 4).

**M4 — Ajolabelien propagointi (§3).**
- Uusi funktio (sijainti: `lib/issue.sh` tai uusi `lib/epic.sh`)
  `propagate_run_labels <repo> <epic-N> <labels-csv> [<owner/repo>]` — iteroi avoimet lapset,
  lisää puuttuvat ajolabelit idempotentisti `labels_add`illa (`lib/labels.sh:85`) /
  `labels_ensure`illa (`lib/labels.sh:153`). Ohittaa `wip`- ja suljetut lapset.

**M5 — Pollerin epic-skannaus (§3.2, avoin päätös C).**
- `poller.sh`: uusi `scan_epics`-vaihe ennen normaalia poimintaa — hakee `is:open label:epic`
  (+ watchlistin labelit), kutsuu `propagate_run_labels`in kullekin, ja emittoi epic-merkinnän
  (4.2) jumittuneista lapsista. Sijoitus poiminnan eteen, jotta juuri propagoitu lapsi on
  poimittavissa samalla tikillä. Host-portti ja watchlist-resolvointi kuten muillakin
  poller-vaiheilla (`lib/poller-config.sh`).

**M6 — `/run-epic`-komento (§5).**
- Uusi `commands/run-epic.md` (slash-komento, Claude Code lukee sen suoraan; ei
  `render_prompt`-käsittelyä). Delegoi validoinnin ja propagoinnin M3/M4-funktioihin.
  Mahdollinen ohut `run-epic.sh` repo-juureen, jos komento tarvitsee ei-triviaalia
  bash-logiikkaa (syklintarkistus, topologinen järjestys) — symmetrinen `stop-run.sh`:n kanssa.
- Asennus: `install.sh` linkittää `commands/*.md` jo globilla, joten uusi komento tulee
  asennukseen pelkällä nimeämisellä (CLAUDE.md §3). Uusi juuren skripti näkyisi automaattisesti
  litteässä juuressa (CLAUDE.md §2).

**M7 — Epicin näkyvä merkintä (§4.2, avoin päätös G).**
- Osa M5:tä: kommentti epic-issuelle jumittuneesta lapsesta + kevyt `epic-attention`-label.
  Idempotenssi #65:n `pr_last_decision`-hengessä (lue viimeisin kirjattu tila, älä toista).

**M8 — Dokumentaatio.**
- `README.md`: uusi alaluku (esim. 6.11 "Epicin ajaminen") ihmiselle.
- `CLAUDE.md`: viittaus tähän dokumenttiin (hyväksyntäkriteeri 6, tehty tässä PR:ssä).
- Uudet exit-koodit ja env-muuttujat CLAUDE.md §5/§7:ään toteutuksen yhteydessä.

### 6.3 Muutosten kokoluokka

M1 ja M2 ovat **pakollisia ennakkoehtoja** (ilman niitä epic+auto-run on jo haitallinen, §2).
M3–M7 ovat varsinainen epic-automaatio. Kaikki nojaavat olemassa oleviin abstraktioihin;
mitään ydinkoneistoa (S2b, lukot, PR-vahti) ei kirjoiteta uusiksi. Tämä on issuen tavoittelema
minimimuutos.

---

## 7. Virhetilanteet

| Tilanne | Käytös |
|---|---|
| **Syklinen riippuvuusgraafi** (A `blocked_by` B, B `blocked_by` A) | `/run-epic`-validointi (§5.2) havaitsee syklin topologisessa järjestyksessä ja **kieltäytyy ajamasta**, nimeten sykliin osallistuvat issuet. Ilman `/run-epic`iä (pelkkä poller) sykli ei kaada mitään, mutta jokainen sykliin kuuluva lapsi on ikuisesti `blocked_by`-estetty (S2b pitää ne poiminnan ulkopuolella), joten ketju vain pysähtyy hiljaa — siksi `/run-epic`-validointi on ainoa paikka, joka **havaitsee** syklin aktiivisesti. Suositus: epic-merkintä (4.2) nostaa myös "N lasta ikuisesti estettynä" -tilan näkyviin. |
| **Alaissue toisessa repossa** | Rajausten (ks. Rajaukset) ulkopuolella. `list_epic_children` (M3) ohittaa cross-repo-lapsen ja kirjaa varoituksen; `/run-epic`-raportti (§5.4) listaa sen. Epic voi silti valmistua saman repon lasten osalta, mutta ei sulkeudu automaattisesti, koska cross-repo-lapsi jää avoimeksi (ihminen hoitaa). |
| **Epic ilman alaissueita** | `list_epic_children` palauttaa tyhjän (ei natiiveja, ei fallback-rivejä). `/run-epic`-validointi (§5.2.2) **kieltäytyy** — ei propagoitavaa. Poller-skannaus (M5) ohittaa hiljaa (ei lapsia = ei työtä), ei kaada tikkiä. Epicin poissulku poiminnasta (M1) on silti voimassa, joten tyhjä epic ei koskaan aja vahingossa. |
| **Alaissue jolla on jo elävä ajo** | Ei virhe. Propagointi (M4) on idempotentti: jos lapsella on jo `auto-run` ja elävä ajo, mitään ei tehdä (label on jo, poller ei poimi assignattuja, README 6.4). `/run-epic`-raportti mainitsee "N lasta jo ajossa". |
| **Epicin alaissueen manuaalinen sulkeminen kesken ajon** | Suljettu lapsi tippuu poiminnasta (`is:open`), ja sen mahdollinen elävä ajo jää orvoksi — poller havaitsee sen liveness-rajalla (`RUN_ISSUES_STALE_AFTER`) ja finalisoi `stalled_in_*` normaalisti. `blocked_by`-riippuvuudet: suljettu lapsi lakkaa estämästä siitä riippuvia (sulku = ei enää avoin estäjä), joten seuraavat lapset vapautuvat — mikä on oikea käytös, jos ihminen sulki lapsen "valmiina". Jos lapsi suljettiin **keskeneräisenä**, epic-merkintä (4.2) ei sitä huomaa; se on ihmisen tietoinen toimenpide, jonka semantiikka on "tämä on hoidettu". |
| **Epic-runko + task-lista + natiivit ristiriidassa** | Natiivi voittaa aina (§1.2 sääntö 1): jos natiiveja lapsia on, task-listaa ei lueta lainkaan, joten ristiriita on rakenteellisesti mahdoton. |
| **`epic`-label lisätty mutta hakuindeksi laahaa** | M1:n `-label:epic` nojaa hakuindeksiin; M2:n autoritatiivinen portti (jos toteutetaan, avoin päätös B) pyydystää epicin claimia ennen, vaikka indeksi laahaisi — sama fail-closed-suoja kuin S2b:llä. |

---

## Avoimet päätökset — yhteenveto

Nämä ratkaistaan PR-katselmoinnissa; kullekin on suositus perusteluineen yllä.

| # | Kysymys | Suositus |
|---|---|---|
| A | Kirjoittaako task-lista-fallback natiivit lapset? | Ei — fallback on vain lukusääntö |
| B | Autoritatiivinen epic-portti claimia ennen? | Kyllä, kevyt label-luku S2b:n mallilla |
| C | Propagoinnin ajankohta? | Poller ylläpitää joka tikki, `/run-epic` tekee ensilisäyksen |
| D | Voiko lapsen jättää ajon ulkopuolelle? | Kyllä, olemassa olevalla `wip`illä (ei uutta labelia) |
| E | Mitkä labelit propagoituvat? | Watchlistin repolle vaatima joukko |
| F | Kuka sulkee valmiin epicin? | Ihminen oletuksena; GitHubin auto-close jos konfiguroitu |
| G | Epic-merkinnän muoto jumittuneesta lapsesta? | Kommentti + suodatettava `epic-attention`-label |
| H | Keskeytyskomennon muoto? | `/run-epic <N> --stop`, delegoi `stop-run.sh`:lle |
| I | Lisääkö `/run-epic` puuttuvan `epic`-labelin? | Kyllä, idempotentisti |
| J | Käynnistääkö komento ajon vai pelkkä labelointi? | Labelointi + poller oletuksena, `--start-now` synkroniseen |
