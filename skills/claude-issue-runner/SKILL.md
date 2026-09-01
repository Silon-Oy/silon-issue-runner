---
name: claude-issue-runner
description: Use when working in a repository watched by the claude-issue-runner / run-issues automation — you see an auto-run, auto-claimed, needs-human, waiting, wip, epic, auto-clean or auto-merge label; a branch whose name starts with auto-run/ (e.g. auto-run/<repo>-issue-<N>-<slug>); a run.json artifact or a .claude/run-issues-archive/ directory; an issue comment carrying a <!-- run-issues:… --> marker; a bot-opened PR closing an issue; or the /run-issues, /run-epic, /pr-watch or /cleanup-run commands. Covers what the system is, when it picks an issue up, what every label means and who writes it (including the auto-claimed reservation label), how to read and unstick a blocked or stalled run, and which command or script to reach for.
when_to_use: You are in a repository the run-issues automation watches — writing or labelling an issue you want it to run, or looking at something it left behind (a label, a branch, a bot PR, a question comment, a run that stopped) and deciding what to do next.
version: 2.2.0
---

# claude-issue-runner — järjestelmän käyttöohje

Tämä paketti vie GitHub-issuen valmiiseen pull requestiin ilman ihmistä silmukassa: poller
poimii labeloidun issuen noin viiden minuutin välein ja avaa siitä PR:n, ja PR-vahti odottaa
CI:n ja mergeää. Päätökset tehdään **kohderepossa**, jossa paketin oma dokumentaatio ei ole
ladattuna — tämä skill tuo ne mukaan. Koodi ja täysi dokumentaatio ovat hakemistossa
`$HOME/.claude/scripts/run-issues` (`README.md` ihmiselle, `CLAUDE.md` agentille).

Jokainen poimintaehto **epäonnistuu hiljaa**: issue jää poimimatta eikä mistään näy miksi.
Ei virhettä, ei lokiriviä. Siksi konventiot pitää tietää etukäteen, ei jälkikäteen.

## Tunnistat järjestelmän näistä

| Näet | Merkitys |
|---|---|
| `auto-run`-label issuella | Issue on merkitty automaation ajettavaksi |
| Haara `auto-run/…-issue-<N>-<slug>` | Yhden ajon feature-haara (nimi alkaa aina `auto-run/`) |
| `run.json` hakemistossa `.claude/run-issues/` | Elävän tai keskenjääneen ajon tilatiedosto |
| Hakemisto `.claude/run-issues-archive/` | Siivotun ajon arkistoidut artefaktit |
| Issue-kommentissa `<!-- run-issues:… -->` | Automaation markeri: ajo odottaa **sinun vastaustasi** |
| `auto-claimed`-label issuella | Automaation varaus: issue on käynnissä olevan tai siivoamattoman ajon hallussa |
| `needs-human`-label | Automaatio luovutti — syy on issuen viimeisimmässä tilannekommentissa |
| Botin avaama PR, jonka rungossa `Closes #N` | Ajon tulos; PR-vahti vie sen eteenpäin |

## Elinkaari yhdellä silmäyksellä

1. Kirjoitat issuen ja lisäät poimintalabelit (oletuksena `auto-run`).
2. Poller poimii vanhimman ehdot täyttävän issuen ja **varaa sen `auto-claimed`-labelilla**
   (assignaatio `@me`:lle jää kirjanpidoksi).
3. Ajo saa oman git-worktreen ja feature-haaran; toteutus tapahtuu siellä, ei työpuussasi.
4. Ajo avaa pull requestin, joka sulkee issuen (`Closes #N`).
5. PR-vahti odottaa CI:n, ratkoo tarvittaessa rebase-konfliktin ja mergeää `auto-merge`-labeloidun PR:n.
6. Siivous purkaa worktreen, haaran ja varauksen.

## Labelit — kuka kirjoittaa, mitä vaikuttaa

Tärkein tieto labelista on **kuka sen kirjoittaa**. Itse lisättävää labelia ei kannata jäädä
odottamaan, eikä automaation lisäämää labelia kannata poistaa ennen kuin syy on korjattu.

