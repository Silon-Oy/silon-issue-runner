## Raskas polku (`heavy-run`) — koe ensin, korjaus vasta sitten

Tämä issue on raskaan polun bugi. Cycle review -tuloksessa on osiot `## Hypoteesit` ja
`## Diagnostinen koe`. **Et saa tehdä korjausmuutoksia ennen kuin koe on ajettu ja yksi
hypoteesi vahvistettu.** Tee tässä järjestyksessä:

1. **Aja diagnostinen koe** sellaisenaan. Älä muuta tuotantokoodia sitä varten; väliaikaiset
   mittausrivit tai testit ovat sallittuja, kunhan poistat ne tai ne ovat osa korjausta.
2. **Kirjaa raakatulos** tiedostoon `{{DIAGNOSIS_FILE}}` (ajon hakemistossa, ei worktreessä;
   älä committaa sitä): ajettu komento, sen tuloste muokkaamattomana ja lyhyt tulkinta siitä,
   mikä hypoteesi tulos vahvistaa ja mitkä se kumoaa. Tiedosto julkaistaan PR-kuvauksessa
   ja issuekommentissa: **poista tulosteesta salaisuudet ja henkilötiedot** (tokenit,
   salasanat, yhteysosoitteet tunnuksineen, sähköpostiosoitteet) ennen kirjausta.
3. **Tulosta välirivi** omalle rivilleen, täsmälleen yksi näistä:

   ```
   DIAGNOSIS_RESULT: CONFIRMED H<n>
   DIAGNOSIS_RESULT: REFUTED — <mitä koe näytti>
   DIAGNOSIS_RESULT: UNEXPECTED — <mitä koe näytti>
   ```

   `REFUTED` = tulos kumoaa kaikki hypoteesit. `UNEXPECTED` = tulos ei vastaa yhtäkään
   ennustetta tai vahvistaa useamman kuin yhden.
4. **Jos tulos ei ole `CONFIRMED`:** älä korjaa äläkä arvaa syytä. Kirjaa vastaukseesi,
   mitä koe näytti ja mitä ihmisen pitäisi selvittää, ja lopeta rivillä
   `IMPLEMENTER_RESULT: BLOCKED — diagnostiikka ei vahvistanut hypoteesia`. Orkestraattori
   pysäyttää ajon ihmiselle välirivin perusteella.
5. **Jos tulos on `CONFIRMED H<n>`:** korjaa vain vahvistetun hypoteesin kuvaama syy ja
   jatka muuten tavalliseen tapaan.

Orkestraattori tarkistaa välirivin ja raakatulostiedoston. Ilman molempia ajo pysähtyy
ihmiselle, vaikka korjaus olisi valmis.

**Uudelleenkäynnistetty ajo:** jos `{{DIAGNOSIS_FILE}}` on jo olemassa ja siinä on tulos, älä
aja koetta uudelleen. Tulosta sama `DIAGNOSIS_RESULT`-rivi uudelleen ja jatka siitä.
