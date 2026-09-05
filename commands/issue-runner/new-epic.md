---
argument-hint: "<kuvaus kokonaisuudesta>"
description: Pilko kokonaisuus epiciksi ja alaissueiksi — luo issuet, linkitä ne sub-issueiksi, merkitse riippuvuudet ja labeloi epic ajoon. Suunnitelma vahvistetaan ennen ensimmäistäkään kirjoitusta.
---

# /issue-runner:new-epic

Muuntaa vapaamuotoisen kuvauksen **ajokelpoiseksi epiciksi**: yksi epic-issue, sen alaissueet,
natiivit sub-issue-linkit, `blocked_by`-riippuvuudet ja lopuksi ajolabelit **vain epicille**.
Tästä eteenpäin ketjun ajaa poller tai `/issue-runner:run-epic` — tämä komento **ei aja mitään**.

Sisarkomento on [`/issue-runner:run-epic`](run-epic.md), joka käynnistää jo olemassa olevan epicin. Epic-koneisto
kokonaisuudessaan: [`docs/epic-orchestration.md`](../../docs/epic-orchestration.md).

**Rajaukset, jotka pätevät aina:**

- Komento **luo vain uusia issueita**. Se ei muokkaa eikä sulje olemassa olevia.
- **Ei cross-repo-epicejä.** Kaikki lapset syntyvät samaan repoon kuin epic. (Lukupuoli tukee
  cross-repoa, luonti ei.)
- Komento **ei koskaan kirjoita `auto-claimed`-labelia** — se on automaation oma varaus.
- **Assignee ei ole valinta.** Sekä epic että jokainen alaissue assignataan sille tunnukselle,
  jolla `gh` on autentikoitu; vaihtaminen tapahtuu jälkikäteen GitHubissa.

## 0. Ilman argumenttia: usage

Argumentti on vapaamuotoinen kuvaus kokonaisuudesta. Jos sitä ei ole, tulosta usage äläkä lue
eikä kirjoita mitään:

```
usage: /issue-runner:new-epic <kuvaus kokonaisuudesta>
  esim. /issue-runner:new-epic Statussivulle kirjautuminen: Tailscale-tunnistus, sessioevästeet ja audit-loki.
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

# Assignee = se tunnus, jolla gh on autentikoitu. Paljas gh tarkoituksella:
# App-identiteetti palauttaisi Appin, eivätkä GitHub Appit voi olla assigneita.
RUNNER_LOGIN=$(gh api user --jq .login 2>/dev/null) || RUNNER_LOGIN=""

# Tyhjä tunnus => kenttä jätetään pois payloadista, ei lähetetä tyhjää listaa.
ASSIGNEES_JSON=$(jq -cn --arg login "${RUNNER_LOGIN:-}" \
  'if ($login | length) > 0 then [$login] else [] end')

echo "OWNER_REPO=$OWNER_REPO"
echo "WATCHLIST=${WATCHLIST:-<ei löytynyt>}"
echo "PICK_LABELS=$PICK_LABELS"
echo "WATCHLIST_COVERS_REPO=$COVERED"
echo "RUNNER_LOGIN=${RUNNER_LOGIN:-<ei tunnusta>}"
```

**`COVERED=1` on kerrottava käyttäjälle suunnitelmassa sanallisesti**, esim.: *"Watchlist ei kata
tätä repoa (tai sitä ei löytynyt), joten poimintalabeliksi tulee sisäänrakennettu oletus
`auto-run`. Tämän koneen poller ei aja tätä repoa — ketjun ajaa se kone, jonka watchlist kattaa
sen, tai käynnistät sen itse `/issue-runner:run-epic #N --start-now`."* Hiljainen oletus on tässä sama vika
kuin väärä label: molemmissa issue ei lähde ajoon eikä mikään kerro miksi.

**Tarkista poimintalabelit ennen suunnitelmaa.** Jos `PICK_LABELS` sisältää jonkin näistä:
`auto-clean`, `waiting`, `wip`, `needs-human`, `auto-claimed` — **älä jatka**. Poimintahaku
sulkee ne pois, joten vaadittuna ne tuottavat nolla osumaa ikuisesti. Kerro käyttäjälle, mikä
label on kyseessä ja että watchlistin `labels`/`default_labels` on korjattava ensin.

