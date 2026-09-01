---
argument-hint: "<kuvaus kokonaisuudesta>"
description: Pilko kokonaisuus epiciksi ja alaissueiksi — luo issuet, linkitä ne sub-issueiksi, merkitse riippuvuudet ja labeloi epic ajoon. Suunnitelma vahvistetaan ennen ensimmäistäkään kirjoitusta.
---

# /new-epic

Muuntaa vapaamuotoisen kuvauksen **ajokelpoiseksi epiciksi**: yksi epic-issue, sen alaissueet,
natiivit sub-issue-linkit, `blocked_by`-riippuvuudet ja lopuksi ajolabelit **vain epicille**.
Tästä eteenpäin ketjun ajaa poller tai `/run-epic` — tämä komento **ei aja mitään**.

Sisarkomento on [`/run-epic`](run-epic.md), joka käynnistää jo olemassa olevan epicin. Epic-koneisto
kokonaisuudessaan: [`docs/epic-orchestration.md`](../docs/epic-orchestration.md).

**Rajaukset, jotka pätevät aina:**

- Komento **luo vain uusia issueita**. Se ei muokkaa eikä sulje olemassa olevia.
- **Ei cross-repo-epicejä.** Kaikki lapset syntyvät samaan repoon kuin epic. (Lukupuoli tukee
  cross-repoa, luonti ei.)
- Komento **ei koskaan kirjoita `auto-claimed`-labelia** — se on automaation oma varaus.

## 0. Ilman argumenttia: usage

Argumentti on vapaamuotoinen kuvaus kokonaisuudesta. Jos sitä ei ole, tulosta usage äläkä lue
eikä kirjoita mitään:

```
usage: /new-epic <kuvaus kokonaisuudesta>
  esim. /new-epic Statussivulle kirjautuminen: Tailscale-tunnistus, sessioevästeet ja audit-loki.
```

## 1. Resolvoi konteksti (vain lukua)

Kohderepo on **nykyinen työhakemisto**. Poimintalabelit resolvoidaan **samalla jaetulla
funktiolla, jota poller käyttää** (`lib/poller-config.sh`), jottei epic voi saada labelia, jota
tämän koneen poller ei koskaan poimi.

```bash
REPO_ROOT=$(pwd)

. "$HOME/.claude/scripts/run-issues/lib/poller-config.sh"
set +e   # lib asettaa -e:n tuotantokutsujiaan varten

WATCHLIST=$(poller_resolve_watchlist "${RUN_ISSUES_WATCHLIST:-}" \
  "$HOME/.config/run-issues/watchlist.json" \
  "$HOME/dotfiles/machine-studio/run-issues-watchlist.json") || WATCHLIST=""

PICK_LABELS=$(poller_watchlist_pick_labels "$WATCHLIST" "$REPO_ROOT")
COVERED=$?   # 0 = watchlist kattaa tämän repon, 1 = ei kata (labelit ovat sisäänrakennettu oletus)
set -e

OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

echo "OWNER_REPO=$OWNER_REPO"
echo "WATCHLIST=${WATCHLIST:-<ei löytynyt>}"
echo "PICK_LABELS=$PICK_LABELS"
echo "WATCHLIST_COVERS_REPO=$COVERED"
```

**`COVERED=1` on kerrottava käyttäjälle suunnitelmassa sanallisesti**, esim.: *"Watchlist ei kata
tätä repoa (tai sitä ei löytynyt), joten poimintalabeliksi tulee sisäänrakennettu oletus
`auto-run`. Tämän koneen poller ei aja tätä repoa — ketjun ajaa se kone, jonka watchlist kattaa
sen, tai käynnistät sen itse `/run-epic #N --start-now`."* Hiljainen oletus on tässä sama vika
kuin väärä label: molemmissa issue ei lähde ajoon eikä mikään kerro miksi.

**Tarkista poimintalabelit ennen suunnitelmaa.** Jos `PICK_LABELS` sisältää jonkin näistä:
`auto-clean`, `waiting`, `wip`, `needs-human`, `auto-claimed` — **älä jatka**. Poimintahaku
sulkee ne pois, joten vaadittuna ne tuottavat nolla osumaa ikuisesti. Kerro käyttäjälle, mikä
label on kyseessä ja että watchlistin `labels`/`default_labels` on korjattava ensin.

## 2. Pilko kokonaisuus — suunnitelma

Lue kuvaus ja perehdy repoon sen verran, että pilkkominen osuu todelliseen koodiin (`README.md`,
`CLAUDE.md`, hakemistorakenne). Muodosta:

