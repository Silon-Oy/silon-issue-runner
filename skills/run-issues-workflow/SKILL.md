---
name: run-issues-workflow
description: Use when writing GitHub issues that the /run-issues automation (auto-run label, run.json, pr-watch) should pick up and run, or when triaging why an issue is not being picked up. Covers pickup conditions, label ownership, assignee-as-reservation, and blocked_by dependency chains — the conventions that decide pickup, made at issue-creation time in the target repo where README/CLAUDE.md are not loaded.
when_to_use: You are creating, labelling or ordering issues in a repository that the run-issues automation watches (you see an auto-run label, a run.json artifact, or a pr-watch bot), or an issue you expected the runner to pick up is sitting untouched with no error anywhere.
version: 1.0.0
---

# run-issues-workflow — issue-konventiot

Tämä paketti (`claude-issue-runner`) ajaa GitHub-issuen valmiiseen pull requestiin ilman
ihmistä silmukassa: `/run-issues`-orkestraattori poimii issuen, avaa PR:n, ja `pr-watch`
vie sen mergeen. Poiminta- ja labelointipäätökset tehdään silloin kun issue **luodaan** —
kohderepossa, jossa paketin oma dokumentaatio (`README.md`, `CLAUDE.md`) ei ole ladattuna.
Tämä skill tuo ne päätöksentekohetkeen mukaan.

Jokainen alla oleva ehto **epäonnistuu hiljaa**: issue jää poimimatta eikä mistään näy miksi.
Ei virhettä, ei lokiriviä. Siksi konventiot pitää tietää etukäteen, ei jälkikäteen.

---

## a) Kun kirjoitat issuen, jonka runner poimii

### Kuusi poimintaehtoa

Poiminta on **yksi GitHub-haku**. Issue lähtee ajoon täsmälleen kun **kaikki kuusi** pätevät:

1. Issue on **avoin**.
2. Issuella **ei ole yhtään assigneeta** (`no:assignee`) — ei sinua, ei ketään muuta.
3. Issue **ei ole estetty** GitHubin natiivissa riippuvuusgraafissa (`-is:blocked`).
4. Issuella **ei ole** labelia `waiting`, `wip`, `epic` eikä `auto-clean`.
5. Issuella on **kaikki** konfiguroidut poimintalabelit (oletus: yksi label, `auto-run`).
6. Se on vanhin ehdot täyttävä issue — yksi issue per tikki per remote.

Viides kohta yllättää useimmin: **poimintalabelit yhdistyvät JA-ehdolla, eivät TAI-ehdolla.**
Jos poimintalabeleita on kaksi, issue tarvitsee molemmat.

> **Ansa:** `auto-clean` on aina poissuljettu (kohta 4). Jos listaat sen poimintalabeliksi,
> haku sisältää sekä `label:"auto-clean"` että `-label:auto-clean` → **nolla osumaa, ei
> virhettä, ei lokiriviä.** Repo jää pysyvästi tyhjäksi ajoista. Älä koskaan käytä
> `auto-clean`ia poimintalabelina.

### Labelien omistajuus — kuka lisää, kuka poistaa

Tärkein tieto labelista on **kuka sen kirjoittaa**. Itse lisättävää labelia ei kannata jäädä
odottamaan, eikä automaation lisäämää labelia kannata poistaa käsin ennen kuin syy on korjattu.

| Label | Kuka lisää | Kuka poistaa | Vaikutus |
|---|---|---|---|
| `auto-run` | **sinä** | sinä | Poimintaehto. Nimi tulee konfiguraatiosta, ei koodista — oletus, ei kiinteä |
| `wip` | **sinä** | sinä | Estää poiminnan. "Teen tämän itse" -merkintä |
| `epic` | **sinä** | sinä | Merkitsee kokoavan epic-issuen. **Estää poiminnan** — epic ei ole itse ajettava, vaan sen `auto-run` propagoituu avoimille alaissueille. Jätä alaissue ajon ulkopuolelle `wip`illä, ei `auto-run`ia poistamalla (propagointi palauttaisi sen) |
| `auto-clean` (konfiguroitava: `RUN_ISSUES_CLEAN_LABEL`) | **sinä** | automaatio siivouksen jälkeen | Pyytää siivoamaan ajojäänteet ja sulkemaan issuen. **Ei koskaan poimintalabeliksi** |
| `auto-merge` (konfiguroitava: `PR_WATCH_MERGE_LABEL`) | **sinä** issuelle | — | Propagoituu issuelta PR:lle; `pr-watch` mergeää vain labeloidun PR:n |
| `waiting` | automaatio, kun ajo odottaa vastaustasi | automaatio, kun jatkat | Estää poiminnan tarkennuksen ajaksi |
| `needs-human` | automaatio, kun ajo epäonnistuu | siivous (`cleanup-run`) | **Ei estä poimintaa** — assignaatio estää. Signaali sinulle |
| `auto-clean-skipped` | automaatio, kun se ei voi siivota | **sinä**, kun olet hoitanut asian | Estää siivouksen loputtoman uudelleenyrityksen |