**Tunnus haetaan kerran, tässä** — sekä epic että jokainen alaissue saa saman assigneen osion 3
jaetun `create_issue`n kautta. Kutsu on **paljas `gh`** eikä kulje `gha_with_token`in kautta
samasta syystä kuin `verify_claim`in oma `gh api user` -lookup (`lib/issue.sh`): GitHub App ei
voi olla issuen assignee.

**Tyhjä tunnus ei ole este.** Jos `gh api user` epäonnistuu, issuet luodaan ilman assigneeta ja
osion 4 raportti **sanoo sen ääneen**. Hiljaa pudotettu assignee on juuri se vika, jota nämä
komennot ovat estämässä.

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
  syklinen** (`/issue-runner:run-epic` kieltäytyy syklistä exit-koodilla 4).
- **Labelit:** epicille `epic` + `PICK_LABELS`. **Lapsille ei mitään** — poller propagoi
  ajolabelit epicin avoimille lapsille.

**Esitä suunnitelma käyttäjälle kokonaisuudessaan ja pyydä vahvistus.** Suunnitelmassa näkyvät
epicin otsikko ja runko, jokaisen alaissueen otsikko ja runko, riippuvuudet (`"B odottaa A:ta"`)
ja labelit — sekä osion 1 watchlist-huomio, jos `COVERED=1`.

> **Ei vahvistusta ⇒ nolla kirjoitusta.** Sama suunnittele–sovella-jako kuin `install.sh`:ssa ja
> `run-epic.sh`:ssa. Jos käyttäjä haluaa muutoksia, korjaa suunnitelma ja kysy uudelleen.

### 2.1 Kielimäärittely — kysy, jos projektin `CLAUDE.md` ei sitä anna

Ketjun jokainen ajo kirjoittaa ihmiselle näkyvää tekstiä: PR-kuvauksia, issue-kommentteja,
dokumentaatiota. **Runner ei väitä niiden kieltä** — sen määrittelee kohderepo itse. Kysymys
kuuluu tähän hetkeen, koska tämä on ainoa kohta koko ketjussa, jossa ihminen on varmasti
paikalla; epicin kohdalla yksi kysymys kattaa kaikki alaissueet.

```bash
LANG_DECL=1
# Kohderepon juuri on työhakemisto (osio 1). Luetaan se tässä uudelleen eikä
# osion muuttujasta: tyhjäksi jäänyt polku ohittaisi määrittelyn hiljaa ja
# kysyisi kielet repolta, joka on ne jo kirjannut.
grep -qiE '^#{1,6}[^#]*languages' "$(pwd)/CLAUDE.md" 2>/dev/null || LANG_DECL=0
echo "LANGUAGE_DECLARATION=$LANG_DECL"
```

Tunnistuskuvio on sama kuin orkestraattorin `repo_declares_languages`illa, ja muoto on
dokumentoitu kertaalleen: [`principles/coding.md`](../../principles/coding.md), luku *Ihmiselle
näkyvän tekstin kieli*. **Älä keksi tähän toista muotoa.**

**`LANG_DECL=1` ⇒ älä kysy äläkä muokkaa mitään.** Jatka osioon 3.

**`LANG_DECL=0` ⇒ kysy `AskUserQuestion`illa** ennen ensimmäistäkään kirjoitusta. Yksi kysymys,
ei yhtä per pinta. Koodi, koodikommentit ja commit-viestit ovat jo englanniksi koodausstandardin
nojalla, joten kysymys koskee **ihmiselle näkyviä pintoja** — PR-kuvaukset, issue-kommentit,
dokumentaatio ja suunnitelmat. **Älä tarjoa mitään kieltä valmiiksi valittuna**; repon olemassa
oleva teksti kelpaa havainnoksi, ei oletusarvoksi.

Kokoa vastauksesta valmis lisäys ja **näytä se osion 2 suunnitelman yhteydessä** samassa
vahvistuksessa kuin epic ja sen lapset:

```markdown
## Languages

- Code and comments: English
- Commit messages: English
- PR descriptions: <vastaus>
- Issue comments: <vastaus>
- Documentation: <vastaus>
- Plans: <vastaus>
```

Vahvistuksen jälkeen **lohko kirjoitetaan kohderepon `CLAUDE.md`:hen ennen osion 3 ensimmäistä
kirjoitusta**, jotta ketju on määritelty jo silloin kun poller voi poimia sen. Komento **ei
committaa**: muutos jää työpuuhun, kuten muukin sen tuotos.

Sisarkomento [`/issue-runner:new-issue`](new-issue.md) tekee saman yhdelle issuelle osiossaan 4.1.

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

