# Evolutionin havaintojen kooste — toistuvien aiheiden ryhmittely

Sinulle annetaan Evolution-vaiheen havainnot kaikista ajoista viimeisen {{WINDOW_DAYS}}
vuorokauden ajalta. Havaintoja on enintään neljää lajia:

- `FIXED`: Evolution korjasi asian itse, eli Implementer jätti sen tekemättä.
- `NEEDS_FOLLOWUP`: Evolution jätti asian korjaamatta, ja PR jäi luonnokseksi.
- `DELTA_PSI`: rakenteellinen ongelma, jonka Evolution näki mutta rajasi PR:n ulkopuolelle.
  Sen kenttä `class` kertoo lajin: `tooling` (testiympäristö, provisiointi tai runnerin oma
  toiminta), `product` (kohdesovelluksen koodi) tai `unclassified` (vanha rivi ilman lajia).
- `ESCAPE`: vika, joka löydettiin mainista myöhemmin (auditointi tai muu löydösissue) ja jonka
  rivin viimeksi muutti runnerin PR. Teksti nimeää tiedoston ja rivin, löydösissuen ja PR:n.
  Yksi runnerin PR lasketaan yhdeksi ajoksi. Nämä eivät ole Evolutionin omia havaintoja vaan
  `escape-trace.sh`:n jäljitys, eikä niillä ole aikaleimaa.

Tehtäväsi on **vain raportti**. Älä muokkaa tiedostoja, älä aja git- tai gh-komentoja äläkä
kirjoita mitään GitHubiin. Vastauksesi on koko tuotos.

## Mitä teet

1. Ryhmittele havainnot **aiheittain merkityksen perusteella**, ei sanamuodon. Kaksi havaintoa
   kuuluu samaan aiheeseen, jos sama korjaus ohjeeseen tai rakenteeseen olisi estänyt
   molemmat. Älä yhdistä `tooling`-havaintoa muun lajin havaintoon samaksi aiheeksi, vaikka
   ne mainitsisivat saman tiedoston: ne korjataan eri paikassa.
2. Ota mukaan vain aiheet, joissa on havaintoja **vähintään {{MIN_COUNT}} eri ajosta**. Saman
   ajon useampi havainto lasketaan yhdeksi.
3. Ehdota jokaiselle aiheelle **yksi** kohde perusteluineen:
   - **Implementerin prompti** (`prompts/02-implementer.md`), kun aihe toistuu useammassa
     repossa tai se on yleinen työtapa, jonka Implementer ohittaa.
   - **Kohderepon `CLAUDE.md`**, kun aihe on yhden repon konventio, jota Implementer ei
     tunne. Nimeä repo.
   - **Uusi issue**, kun aihe on korjaamaton rakenteellinen vika eikä ohjeen puute. Anna
     ehdotettu otsikko ja repo.
   - **Testiympäristö tai provisiointi** (kohderepon `.claude/provision-test-env.sh`, nimeä
     repo) **tai runnerin paketti**, kun aihe on `tooling`-lajin kitkaa. Kerro kumpi.
   - **Vaiheen prompti tai merge-portti** (cycle review, toteutus, Evolution, tietoturva- tai semanttinen portti),
     kun aiheessa on `ESCAPE`-havaintoja: runnerin ajo päästi vian mainiin, joten jonkin
     vaiheen olisi pitänyt nähdä se. Nimeä se yksi vaihe,
     joka vian olisi pitänyt pysäyttää, ja perustele valinta vian luonteella:
     - cycle review (`prompts/01-cycle-review.md`), kun vika johtuu speksin ristiriidasta tai
       väärin rajatusta laajuudesta,
     - toteutus (`prompts/02-implementer.md`), kun puuttui testi tai tunnettu käytäntö,
     - Evolution (`prompts/03-evolution.md`), kun vika olisi näkynyt valmiin diffin
       katselmoinnissa,
     - tietoturvaportti, kun vika on tietoturvavika,
     - semanttinen portti, kun vika syntyi sisar-PR:ien yhteisvaikutuksesta.
4. Ehdota kullekin aiheelle konkreettinen muotoilu: lisättävä ohjerivi tai issuen otsikko ja
   yhden virkkeen kuvaus.
5. Jokaiseen **kohderepon `CLAUDE.md`** -ehdotukseen kuuluu rivi
   `Mekaaninen tarkistus: <testi, lint-sääntö tai invarianttitesti>`, joka pitää säännön
   voimassa, tai perustelu, miksi tarkistusta ei voi tehdä. Pelkkä proosasääntö ei pidä:
   `CLAUDE.md`:n "aina"-sääntöjä on löydetty rikottuina koodista.

## Tuotoksen muoto

Kirjoita suomeksi. Jokaisesta aiheesta:

```
### <aiheen nimi>
- Kohde: <Implementerin prompti | kohderepon CLAUDE.md (<repo>) | uusi issue (<repo>) | testiympäristö tai provisiointi (<repo>) | runnerin paketti | vaiheen prompti tai merge-portti (<vaihe>)>
- Perustelu: <yksi virke>
- Ehdotus: <ohjerivi tai issuen otsikko + kuvaus>
- Mekaaninen tarkistus: <testi, lint-sääntö tai invarianttitesti, tai miksi ei voi> (pakollinen kohderepon CLAUDE.md -ehdotukselle)
- Havainnot: <repo>#<issue> (<laji>), …
```

Jos yksikään aihe ei toistu, sano se yhdellä rivillä. Älä keksi toistoa, jota aineisto ei
näytä.

## Mekaaninen esiryhmittely

Skripti on jo ryhmitellyt havainnot niissä mainittujen tiedostojen ja tunnisteiden mukaan.
Käytä sitä apuna, mutta se ei ole lopullinen: se ei näe saman asian eri sanamuotoja ja voi
yhdistää eri asioita, jotka koskevat samaa tiedostoa.

```
{{DETERMINISTIC_GROUPS}}
```

## Havainnot (JSON)

```json
{{FINDINGS_JSON}}
```
