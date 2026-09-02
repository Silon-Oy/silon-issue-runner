---
name: e2e-testing
description: Use when writing, repairing or reviewing an end-to-end browser test — adding a test for a user flow, chasing a flaky or failing E2E spec, choosing the selectors a test uses, or deciding which account it logs in as. Covers Playwright as the default runner, web-first assertions instead of manual waits, data-test / data-testid locators in preference to text-based ones, and the rule that test credentials are provisioned as a separate account and never by changing an existing user's password.
when_to_use: You are about to write, repair or review a test that drives a real browser end to end — including picking its locators and deciding which account it authenticates as.
version: 1.0.0
---

# End-to-end-testaus

Nämä säännöt koskevat **selainta ajavia end-to-end-testejä**. Yksikkö- ja integraatiotestit
seuraavat projektin omia käytäntöjä, eivät tätä.

E2E-testin kaksi tyypillistä hajoamistapaa eivät näy koodikatselmuksessa: testi menee läpi
paikallisesti ja punaisena CI:ssä (ajoitus), tai se menee läpi kunnes joku vaihtaa napin
tekstin (valitsin). Molemmat estetään kirjoitusvaiheessa, ei jälkikäteen.

## Työkalu

**Playwright on oletus.** Jos projektissa on jo toinen E2E-kehys käytössä, jatka sillä —
älä tuo rinnalle toista. Uutta E2E-pakettia perustettaessa valinta on Playwright.

Noudata Playwrightin omia best practices -ohjeita. Kaksi niistä kantaa suurimman osan
hyödystä:

- **Web-first assertions.** `expect(locator).toBeVisible()` ja vastaavat odottavat itse
  siihen asti kunnes ehto täyttyy tai timeout umpeutuu.
- **Ei käsin kirjoitettuja odotuksia.** Kiinteä `waitForTimeout` on joko liian lyhyt
  (satunnainen punainen) tai liian pitkä (hidas paketti) — ja vaihtaa luokkaa koneen
  kuorman mukaan. Jos jotain pitää odottaa, odota **sitä ehtoa** jota odotat, ei kelloa.

## Lokaattorit

**Ensisijaisesti `data-test` (tai `data-testid`).** Lisää attribuutti komponenttiin silloin
kun sitä ei vielä ole — se on osa testin kirjoittamista, ei erillinen pyyntö.

**Vältä tekstipohjaisia valitsimia**: `getByText()` ja `getByRole({ name: "…" })`. Käyttö-
liittymän teksti muuttuu tiuhaan — sanamuodon hiominen, käännös, kirjoitusvirheen korjaus —
ja jokainen muutos rikkoo testin, jonka kanssa sillä ei ole mitään tekemistä. Rikkoutuminen
näyttää lisäksi regressiolta, vaikka toiminnallisuus on ennallaan.

Poikkeus, joka on sääntö itsessään: kun testin **koko tarkoitus** on varmistaa että
käyttäjälle näkyy tietty teksti, silloin tekstiin kohdistuva assertio on oikein. Valitsin ja
assertio ovat eri asioita — vältä tekstiä valitsimessa, älä assertiossa.

## Tunnukset

**Älä koskaan muuta olemassa olevan käyttäjätilin salasanaa testejä varten.** Se rikkoo tilin
oikean omistajan pääsyn, eikä muutos näy mistään testikoodista — vika ilmenee vasta kun joku
muu yrittää kirjautua.

Tee sen sijaan jompikumpi:

- **Luo erillinen testitili** (esim. `e2e-admin`), joka on olemassa vain testejä varten ja
  jonka saa vapaasti alustaa uudelleen.
- **Pyydä tunnukset etukäteen**, jos testin on kirjauduttava tilillä jota et voi luoda.

Tunnukset luetaan ympäristömuuttujista, eivät testikoodista — myöskään testitilin salasana ei
kuulu versionhallintaan.
