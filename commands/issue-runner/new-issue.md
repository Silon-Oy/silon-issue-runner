---
argument-hint: "<kuvaus tehtävästä>"
description: Kirjoita vapaamuotoisesta kuvauksesta yhden ajon kokoinen issue, joka täyttää kaikki poimintaehdot — luonnos vahvistetaan ennen kirjoitusta, epicin kokoinen kuvaus vain ehdotetaan eskaloitavaksi.
---

# /issue-runner:new-issue

Muuntaa vapaamuotoisen kuvauksen **ajokelpoiseksi issueksi**: paketin oman rungon mukainen
speksi ja **ne labelit, joilla poller sen poimii**. Tästä eteenpäin ajon tekee poller — tämä
komento **ei aja mitään**.

Komennon arvo ei ole kirjoittamisen nopeuttamisessa. Se on siinä, että poimintaehdot ovat
koodissa, eivät ihmisen muistissa: **jokainen niistä epäonnistuu hiljaa.** Väärin labeloitu
issue näyttää GitHubissa täsmälleen samalta kuin oikein labeloitu, se vain ei koskaan lähde
ajoon eikä mikään kerro miksi.

Sisarkomento on [`/issue-runner:new-epic`](new-epic.md), joka tekee saman kokonaisuudelle: epic, alaissueet,
riippuvuudet. Tämä komento tekee **yhden issuen**.

**Rajaukset, jotka pätevät aina:**

- Komento **luo vain yhden uuden issuen**. Se ei muokkaa eikä sulje olemassa olevia.
- **Ei riippuvuuksia eikä sub-issue-linkkejä.** Ketjut kuuluvat `/issue-runner:new-epic`ille.
- Komento **ei koskaan kirjoita `auto-claimed`-labelia** — se on automaation oma varaus.
- Komento **ei eskaloi epiciksi omin päin.** Se ehdottaa; päätöksen tekee käyttäjä.

## 0. Ilman argumenttia: usage

Argumentti on vapaamuotoinen kuvaus yhdestä tehtävästä. Jos sitä ei ole, tulosta usage äläkä lue
eikä kirjoita mitään:

```
usage: /issue-runner:new-issue <kuvaus tehtävästä>
  esim. /issue-runner:new-issue status.sh näyttää arkistoidut ajot samanlaisina kuin elävät — erottele ne omaan osioonsa.
```

## 1. Resolvoi poimintalabelit (vain lukua)

Kohderepo on **nykyinen työhakemisto**. Labelit resolvoidaan **samalla jaetulla funktiolla, jota
poller käyttää** (`lib/poller-config.sh`), jottei issue voi saada labelia, jota tämän koneen
poller ei koskaan poimi. Älä päättele labelia repon olemassa olevista issueista — vanha issue voi
kantaa labelia, jonka watchlist on sittemmin vaihtanut.

```bash
REPO_ROOT=$(pwd)

. "$HOME/.claude/scripts/run-issues/lib/poller-config.sh"
set +e   # lib asettaa -e:n tuotantokutsujiaan varten

WATCHLIST=$(poller_resolve_watchlist "${RUN_ISSUES_WATCHLIST:-}" \
  "$HOME/.config/run-issues/watchlist.json" \
  "$HOME/dotfiles/machine-studio/run-issues-watchlist.json") || WATCHLIST=""

# Fail-closed: vanhempaan pinniin jäänyt asennus ei tunne jaettua funktiota, ja ilman
# tätä tarkistusta PICK_LABELS jäisi tyhjäksi => labeliton, ei-poimittava issue.
if ! command -v poller_watchlist_pick_labels >/dev/null 2>&1; then
  echo "FAIL: poller_watchlist_pick_labels puuttuu asennuksesta"
  echo "  Ajossa oleva runner on mainia vanhempi. Päivitä ensin:"
  echo "  git -C \"$HOME/.claude/scripts/run-issues\" pull --ff-only && ./install.sh"
  exit 1
fi

PICK_LABELS=$(poller_watchlist_pick_labels "$WATCHLIST" "$REPO_ROOT")
COVERED=$?   # 0 = watchlist kattaa tämän repon, 1 = ei kata (labelit ovat sisäänrakennettu oletus)
set -e

# Tyhjä labelijoukko ei ole koskaan oikea vastaus: jaettu funktio palauttaa aina
# vähintään sisäänrakennetun oletuksen, joten tyhjä tarkoittaa rikkinäistä resolvointia.
[ -n "$PICK_LABELS" ] || { echo "FAIL: poimintalabelit resolvoituivat tyhjiksi — älä luo issueta"; exit 1; }

OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

echo "OWNER_REPO=$OWNER_REPO"
echo "WATCHLIST=${WATCHLIST:-<ei löytynyt>}"
echo "PICK_LABELS=$PICK_LABELS"
echo "WATCHLIST_COVERS_REPO=$COVERED"
```

