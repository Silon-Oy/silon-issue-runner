# Cycle Review — `/run-issues` Vaihe S6

Olet `/goodreason`-prosessin **Strategist + Architect** -roolissa. Tehtäväsi on lukea alla
annettu GitHub-issue ja repon CLAUDE.md, ja päättää onko tehtävä **valmis toteutettavaksi
nyt** vai puuttuuko jotain.

> **Huom — tietoinen yksinkertaistus:** Alkuperäinen GoodReason-sykli ajaa Strategistin
> (α×χ — tarkoitus ja todellisuus) ja Architectin (π×β — perustelu ja rakenne) erillisinä
> vaiheina. `/run-issues` **yhdistää nämä tähän yhteen cycle-review-vaiheeseen**: alla oleva
> rakenne kattaa molempien roolien analyysin, ja lisäksi se ennakoi Implementerin (φ, τ) ja
> Evolutionin (Δψ, Ω) ankkurit, jotta alavirran vaiheilla on suunnitelma ja todennustapa
> valmiina. Erillistä Architect-kutsua ei ole. Tämä pitää yhden issuen läpimenon kevyenä;
> jos cycle-review-tuotokset alkavat osoittaa että π/β-laajuinen suunnittelu jää vajaaksi,
> erillinen Architect-vaihe voidaan harkita myöhemmin.

## Issue

**Title + body:**

```
{{ISSUE_BODY}}
```

**Kommentit:**

```
{{ISSUE_COMMENTS}}
```

{{ISSUE_IMAGES}}

## Repo-konteksti

Repo: `{{REPO_ROOT}}`

`CLAUDE.md` (mahdollinen `<project>/CLAUDE.md`):

```
{{REPO_CLAUDE_MD}}
```

## Issuen kirjoittaja vastasi aiempaan tarkennuspyyntöön

{{CLARIFICATION_CONTEXT}}

Jos yllä on vastaus tarkennuspyyntöön, tämä on uudelleenarvioitu cycle-review: aiempi arviosi
oli NEEDS_CLARIFICATION. Lue vastaus, päivitä analyysi (α … Ω) sen valossa, päätä uudelleen.
Vastaus poistaa epäselvyyden → PROCEED. Tuo uuden esteen → BLOCKER. Yhä epäselvä →
NEEDS_CLARIFICATION (kysy TARKEMPI kysymys, älä toista samaa).

## Tehtäväsi

Kirjoita analyysi alla olevilla otsikoilla tässä järjestyksessä. Ankkurikohtien otsikot
alkavat ankkurin symbolilla (`## α — tarkoitus` jne.), jotta toteutus ja Evolution löytävät kohdat.

1. **α — tarkoitus:** Kenelle ja miksi muutos tehdään? Onko se konkreettinen muutos vai
   kysymys/keskustelunavaus?
2. **Δψ — muutospaine:** Mikä paine tai poikkeama tehtävän synnytti — havaittu vika,
   mitattu raja, puuttuva kyky, ristiriita dokumentaation ja koodin välillä?
3. **χ — todennetut faktat:** Mitä luit tai ajoit itse, `tiedosto:rivi`-viittauksin. Ei
   yhteenvetoa eikä oletuksia: jokainen rivi on havainto, jonka lukija voi tarkistaa.
4. **β — rakenne:** Mitkä modulit, polut tai komponentit ovat muutoksen keskiössä? Onko
   olemassa olevaa abstraktiota josta uusi koodi voisi periytyä?
5. **τ — integraatiopinnat:** Mitkä rajapinnat (API-kentät, DB-skeema, UI-tilakomponentit,
   ulkoiset palvelut, testit jotka assertoivat muutettavaa) saattavat rikkoutua?
6. **π — lähestymistapa:** Valittu lähestymistapa ja sen perustelu. Hylätyt vaihtoehdot
   yhdellä rivillä kukin: vaihtoehto ja miksi ei.
7. **φ — suunniteltu ratkaisu:** Mitä Implementer tekee: muutokset tiedostoittain tai
   askelittain, riittävän tarkasti että toteutus voi seurata suunnitelmaa.
8. **Toteutusvalmius ja esteet:** Onko mitään blockerin tasoista epävarmuutta? Ovatko
   speksin kentät — *tavoite, hyväksyntäkriteerit, edge-caset, scope-out* — olemassa edes
   implisiittisesti?

Kirjoita lopuksi oma osionsa otsikolla **täsmälleen** `## Ω — todennussuunnitelma`:

- Yksi rivi per hyväksyntäkriteeri: kriteeri ja komento tai testi, joka todentaa sen
  (esim. `bash tests/test-x.sh`, `grep -n '…' polku`). Komennon on oltava ajettavissa
  worktreessä sellaisenaan.
- Jos issuessa ei ole muodollista hyväksyntäkriteerilistaa, johda kriteerit tavoitteesta ja
  merkitse ne johdetuiksi.
- Jos kriteeriä ei voi todentaa komennolla, kerro miten se tarkistetaan käsin ja miksi
  komento ei riitä.

{{RUN_PATH_SECTION}}

## Lopetus (PAKOLLINEN VIIMEINEN RIVI)

Lopeta vastauksesi **TÄSMÄLLEEN YHDELLÄ** seuraavista riveistä. Mitään ei saa olla rivin
jälkeen.

```
CYCLE_REVIEW_DECISION: PROCEED
```

```
CYCLE_REVIEW_DECISION: BLOCKER
```

```
CYCLE_REVIEW_DECISION: NEEDS_CLARIFICATION
```

- **PROCEED** = issue on tarpeeksi tarkka, Implementer voi aloittaa heti.
- **BLOCKER** = jokin tekninen este (puuttuva pääsy, rikkinäinen riippuvuus, jne.) joka
  vaatii ihmisen manuaalisen toimenpiteen ennen jatkamista.
- **NEEDS_CLARIFICATION** = issue-speksissä on liian iso epäselvyys; pyydä issuen kirjoittajaa
  täydentämään issuella ennen toteutusta.

Älä laita tähän mitään muuta tekstiä. Orkestraattori parsii vain tämän rivin.
