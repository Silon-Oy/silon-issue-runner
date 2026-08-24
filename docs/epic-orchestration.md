# Epic-ajon arkkitehtuuri

> **Toteutustila (päivitetty #93).** Tämä oli alun perin **suunnitteludokumentti** (#80),
> kirjoitettu *ennen* toteutusta. Sittemmin epic-koneisto on rakennettu:
>
> - **#81 toteutti auto-run-tason semantiikan** — muutoskohdat M1–M5 ja M7 (§6): epicin
>   poissulku poiminnasta (`-label:epic` molemmissa hauissa), autoritatiivinen **S2c
>   EpicCheck** -portti (`orchestrate.sh` + `lib/issue.sh:is_epic`, exit 12), lapsijoukon
>   resolvointi (`lib/issue.sh:list_epic_children`), ajolabelien idempotentti propagointi +
>   `needs-human`-lapsen eskalaatio + valmiuskommentti/-label (`lib/epic.sh`, pollerin
>   `scan_epics`-vaihe).
> - **#82 toteutti `/run-epic`-komennon** — M6 (§6): `run-epic.sh` + `commands/run-epic.md`,
>   validointi suunnittele–sovella-jaolla, `epic`-labelin idempotentti lisäys, ajolabelien
>   propagointi jaetulla `propagate_run_labels`illa, `--dry-run` ja `--start-now`.
> - **#90 toteutti epicin keskeytyksen** — M6:n täydennys (§6) ja päätös H: `run-epic.sh --stop`
>   pysäyttää elävät lapsiajot delegoimalla `stop-run.sh`:lle ja poistaa ajolabelit (epiciltä
>   ensin, sitten avoimilta lapsilta), plan-then-apply-jaolla kuten käynnistyspolku.
>
> Kymmenestä alla luetellusta avoimesta päätöksestä (§"Avoimet päätökset") **kaikki on
> ratkaistu koodissa**; kunkin ratkaisukohta on nimetty päätöstaulukon ratkaisusarakkeessa.
> Viimeisenä ratkesi **H (epicin keskeytys)** → #90. Osin avoinna ovat vielä lapsijoukon
> jaettu resolvointi (§1.3, → **#91**) ja cross-repo-rajaus (§Rajaukset, → **#92**).
>
> Dokumentin arvo ei ole enää suunnitelmana vaan **perusteluna**: se kertoo *miksi* koneisto on
> tällainen. Alkuperäiset ehdotukset ja "avoin päätös" -laatikot on säilytetty, mutta kukin on
> merkitty ratkaistuksi tai avoimeksi, jottei niitä lueta nykytilan kuvauksena.

Alla oleva dokumentti määrittelee, miten `/run-issues`-runner ajaa kokonaisen *epicin* — usean
toisiinsa liittyvän issuen ketjun — ilman ihmistä silmukassa. Kohdeyleisö oli alun perin ne
toteutusissueet (auto-run epic-tasolla; `/run-epic`-komento), jotka kirjoitettiin suoraan tämän
dokumentin pohjalta; nyt se palvelee epic-koneiston kokonaisesityksenä. Alkuperäiset
*ehdotukset* ja *avoimet päätökset* on merkitty näkyvästi; niiden toteutumistila kerrotaan yllä
ja päätöskohtaisesti.

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

- **Ei cross-repo-epicejä (toistaiseksi, → #92).** Epicin kaikki alaissueet ovat samassa
  repossa kuin epic-issue itse. Toisessa repossa oleva alaissue on **nykytoteutuksessa**
  virhetilanne (§7), ei tuettu muoto: `list_epic_children` ohittaa cross-repo-lapsen
  varoituksella. GitHubin sub-issue-relaatio *sallii* cross-repo-lapset, mutta runnerin
  poiminta, lukot ja worktree ovat kaikki repo-kohtaisia, joten cross-repo-ajo vaatisi oman
  suunnittelunsa. Tämä rajaus **ei ole periaatteellinen vaan toteutuksellinen** ja on **työn
  alla (#92)**; sitä ei pidä esittää ikuisena.
- **Ei näkyvyysmuutoksia Ohjaamo-näkymään.** Epicin tila esitetään erikseen Ohjaamon
  V4-näkymäissuessa; tämä dokumentti määrittelee vain *ajon* arkkitehtuurin. Jaettu vaatimus
  molemmille on sama kanoninen muoto ja sama fallback (§1) — tämä dokumentti on siitä
  yksi totuudenlähde.
- **Tämä dokumentti ei sisällä koodia.** Kohdan §6 muutoskohdat on nimetty tiedosto- ja
  funktiotasolla, mutta ne toteutetaan erillisissä issueissa.

## Nykytila-analyysi lyhyesti (§2:n löydös etukäteen)

> **Historiallinen (kirjoitushetki #80).** Löydös oli tosi kun tämä kirjoitettiin, ja se on
> sittemmin **korjattu #81:ssä** (`-label:epic` poiminnassa + S2c EpicCheck -portti). Säilytetty
> tähän, koska §2 perustelee siihen koko epic-poissulun tarpeen — mutta sitä ei saa lukea
> nykytilana. Nykytila: epic **ei** enää poimiudu.
>
> **Löydös (kirjoitushetkellä):** epic-labelillinen issue, jolla on `auto-run` eikä estäjää,
> poimittiin *tuolloin* tavallisena työissuena. Koodissa ei ollut mitään, joka erottaisi epicin
> lehti-issuesta. Tarkka koodianalyysi ja seuraukset §2:ssa.

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

> **Päätös A — kirjoittaako fallback natiivit lapset?** — **Ratkaistu (#81):** vaihtoehto (i),
> fallback on vain lukusääntö (`lib/issue.sh:list_epic_children`). Alkuperäinen harkinta:
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

> **Toteutustila (TOTEUTETTU, #91).** Invariantti on voimassa: epicin lapsijoukolle on
> **yksi** resolvointitoteutus, `lib/issue.sh:list_epic_children`, ja sitä kutsuvat **kaikki**
> kuluttajat — ajopuoli (`run-epic.sh`, `lib/epic.sh`: `propagate_run_labels`,
> `epic_process_one`) **ja** näkymäpuoli (`lib/status-github.sh:status_github_build_epics`,
> Ohjaamon epic-rollup #79). Näkymän aiemmat omat funktiot (`status_github_fetch_sub_issues`,
> `status_github_parse_task_list`) on **poistettu** — `grep -rn "sub_issues" lib/ --include="*.sh"`
> ei enää löydä kahta resolvointia. #91 laajensi jaetun funktion kattamaan näkymän tarpeet ilman
> että ajopuolen semantiikka muuttui:
>
> - **Fallback-lapsen tila on autoritatiivinen molemmilla puolilla** (ei enää checkbox-arvaus):
>   avoimien issueiden joukko ratkaisee — numero joukossa ⇒ `open`; puuttuu + `[x]` ⇒ `closed`;
>   puuttuu + `[ ]` ⇒ ohitetaan. Näkymä injektoi joukon (`--open-map`, sillä se on jo haettu ⇒
>   ei lisäkutsua per epic); ajopuoli hakee sen kerran laiskasti ensimmäiselle task-lista-lapselle.
> - **Fail-closed molemmilla:** lukukelvoton natiivigraafi tuottaa rc 2. Ajo kieltäytyy; näkymä
>   merkitsee epicin `source: "unreadable"` (tyhjä `sub_issues`) eikä pudota task-lista-fallbackiin.
> - **Cross-repo-lapsi suodatetaan identtisesti** — sama funktio, joten näkymä ja ajo eivät voi
>   olla eri mieltä (§Rajaukset; cross-repo-**tuki** on yhä eri issue #92).
> - **Identiteettiä ei sidota funktioon:** kutsuja valitsee (`--gh-runner`) — näkymä ajaa
>   `gha_with_token`-kääreen läpi (GitHub App), ajo käyttää paljasta `gh`-CLI:tä.
>
> Lähde on nyt tämä yksi funktio: jos näkymä ja ajo näyttäisivät eri lapsijoukon, se olisi bugi
> `list_epic_children`issä, ei kahden toteutuksen ajautuma.

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

## 2. Tunnistus ja poiminta — koodianalyysi kirjoitushetkeltä (historiallinen)

> **Historiallinen.** Tämän luvun kaikki lainaukset on luettu repon `main`-tilasta commitissa
> `4ad8d5b`, joka on **#81:tä edeltävä** tila. Poimintahaut **eivät** silloin vielä sisältäneet
> `-label:epic`iä eikä S2c-porttia ollut. Luku kuvaa siis lähtötilan, jota vasten M1/M2
> perusteltiin — **ei nykytilaa**. Nykyinen poimintahaku sisältää `-label:epic`in ja S2c
> pyydystää epicin autoritatiivisesti (§2.2:n merkintä).

**Hyväksyntäkriteeri 2 vaati, että tämä analyysi tehdään koodia vasten, ei arvailtu.** Alla
lainatut kohdat on luettu suoraan repon `main`-tilasta (commit `4ad8d5b`, ennen #81:tä).

### 2.1 Poimintahaku kirjoitushetkellä (ennen #81:tä)

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

### 2.2 Löydös (historiallinen): epic poimittiin tavallisena issuena — korjattu #81:ssä

> **Historiallinen.** Tämä koko alaluku on **nykytila-analyysi kirjoitushetkeltä (#80)** ja
> kuvaa vian, jonka #81 nimenomaan korjasi. Nykyään `epic`-labelia **suodatetaan** molemmissa
> poimintakyselyissä (`-label:epic`, M1) ja **S2c EpicCheck** -portti (M2) pyydystää epicin
> autoritatiivisesti lukon jälkeen ja claimia ennen (fail-closed, exit 12). Epic ei siis enää
> poimiudu eikä aja. Alaluku on säilytetty, koska se perustelee, *miksi* poissulku on
> pakollinen — mutta se ei kuvaa nykytilaa. **Älä "korjaa" tästä mitään: asia on jo korjattu.**

Löydös kirjoitushetkellä:

> **`epic`-labelia ei suodatettu kummassakaan poimintakyselyssä.** Jos epic-issuelle lisättiin
> `auto-run` *tuolloin*, ja se oli avoin, assignoimaton eikä `blocked_by`-estetty, se täytti
> poimintaehdon täsmälleen kuten lehti-issue ja tuli poimituksi.

Seuraukset, kun näin *tuolloin* kävi (nyt M1+M2 estävät tämän):

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

**Johtopäätös (toteutui näin):** epicin poiminnan esto oli **pakollinen ennakkoehto** kaikelle
epic-tason automaatiolle — ilman sitä `epic`-labelin ja `auto-run`in samanaikaisuus olisi ollut
haitallinen. Tämä oli §6:n ensimmäinen ja tärkein muutoskohta, ja **#81 toteutti sen** (M1
`-label:epic` + M2 S2c-portti).

### 2.3 Kuinka erottaa epic poiminnassa

> **Toteutettu (#81):** molempiin poimintakyselyihin lisättiin `-label:epic` (M1), ja
> autoritatiivinen S2c-portti täydentää sen (M2, päätös B). Alla alkuperäinen perustelu.

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

> **Päätös B — tarvitaanko autoritatiivinen toinen luku (S2b-tyyliin)?** — **Ratkaistu (#81):**
> vaihtoehto (ii), autoritatiivinen **S2c EpicCheck** -portti lukon jälkeen ja claimia ennen
> (`orchestrate.sh` + `lib/issue.sh:is_epic`, fail-closed, exit 12). Alkuperäinen harkinta:
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

> **Päätös C — propagoinnin ajankohta.** — **Ratkaistu (#81/#82):** P3, painottuen P2:een.
> Pollerin `scan_epics` propagoi joka tikki ennen poimintaa (`lib/epic.sh:epic_process_one`);
> `/run-epic` tekee ensilisäyksen (`run-epic.sh`). Molemmat kutsuvat samaa
> `propagate_run_labels`ia. Alkuperäinen harkinta:
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

> **Päätös D — voiko ihminen jättää lapsen ajon ulkopuolelle?** — **Ratkaistu (#81):** vaihtoehto
> (i), olemassa oleva `wip` (ja `blocked_by`); `scan_epics` ohittaa `wip`-lapset propagoinnissa,
> ei uutta opt-out-labelia. Alkuperäinen harkinta:
> Jos poller propagoi `auto-run`in joka tikki idempotentisti, ihminen ei voi pysyvästi poistaa
> sitä yksittäiseltä lapselta — se palaa seuraavalla tikillä.
> Vaihtoehdot: (i) hyväksy tämä — epicin lapset ajetaan kaikki, poikkeukset hoidetaan `wip`- tai
> `blocked_by`-merkinnällä (jotka poiminta kunnioittaa, joten labeloitu-mutta-`wip` lapsi ei
> aja); (ii) käytä opt-out-labelia (esim. `epic-skip`), jonka läsnäolo estää propagoinnin
> kyseiselle lapselle.
> **Suositus: (i).** `wip` on jo olemassa ja tekee juuri tämän (README 6.3: "teen tämän itse"),
> joten uusi opt-out-label olisi päällekkäinen mekanismi. Dokumentoidaan: "jätä lapsi ajon
> ulkopuolelle `wip`-labelilla tai `blocked_by`-riippuvuudella".

> **Päätös E — mitkä labelit propagoituvat?** — **Ratkaistu (#81):** watchlistin repolle vaatima
> ajolabelijoukko (`auto-run` + repon vaatimat) → `lib/epic.sh:propagate_run_labels`. Alkuperäinen
> harkinta:
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

> **Päätös F — kuka sulkee epicin?** — **Ratkaistu (#81):** vaihtoehto (ii) oletuksena, (iii)
> jos repo konfiguroitu. Runner ei sulje — merkitsee valmiuden (yhteenvetokommentti +
> `epic-complete`-label, `lib/epic.sh:_epic_announce_complete`); ihminen sulkee, GitHubin natiivi
> auto-close voittaa jos konfiguroitu. Alkuperäinen harkinta:
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

> **Päätös G — epic-merkinnän muoto.** — **Ratkaistu (#81):** kommentti + label. Per-child
> piilomarker vartioi kertaluonteisuuden ja `epic-attention`-label tekee jumittuneen epicin
> suodatettavaksi (`lib/epic.sh:_epic_escalate_child`). Alkuperäinen harkinta:
> Kommentti vai label vai molemmat? **Suositus:** kommentti (linkittää lapsen ja syyn) + kevyt
> label epicille (esim. `epic-attention`), jotta jumittunut epic on **suodatettavissa** —
> sama oppi kuin #43:n `needs-human`-label alaissuetasolla: pelkkä kommentti ei ole
> suodatettava, joten pysähtynyt epic näyttäisi terveeltä. Label mahdollistaa "näytä
> huomiota vaativat epicit" -haun.

### 4.3 Keskeytyksen semantiikka

> **Toteutettu #90:ssä** — `run-epic.sh <N> --stop` (ks. §5). Tämä osio kuvaa semantiikan; alla
> oleva vastaa toteutusta.

**Ehdotus (issuen mukainen):** epicin keskeytys = **elävän ajon pysäytys + jonossa olevien
vapautus poiminnasta**.

Kaksi osaa, molemmat olemassa olevalla koneistolla:

1. **Elävät ajot:** epicin ne alaissuet, joilla on elävä ajo, pysäytetään `stop-run.sh`:llä
   (#64) — se finalisoi ajon `blocked/stopped_by_operator` ja purkaa lukon
   ei-destruktiivisesti. Epicin keskeytys iteroi elävät lapsiajot ja kutsuu `stop-run.sh`:n
   (tai suoraan `lib/run-terminate.sh`:n `run_terminate`in) kullekin.
2. **Jonossa olevat:** alaissuet, jotka eivät vielä aja, vapautetaan poiminnasta **poistamalla
   ajolabelit** (propagoinnin käänteisoperaatio, `labels_remove` = `labels_add`in sisar). Ilman
   `auto-run`ia poller ei poimi niitä. **Järjestys on olennainen:** labelit poistetaan **ensin
   epiciltä, sitten avoimilta lapsilta** — toisin päin `scan_epics` ehtisi propagoida labelit
   takaisin kesken operaation. Epiciltä poisto lakkauttaa propagoinnin; lapsilta poisto siivoaa
   jo lisätyt labelit. Toteutus tekee molemmat tässä järjestyksessä.

> **Päätös H — keskeytyskomennon muoto. RATKAISTU #90:ssä → `/run-epic <N> --stop`.**
> Keskeytys on osa `/run-epic`-komentoa (ei erillistä `/stop-epic`iä), symmetrinen ajon
> käynnistyksen kanssa, koska molemmat operoivat samaa lapsijoukkoa samalla resolvointilogiikalla.
> Se delegoi elävien ajojen pysäytyksen `stop-run.sh`:lle monistamatta turvakriittistä
> lopetuslogiikkaa (sama periaate kuin #64 ↔ #63). Toteutettu `run-epic.sh --stop`ina
> plan-then-apply-jaolla; osittainen onnistuminen (vieras kone / terminaalitila) erottuu
> täydestä exit-koodilla 6.

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

> **Päätös I — lisääkö `/run-epic` puuttuvan `epic`-labelin?** — **Ratkaistu (#82):** kyllä,
> `run-epic.sh` lisää `epic`-labelin idempotentisti jos puuttuu (`--dry-run` ei lisää). Näin
> komento myös **muuntaa** kokoavan issuen epiciksi. Alkuperäinen harkinta:
> **Suositus: lisää se** (idempotentisti), koska komennon nimi ilmaisee jo aikomuksen "aja tämä
> epicinä". Tämä tekee komennosta myös tavan **muuntaa** tavallinen kokoava issue epiciksi
> yhdellä komennolla. `--dry-run` ei lisää.

### 5.3 Mitä komento tekee

> **Päätös J — käynnistääkö komento ajon vai pelkkä labelointi?** — **Ratkaistu (#82):** (i)
> oletuksena, (ii) lipulla `--start-now`. `run-epic.sh` propagoi labelit ja jättää ajon
> pollerille; `--start-now` käynnistää ensimmäisen ajokelpoisen lapsen heti. Alkuperäinen
> harkinta:
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

> **Toteutustila.** M1–M5 ja M7 toteutettiin **#81:ssä**, M6 **#82:ssa** (keskeytys `--stop`
> täydennettiin **#90:ssä**), ja M8 on suurelta
> osin tehty (README + CLAUDE.md + tämä statuspäivitys). Kunkin kohdan alla kerrotaan, mihin se
> päätyi. Alkuperäinen "tehdään näin" -kuvaus on säilytetty; toteutus seurasi sitä ellei toisin
> mainita.

**M1 — Epicin poissulku poiminnasta (pakollinen, §2:n löydös).** — **TOTEUTETTU (#81):**
`-label:epic` lisätty molempiin poimintakyselyihin.
- `lib/issue.sh:pick_oldest_unassigned` (rivi 108): lisää `-label:epic` hakumerkkijonoon.
- `poller.sh` inline-poiminta (rivi 775): **sama lisäys** — nämä kaksi hakua on pidettävä
  synkassa (olemassa oleva duplikaatio; harkitse merkkijonon nostamista jaetuksi vakioksi
  `lib/issue.sh`:ään samalla). Vartija: `tests/test-issue-pick.sh` pinnaa hakumerkkijonon;
  lisää `-label:epic` sen assertioon.

**M2 — (Päätös B) Autoritatiivinen epic-portti claimia ennen.** — **TOTEUTETTU (#81):**
S2c EpicCheck -portti, `lib/issue.sh:is_epic`, exit 12, `blocked/is_epic_not_runnable`
(tai `epic_check_failed`), ei `needs-human`-labelia.
- `orchestrate.sh`: uusi portti S2b:n viereen (lukon jälkeen, claimia ennen), joka lukee issuen
  labelit / `sub_issues_summary`n ja perääntyy jos issue on epic. Uusi finalisointisyy esim.
  `blocked/is_epic_not_runnable`, uusi exit-koodi (jatkaa orkestraattorin koodiavaruutta, §5
  CLAUDE.md). Ei `needs-human`-labelia (kuten S2b:n claimia edeltävät portit, CLAUDE.md §4).
- `lib/issue.sh`: uusi `is_epic <repo> <N> [<owner/repo>]` (label-luku, fail-closed samaan
  tapaan kuin `count_open_blockers`).

**M3 — Lapsijoukon resolvointi (jaettu, §1.3).** — **TOTEUTETTU AJOPUOLELLA (#81), NÄKYMÄPUOLI
AVOIN (#91).**
- `lib/issue.sh`: uusi `list_epic_children <repo> <N> [<owner/repo>]` — lukee natiivit
  `GET …/issues/{N}/sub_issues`; jos tyhjä, jäsentää rungon task-listan (`- [ ] … #N`).
  Palauttaa lapsi-issuenumerot + tilan. **Toteutunut poikkeama:** funktion piti palvella ajoa
  **ja** Ohjaamon näkymää (hyväksyntäkriteeri 4), mutta tällä hetkellä sitä käyttää vain
  ajopuoli (`run-epic.sh`, `lib/epic.sh`); Ohjaamon rollup (`lib/status-github.sh`, #79)
  resolvoi lapset omilla funktioillaan. Näkymän kokoaminen samaan funktioon on **#91** (§1.3).

**M4 — Ajolabelien propagointi (§3).** — **TOTEUTETTU (#81):** sijainti `lib/epic.sh`.
- `lib/epic.sh:propagate_run_labels` — iteroi avoimet lapset, lisää puuttuvat ajolabelit
  idempotentisti `labels_add`illa. Ohittaa `wip`- ja suljetut lapset. Propagoinnin yksi jaettu
  primitiivi `_epic_propagate_child` palvelee sekä `epic_process_one`ia (poller) että
  `propagate_run_labels`ia (`/run-epic`) — ei kahta toteutusta (#82 AC4).

**M5 — Pollerin epic-skannaus (§3.2, päätös C).** — **TOTEUTETTU (#81):**
- `poller.sh`: `scan_epics`-vaihe ennen normaalia poimintaa — hakee `is:open label:epic`
  (+ watchlistin labelit, `lib/epic.sh:epic_list_open`), kutsuu `epic_process_one`in kullekin
  (best-effort, aina rc 0), ja emittoi epic-merkinnän (4.2) jumittuneista lapsista. Sijoitus
  poiminnan eteen, jotta juuri propagoitu lapsi on poimittavissa samalla tikillä. Host-portti ja
  watchlist-resolvointi kuten muillakin poller-vaiheilla (`lib/poller-config.sh`).

**M6 — `/run-epic`-komento (§5).** — **TOTEUTETTU (#82), täydennetty (#90):** komento **ja**
ohut skripti; keskeytys `--stop` tuli #90:ssä.
- `commands/run-epic.md` (slash-komento, Claude Code lukee sen suoraan) **ja** `run-epic.sh`
  repo-juuressa, koska komento tarvitsi ei-triviaalia bash-logiikkaa (syklintarkistus Kahnin
  algoritmilla bash 3.2:ssa ilman assosiatiivisia taulukoita, topologinen järjestys) —
  symmetrinen `stop-run.sh`:n kanssa. Validointi suunnittele–sovella-jaolla, delegoi propagoinnin
  jaettuun `propagate_run_labels`iin (M4). `--dry-run`, `--start-now`; keskeytys `--stop` jäi
  #82:ssa tietoisesti pois ja toteutettiin **#90:ssä** (päätös H) samalla
  plan-then-apply-jaolla, delegoiden elävien ajojen pysäytyksen `stop-run.sh`:lle.
- Asennus: `install.sh` linkittää `commands/*.md` jo globilla, joten komento tuli asennukseen
  pelkällä nimeämisellä (CLAUDE.md §3). Juuren skripti näkyy automaattisesti litteässä juuressa
  (CLAUDE.md §2).

**M7 — Epicin näkyvä merkintä (§4.2, päätös G).** — **TOTEUTETTU (#81):**
- Osa M5:tä: kommentti epic-issuelle jumittuneesta lapsesta (`lib/epic.sh:_epic_escalate_child`,
  per-child piilomarker) + kevyt `epic-attention`-label. Idempotenssi #65:n
  `pr_last_decision`-hengessä (kertaluonteinen per lapsi). Lisäksi valmiuden merkintä
  (`_epic_announce_complete`: yhteenvetokommentti + `epic-complete`-label, päätös F).

**M8 — Dokumentaatio.** — **TOTEUTETTU (#82) + statuspäivitys (#93) + keskeytys (#90):**
- `README.md`: alaluku "Epicit — usean issuen ketjun ajaminen `auto-run`illa" ihmiselle (#82).
- `CLAUDE.md`: epic-koneisto kuvattu §4:ssä ja §6:ssa; viittaus tähän dokumenttiin.
- Uudet exit-koodit (12 orkestraattori; `run-epic.sh`-avaruus) ja labelit CLAUDE.md §4/§5:ssä.
- **#93:** dokumentin statuspäivitys — suunnitelmasta toteutustilan kuvaukseksi.
- **#90:** `--stop` dokumentoitu README §6.5:ssä, `commands/run-epic.md`:ssä ja CLAUDE.md §5:n
  `run-epic.sh`-exit-koodeissa; §4.3 ja päätös H merkitty ratkaistuiksi.

### 6.3 Muutosten kokoluokka

M1 ja M2 olivat **pakollisia ennakkoehtoja** (ilman niitä epic+auto-run olisi ollut haitallinen,
§2). M3–M7 olivat varsinainen epic-automaatio. Kaikki nojasivat olemassa oleviin abstraktioihin;
mitään ydinkoneistoa (S2b, lukot, PR-vahti) ei kirjoitettu uusiksi. Tämä oli issuen tavoittelema
minimimuutos, ja se toteutui suunnitellusti (#81 M1–M5 + M7, #82 M6).

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

**Kaikki kymmenen on ratkaistu koodissa** (#81, #82, #90). Ratkaisusarake nimeää kunkin
toteutuskohdan tiedosto/funktio-tasolla. Suositus-sarake on
säilytetty osoittamaan, että toteutus seurasi (tai poikkesi) alkuperäisestä suosituksesta —
perustelut ovat laatikoissa yllä. Ristiriitatilanteessa **koodi (ja CLAUDE.md §12) voittaa**.

| # | Kysymys | Alkuperäinen suositus | Ratkaisu (toteutuskohta / avoin) |
|---|---|---|---|
| A | Kirjoittaako task-lista-fallback natiivit lapset? | Ei — fallback on vain lukusääntö | **Ratkaistu (#81):** fallback on vain lukusääntö → `lib/issue.sh:list_epic_children` (natiivit `sub_issues` kanoninen, task-lista fallback vain kun natiiveja on nolla; ei kirjoita natiiveja) |
| B | Autoritatiivinen epic-portti claimia ennen? | Kyllä, kevyt label-luku S2b:n mallilla | **Ratkaistu (#81):** S2c EpicCheck lukon jälkeen, claimia ennen → `orchestrate.sh` + `lib/issue.sh:is_epic`, fail-closed, **exit 12**, ei `needs-human`-labelia |
| C | Propagoinnin ajankohta? | Poller ylläpitää joka tikki, `/run-epic` tekee ensilisäyksen | **Ratkaistu (#81/#82):** pollerin `scan_epics`-vaihe joka tikki ennen poimintaa (`lib/epic.sh:epic_process_one`); `/run-epic` tekee ensilisäyksen (`run-epic.sh`). Molemmat kutsuvat samaa `propagate_run_labels`ia |
| D | Voiko lapsen jättää ajon ulkopuolelle? | Kyllä, olemassa olevalla `wip`illä (ei uutta labelia) | **Ratkaistu (#81):** olemassa oleva `wip` → `scan_epics` ohittaa `wip`-lapset propagoinnissa, poiminta ei poimi `wip`-issueita. Ei uutta opt-out-labelia |
| E | Mitkä labelit propagoituvat? | Watchlistin repolle vaatima joukko | **Ratkaistu (#81):** watchlistin ajolabelit (`auto-run` + repon vaatimat) → `lib/epic.sh:propagate_run_labels` |
| F | Kuka sulkee valmiin epicin? | Ihminen oletuksena; GitHubin auto-close jos konfiguroitu | **Ratkaistu (#81):** runner ei sulje — merkitsee valmiuden (yhteenvetokommentti + `epic-complete`-label, `lib/epic.sh:_epic_announce_complete`); ihminen sulkee, GitHubin natiivi auto-close voittaa jos konfiguroitu |
| G | Epic-merkinnän muoto jumittuneesta lapsesta? | Kommentti + suodatettava `epic-attention`-label | **Ratkaistu (#81):** kommentti (per-child piilomarker, kertaluonteinen) + `epic-attention`-label → `lib/epic.sh:_epic_escalate_child` |
| H | Keskeytyskomennon muoto? | `/run-epic <N> --stop`, delegoi `stop-run.sh`:lle | **Ratkaistu (#90):** `/run-epic <N> --stop` osana samaa komentoa, plan-then-apply-jaolla → `run-epic.sh`; elävien ajojen pysäytys delegoidaan `stop-run.sh`:lle, osittainen onnistuminen (vieras kone / terminaalitila) erottuu **exit-koodilla 6** |
| I | Lisääkö `/run-epic` puuttuvan `epic`-labelin? | Kyllä, idempotentisti | **Ratkaistu (#82):** `run-epic.sh` lisää `epic`-labelin idempotentisti jos puuttuu (`--dry-run` ei lisää) |
| J | Käynnistääkö komento ajon vai pelkkä labelointi? | Labelointi + poller oletuksena, `--start-now` synkroniseen | **Ratkaistu (#82):** oletus labelointi + poller; `--start-now` käynnistää ensimmäisen ajokelpoisen lapsen heti (`run-epic.sh`) |
