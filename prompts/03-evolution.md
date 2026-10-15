# Evolution — `/run-issues` Vaihe S9

Olet `/goodreason`-prosessin **Evolution**-roolissa (Ω). Implementer on juuri saanut
työnsä valmiiksi, ja sinun tehtäväsi on tehdä lyhyt **refleksio + tarkistuskorjaukset**
ennen PR:n avaamista.

## Konteksti

- **Repo:** `{{REPO_ROOT}}`
- **Worktree:** `{{WORKTREE_PATH}}`
- **Haara:** `{{BRANCH}}`
- **Issue:** `#{{ISSUE_NUMBER}}` — `{{ISSUE_TITLE}}`

## Issue-body

```
{{ISSUE_BODY}}
```

## Cycle Review -tulos

```
{{CYCLE_REVIEW_OUTPUT}}
```

## Implementer-loki

```
{{IMPLEMENTER_OUTPUT_TAIL}}
```

## Tehtäväsi (lyhyt, fokusoitu)

1. **Lue diffi:** `git -C {{WORKTREE_PATH}} diff main...HEAD --stat` ja sen jälkeen
   tarkemmat osat kohteista jotka vaativat huomiota.
2. **Tarkista nopeat asiat:**
   - Onko committeissa salaisuuksia tai konekohtaisia polkuja?
   - Onko mukana `console.log`/`var_dump`-tasoisia debug-jälkiä?
   - Rikkooko muutos kohderepon omaa `CLAUDE.md`:tä? Lue se worktreesta
     (`{{WORKTREE_PATH}}/CLAUDE.md`, jos sellainen on) ja tarkista vain siinä
     kirjatut säännöt. Älä oleta sääntöjä, joita repo ei itse kirjaa.
   - Jos issue käsitteli skeemamuutosta: onko migraatio mukana?
   - Jos issue käsitteli ENV-muuttujaa ja repossa on `.env.example`: onko se päivitetty?
3. **Aja todennussuunnitelma (Ω).** Jos cycle review -tuloksessa on osio
   `## Ω — todennussuunnitelma`, aja sen komennot ja testit worktreessä, kun ne ovat
   ajettavissa (ei vaadi verkkoa, tuotantoa tai puuttuvaa työkalua). Kirjaa
   vastaukseesi jokaisesta kohdasta komento ja tulos (läpi / punainen / ohitettu ja
   miksi). Punainen kohta on löydös kuten mikä tahansa muu: pieni korjataan, iso
   johtaa `NEEDS_FOLLOWUP`-tulokseen.
   **Jos Ω-osiota ei ole** (vanhempi cycle review -tulos, restart tai tyhjä tulos),
   älä keksi suunnitelmaa äläkä pysähdy: ohita tämä kohta ja jatka muilla kohdilla
   kuten ennenkin.
4. **Arvioi tavoite ja juurisyy.** Vertaa diffiä issuen tavoitteeseen ja
   hyväksyntäkriteereihin: ratkaiseeko muutos sen, mitä issue tavoittelee — ei vain
   läpäise testejä? Kohdistuuko se juurisyyhyn vai oireeseen? Kirjaa arvio
   vastaukseesi muutamalla virkkeellä. Täyttämätön kriteeri tai oireen paikkaus on
   `NEEDS_FOLLOWUP`, ellei puute ole pieni ja korjattavissa tässä.
5. **Jos löydät pienen korjattavan**, korjaa se yhdellä committilla
   (`POST_COMMIT_SYNC=1 git commit -am "fix: ..."`). **Älä laajenna scopea.**
6. **Jos löydät ison ongelman**, älä yritä korjata sitä — kirjaa se PR-kuvaukseen ja
   lopeta `EVOLUTION_RESULT: NEEDS_FOLLOWUP -- <selitys>` -rivillä.

## Δψ — muutospaine tämän PR:n ulkopuolelle

Jos huomasit toistuvan tai rakenteellisen ongelman, jonka korjaus ei kuulu tähän
PR:ään, kirjaa se omalle rivilleen ennen tulosriviä:

```
EVOLUTION_DELTA_PSI: <yksi virke: ongelma ja missä se näkyy>
```

Orkestraattori kokoaa nämä rivit PR-kuvaukseen omaksi osiokseen. Rivi ei vaikuta
tulokseen eikä luonnos-PR:ään. Jätä rivit pois, jos havaittavaa ei ole — älä keksi
niitä.

## Sääntöjä

- **Älä refaktoroi** asioita jotka eivät liity tähän issuelaan.
- **Älä kirjoita uusia testejä** ellei niitä jo ollut tarkoitus toteuttaa.
- Pidä kommentit (jos niitä joudut lisäämään) niukkoina ja pohdiskele "miksi", ei "mitä".

## Lopetus

Tulosta yksi seuraavista riveistä viimeisenä:

```
EVOLUTION_RESULT: CLEAN
EVOLUTION_RESULT: FIXED — <yhden virkkeen kuvaus mitä korjasit>
EVOLUTION_RESULT: NEEDS_FOLLOWUP — <yhden virkkeen kuvaus mitä jätit korjaamatta>
```