| Label | Kuka lisää | Kuka poistaa | Vaikutus |
|---|---|---|---|
| `auto-run` | sinä (tai epic-propagointi) | sinä | Poimintaehto. Nimi tulee watchlistin konfiguraatiosta (`default_labels` tai repon `labels`), ei koodista |
| `wip` | **vain sinä** | sinä | Estää poiminnan. "Teen tämän itse" — ja epicin lapsella opt-out propagoinnista |
| `waiting` | automaatio, kun ajo odottaa vastaustasi | automaatio, kun jatkat | Estää poiminnan tarkennuksen ajaksi |
| `epic` | sinä tai `/run-epic` | sinä | Estää poiminnan: epic kokoaa alaissueet muttei ole itse ajettava |
| `auto-clean` (`RUN_ISSUES_CLEAN_LABEL`) | sinä | automaatio siivouksen jälkeen | Pyytää siivoamaan ajojäänteet ja **sulkemaan** issuen. **Ei koskaan poimintalabeliksi** |
| `auto-clean-skipped` | automaatio, kun se ei voi siivota | **sinä**, kun olet hoitanut asian | Estää siivouksen loputtoman uudelleenyrityksen |
| `auto-merge` (`PR_WATCH_MERGE_LABEL`) | sinä issuelle, automaatio PR:lle | sinä | PR-vahti mergeää **vain** labeloidun PR:n |
| `auto-claimed` | automaatio, kun ajo varaa issuen (S3) | automaatio, kun ajo perääntyy tai siivotaan | **Varaus**: estää poiminnan käynnissä olevan tai siivoamattoman ajon ajaksi. Kiinteä nimi. **Älä lisää tai poista käsin** |
| `needs-human` | automaatio, kun ajo luovuttaa | siivous, tai sinä PR:llä | Signaali sinulle. Issuella ei estä poimintaa; PR:llä pidättää vahdin CI-korjauksen luovutuksen jälkeen |
| `epic-attention` | automaatio, kun epicin lapsi tarvitsee ihmistä | sinä | Suodatettava merkintä epic-issuella |
| `epic-complete` | automaatio, kun kaikki alaissueet ovat kiinni | sinä | Merkintä epicillä; **runner ei sulje epiciä** |

Luo `auto-run`, `wip` ja `auto-clean` repoon itse: GitHub ei salli tuntemattoman labelin
liittämistä, ja automaatio luo vain omat labelinsa. Kolme kallista sekaannusta:

- **Esto ei ole label.** Riippuvuudet merkitään GitHubin omalla "blocked by" -toiminnolla.
- **`needs-human` ei estä poimintaa issuella** — varaus (`auto-claimed`) estää. PR:llä se
  pidättää vahdin, mutta vain kun vahti itse lisäsi sen CI-korjauksen luovutuksessa; käsin
  lisättynä muulle PR:lle se ei jarruta mergeä.
- **`auto-merge` luetaan issuelta ajon alkaessa ja siirretään PR:lle sen avaushetkellä.**
  Kesken ajon tai sen jälkeen issuelle lisätty label ei siirry — lisää se silloin suoraan PR:lle.

## Milloin issue lähtee ajoon

Poiminta on **yksi REST-listaus GitHubista** ja sen päälle paikallinen suodatus (#133:
suodatettu `gh issue list` kulkee hakuyhteyden kautta, joka voi olla estetty muun API:n
vastatessa). Issue lähtee ajoon täsmälleen kun **kaikki kuusi** pätevät:

1. Issue on **avoin**.
2. Issuella **ei ole `auto-claimed`-labelia** — se on automaation oma varausmerkintä käynnissä
   olevalle tai siivoamattomalle ajolle. **Käsin assignattu issue lähtee ajoon normaalisti**:
   assignaatio ei estä poimintaa.
3. Issue **ei ole estetty** GitHubin natiivissa riippuvuusgraafissa ("Mark as blocked by").
   Graafi luetaan suoraan riippuvuusrajapinnasta ehdokas kerrallaan, vanhimmasta alkaen.
4. Issuella **ei ole** labelia `waiting`, `wip`, `epic` eikä `auto-clean`.
5. Issuella on **kaikki** konfiguroidut poimintalabelit (oletus: yksi label, `auto-run`).
6. Se on vanhin ehdot täyttävä issue — yksi issue per tikki per remote.

Viides kohta yllättää useimmin: **poimintalabelit yhdistyvät JA-ehdolla, eivät TAI-ehdolla.**
Jos poimintalabeleita on kaksi, issue tarvitsee molemmat.

> **Ansa:** `auto-clean` on aina poissuljettu (kohta 4). Jos listaat sen poimintalabeliksi,
> listaus pyytää palvelimelta `auto-clean`-issuet ja paikallinen suodatin pudottaa ne kaikki →
> **nolla ehdokasta, ei virhettä, ei lokiriviä.** Repo jää pysyvästi tyhjäksi ajoista. Älä
> koskaan käytä `auto-clean`ia poimintalabelina.

## Varaus on `auto-claimed`-label, assignaatio on kirjanpitoa