**Jos jaettu funktio puuttuu, lopeta.** Asennus voi olla pinnattu mainia vanhempaan committiin
(`CLAUDE.md` §3), jolloin funktiota ei ole. Ilman yllä olevaa porttia `PICK_LABELS` jäisi tyhjäksi
ja komento loisi labelittoman issuen, jota poimintahaku ei koskaan palauta — sama hiljainen vika,
jota tämä komento on estämässä, vain omalla aiheuttamana.

**`COVERED=1` on kerrottava käyttäjälle luonnoksessa sanallisesti**, esim.: *"Watchlist ei kata
tätä repoa (tai sitä ei löytynyt), joten poimintalabeliksi tulee sisäänrakennettu oletus
`auto-run`. Tämän koneen poller ei aja tätä repoa — ajon tekee se kone, jonka watchlist kattaa
sen, tai käynnistät sen itse `/issue-runner:run-issue #N`."* Hiljainen oletus on tässä sama vika kuin väärä
label: kummassakin issue ei lähde ajoon eikä mikään kerro miksi.

**Tarkista poimintalabelit ennen luonnosta.** Jos `PICK_LABELS` sisältää jonkin näistä:
`auto-clean`, `waiting`, `wip`, `needs-human`, `auto-claimed`, `epic` — **älä jatka**. Poimintahaku
sulkee ne pois, joten vaadittuna ne tuottavat nolla osumaa ikuisesti. Kerro käyttäjälle, mikä
label on kyseessä ja että watchlistin `labels`/`default_labels` on korjattava ensin.

### 1.1 Jokaisen poimintalabelin on oltava repossa olemassa

```bash
EXISTING=$(gh api "repos/$OWNER_REPO/labels" --paginate --jq '.[].name')

MISSING=()
IFS=',' read -r -a PICK_ARR <<<"$PICK_LABELS"
for l in "${PICK_ARR[@]}"; do
  [ -n "$l" ] || continue
  grep -qxF -- "$l" <<<"$EXISTING" || MISSING+=("$l")
done
printf 'MISSING_LABELS=%s\n' "${MISSING[*]:-<ei yhtään>}"
```

Listaus on **REST:iä tarkoituksella**: `gh`:n GraphQL-yhteys on ollut erikseen estettynä samalla
kun REST vastasi normaalisti (`CLAUDE.md` §5.2).

**Jos yksikin label puuttuu, sano se ääneen luonnoksessa ja tarjoudu luomaan se.** Älä luo issueta
ennen kuin käyttäjä on hyväksynyt labelin luonnin — issue, joka ei koskaan lähde ajoon, on
täsmälleen se hiljainen vika, jota tämä komento on estämässä. Jos käyttäjä ei halua labelia
luotavaksi, **lopeta ilman kirjoituksia** ja kerro miksi.