- **Epic:** otsikko ja runko. Runko kertoo mitä kokonaisuus on, miksi se tehdään ja listaa lapset.
  Epic **ei ole ajettava** — sen "toteutus" on alaissueiden toteutus, joten sen runkoon ei
  kirjoiteta hyväksyntäkriteerejä toteutettavaksi.
- **Alaissueet:** kukin **itsenäisesti toteutettava** ja niin rajattu, että yksi ajo saa sen
  valmiiksi. Jokaisen runko noudattaa paketin omaa muotoa, koska implementer lukee juuri sen:

  ```markdown
  ## Tavoite

  <yhdellä kappaleella: mitä ja miksi; maininta epicistä, jonka osa tämä on>

  ## Hyväksyntäkriteerit

  - [ ] <tarkistettava, koodiin osuva väite>
  - [ ] <…>

  ## Rajaukset

  - <mitä tämä issue ei tee — mihin toiseen alaissueeseen se kuuluu>
  ```

- **Riippuvuudet:** mitkä lapset ovat `blocked_by` mihinkin lapseen. Vain aitoja
  järjestysriippuvuuksia — löysä ketjutus jonottaa ajot turhaan sarjaan. **Graafi ei saa olla
  syklinen** (`/run-epic` kieltäytyy syklistä exit-koodilla 4).
- **Labelit:** epicille `epic` + `PICK_LABELS`. **Lapsille ei mitään** — poller propagoi
  ajolabelit epicin avoimille lapsille.

**Esitä suunnitelma käyttäjälle kokonaisuudessaan ja pyydä vahvistus.** Suunnitelmassa näkyvät
epicin otsikko ja runko, jokaisen alaissueen otsikko ja runko, riippuvuudet (`"B odottaa A:ta"`)
ja labelit — sekä osion 1 watchlist-huomio, jos `COVERED=1`.

> **Ei vahvistusta ⇒ nolla kirjoitusta.** Sama suunnittele–sovella-jako kuin `install.sh`:ssa ja
> `run-epic.sh`:ssa. Jos käyttäjä haluaa muutoksia, korjaa suunnitelma ja kysy uudelleen.

## 3. Kirjoita — järjestys on ehdoton

Poller tikkaa minuuttien välein ja propagoi epicin ajolabelit sen avoimille lapsille. Jos
ajolabeli osuisi epicille ennen kuin riippuvuudet on merkitty, poller päästäisi ketjun ajoon
**väärässä järjestyksessä** — eikä sitä saisi jälkikäteen kiinni, koska S2b torjuu vain sen, mikä
on jo merkitty estetyksi. Siksi:

1. luo alaissueet (**ilman poimintalabeleita**),
2. linkitä ne epicin sub-issueiksi,
3. merkitse `blocked_by`-riippuvuudet,
4. lisää `epic`- ja poimintalabelit **viimeisenä, vain epicille**.

Epic itse luodaan ensin (ilman labeleita), jotta lapset voi linkittää siihen. Ilman `epic`-labelia
ja ilman ajolabelia se ei ole poimittavissa, joten se saa odottaa vaiheeseen 4 asti.

**Molemmat kirjoitusrajapinnat vaativat issuen `id`:n, eivät numeroa.** Siksi issuet luodaan
`gh api`lla `gh issue create`n sijaan: sama kutsu palauttaa numeron ja id:n, eikä id:tä tarvitse
hakea erikseen.

**Pidä kirjaa jokaisesta onnistuneesta kirjoituksesta sitä mukaa kun se tapahtuu** (`$LEDGER`).
Se on osion 4 raportin ainoa lähde.

```bash
LEDGER=$(mktemp)
echo "LEDGER=$LEDGER"

# Luo yksi issue ja tulosta "<numero> <id>". Runko tulee tiedostosta, jotta
# markdown, rivinvaihdot ja backtickit säilyvät koskemattomina.
create_issue() {   # <otsikko> <runkotiedosto>
  jq -n --arg t "$1" --rawfile b "$2" '{title: $t, body: $b}' \
    | gh api "repos/$OWNER_REPO/issues" --input - --jq '[.number, .id] | @tsv'
}
```

### 3.0 Epic-issue (ilman labeleita)

```bash
EPIC_LINE=$(create_issue "$EPIC_TITLE" "$EPIC_BODY_FILE") \
  || { echo "FAIL: epicin luonti epäonnistui — mitään ei ole vielä kirjoitettu"; exit 1; }
IFS=$'\t' read -r EPIC_NUM EPIC_ID <<<"$EPIC_LINE"   # erotin on tabi, ei väli
echo "epic #$EPIC_NUM (id $EPIC_ID) luotu" | tee -a "$LEDGER"
```

