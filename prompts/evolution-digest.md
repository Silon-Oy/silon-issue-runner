# Evolutionin havaintojen kooste — toistuvien aiheiden ryhmittely

Sinulle annetaan Evolution-vaiheen havainnot kaikista ajoista viimeisen {{WINDOW_DAYS}}
vuorokauden ajalta. Havaintoja on kolmea lajia:

- `FIXED`: Evolution korjasi asian itse, eli Implementer jätti sen tekemättä.
- `NEEDS_FOLLOWUP`: Evolution jätti asian korjaamatta, ja PR jäi luonnokseksi.
- `DELTA_PSI`: rakenteellinen ongelma, jonka Evolution näki mutta rajasi PR:n ulkopuolelle.

Tehtäväsi on **vain raportti**. Älä muokkaa tiedostoja, älä aja git- tai gh-komentoja äläkä
kirjoita mitään GitHubiin. Vastauksesi on koko tuotos.

## Mitä teet

1. Ryhmittele havainnot **aiheittain merkityksen perusteella**, ei sanamuodon. Kaksi havaintoa
   kuuluu samaan aiheeseen, jos sama korjaus ohjeeseen tai rakenteeseen olisi estänyt
   molemmat.
2. Ota mukaan vain aiheet, joissa on havaintoja **vähintään {{MIN_COUNT}} eri ajosta**. Saman
   ajon useampi havainto lasketaan yhdeksi.
3. Ehdota jokaiselle aiheelle **yksi** kohde perusteluineen:
   - **Implementerin prompti** (`prompts/02-implementer.md`), kun aihe toistuu useammassa
     repossa tai se on yleinen työtapa, jonka Implementer ohittaa.
   - **Kohderepon `CLAUDE.md`**, kun aihe on yhden repon konventio, jota Implementer ei
     tunne. Nimeä repo.
   - **Uusi issue**, kun aihe on korjaamaton rakenteellinen vika eikä ohjeen puute. Anna
     ehdotettu otsikko ja repo.
4. Ehdota kullekin aiheelle konkreettinen muotoilu: lisättävä ohjerivi tai issuen otsikko ja
   yhden virkkeen kuvaus.

## Tuotoksen muoto

Kirjoita suomeksi. Jokaisesta aiheesta:

```
### <aiheen nimi>
- Kohde: <Implementerin prompti | kohderepon CLAUDE.md (<repo>) | uusi issue (<repo>)>
- Perustelu: <yksi virke>
- Ehdotus: <ohjerivi tai issuen otsikko + kuvaus>
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