> **Tämä poikkeaa `/issue-runner:new-epic` §3.4:stä tietoisesti, ei vahingossa.** POST `…/labels` kyllä luo
> puuttuvan labelin itsestään, mutta noin syntyvä label on väriltään ja kuvaukseltaan tyhjä —
> ja mikä tärkeämpää, **kirjoitusvirhe menee läpi hiljaa**: `auto-runn` syntyisi uutena labelina
> eikä mikään erottaisi sitä oikeasta. Eksplisiittinen tarkistus tekee eron näkyväksi.

## 2. Perehdy koodiin ennen kirjoittamista

Lue kuvaus ja **selvitä repon koodista, mitä se koskee**: `README.md`, `CLAUDE.md`,
hakemistorakenne, ja ennen kaikkea ne tiedostot, joihin muutos osuisi. Ilman tätä syntyy issue,
joka näyttää hyvältä ja jonka implementer joutuu arvaamaan — ja arvaus maksaa kokonaisen ajon.

Perehtymisen mitta on yksinkertainen: **hyväksyntäkriteerien pitää pystyä nimeämään oikeat
tiedostot ja funktiot.** Jos et pysty, et ole vielä lukenut tarpeeksi.

Tämä vaihe on **vain lukua**, ja se palvelee myös osiota 3: kokoarvio on uskottava vasta, kun
tiedät mihin muutos koskee.

## 3. Epic-portti: ehdota, älä eskaloi

Arvioi kuvaus **luettuasi koodin**. Kyseessä on epicin kokoinen kokonaisuus, jos jokin näistä
pätee:

- se hajoaa useaksi **itsenäisesti toteutettavaksi** muutokseksi,
- osilla on **aito järjestysriippuvuus** (yksi on tehtävä ennen toista), tai
- **yksi ajo ei saa sitä valmiiksi** — laajuus ylittää yhden implementer-vaiheen budjetin.

Jos mikään ei päde, jatka suoraan osioon 4.

Jos jokin pätee, **kysy `AskUserQuestion`illa** — älä eskaloi itse. Esitä kysymyksessä lyhyt,
konkreettinen perustelu: mihin osiin kuvaus hajoaisi ja miksi ne eivät mahdu yhteen ajoon.
Vaihtoehdot ovat "Tee epic" (delegointi `/issue-runner:new-epic`ille) ja "Tee yksi issue" (jatka osioon 4
kuvatulla rajauksella).

> **Miksi ehdotus eikä automatiikka:** väärä eskalaatio maksaa enemmän kuin yksi kysymys. Tämän
> komennon käyttäjä on juuri se, joka ei huomaa saaneensa väärän kokoista tuotosta — hän kuvasi
> tehtävän omin sanoin, ei speksinä. Yksi kysymys on halpa; kuudeksi issueksi pilkottu kuvaus,
> jota kukaan ei pyytänyt, ei ole.

**Hyväksytty eskalaatio delegoi `/issue-runner:new-epic`ille.** Älä toteuta epic-luontia täällä toista kertaa:
sub-issue-linkit, `blocked_by`-riippuvuudet ja labelointijärjestys ovat `/issue-runner:new-epic`in vastuulla, ja
niiden monistaminen tarkoittaisi kahta toteutusta, jotka ajautuvat erilleen. Kerro käyttäjälle,
että jatko on `/issue-runner:new-epic <sama kuvaus>`, äläkä kirjoita mitään.

## 4. Luonnos — ja vahvistus ennen kirjoitusta

Kirjoita issuen otsikko ja runko. **Runko noudattaa paketin omaa muotoa**, koska implementer lukee
juuri sen — vapaamuotoinen kuvaus ei ole ajokelpoinen speksi:

```markdown
## Tavoite

<yhdellä kappaleella: mitä ja miksi>

## Hyväksyntäkriteerit

- [ ] <tarkistettava, koodiin osuva väite — nimeää tiedoston tai funktion>
- [ ] <…>

## Rajaukset

- <mitä tämä issue ei tee>
```