Jos epicin luonti epäonnistuu, **lopeta heti** — mitään ei ole vielä kirjoitettu, joten tila on
puhdas.

### 3.1 Alaissueet

Luo jokainen lapsi samalla `create_issue`lla ja kirjaa numero + id. Yhden lapsen epäonnistuminen
**ei** lopeta ajoa: jatka lopuilla ja raportoi puuttuvat osiossa 4 — puolivalmis epic, josta ei
kerrota, on tämän komennon pahin vikatila.

### 3.2 Sub-issue-linkitys

```bash
gh api --method POST "repos/$OWNER_REPO/issues/$EPIC_NUM/sub_issues" \
  -F sub_issue_id="$CHILD_ID" >/dev/null \
  && echo "sub-issue: #$CHILD_NUM -> epic #$EPIC_NUM" | tee -a "$LEDGER" \
  || echo "FAIL sub-issue: #$CHILD_NUM -> epic #$EPIC_NUM"
```

`-F` (ei `-f`) pitää arvon lukuna. Kenttä on **`sub_issue_id` eli issuen `id`**, ei numero.

### 3.3 Riippuvuudet

Merkitään **estetylle** issuelle, ja kentässä on **estäjän `id`**:

```bash
gh api --method POST "repos/$OWNER_REPO/issues/$BLOCKED_NUM/dependencies/blocked_by" \
  -F issue_id="$BLOCKER_ID" >/dev/null \
  && echo "blocked_by: #$BLOCKED_NUM odottaa #$BLOCKER_NUM" | tee -a "$LEDGER" \
  || echo "FAIL blocked_by: #$BLOCKED_NUM odottaa #$BLOCKER_NUM"
```

**Jos yksikin riippuvuus epäonnistuu, älä labeloi epiciä vaiheessa 4.** Labelointi käynnistäisi
ketjun, jonka järjestys on osittain merkitsemättä — juuri se, mitä järjestyksellä estetään.
Raportoi tilanne ja kerro, että labeloinnin voi tehdä `/run-epic #N`illä sen jälkeen, kun
puuttuva riippuvuus on merkitty käsin.

### 3.4 Labelit — viimeisenä, vain epicille

Yksi kutsu, `epic` ensin: jos labelit jaettaisiin kahteen kutsuun ja ajolabeli menisi ensin,
poller voisi väliaikana poimia epicin tavallisena issuena ja polttaa koko timeout-budjetin
tehtävään, jota ei ole.

```bash
LABEL_ARGS=(-f 'labels[]=epic')
IFS=',' read -r -a PICK_ARR <<<"$PICK_LABELS"
for l in "${PICK_ARR[@]}"; do [ -n "$l" ] && LABEL_ARGS+=(-f "labels[]=$l"); done

gh api --method POST "repos/$OWNER_REPO/issues/$EPIC_NUM/labels" "${LABEL_ARGS[@]}" >/dev/null \
  && echo "labelit epicille #$EPIC_NUM: epic,$PICK_LABELS" | tee -a "$LEDGER" \
  || echo "FAIL labelit epicille #$EPIC_NUM"
```

Puuttuva label syntyy GitHubissa automaattisesti. **Lapsille ei lisätä labeleita** missään
vaiheessa.

## 4. Raportoi — myös kun jokin meni pieleen

Tulosta aina, myös osittaisessa epäonnistumisessa, sillä tarkkuudella että ihminen voi jatkaa
käsin:

| Kohta | Mitä raportoidaan |
|---|---|
| Epic | numero + URL |
| Alaissueet | mitkä syntyivät (numero + otsikko) ja **mitkä eivät** |
| Sub-issue-linkit | mitkä kirjautuivat ja mitkä eivät |
| Riippuvuudet | mitkä kirjautuivat ja mitkä eivät |
| Labelit | lisättiinkö ja mitkä — vai jätettiinkö tarkoituksella lisäämättä (3.3) |
| Watchlist | osion 1 huomio, jos `COVERED=1` |

Jokaisesta epäonnistuneesta kirjoituksesta kerrotaan **komento, jolla ihminen tekee sen käsin** —
yllä olevat `gh api` -kutsut kelpaavat sellaisenaan. Lopuksi:

> **Mitään ei ole käynnistetty.** Ajon tekee poller seuraavalla tikillä (jos tämän koneen
> watchlist kattaa repon) tai ihminen komennolla `/run-epic #<epic>`. Ketjun voi tarkistaa
> etukäteen: `/run-epic #<epic> --dry-run`.