Varaus — käynnissä olevan tai siivoamattoman ajon poistaminen poiminnasta — on automaation oma
`auto-claimed`-label, jonka **vain automaatio kirjoittaa**. Ajo lisää sen varatessaan issuen ja
poistaa sen perääntyessään tai siivouksessa; assignaatio jää pelkäksi kirjanpidoksi. Kaksi
seurausta:

- **Käsin assignattu issue lähtee ajoon normaalisti.** Jos haluat tehdä issuen itse, käytä
  **`wip`-labelia** — se on ainoa "teen tämän itse" -opt-out.
- **Epäonnistunut ajo jättää issuen varatuksi `auto-claimed`illa**, ja issue palaa automaatioon
  vasta siivouksen jälkeen: poller ei poimi samaa issueta yhä uudelleen samaan seinään. **Älä
  poista `auto-claimed`ia käsin** — se palauttaisi keskeneräisen ajon poimintaan.

## Riippuvuudet ja epicit

Kun issuen pitää odottaa toista, merkitse riippuvuus GitHubin **"Mark as blocked by"**
-toiminnolla. Työjärjestys ketjua rakentaessa:

1. **Luo issuet.**
2. **Merkitse riippuvuudet** GitHubin omalla toiminnolla (ei labelia).
3. **Lisää `auto-run` vasta sitten.**

Automaatio etenee ketjussa yksi lenkki kerrallaan itsestään: kun viimeinen estäjä sulkeutuu,
issue vapautuu poimintaan seuraavalla tikillä. Yksi avoin estäjä riittää pitämään issuen
poiminnan ulkopuolella, eikä estoa voi vahingossa poistaa labelia poistamalla.

**Epic** on kokoava issue, jolla on alaissueita (GitHubin sub-issues tai rungon task-lista):

- `epic`-label **estää poiminnan** — epic ei ole itse ajettava tehtävä.
- `auto-run` epicillä on **propagointisignaali**, ei ajosignaali: automaatio lisää ajolabelit
  epicin avoimille alaissueille ja poller ajaa ketjun riippuvuusjärjestyksessä.
- Jätä yksittäinen alaissue ajon ulkopuolelle `wip`illä, älä `auto-run`ia poistamalla —
  propagointi palauttaisi sen.
- `epic-attention` epicillä tarkoittaa, että jokin lapsi tarvitsee ihmistä; riippumattomat
  haarat jatkavat silti itsestään.
- `epic-complete` tarkoittaa, että kaikki alaissueet ovat kiinni. **Runner ei sulje epiciä** —
  sulkupäätös on sinun, koska epicin rungossa voi olla hyväksyntäkriteereitä.

## Kun jokin on pysähtynyt — mitä teet

| Mitä näet | Merkitys | Mitä teet |
|---|---|---|
| `waiting` + kysymyskommentti | Ajo pyytää tarkennusta ja odottaa | **Vastaa kommentilla.** Ajo jatkuu itsestään |
| `needs-human` issuella | Ajo pysähtyi terminaalisesti; syy on tilannekommentissa | Lue kommentti: jos se pyytää kommentoimaan esteen poistuttua, tee niin — ajo siivotaan ja yritetään uudelleen. Jos ei pyydä (esim. restart-budjetti paloi loppuun), kommentointi ei auta: jatka `--restart`illa tai siivoa |
| `needs-human` PR:llä | Vahti luovutti CI-korjauksen eikä koske PR:ään | Korjaa kommentissa nimetty syy, **poista label** — vahti mergeää jos CI on vihreä |
| PR auki, ei mergeydy | Puuttuva `auto-merge`-label, punainen CI tai konflikti | Tarkista label ja CI; loput vahti hoitaa itse |
| Ajo näyttää jumittuneen | Ei rakenteellista edistymää | **Odota ensin**: poller finalisoi jumiutuneen ajon itse noin tunnin rajalla. Kiireessä `stop-run.sh` |
| Issue ei lähde ajoon lainkaan | Jokin poimintaehto ei täyty | Ks. triage alla |

**Yhden kommentin vastaussääntö.** Automaatio ei lue koko keskusteluketjua, vaan **vain
uusimman `<!-- run-issues:… -->` -markerin jälkeen kirjoitetun kommentin**. Siitä seuraa kaksi
asiaa: markeria vanhempi kommentti ei koskaan kelpaa vastaukseksi, ja **yksi kommentti = yksi
yritys** (uusi epäonnistuminen postaa uuden markerin, joka taas odottaa uutta kommenttia).
Kirjoittajan nimi ei kelpaa erottimeksi, koska botti ja ihminen voivat jakaa saman GitHub-tilin
— vain markerin aikaleima erottaa ne luotettavasti.

