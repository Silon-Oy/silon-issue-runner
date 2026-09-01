---
argument-hint: "<ongelma omin sanoin>"
description: Triagee kuvatun ongelman repon koodista ja lokeista, kysyy puuttuvat toistoaskeleet ja tarkistaa duplikaatit — päätyy joko korjausohjeeseen ilman issueta, tai delegoi issuen /new-issuelle ja kokonaisuuden /new-epicille.
---

# /report-problem

Ottaa vastaan **oireen** — "tämä ei toimi", "sivu näyttää väärältä", "ajo jäi jumiin" — selvittää
mistä on kyse, ja tuottaa issuen **vain jos issue on oikea vastaus**. Tämä komento **ei aja
mitään** eikä **korjaa mitään**.

Ero sisarkomentoon [`/new-issue`](new-issue.md) on triage. `/new-issue` olettaa, että käyttäjä
tietää mitä pitää tehdä; tämä komento on sitä varten, että hän tietää vain mikä ei toimi. Siksi
tämä ei ole `/new-issue` toisella nimellä: **suurin osa arvosta on siinä lopputuloksessa, joka ei
ole issue.** Ilman "ei issueta" -haaraa komento kääntäisi jokaisen käyttövirheen ja
konfiguraatio-ongelman jonoon meneväksi työksi, ja jonon laadun mittaa vasta se, kuinka moni sen
issue oli oikeasti issue.

**Rajaukset, jotka pätevät aina:**

- Komento **ei korjaa ongelmaa itse.** Ei tiedostomuutoksia, ei committeja, ei konfiguraation
  kirjoittamista. Korjaus on runnerin työtä — se tulee PR:nä ja CI:n läpi.
- Komento **ei luo issueta eikä epiciä omin päin.** Molemmat delegoidaan.
- Komento **ei sulje eikä muokkaa olemassa olevia issueita.** Ainoa oma kirjoitus on
  duplikaattiosuman kommentti (osio 4), eikä sekään koske labeleihin.
- Komento **ei aja orkestraattoria eikä `/run-issues`ia.**

> **Miksi korjaus on rajattu ulos.** Tämän komennon käyttäjä on se, joka ei osaa arvioida
> korjausta. Hän ei myöskään osaa arvioida sitä ilman PR:ää ja CI:tä — joten "korjasin sen jo"
> tarkoittaisi käytännössä katselmoimatonta muutosta, jonka oikeellisuudesta kukaan paikalla
> oleva ei voi sanoa mitään. Havainto on halpa ja tarkistettavissa; korjaus ei ole kumpaakaan.

## 0. Ilman argumenttia: usage

Argumentti on vapaamuotoinen kuvaus havaitusta ongelmasta. Jos sitä ei ole, tulosta usage äläkä
lue eikä kirjoita mitään:

```
usage: /report-problem <ongelma omin sanoin>
  esim. /report-problem käynnistin ajon eilen issuelle 140 mutta mitään ei ole tapahtunut, PR:ää ei näy
```

## 1. Triage — selvitä ennen kuin ehdotat mitään

**Tämä osio on vain lukua.** Älä muokkaa tiedostoja, älä aja mitään mikä kirjoittaa levylle, älä
kirjoita GitHubiin.

Kohderepo on **nykyinen työhakemisto**. Selvitä koodista, mikä oireen aiheuttaa:

1. **`README.md` ja `CLAUDE.md` ensin.** Iso osa raportoiduista "vioista" on dokumentoituja
   tietoisia valintoja tai tunnettuja avoimia asioita. Jos oire osuu sellaiseen, verdikti on
   melkein varmasti osio 3.1.
2. **Ne tiedostot, joihin oire osuu.** Etsi se koodipolku, joka tuottaa kuvatun käytöksen — älä
   tyydy siihen, että löysit aiheeseen liittyvän tiedoston.
