---
argument-hint: [--all | --last <N>]
description: Näytä agenttitehtaan ajojen mittarit nykyisen projektin .factory/metrics.jsonl-tiedostosta.
---

# /factory:metrics

Lue nykyisen projektin `.factory/metrics.jsonl` ja näytä ajot taulukkona.

## Argumentit

- (ei argumenttia) — näytä viimeisimmät 10 ajoa
- `--last N` — näytä viimeisimmät N ajoa
- `--all` — näytä kaikki ajot

## Toteutus

1. Etsi metrics-tiedosto:
   ```bash
   ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
   METRICS="$ROOT/.factory/metrics.jsonl"
   ```
2. Jos tiedostoa ei ole, kerro käyttäjälle:
   > "Ei mittareita: `.factory/metrics.jsonl` puuttuu. Aja tehdas vähintään kerran (`/factory:run <spec>`) ennen kuin mittareita on saatavilla."
3. Jos tiedosto on tyhjä, ilmoita:
   > "Mittarit-tiedosto on tyhjä — tehdasta ei ole ajettu tässä projektissa vielä."
4. Muuten lue rivit ja parsi JSON. Suodata argumentin mukaan:
   - Oletus: viimeiset 10 riviä
   - `--last N`: viimeiset N riviä
   - `--all`: kaikki rivit
5. Tulosta markdown-taulukko:

   ```
   | Slug | Status | Review-kierrokset | Scope-violations | Must-fix yht. | Kesto (s) |
   |------|--------|-------------------|------------------|----------------|-----------|
   | ...  | ...    | ...               | ...              | ...            | ...       |
   ```

6. Tulosta lisäksi tiivistys:
   - **Ajojen kokonaismäärä:** N
   - **Approved:** X (% of total)
   - **Blocked:** Y (% of total)
   - **Keskimääräinen review-kierrosten määrä:** Z
   - **Scope-violations / ajo (keskimäärin):** W

## Pelisäännöt

- Älä muokkaa metrics.jsonl-tiedostoa — vain luku.
- Jos riveissä on epävalidi JSON, ohita rivi ja varoita käyttäjää.
- Älä kutsu agenteja, älä lue muita tiedostoja kuin metrics.jsonl. Tämä on yksinkertainen luku-komento.