## Triage — miksi issueni ei lähde ajoon

Käy ehdot läpi **halvimmasta ja yleisimmästä syystä alkaen**. Ensimmäinen osuma on syy; älä
jatka listaa pidemmälle kuin on pakko.

1. **Varaus (`auto-claimed`).** Onko issuella `auto-claimed`-label? Se tarkoittaa käynnissä
   olevaa tai siivoamatonta ajoa, joka on varannut issuen — ylivoimaisesti yleisin syy. Siivoa
   vanha ajo, mikä poistaa varauslabelin. **Assignaatio ei estä poimintaa.**
2. **Riippuvuudet.** Onko issue merkitty "blocked by" johonkin avoimeen issueen? Katso issuen
   omasta näkymästä — **esto ei näy labeleissa.** Yksikin avoin estäjä riittää.
3. **Estolabelit.** Onko issuella `waiting`, `wip`, `epic` tai `auto-clean`? Kaikki neljä
   estävät poiminnan. Huom: `needs-human` **ei** estä poimintaa — varaus (`auto-claimed`) estää.
4. **Poimintalabelien JA-ehto.** Onko issuella **kaikki** konfiguroidut poimintalabelit? Jos
   niitä on kaksi, yksi ei riitä. Ja jos `auto-clean` on vahingossa listattu poimintalabeliksi,
   haku on itsensä kanssa ristiriidassa → nolla osumaa aina.

Jos mikään näistä ei ole syy, ongelma on ajoympäristössä (poller ei aja tällä koneella,
watchlist ei kata repoa, rinnakkaisuuskatto täynnä) — ks. paketin README osio 9.

## Komennot ja skriptit

Slash-komennot toimivat **vain Claude Coden sisällä** (ne ovat ohjeita agentille, eivät
skriptejä):

- `/run-issues` — aja orkestraattori **nimetylle** issuelle (`#N`); issuenumero on pakollinen,
  automaattinen poiminta on pollerin tehtävä.
- `/new-epic` — pilkkoo vapaamuotoisen kuvauksen epiciksi ja alaissueiksi: luo issuet, linkittää
  ne sub-issueiksi, merkitsee riippuvuudet ja labeloi **vain epicin** ajoon. Ei aja mitään.
- `/run-epic` — validoi epicin rakenne ja propagoi ajolabelit sen alaissueille; `--stop` keskeyttää.
- `/pr-watch` — aja PR-vahti yhdelle PR:lle tai skannaa tämän koneen valmiit ajot.
- `/cleanup-run` — siivoa keskenjääneen ajon jäänteet.

Skriptit ovat hakemistossa `$HOME/.claude/scripts/run-issues` ja ajettavissa suoraan:

- `orchestrate.sh` — orkestraattori: yksi issue → yksi ajo → yksi PR.
- `run-epic.sh` — epicin käynnistys ja keskeytys.
- `pr-watch.sh` — PR-vahti: CI-odotus, konfliktin ratkaisu, auto-merge.
- `status.sh` — puhtaasti lukeva kokonaistila kaikista ajoista.
- `stop-run.sh` — pysäytä yksi elävä ajo (ei siivoa jäänteitä).
- `cleanup-run.sh` — pura yhden ajon worktree, haara, run-dir, varaus ja lukko.
- `auto-clean.sh` — sama siivous labelin laukaisemana, ja issuen sulkeminen.

**Siivous on konekohtaista:** worktree, run-dir ja lukko ovat sillä koneella, jolla ajo
tapahtui, eikä väärällä koneella ajettu siivous löydä mitään. Liput ja exit-koodit ovat paketin
README:n osioissa 6.7–6.8 (komennot ja skriptit) ja 9 (vianetsintä).

## Rajaus ja mistä löydät loput

Tämä skill kattaa **päätöskriittisen ytimen**: mikä saa issuen ajoon, mitä labelit tarkoittavat
ja mitä teet kun jokin pysähtyy. Se **ei** kata tilakonetta, `lib/`-rakennetta, exit-koodien
avaruuksia, asennusta, turvamallia, LaunchAgent-konfiguraatiota, statussivua eikä PR-vahdin
sisuskaluja — ne ovat paketin anatomiaa hakemistossa `$HOME/.claude/scripts/run-issues`
(`README.md` ihmiselle, `CLAUDE.md` agentille).

Paketin `commands/`-hakemiston factory- ja refresh-komennot sekä `agents/`-hakemiston neljä
määrittelyä kuuluvat erilliseen agenttitehtaaseen eivätkä tähän järjestelmään; tämän runnerin
omat "agentit" ovat `prompts/`-hakemiston promptipohjia.