3. **Lokit, jos ne ovat luettavissa.** Kohderepon omat lokit, ja jos raportoitu ongelma koskee
   runneria itseään, myös sen lokit hakemistossa `${RUN_ISSUES_LOG_DIR:-$HOME/Library/Logs}`
   (`.log`, `.runs.log`, `.stdout.log`, `.stderr.log` per poller). Ajokohtainen tila on
   `status.sh`:lla — se on puhtaasti lukeva.

**Lokista ei kopioida mitään tarkistamatta.** Lokirivi voi sisältää tokenin, URL-parametrin tai
muun salaisuuden, ja issue on julkinen pinta myös yksityisessä repossa: se päätyy prompteihin,
PR-kuvauksiin ja kommentteihin. Lainaa lokista vain se rivi, jonka olet lukenut, ja poista
tunnisteet.

**Triagen mitta:** pystyt nimeämään tiedoston ja funktion, jossa oire syntyy, **tai** pystyt
sanomaan täsmällisesti mitä olet sulkenut pois ja mihin tieto loppui. Toinen on kelvollinen
lopputulos — ensimmäinen on parempi.

> **"En löytänyt syytä" ei ole peruste jättää issue luomatta.** Se on issuen sisältöä: mitä
> oireesta havaittiin, mitä poissuljettiin, mihin tieto loppui. Juuri se säästää implementeriltä
> koko sen työn, jonka juuri teit. Ainoa peruste jättää issue luomatta on se, että issue on
> **väärä vastaus** — ks. osio 3.1.

## 2. Puuttuvat toistoaskeleet kysytään — kerran, ei yksi kerrallaan

Ajokelpoinen issue vastaa kolmeen kysymykseen: **mitä teit, mitä odotit, mitä tapahtui.**
Ei-devaustaitoinen käyttäjä kuvaa yleensä vain kolmannen. Kysy puuttuvat `AskUserQuestion`illa.

Kysy **vain se, mitä triage ei ratkaissut**, ja kysy kaikki yhdellä kierroksella. Jos osiossa 1
löysit koodista, mikä oireen aiheuttaa, älä kysy toistoaskelia rituaalina — kysy se, mikä yhä
erottaa kaksi mahdollista selitystä toisistaan.

Tyypilliset aukot, jotka kannattaa kysyä:

| Aukko | Miksi se ratkaisee jotain |
|---|---|
| Mitä teit tarkalleen | erottaa käyttövirheen viasta — sama oire, eri verdikti |
| Mitä odotit tapahtuvan | odotus voi olla väärä; silloin vika on dokumentaatiossa, ei koodissa |
| Toistuuko se | kertaluontoinen ≠ deterministinen; jälkimmäinen on ajokelpoinen, edellinen tarvitsee lisää havaintoja |
| Milloin se alkoi | rajaa muutosjoukon, josta syytä etsitään |

Jos käyttäjä ei tiedä vastausta, se on **kelvollinen vastaus** ja kirjataan issueen sellaisenaan.
Älä jää jumiin kysymykseen, johon raportoija ei voi vastata.

## 3. Verdikti: kolme lopputulosta, ja se sanotaan ääneen

Kerro käyttäjälle **suoraan ja ensimmäisenä**, mihin kolmesta päädyit ja miksi. Vaihtoehtoja on
kolme eikä muita; "en tiedä" ei ole neljäs (ks. osion 1 huomautus).

### 3.1 Ei issueta — käyttövirhe, konfiguraatio tai väärinkäsitys

Valitse tämä, kun **koodi tekee sen mitä sen on tarkoitus tehdä**: puuttuva tai väärä
konfiguraatio, väärin muistettu komento tai argumentti, dokumentoitu tietoinen valinta, tai
odotus, joka ei vastaa sitä mitä ohjelma lupaa.

Anna **korjausohje**: tarkka komento tai muutettava asetus, ja mistä sen näkee menneen läpi.
Tämä on **aito lopputulos, ei epäonnistuminen** — sano se niin, ettei raportoija jää siihen
käsitykseen, että hänen havaintonsa oli turha.