Otsikko kertoo lopputuloksen, ei toiminnan: *"status.sh erottelee arkistoidut ajot omaan
osioonsa"*, ei *"korjaa status.sh"*.

**Esitä luonnos käyttäjälle kokonaisuudessaan ja pyydä vahvistus.** Luonnoksessa näkyvät otsikko,
runko, labelit — sekä osion 1 watchlist-huomio, jos `COVERED=1`, ja osion 1.1 puuttuvat labelit,
jos niitä on.

> **Ei vahvistusta ⇒ nolla kirjoitusta.** Sama suunnittele–sovella-jako kuin `install.sh`:ssa ja
> `run-epic.sh`:ssa. Jos käyttäjä haluaa muutoksia, korjaa luonnos ja kysy uudelleen.

### 4.1 Kielimäärittely — kysy, jos projektin `CLAUDE.md` ei sitä anna

Ajo kirjoittaa ihmiselle näkyvää tekstiä: PR-kuvauksen, issue-kommentteja, dokumentaatiota.
**Runner ei väitä niiden kieltä** — sen määrittelee kohderepo itse. Kysymys kuuluu tähän
hetkeen, koska tämä on ainoa kohta koko ketjussa, jossa ihminen on varmasti paikalla.

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
näkyvän tekstin kieli*. **Älä keksi tähän toista muotoa** — kaksi käsitystä siitä, mikä on
määrittely, on sama kahdentuma kuin kaksi toteutusta samasta funktiosta.

**`LANG_DECL=1` ⇒ älä kysy äläkä muokkaa mitään.** Jatka osioon 5.

**`LANG_DECL=0` ⇒ kysy `AskUserQuestion`illa** ennen kuin luot issueta. Yksi kysymys, ei yhtä per
pinta. Tee kysymyksessä ero näkyväksi: koodi, koodikommentit ja commit-viestit ovat jo
englanniksi koodausstandardin nojalla, joten kysymys koskee **ihmiselle näkyviä pintoja** —
PR-kuvaukset, issue-kommentit, dokumentaatio ja suunnitelmat.

**Älä tarjoa mitään kieltä valmiiksi valittuna.** Repon olemassa oleva teksti kelpaa
havainnoksi (*"repon dokumentaatio on tällä hetkellä kielellä X"*), ei oletusarvoksi: oikeaan
osunut oletus on sattuma eikä johdos, ja sattuma menee läpi hiljaa.

Kokoa vastauksesta valmis lisäys ja **näytä se osion 4 luonnoksen yhteydessä** samassa
vahvistuksessa kuin issue. Tämä on ainoa kohta, jossa tämä komento koskee kohderepon
työpuuhun, joten se ei saa tapahtua näkymättömissä:

```markdown
## Languages

- Code and comments: English
- Commit messages: English
- PR descriptions: <vastaus>
- Issue comments: <vastaus>
- Documentation: <vastaus>
- Plans: <vastaus>
```

> **Komento ei committaa.** Se lisää lohkon `CLAUDE.md`-tiedoston loppuun ja jättää muutoksen
> työpuuhun, kuten muunkin tuotoksensa. Committaaminen on käyttäjän päätös.

Sisarkomento [`/issue-runner:new-epic`](new-epic.md) tekee saman kokonaisuudelle osiossaan 2.1 — yksi kysymys
kattaa siellä koko ketjun.

## 5. Kirjoita — kaikki kuusi poimintaehtoa yhdellä kutsulla

Poimintaehdot ovat `lib/issue.sh`:n `pick_oldest_candidate` ja `_pick_filter_jq`. Luotavan issuen
on täytettävä **kaikki kuusi**:

