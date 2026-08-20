---
argument-hint: [#N] [--dry-run] [--start-now] [--stop]
description: Käynnistä koko epic yhdellä komennolla — validoi rakenteen, propagoi ajolabelit alaissueille ja raportoi ketjun tilan. --stop keskeyttää.
---

# /run-epic

Käynnistää **epic-issuen** ajon: validoi epicin rakenteen, propagoi ajolabelit (`auto-run`) sen
avoimille alaissueille, ja poller ajaa ketjun normaalisti `blocked_by`-järjestyksessä. Tämä on
eksplisiittinen käynnistyspinta sille, minkä poller muutenkin tekee joka tikki (ks.
[`docs/epic-orchestration.md`](../docs/epic-orchestration.md)) — komennolla ketju lähtee heti,
odottamatta seuraavaa tikkiä, ja epicin rakenne tarkistetaan ennen mitään kirjoitusta.

Epic on GitHub-issue jolla on **`epic`-label**; sen alaissueet liitetään GitHubin natiivilla
**sub-issue**-toiminnolla (vanhoissa epiceissä rungon task-lista `- [ ] Otsikko #123` toimii
varamuotona). Epic **ei koskaan itse aja** — sen "toteutus" on alaissueiden toteutus.

## 1. Aja komento

Käytä **nykyistä työhakemistoa kohdereposijaintina** (`pwd`). Poimi käyttäjän antama epic-numero
argumentista `#N`.

```bash
REPO_ROOT=$(pwd)
EPIC="<n>"        # käyttäjän antama epic-issuen numero, esim. 101

set +e
"$HOME/.claude/scripts/run-issues/run-epic.sh" "$EPIC" --repo "$REPO_ROOT"
RC=$?
set -e
echo "RUN_EPIC_EXIT=$RC"
```

Liput:

- `--dry-run` — tulostaa saman raportin (mitä labeloitaisiin, mikä ajaa ensin, mitkä ovat
  estettyjä ja minkä takana, ketjun pituus) **kirjoittamatta mitään**. Aja tämä ensin, jos
  haluat nähdä suunnitelman.
- `--start-now` — labeloinnin jälkeen käynnistää heti ensimmäisen ajokelpoisen alaissueen
  (`orchestrate.sh`) odottamatta pollerin tikkiä. Hyödyllinen koneella, jolla poller ei aja.
- `--stop` — **keskeyttää** epicin: pysäyttää elävät lapsiajot (delegoi `stop-run.sh`:lle) ja
  poistaa ajolabelit **ensin epiciltä, sitten avoimilta lapsilta**. Ei yhteensopiva
  `--start-now`n kanssa (käyttövirhe). Ks. alla oleva keskeytysosio.
- `--remote <nimi>` / `--labels <csv>` — monirepo- ja monilabel-tapauksiin (oletus `origin`,
  `auto-run`).

## 2. Toimi exit-koodin mukaan

Koodit 1/2/3/5 ovat yhteisiä molemmille moodeille; 4 on vain käynnistys, 6 vain `--stop`.

| RC | Mitä tarkoittaa | Mitä tee |
|---|---|---|
| 0 | Käynnistys: validoitu + propagoitu. `--stop`: epic kokonaan pysäytetty. (Tai `--dry-run` tulosti suunnitelman.) | Tulosta raportti. Käynnistyksessä kerro mikä alaissue ajaa ensin; keskeytyksessä kerro mitkä ajot pysäytettiin ja mitkä lapset vapautettiin. |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva tai epäkelpo epic-numero / `--stop` yhdessä `--start-now`n kanssa) | Tulosta virheviesti. |
| 2 | Epic-issueta ei löytynyt tai se ei ole avoin | Kerro käyttäjälle — tarkista numero ja tila. |
| 3 | Epic ilman alaissueita | Kerro että epiciin pitää lisätä alaissueet (natiivit tai task-lista) ennen ajoa. |
| 4 | Käynnistys: syklinen `blocked_by`-graafi alaissueiden välillä | Tulosta virheviesti **sellaisenaan** — se nimeää sykliin osallistuvat issuet. Käyttäjän on purettava sykli. |
| 5 | Riippuvuusgraafia ei saatu luettua (fail-closed) | GitHub-lukuvirhe — yritä uudelleen tai tarkista `gh`-yhteys. |
| 6 | `--stop`: osittainen — epic vapautettiin mutta ≥1 elävää lapsiajoa ei voitu pysäyttää (vieras kone / terminaalitila ilman `--force`ia / moniselitteinen / delegoitu `stop-run.sh` epäonnistui) | Tulosta raportti **sellaisenaan** — se nimeää mikä lapsi jäi ja miksi. Pysäytä vieraan koneen ajo siellä; terminaalitilan ajon voi purkaa `stop-run.sh --force`illa jos todella halutaan. |

## Huomioita

- **Kirjoitukset tehdään vasta validoinnin jälkeen** (suunnittele–sovella, kuten `install.sh`):
  yksikin validointivirhe ⇒ nolla muutosta.
- Jos epiciltä puuttuu `epic`-label, komento **lisää sen** — komennolla voi siis muuntaa
  kokoavan issuen epiciksi (`--dry-run` ei lisää).
- **GitHub-tila on globaali**, joten labelointi toimii miltä koneelta tahansa; ketjun ajaa se
  kone, jonka poller pollaa repoa (host-portti). Jos tällä koneella ei ole polleria, käytä
  `--start-now`.
- Jätä yksittäinen alaissue ajon ulkopuolelle `wip`illä — älä poista siltä `auto-run`ia.

## 3. Keskeytys — `--stop`

`/run-epic #N --stop` keskeyttää käynnissä olevan epicin. Se on **symmetrinen** käynnistyksen
kanssa: sama suunnittele–sovella-jako (kaikki luokittelu ensin, mitään ei kirjoiteta ennen kuin
suunnitelma on koossa; `--dry-run` tulostaa saman suunnitelman kirjoittamatta) ja sama jaettu
lapsijoukon resolvointi. Keskeytys on kaksiosainen:

1. **Elävät lapsiajot** pysäytetään **delegoimalla** `stop-run.sh`:lle (turvakriittistä
   lopetuslogiikkaa ei monisteta). Vieraan koneen ajoa ei kosketa (host-portti), eikä
   terminaalitilan ajoa pakoteta — molemmat raportoidaan ja tekevät exitistä osittaisen (6).
2. **Jonossa olevat** vapautetaan poiminnasta poistamalla ajolabelit **ensin epiciltä, sitten
   avoimilta lapsilta** — toisin päin poller ehtisi propagoida labelit takaisin kesken
   operaation.

Raportti vastaa neljään kysymykseen: mitkä ajot pysäytettiin, mitkä lapset vapautettiin, mitkä
jäivät koskematta ja **miksi** (suljettu / vieras kone / `wip` / terminaalitila), ja jäikö jotain
kesken. Keskeytys **ei siivoa** worktreetä/haaraa/run-diriä — käytä `cleanup-run.sh`ia tai
`auto-clean`-labelia teardowniin. Uudelleenkäynnistys: `--stop` + myöhempi `/run-epic #N`.

```bash
set +e
"$HOME/.claude/scripts/run-issues/run-epic.sh" "$EPIC" --repo "$REPO_ROOT" --stop
RC=$?
set -e
echo "RUN_EPIC_EXIT=$RC"
```