**Kaksi tapausta, joissa tämä haara silti tuottaa issuen** — kysy silloin käyttäjältä
`AskUserQuestion`illa, tehdäänkö se:

- **Dokumentaatio johti harhaan.** Jos ohje on väärä tai puuttuu, korjaus koodiin on tarpeeton
  mutta korjaus dokumenttiin on aito issue.
- **Sama käyttövirhe on liian helppo tehdä.** Jos ohjelma hyväksyy virheellisen syötteen hiljaa
  eikä sano mitään, virheilmoituksen lisääminen on issue.

### 3.2 Issue — delegoi `/new-issue`lle

Valitse tämä, kun kyseessä on aito vika tai puute, joka **mahtuu yhteen ajoon**: yksi
itsenäisesti toteutettava muutos ilman järjestysriippuvuutta muihin.

### 3.3 Epicin kokoinen — delegoi `/new-epic`ille

Valitse tämä, jos jokin näistä pätee (sama arviointi kuin `/new-issue` §3:ssa):

- korjaus hajoaa useaksi **itsenäisesti toteutettavaksi** muutokseksi,
- osilla on **aito järjestysriippuvuus**, tai
- **yksi ajo ei saa sitä valmiiksi.**

Yksi oire voi hyvinkin olla epicin kokoinen — usein juuri siksi, että oire on ainoa näkyvä osa
rakenteellisesta ongelmasta.

## 4. Duplikaattitarkistus ennen delegointia

Koskee vain lopputuloksia 3.2 ja 3.3. **Tarkista avoimet issuet ennen kuin delegoit.**

```bash
OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

gh api "repos/$OWNER_REPO/issues?state=open&per_page=100" --paginate \
  --jq '.[] | select(.pull_request | not)
        | "\(.number)\t\(.title)\t\([.labels[].name] | join(","))"'
```

Kaksi yksityiskohtaa, jotka eivät ole tyylivalintoja:

- **REST, ei `gh issue list --search`.** `gh`:n GraphQL-hakuyhteys on ollut erikseen estettynä
  27 tunnin ajan samalla kun REST vastasi normaalisti (`CLAUDE.md` §5.2). Duplikaattitarkistus,
  joka epäonnistuu, tuottaisi duplikaatin.
- **`.pull_request`-suodatus on pakollinen.** REST `/issues` palauttaa myös PR:t, ja PR:n otsikko
  on tyypillisesti sama kuin sen sulkeman issuen — ilman suodatusta jokainen ajossa oleva issue
  näyttäisi omalta duplikaatiltaan.

Vertaa otsikoita ja tarvittaessa runkoja (`gh issue view <N>`) **oireeseen, älä sanamuotoon**:
sama vika kuvataan eri sanoin joka kerta.

**Osuma esitetään käyttäjälle, joka päättää.** Näytä numero, otsikko, labelit ja lyhyt perustelu
siitä, miksi pidät sitä samana asiana. Kysy `AskUserQuestion`illa: **kommentoi olemassa olevaa**
vai **luo uusi issue**.

Jos käyttäjä valitsee kommentoinnin, kommentti on tämän komennon **ainoa oma kirjoitus**:

```bash
jq -n --arg b "$COMMENT_BODY" '{body: $b}' \
  | gh api --method POST "repos/$OWNER_REPO/issues/$DUP_NUMBER/comments" --input - --jq '.html_url'
```

Kommentin säännöt:

- **Vain kommentti.** Ei labeleita, ei sulkemista, ei assignaatiota — eikä koskaan
  `auto-claimed`ia, joka on automaation oma varaus.
- **Ei `<!-- run-issues:… -->` -markeria.** Ne ovat automaation tilakommenttien sanastoa, ja
  ihmisen kirjoittama kommentti markerilla sekoittuisi pollerin lukemaan tilaan.
