## Raskas polku (`heavy-run`) — hypoteesit ennen korjausta

Issuen kirjoittaja on luokitellut tämän issuen raskaaseen polkuun. Raskaan polun PR:ää ei
yhdistetä automaattisesti, ja **bugia ei korjata ennen kuin sen syy on vahvistettu**.

**1. Luokittele, onko issue bugi.** Bugi = havaittu toiminta poikkeaa odotetusta ja syy
pitää selvittää. Uusi ominaisuus, refaktorointi tai arkkitehtuurimuutos ei ole bugi. Kirjaa
luokitus omalle rivilleen **ennen** päätösriviä:

```
HEAVY_RUN_KIND: BUG
```

tai

```
HEAVY_RUN_KIND: NOT_BUG
```

Jos rivi puuttuu, orkestraattori käsittelee issuen bugina. `NOT_BUG` kulkee tavallista
polkua ilman alla olevia osioita (PR jää silti ilman automaattista yhdistämistä).

**2. Jos issue on bugi**, kirjoita Ω-osion jälkeen kaksi osiota:

`## Hypoteesit` — **vähintään kolme kilpailevaa** hypoteesia vian syystä, tunnisteilla
`H1`, `H2`, `H3`, … Kustakin:

- väite: mikä syy, missä kohdassa koodia (`tiedosto:rivi`, jos tiedossa)
- falsifiointikriteeri: mikä havainto kumoaisi tämän hypoteesin

Hypoteesien on oltava aidosti kilpailevia: ne ennustavat eri tuloksen samasta kokeesta.

`## Diagnostinen koe` — **pienin** koe, joka erottaa hypoteesit toisistaan:

- ajettava komento tai toimenpide, worktreessä sellaisenaan toistettavissa
- ennuste hypoteesikohtaisesti: mitä tulos näyttää, jos `H1` pitää, jos `H2` pitää, …
- mikä tulos olisi odottamaton (ei vastaa yhtäkään ennustetta)

φ-osio kuvaa korjauksen ehdollisena: mitä korjataan kunkin hypoteesin vahvistuessa. Toteutus
ajaa kokeen ensin ja korjaa vain vahvistetun syyn.
