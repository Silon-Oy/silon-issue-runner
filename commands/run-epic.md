---
argument-hint: [#N] [--dry-run] [--start-now]
description: Käynnistä koko epic yhdellä komennolla — validoi rakenteen, propagoi ajolabelit alaissueille ja raportoi ketjun tilan.
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
- `--remote <nimi>` / `--labels <csv>` — monirepo- ja monilabel-tapauksiin (oletus `origin`,
  `auto-run`).

## 2. Toimi exit-koodin mukaan

| RC | Mitä tarkoittaa | Mitä tee |
|---|---|---|
| 0 | Validoitu + propagoitu (tai `--dry-run` tulosti suunnitelman) | Tulosta raportti. Kerro käyttäjälle mikä alaissue ajaa ensin ja että poller vie ketjun eteenpäin. |
| 1 | Käyttövirhe (tuntematon lippu / puuttuva tai epäkelpo epic-numero) | Tulosta virheviesti. |
| 2 | Epic-issueta ei löytynyt tai se ei ole avoin | Kerro käyttäjälle — tarkista numero ja tila. |
| 3 | Epic ilman alaissueita | Kerro että epiciin pitää lisätä alaissueet (natiivit tai task-lista) ennen ajoa. |
| 4 | Syklinen `blocked_by`-graafi alaissueiden välillä | Tulosta virheviesti **sellaisenaan** — se nimeää sykliin osallistuvat issuet. Käyttäjän on purettava sykli. |
| 5 | Riippuvuusgraafia ei saatu luettua (fail-closed) | GitHub-lukuvirhe — yritä uudelleen tai tarkista `gh`-yhteys. |

## Huomioita

- **Kirjoitukset tehdään vasta validoinnin jälkeen** (suunnittele–sovella, kuten `install.sh`):
  yksikin validointivirhe ⇒ nolla muutosta.
- Jos epiciltä puuttuu `epic`-label, komento **lisää sen** — komennolla voi siis muuntaa
  kokoavan issuen epiciksi (`--dry-run` ei lisää).
- **GitHub-tila on globaali**, joten labelointi toimii miltä koneelta tahansa; ketjun ajaa se
  kone, jonka poller pollaa repoa (host-portti). Jos tällä koneella ei ole polleria, käytä
  `--start-now`.
- Jätä yksittäinen alaissue ajon ulkopuolelle `wip`illä — älä poista siltä `auto-run`ia.
- Keskeytys ja `--stop` eivät ole vielä toteutettuja; pysäytä yksittäinen ajo `stop-run.sh`:llä
  ja poista `auto-run` epiciltä + jonossa olevilta lapsilta käsin.