# Luo yksi issue ja tulosta "<numero> <id> <assigneet>". Runko tulee tiedostosta,
# jotta markdown, rivinvaihdot ja backtickit säilyvät koskemattomina. Assignee
# menee samaan payloadiin (osio 1): yksi kutsu per issue, ei erillistä
# assignauskutsua, joka epäonnistuessaan jättäisi issuen ilman assigneeta.
create_issue() {   # <otsikko> <runkotiedosto>
  jq -n --arg t "$1" --rawfile b "$2" --argjson a "$ASSIGNEES_JSON" \
    '{title: $t, body: $b} + (if ($a | length) > 0 then {assignees: $a} else {} end)' \
    | gh api "repos/$OWNER_REPO/issues" --input - \
        --jq '[.number, .id, ([.assignees[].login] | join(","))] | @tsv'
}
```

**Assignee luetaan vastauksesta, ei oleteta.** GitHub **pudottaa hiljaa** assigneen, jolla ei ole
repoon kirjoitusoikeutta: kutsu onnistuu, mutta issue jää assignaamatta. Sama funktio palauttaa
siis todellisen assignee-joukon, ja se kirjataan `$LEDGER`iin muun tuotoksen tapaan.

### 3.0 Epic-issue (ilman labeleita)

```bash
EPIC_LINE=$(create_issue "$EPIC_TITLE" "$EPIC_BODY_FILE") \
  || { echo "FAIL: epicin luonti epäonnistui — mitään ei ole vielä kirjoitettu"; exit 1; }
IFS=$'\t' read -r EPIC_NUM EPIC_ID EPIC_ASSIGNEES <<<"$EPIC_LINE"   # erotin on tabi, ei väli
echo "epic #$EPIC_NUM (id $EPIC_ID) luotu, assignee: ${EPIC_ASSIGNEES:-<ei yhtään>}" \
  | tee -a "$LEDGER"
```

Jos epicin luonti epäonnistuu, **lopeta heti** — mitään ei ole vielä kirjoitettu, joten tila on
puhdas.

### 3.1 Alaissueet

Luo jokainen lapsi samalla `create_issue`lla ja kirjaa numero + id + assignee. Yhden lapsen
epäonnistuminen
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
Raportoi tilanne ja kerro, että labeloinnin voi tehdä `/issue-runner:run-epic #N`illä sen jälkeen, kun
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
| Assignee | kenelle epic ja lapset assignattiin — tai **että ne jäivät assignaamatta ja miksi** |
| Labelit | lisättiinkö ja mitkä — vai jätettiinkö tarkoituksella lisäämättä (3.3) |
| Watchlist | osion 1 huomio, jos `COVERED=1` |
| Kielimäärittely | kirjattiinko se `CLAUDE.md`:hen (osio 2.1) — ja että muutos on committaamatta |

**Assignaamatta jäänyt issue on kerrottava ääneen, ei ohitettava.** Kaksi syytä johtaa samaan
lopputulokseen: tunnusta ei saatu (osio 1) tai GitHub pudotti sen oikeuksien puutteessa (osio 3).
Kumpikaan ei estä ketjun ajoa tänään, mutta reititys jää näkymättömäksi eikä siirrettäväksi, ja
sen huomaa vain tästä raportista.

**Assignee on reitityksen kahva.** Ajokoneen watchlist voi rajata poiminnan nimetyille
tunnuksille, ja silloin issuen assigneen vaihtaminen siirtää työn sille koneelle, jonka watchlist
tuon tunnuksen nimeää — vaihto tehdään GitHubin käyttöliittymästä, ei tällä komennolla. Ilman
tuota rajausta assignee on merkintä, joka ei vielä ohjaa poimintaa: poimintahaku suodattaa
labeleilla eikä assigneella (`lib/issue.sh`, `_pick_filter_jq`).

Jokaisesta epäonnistuneesta kirjoituksesta kerrotaan **komento, jolla ihminen tekee sen käsin** —
yllä olevat `gh api` -kutsut kelpaavat sellaisenaan. Lopuksi:

> **Mitään ei ole käynnistetty.** Ajon tekee poller seuraavalla tikillä (jos tämän koneen
> watchlist kattaa repon) tai ihminen komennolla `/issue-runner:run-epic #<epic>`. Ketjun voi tarkistaa
> etukäteen: `/issue-runner:run-epic #<epic> --dry-run`.
