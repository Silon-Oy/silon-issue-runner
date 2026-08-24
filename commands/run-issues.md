---
argument-hint: "#N"
description: Aja /run-issues-orkestraattori nimetylle issuelle (`#N`). Issuenumero on pakollinen — automaattinen poiminta on pollerin tehtävä.
---

# /run-issues

Geneerinen issue-pohjainen kehitysworkflow. Orkestraattori on **kaksivaiheinen tilakone**:

1. **Vaihe A** (S1..S6): pick → claim → worktree → db-clone → cycle-review.
2. **Review gate**: interaktiivisessa tilassa orkestraattori exittaa exit-koodilla **10** ja kirjoittaa `awaiting_review`-tapahtuman state.jsonl:ään. Tämä komento esittää cycle-review-tulokset maintainerlle ja kysyy lupaa jatkaa.
3. **Vaihe B** (S8..S12): implementer → evolution → push → PR. Käynnistetään `--resume`-kutsulla decisionin perusteella.

Tämä rakenne toimii sekä silloin kun Claude Coden Bash-työkalu ajaa orkestraattorin etualalla että silloin kun se siirtää sen taustalle — review-gate ei nojaa stdin-lukuun.

## 1. Aja vaihe A

Käytä **nykyistä työhakemistoa kohdereposijaintina** (`pwd`). **Issuenumero on pakollinen.**
Jos käyttäjä ei antanut argumenttia `#N`, tulosta usage-viesti äläkä kutsu orkestraattoria
lainkaan — automaattinen poiminta on pollerin tehtävä, ei tämän komennon.

```bash
REPO_ROOT=$(pwd)
# ISSUE_ARG: käyttäjän antama issuenumero, esim. "19" (ilman #-etuliitettä myös kelpaa).
ISSUE_ARG="<n>"          # esim. "19" jos käyttäjä antoi #19

# Ilman numeroa: älä aja orkestraattoria.
if [ -z "$ISSUE_ARG" ] || [ "$ISSUE_ARG" = "<n>" ]; then
  echo "usage: /run-issues #N — anna ajettava issuenumero (automaattinen poiminta on pollerin tehtävä)."
  exit 0
fi

set +e
"$HOME/.claude/scripts/run-issues/orchestrate.sh" "$REPO_ROOT" "$ISSUE_ARG"
RC=$?
set -e
echo "ORCHESTRATE_EXIT=$RC"
```

## 2. Toimi exit-koodin mukaan

| RC | Mitä tarkoittaa | Mitä tee |
|---|---|---|
| 0 | Valmis (auto-tila tai resume-cancel) | Tulosta lopputulos. Jos `<repo>/.claude/run-issues/<run-id>/run.json` sisältää `pr_url`, näytä se. |
| 10 | Awaiting review — vaihe A valmis | Etene **kohtaan 3**. |
| 3 | Lock/claim race hävitty | Joku toinen runner ajaa samaa issueta. Lopeta hiljaa. |
| 4,5,6 | Vaihe blocked / virhe | Lue tuoreimman ajon `state.jsonl` viimeinen rivi, tulosta `blocked_reason`. |
| 8 | Puuttuva riippuvuus — mitään ei aloitettu | Tulosta orkestraattorin virheviesti **sellaisenaan**; se sisältää korjauskomennon. Älä tulosta usagea. |
| 1 | Käyttövirhe | Tulosta usage. |

## 3. Review gate (vain jos RC=10)

a) Etsi tuoreimman ajon kansio:

```bash
RUN_DIR=$(ls -td "$REPO_ROOT"/.claude/run-issues/*/ 2>/dev/null | head -1 | sed 's:/$::')
echo "RUN_DIR=$RUN_DIR"
```

b) Lue cycle-review-output ja state:

```bash
cat "$RUN_DIR/01-cycle-review.out"
echo "---"
tail -5 "$RUN_DIR/state.jsonl"
```

c) Esitä maintainerlle **tiivis** yhteenveto cycle-reviewn päätöksestä (CYCLE_REVIEW_DECISION + 2–4 keskeistä havaintoa). Kysy AskUserQuestion-työkalulla:

- **"Kyllä, jatka"** → vaihe B PROCEED-päätöksellä (kohta 4 alla)
- **"Peruuta"** → vaihe B CANCEL-päätöksellä (kohta 4 alla; siivoaa assignaation, jättää worktreen)

Jos cycle-review-päätös on `BLOCKER` tai `NEEDS_CLARIFICATION`, nosta se esiin — maintainer näkee suoraan että jatkaminen on riskialtista.

## 4. Aja vaihe B (PROCEED) tai peruutus (CANCEL)

```bash
# PROCEED:
"$HOME/.claude/scripts/run-issues/orchestrate.sh" --resume "$RUN_DIR" --decision PROCEED

# tai CANCEL:
"$HOME/.claude/scripts/run-issues/orchestrate.sh" --resume "$RUN_DIR" --decision CANCEL
```

Exit-koodit kohdan 2 taulukon mukaan. PROCEED-onnistumisessa PR-URL löytyy `run.json`:n `pr_url`-kentästä ja state.jsonl:n `pr_opened`-rivistä.

## Huomioita

- **Auto-tila (Studion poller)** asettaa `RUN_ISSUES_AUTO=1` ja `RUN_ISSUES_REVIEW_GATE=auto`, jolloin S7 ei exittaa 10:llä vaan päättää itse PROCEED/BLOCKER cycle-reviewn output-rivin perusteella. Slash-komentoa ei silloin tarvita.
- **Automaattinen poiminta on pollerin tehtävä.** Tämä komento ajaa vain nimetyn issuen; ilman numeroa se ei kutsu orkestraattoria. `orchestrate.sh <repo> poll` on käyttövirhe (exit 1).
- **Lukko ja assignaatio** pysyvät paikoillaan exit-koodilla 10 — vaihe B saa saman issuen omakseen.
- **Worktree** jätetään aina paikoilleen forensiseksi artefaktiksi; maintainer poistaa sen manuaalisesti tai Phase 2 -PR-valvoja hoitaa siivouksen mergeyksen jälkeen.