Kolme kohtaa, jotka sinun täytyy tehdä itse ennen ensimmäistä ajoa:

- **Luo `auto-run`, `wip` ja `auto-clean` repoon itse.** GitHub ei salli tuntemattoman labelin
  liittämistä, ja automaatio luo vain omat labelinsa (`waiting`, `needs-human`,
  `auto-clean-skipped` sekä PR:lle kopioitavat). Sinun lisäämiäsi labeleita se ei luo.
- **`auto-merge` luetaan PR:ltä, ei issuelta.** Orkestraattori kopioi sen issuelta PR:lle
  **vain PR:n avaushetkellä**. Jos lisäät labelin issuelle vasta PR:n avaamisen jälkeen, se ei
  siirry — lisää se silloin suoraan PR:lle.
- **Esto ei ole label.** Ks. riippuvuudet alla.

### Assignaatio on varaus, ei kirjanpitoa

Assignaatio on **ainoa tila, jonka kaikki koneet näkevät**, joten järjestelmä käyttää sitä
varausmekanismina. Kaksi seurausta issuen kirjoittajalle:

- **Käsin assignattu issue ei koskaan lähde automaatioon** (`no:assignee` poimintahaussa). Jos
  haluat tehdä issuen itse, assignoi se itsellesi — se on `wip`-labelia vahvempi keino.
- **Epäonnistunut ajo jättää issuen varatuksi itselleen.** Issue palaa automaatioon vasta kun
  ajo siivotaan (`cleanup-run`). Tämä on tarkoituksellista: poller ei poimi samaa issueta yhä
  uudelleen samaan seinään.

### Riippuvuusketju — työjärjestys

Kun issuen pitää odottaa toista, merkitse riippuvuus GitHubin **"Mark as blocked by"**
-toiminnolla. **Esto ei ole label** eikä skripti: poimintahaku suodattaa estetyt issuet
`-is:blocked`-kvalifikaattorilla, joka lukee `blocked_by`-graafin suoraan.

Ketjun rakentamisen työjärjestys:

1. **Luo issuet.**
2. **Merkitse riippuvuudet** GitHubin omalla "blocked by" -toiminnolla (ei labelia).
3. **Lisää jokaiselle `auto-run`.**

Automaatio etenee ketjussa yksi lenkki kerrallaan itsestään: kun viimeinen estäjä sulkeutuu,
issue vapautuu poimintaan seuraavalla tikillä. Yksi avoin estäjä riittää pitämään issuen
poiminnan ulkopuolella. Koska esto ei näy labeleissa, sitä ei voi vahingossa poistaa labelia
poistamalla.

---

## b) Triage — miksi issueni ei lähde ajoon

Käy ehdot läpi **halvimmasta ja yleisimmästä syystä alkaen**. Ensimmäinen osuma on syy; älä
jatka listaa pidemmälle kuin on pakko.

1. **Assignaatio.** Onko issuella assignee? `no:assignee` on poimintaehto, joten **kuka tahansa
   assignee estää poiminnan** — myös sinä itse, myös aiemman epäonnistuneen ajon jättämä
   varaus. Tämä on ylivoimaisesti yleisin syy. Poista assignaatio tai siivoa vanha ajo
   (`cleanup-run`).
2. **Riippuvuudet.** Onko issue merkitty "blocked by" johonkin avoimeen issueen? Katso issuen
   omasta näkymästä — **esto ei näy labeleissa.** Yksikin avoin estäjä riittää.
3. **Estolabelit.** Onko issuella `waiting`, `wip` tai `auto-clean`? Kaikki kolme estävät
   poiminnan. `waiting` on automaation lisäämä (tarkennus kesken); `wip` ja `auto-clean` ovat
   sinun. Huom: `needs-human` **ei** estä poimintaa — assignaatio estää.
4. **Poimintalabelien JA-ehto.** Onko issuella **kaikki** konfiguroidut poimintalabelit? Jos
   konfiguraatiossa on kaksi labelia, yksi ei riitä. Ja jos `auto-clean` on vahingossa
   listattu poimintalabeliksi, haku on itsensä kanssa ristiriidassa (`label:"auto-clean"` +
   `-label:auto-clean`) → nolla osumaa aina.

Jos mikään näistä ei ole syy, ongelma ei ole issuen konventioissa vaan ajoympäristössä
(poller ei aja tällä koneella, watchlist ei kata repoa, rinnakkaisuuskatto täynnä) — se on
paketin anatomiaa, ei tämän skillin alaa.

---

## Rajaus

Tämä skill kattaa **issuen konventiot**: mikä saa issuen ajoon ja miksi se jää ajamatta. Se ei
kata tilakonetta, exit-koodeja, `lib/`-rakennetta, LaunchAgent-migraatiota eikä PR-vahdin
sisäistä käyttäytymistä — ne ovat paketin anatomiaa ja kuvattu paketin repon `README.md`:ssä
ja `CLAUDE.md`:ssä siellä, missä ne ovat relevantteja.
