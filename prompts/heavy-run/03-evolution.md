## Raskas polku (`heavy-run`) — kohdistuuko korjaus vahvistettuun syyhyn?

Tämä issue on raskaan polun bugi. Toteutus ajoi diagnostisen kokeen ennen korjausta ja
vahvisti yhden cycle reviewn hypoteeseista. Raakatulos on tiedostossa `{{DIAGNOSIS_FILE}}`,
ja vahvistettu hypoteesi on toteutuslokin rivillä `DIAGNOSIS_RESULT: CONFIRMED H<n>`.

Lue tiedosto ja vertaa diffiä vahvistetun hypoteesin väitteeseen:

- Muuttaako korjaus sitä kohtaa, jonka vahvistettu hypoteesi nimeää syyksi?
- Korjaako se samalla kumottujen hypoteesien kohtia? Se on arvaamista, ei korjausta.
- Tukeeko raakatulos todella vahvistusta, vai tulkittiinko se väkisin?

Kirjaa arvio vastaukseesi. Jos korjaus ei kohdistu vahvistettuun hypoteesiin tai raakatulos
ei tue sitä, lopeta `EVOLUTION_RESULT: NEEDS_FOLLOWUP — <selitys>` -rivillä.
