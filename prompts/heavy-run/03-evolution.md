## Raskas polku (`heavy-run`) — katselmointiohje käsin yhdistettävään PR:ään

Tämä on raskaan polun ajo. Sen PR ei mergeydy automaattisesti: se saa `manual-merge`-labelin,
ja ihminen katselmoi ja yhdistää sen käsin. Orkestraattori nostaa kirjoittamasi
katselmointiohjeen PR-kuvauksen alkuun, joten ohje on ensimmäinen asia, jonka katselmoija lukee.

**Kirjoita vastaukseesi pakollinen osio** täsmälleen otsikolla `## Katselmointiohje`, kerran,
ennen `EVOLUTION_*`-rivejä. Älä käytä osion sisällä muita `## `-tason otsikoita: osio päättyy
seuraavaan `## `-otsikkoon tai ensimmäiseen `EVOLUTION_`-riviin. Käytä alaotsikoina `###`-tasoa.
Älä mainitse otsikkoa muualla vastauksessasi. Osiossa on nämä viisi kohtaa:

### Mihin katsoa
Muutoksen kriittiset kohdat muodossa `tiedosto:rivi`, kukin yhdellä virkkeellä siitä, miksi
juuri siihen kannattaa katsoa.

### Riskit
Mikä muutoksessa voi mennä rikki ja **miksi** se on riski (mihin se vaikuttaa, kuka sen
huomaisi). Älä listaa geneerisiä riskejä, jotka koskevat mitä tahansa muutosta.

### Hyväksyntäkriteerien todennus
Jokainen issuen hyväksyntäkriteeri omalla rivillään muodossa
`kriteeri → todennuskomento → tulos`. Tulos on se, minkä komento tuotti, kun ajoit cycle
reviewn Ω-todennussuunnitelman — ei odotettu tulos. Jos kriteeriä ei voitu todentaa, kirjoita
se ja syy.

### Jäännösriski
Mitä todennus ei kata ja mikä jää katselmoijan arvioitavaksi.

### Peruminen
Miten muutos perutaan (esim. `git revert <commit>`, ja jos muutos koskee tilaa, konfiguraatiota
tai migraatiota, mitä sen lisäksi on tehtävä).

Osio julkaistaan PR-kuvauksessa: **älä kirjoita siihen salaisuuksia** (API-avaimia, salasanoja,
tokeneita) äläkä niitä sisältäviä komentotulosteita.
