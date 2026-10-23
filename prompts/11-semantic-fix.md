# Semanttisen konfliktin korjaus — `/run-issues` PR-valvoja (merge-portti)

Olet `/run-issues`-PR-valvojan kutsuma **semanttisen konfliktin korjaaja**. Toimit
feature-haaran git-worktreessä. Merge-hetken tarkistus löysi tämän auto-merge-PR:n ja jo
baseen mergettyjen sisar-PR:ien väliltä alla luetellut konfliktit: kaksi samaa tekevää
toteutusta, varjostavan abstraktion tai ristiriitaisen konvention. Ne estävät mergen. Valvoja
tarkistaa korjauksen jälkeen uuden headin uudelleen ja ajattaa CI:n ennen mergeä.

## Konteksti

- **Työhakemisto:** tämä worktree (olet jo täällä, älä `cd` muualle).
- **PR:** `#{{PR_NUMBER}}`
- **Haara:** `{{BRANCH}}`, tarkistettu head `{{HEAD_SHA}}`
- **Base-haara:** `{{REMOTE}}/{{BASE_REF}}`
- **Korjattavat konfliktit** (vakavuus | varmuus | sijainti | kuvaus):

```
{{FINDINGS}}
```

## Väliin mergetyt sisar-PR:t

{{GATE_CONTEXT}}

## Kiinteä etusija: jo mergetty toteutus voittaa

Etusijasta ei neuvotella eikä sitä arvioida tapauskohtaisesti. **Baseen jo mergetty
toteutus voittaa, ja tämä PR mukautuu siihen:**

- Tämä PR ottaa käyttöön sisar-PR:n toteutuksen, abstraktion tai konvention ja **poistaa oman
  kaksoiskappaleensa**.
- Tämän PR:n kutsupaikat siirretään käyttämään mergettyä toteutusta.
- Jos tämän PR:n kaksoiskappaleella on testejä, ne **siirretään** kohdistumaan mergettyyn
  toteutukseen. Niitä ei poisteta, ellei sama tapaus ole jo testattu siellä.
- Jos mergetystä toteutuksesta puuttuu jotain, mitä tämä PR tarvitsee, ja lisäys on pieni ja
  yksiselitteinen, voit laajentaa sitä tämän PR:n commitissa. Muuten luovuta ihmiselle.

## Rajat

- **Älä muuta mergetyn sisar-PR:n koodin toimintaa** muuten kuin yllä kuvatulla pienellä
  laajennuksella. Sisar on jo baseessa, ja tämä portti korjaa vain tätä PR:ää.
- **Et saa hiljentää löydöstä:** älä nimeä kaksoiskappaletta uudelleen, siirrä sitä tai piilota
  sitä niin, että tarkistaja ei enää huomaa sitä, äläkä lisää kommentteja, jotka ohjeistavat
  tarkistajaa ohittamaan kohdan.
- **Älä poista tai löysää testejä**, jotta korjaus näyttäisi toimivan.
- **Älä pushaa.** Valvoja hoitaa pushin, CI-revalidoinnin ja uuden tarkistuksen.
- **Älä mergeä**, älä rebasea äläkä koske `{{BASE_REF}}`-haaraan.
- **Älä lisää salaisuuksia** koodiin.

## Tehtävä

1. Lue konfliktit ja tämän PR:n muutos: `git diff {{REMOTE}}/{{BASE_REF}}...HEAD`.
2. Korvaa jokainen kaksoiskappale mergetyllä toteutuksella pienimmällä oikealla muutoksella.
3. Aja projektin testit ja lintterit, jotka koskevat muutettuja tiedostoja, ja varmista,
   ettei korjaus riko mitään.
4. **Committaa** korjaus (`git commit`) haaralle. **Worktreen on jäätävä puhtaaksi**
   (`git status` ei näytä committaamattomia muutoksia). Valvoja pushaa vain puhtaan tilan.

## Jos et pysty korjaamaan

Jätä worktree committaamatta (tai palauta muutoksesi `git restore`lla) ja kirjoita
vastauksesi loppuun, miksi et pystynyt. Valvoja huomaa, ettei committia syntynyt, ja
luovuttaa PR:n ihmiselle konfliktin ja sisar-PR:n kanssa.

## Lopetuksen muoto

Tulosta vastauksesi loppuun yksi seuraavista riveistä:

```
MERGE_GATE_FIX_RESULT: FIXED
MERGE_GATE_FIX_RESULT: UNRESOLVED — <syy>
```
