---
argument-hint: <spec-path>
description: Aja agenttitehtaan pipeline yhdelle speksille (validointi → architect → developer → reviewer → refactorer → päätös).
---

# /factory:run

Aja agenttitehdas yhdelle speksille. Argumentti `$1` on speksin polku, joko absoluuttinen tai projektin juuresta suhteellinen, esim. `specs/active/login-throttling.md`.

Sinä toimit **orkestraattorina**: et koodaa itse, vaan kutsut agenteja Agent-työkalulla ja siirrät tiedostoja Bashilla. Pidä konteksti siistinä — älä lue koko projektia, vaan vain tarvittavat metat ja outputit.

## Vaiheet

### Step 0 — Validoi speksi

1. Tarkista että `$1` osoittaa olemassaolevaan tiedostoon. Jos ei, pysäytä ja raportoi.
2. Lue speksi ja tarkista että se sisältää **kaikki neljä pakollista kenttää**:
   - `## Tavoite`
   - `## Hyväksyntäkriteerit`
   - `## Edge-caset`
   - `## Scope-out`
3. Jos jokin puuttuu, pysäytä. Tulosta puuttuvat kentät. Älä etene.

### Step 1 — Luo run-kansio

1. Generoi timestamp: `date +%Y%m%d-%H%M%S`
2. Generoi slug speksin tiedostonimestä (poista `.md`, korvaa välilyönnit `-`-merkillä, pienennä).
3. Luo kansio: `<projekti>/.factory/runs/<timestamp>-<slug>/`
   - Käytä `git rev-parse --show-toplevel` projektin juuren löytämiseen. Jos ei git-repo, käytä `pwd`:tä.
4. Kopioi speksi: `cp "$1" .factory/runs/<timestamp>-<slug>/00-spec.md`
5. Alusta `run.json`:
   ```json
   {
     "slug": "<slug>",
     "spec_path": "<original spec path>",
     "started_at": "<ISO 8601>",
     "status": "in_progress",
     "review_rounds": 0,
     "scope_violations": 0,
     "must_fix_total": 0,
     "blocked_reason": null
   }
   ```

### Step 2 — Architect

Kutsu `architect` -agentti Agent-työkalulla. Anna sille run-kansion absoluuttinen polku ja ohje:

> "Lue `<runpath>/00-spec.md` ja kirjoita `<runpath>/01-architect-plan.md` agentin promptin määrittelemän rakenteen mukaisesti. Et kirjoita projektin koodia."

Odota vastaus. Jos vastaus sisältää BLOCKER, päivitä `run.json` (`status: blocked`, `blocked_reason: "architect: ..."`), append metrics, ja lopeta.

### Step 3 — Developer

Kutsu `developer` -agentti. Ohje:

> "Lue `<runpath>/00-spec.md` ja `<runpath>/01-architect-plan.md`. Toteuta suunnitelma vaiheittain. Kirjoita `<runpath>/02-developer-notes.md`. Älä committaa."

Odota vastaus. Jos `phi-stuck`, päivitä `run.json` (`status: blocked`, `blocked_reason: "developer-stuck: ..."`) ja lopeta.

### Step 4 — Reviewer

Aseta laskuri `round = 1`. Kutsu `reviewer` -agentti. Ohje:

> "Tämä on review-kierros <round>. Lue `<runpath>/00-spec.md`, `01-architect-plan.md`, `02-developer-notes.md` ja viimeisin `04-refactor-notes*.md` jos olemassa. Kirjoita `<runpath>/03-review.md` (tai `03-review-r<round>.md` jos round > 1). Aja testit itse. Käytä Agent-työkalua delegointiin tarvittaessa."

Odota vastaus. Tutki suositus.

- **APPROVED** → siirry Step 6:een.
- **MUST_FIX** → siirry Step 5:een.
- **BLOCKED** → päivitä `run.json` (`status: blocked`, `blocked_reason: "reviewer: ..."`), append metrics, lopeta.

### Step 5 — Refactorer

Kutsu `refactorer` -agentti. Ohje:

> "Lue `<runpath>/03-review.md` (tai uusin r<round>) ja korjaa must-fix ja scope-violation -kohdat. Kirjoita `<runpath>/04-refactor-notes.md` (tai `-r<round>`). Älä committaa."

Odota vastaus.

Kasvata `round = round + 1`. Päivitä `run.json` (`review_rounds: round`).

- Jos `round > 3`, päivitä `run.json` (`status: blocked`, `blocked_reason: "max review rounds (3) exceeded"`), append metrics, lopeta.
- Muuten palaa Step 4:ään.

### Step 6 — Päätös

1. Päivitä `run.json`:
   - `status: "approved"`
   - `finished_at: <ISO 8601>`
   - `review_rounds: <lopullinen>`
   - `must_fix_total: <kaikkien kierrosten yhteismäärä>`
   - `scope_violations: <kaikkien kierrosten yhteismäärä>`
2. Append `.factory/metrics.jsonl`:n loppuun yksi JSON-rivi:
   ```json
   {"slug":"...","timestamp":"...","status":"approved","review_rounds":N,"must_fix_total":N,"scope_violations":N,"duration_s":N}
   ```
3. Siirrä speksi: `mv <spec_path> specs/done/<slug>.md`
4. Tulosta yhteenveto käyttäjälle:
   - Slug, status, review-kierrokset, scope-violations
   - Run-kansion polku (jotta käyttäjä voi katsoa)
   - Vinkki: "Diffi ei ole committed — tarkista `git diff` ja committaa kun haluat."

## Virheidenkäsittely

- Jos mikä tahansa Bash-komento epäonnistuu, pysäytä ja raportoi. Älä jatka epäonnistuneen tilan päälle.
- Jos `.factory/`-kansiota ei ole olemassa, ehdota käyttäjälle `templates/factory-init.sh` -skriptin ajamista (agenttitehdas-repossa).
- Älä lue muita tiedostoja kuin run-kansion sisältöä — pidä konteksti pieni.

## Tärkeää

- **Älä committaa** missään vaiheessa. Tehdas tuottaa working tree -muutoksia, käyttäjä päättää committauksesta.
- **Vain paikallinen ajo.** Ei pilveä, ei verkkokutsuja muualle kuin agenttien luonnollisiin työkaluihin.
- **Maksimi 3 must-fix -kierrosta**, sen jälkeen `status: blocked` (ei automaattista jatkoyritystä).