| # | Ehto | Miten se täyttyy |
|---|---|---|
| 1 | Issuella on **jokainen** `PICK_LABELS`in label | osion 1 lista, kaikki kerralla — REST `labels=` on **JA**, ei TAI |
| 2 | ei `wip`-labelia | ei lisätä |
| 3 | ei `waiting`-labelia | ei lisätä |
| 4 | ei `epic`-labelia | ei lisätä — epic ei ole ajettava |
| 5 | ei `auto-clean`-labelia | ei lisätä — se on purkusignaali |
| 6 | ei `auto-claimed`-labelia | ei lisätä — se on automaation oma varaus |

Kolme ehtoa täyttyy rakenteellisesti eikä niitä tarvitse tarkistaa: issue on `open`, se ei ole PR,
eikä sillä ole avoimia `blocked_by`-estäjiä, koska tämä komento ei luo riippuvuuksia.

Jos osio 4.1 tuotti kielimäärittelyn, **kirjoita se ensin** kohderepon `CLAUDE.md`:hen. Sen
jälkeen syntyvä issue on jo sellainen, jonka ajo lukee määrittelyn — päinvastaisessa
järjestyksessä poller voi ehtiä väliin.

Jos osio 1.1 löysi puuttuvia labeleita **ja** käyttäjä hyväksyi niiden luonnin, luo ne ensin —
muuten issue syntyisi labelilla, jota ei ole:

```bash
for l in "${MISSING[@]}"; do
  gh api --method POST "repos/$OWNER_REPO/labels" -f "name=$l" -f 'color=ededed' \
    -f 'description=run-issues pickup label' >/dev/null \
    && echo "label luotu: $l" \
    || { echo "FAIL: labelin '$l' luonti epäonnistui — issueta ei luoda"; exit 1; }
done
```

Labelin luonnin epäonnistuminen **lopettaa ajon**: issue ilman poimintalabelia ei koskaan lähde
ajoon.

Issue luodaan **yhdellä kutsulla, labelit mukana samassa payloadissa**:

```bash
BODY_FILE=$(mktemp)   # runko tiedostoon, jotta markdown, rivinvaihdot ja backtickit säilyvät

LABELS_JSON=$(jq -cn --arg csv "$PICK_LABELS" \
  '$csv | split(",") | map(select(length > 0))')

jq -n --arg t "$ISSUE_TITLE" --rawfile b "$BODY_FILE" --argjson l "$LABELS_JSON" \
     '{title: $t, body: $b, labels: $l}' \
  | gh api "repos/$OWNER_REPO/issues" --input - --jq '.number'
```

**Yksi kutsu, ei kahta.** Erillinen labelointikutsu jättäisi epäonnistuessaan jälkeensä issuen,
joka ei koskaan lähde ajoon — täsmälleen se hiljainen vika, jonka estämiseksi tämä komento on
olemassa. Yhdellä kutsulla lopputulos on joko poimittava issue tai ei issueta lainkaan.

## 6. Raportoi — ja kerro mitä tapahtuu seuraavaksi

Tulosta aina, myös epäonnistumisessa:

| Kohta | Mitä raportoidaan |
|---|---|
| Issue | numero + URL + otsikko |
| Labelit | mitkä lisättiin |
| Luodut labelit | jos osio 5 loi puuttuvia labeleita, mitkä |
| Watchlist | osion 1 huomio, jos `COVERED=1` |
| Kielimäärittely | kirjattiinko se `CLAUDE.md`:hen (osio 4.1) — ja että muutos on committaamatta |

Jos kirjoitus epäonnistui, kerro **komento, jolla ihminen tekee sen käsin** — yllä oleva `gh api`
-kutsu kelpaa sellaisenaan. Lopuksi:

> **Mitään ei ole käynnistetty, eikä tätä istuntoa tarvitse jäädä odottamaan.** Ajon tekee poller
> seuraavalla tikillä (jos tämän koneen watchlist kattaa repon), omassa worktreessään ja omassa
> istunnossaan. Tilan näkee `status.sh`:lla. Jos haluat käynnistää sen heti itse:
> `/issue-runner:run-issue #<numero>`.
