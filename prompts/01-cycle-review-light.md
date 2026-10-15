# Kevyt tarkistus — `/run-issues` Vaihe S6 (`light-run`)

Issuen kirjoittaja on luokitellut tämän issuen **kevyeksi** (`light-run`-label): syy on
tiedossa, muutos on enintään noin 3 tiedostoa tai 50 riviä, ja se on helppo perua. Täyttä
cycle reviewiä ei siksi ajeta. Tehtäväsi on tarkistaa **vain kaksi asiaa** ja päättää,
pitääkö luokitus.

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

## Repo

Repo: `{{REPO_ROOT}}`

## Tarkistukset

1. **Koodi vastaa yhä issuen kuvausta.** Lue issuen nimeämät tiedostot, funktiot tai
   käytös. Ovatko ne olemassa ja kuvatun kaltaisia? Jos koodi on muuttunut niin, että
   issuen premissi ei enää päde, luokitus ei pidä.
2. **Muutos on rajattu.** Mahtuuko toteutus kevyen polun kriteereihin: syy on tiedossa,
   enintään noin 3 tiedostoa tai 50 riviä, helppo perua? Jos muutos ylittää tila-,
   rinnakkaisuus- tai integraatiorajan, luokitus ei pidä.

Älä tee täyttä analyysiä. Kirjoita lyhyesti:

- **χ — todennetut faktat:** mitä luit, `tiedosto:rivi`-viittauksin.
- **φ — suunniteltu ratkaisu:** muutokset tiedostoittain, muutamalla rivillä.

Kirjoita lopuksi oma osionsa otsikolla **täsmälleen** `## Ω — todennussuunnitelma`: yksi rivi
per hyväksyntäkriteeri, kriteeri ja worktreessä sellaisenaan ajettava komento, joka todentaa
sen. Jos issuessa ei ole hyväksyntäkriteerejä, johda ne tavoitteesta ja merkitse johdetuiksi.

## Lopetus (PAKOLLINEN VIIMEINEN RIVI)

Lopeta vastauksesi **TÄSMÄLLEEN YHDELLÄ** seuraavista riveistä. Mitään ei saa olla rivin
jälkeen.

```
LIGHT_REVIEW_DECISION: LIGHT
```

```
LIGHT_REVIEW_DECISION: ESCALATE
```

- **LIGHT** = molemmat tarkistukset pitävät; toteutus voi alkaa heti.
- **ESCALATE** = kumpi tahansa tarkistus ei pidä, tai et ole varma. Ajo jatkuu täyteen cycle
  reviewiin automaattisesti — ihmistä ei tarvita, joten epävarmana valitse tämä.

Älä laita tähän mitään muuta tekstiä. Orkestraattori parsii vain tämän rivin.