- **Kerro, jos issue on jo ajossa.** Jos osumalla on `auto-claimed` tai `wip`, sano käyttäjälle,
  että ajo on jo käynnissä ja **implementer luki issuen rungon ajon alussa** — myöhempi kommentti
  ei siis päädy siihen ajoon. Kommentti on tällöin viesti ihmiselle, ei lisäys speksiin.

## 5. Delegointi — triagen tuotos menee argumenttiin

Delegointi tarkoittaa, että **kerrot käyttäjälle komennon** — et kirjoita issueta itse. Sama
kuvio kuin `/new-issue` §3:ssa, ja samasta syystä: issuen muoto, poimintalabelit ja niiden
tarkistukset ovat `/new-issue`n ja `/new-epic`in vastuulla. Jos toteuttaisit ne täällä uudelleen,
kaksi toteutusta ajautuisi erilleen ja poimintaehdot pätisivät vain toisessa — täsmälleen se
hiljainen vika, jota koko komentoperhe on estämässä.

**Tiivistä triagen tuotos argumentiksi.** Muuten delegointi hukkaa juuri sen työn, jonka takia
tämä komento on olemassa, ja käyttäjä joutuu kirjoittamaan oireensa uudelleen — huonommin kuin
sinä sen nyt tiedät. Argumenttiin kuuluu:

| Osa | Mistä se tulee |
|---|---|
| Oire yhtenä lauseena | käyttäjän kuvaus, tarkennettuna |
| Toistoaskeleet | osio 2: mitä teit / mitä odotit / mitä tapahtui |
| Juurisyyhavainto | osio 1: tiedosto ja funktio, tai poissuljetut ja mihin tieto loppui |
| Rajaus | mitä korjaus ei koske |

Esitä komento valmiina rivinä, jonka käyttäjä voi kopioida sellaisenaan:

```
/new-issue <oire>. Toisto: <mitä teit> → odotettiin <x>, tapahtui <y>. Havainto: <tiedosto:funktio tai poissuljetut>. Rajaus: <mitä ei kuulu>.
```

Epic-haarassa sama `/new-epic`ille, ja siihen kuuluu lisäksi **osiin jako**, jonka perustelit
osiossa 3.3 — se on juuri se tieto, jota `/new-epic` tarvitsee eikä voi päätellä oireesta.

**Älä aja delegoitua komentoa käyttäjän puolesta.** Se on hänen vahvistuksensa paikka:
`/new-issue` ja `/new-epic` kysyvät luonnoksesta erikseen, ja tämän ohittaminen tekisi triagesta
kirjoitusoikeuden.

## 6. Raportoi — myös silloin kun issueta ei syntynyt

Tulosta aina, riippumatta lopputuloksesta:

| Kohta | Mitä raportoidaan |
|---|---|
| Verdikti | mikä kolmesta, ja yhdellä lauseella miksi |
| Havainto | tiedosto ja funktio, tai poissuljetut ja mihin tieto loppui |
| Duplikaatti | osuma ja käyttäjän päätös, tai "ei osumaa" (vain 3.2 / 3.3) |
| Seuraava askel | valmis komentorivi, tai korjausohje |

Lopuksi, sanamuoto lopputuloksen mukaan:

> **Lopputulos 3.1:** *Issueta ei luotu, koska issue ei ole tähän oikea vastaus — korjaus on yllä.
> Mitään ei ole muutettu eikä käynnistetty. Jos korjaus ei auta, aja `/report-problem` uudelleen
> sillä mitä tapahtui sen jälkeen.*

> **Lopputulokset 3.2 ja 3.3:** *Issueta ei ole vielä luotu — yllä oleva komento tekee sen ja
> kysyy luonnoksesta erikseen. Mitään ei ole käynnistetty: ajon tekee poller seuraavalla tikillä,
> omassa worktreessään ja omassa istunnossaan. Tilan näkee `status.sh`:lla.*
