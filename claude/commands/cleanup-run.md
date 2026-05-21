---
argument-hint: [<run-id> | --list | --all | --issue <N>]
description: Siivoa keskenjääneen /run-issues-ajon worktree, branch, run-dir, GitHub-assignaatio ja paikallinen lukko.
---

# /cleanup-run

Helper-skripti `/run-issues`-orkestraattorin keskenjääneiden ajojen siivoukseen. Aja **kohderepon juuressa** ja **ajokoneella** — worktree, run-dir ja lukko sijaitsevat sillä koneella, jossa ajo tapahtui. Autoflow-ajot ajetaan Studiolla, joten niiden siivous on tehtävä siellä:

```bash
ssh studio '~/.claude/scripts/run-issues/cleanup-run.sh --issue <N> --force --yes'
```

## Yleisimmät käyttötavat

```bash
"$HOME/.claude/scripts/run-issues/cleanup-run.sh" --list                # näytä kaikki ajot
"$HOME/.claude/scripts/run-issues/cleanup-run.sh" 20260519-132510-issue-18
"$HOME/.claude/scripts/run-issues/cleanup-run.sh" --issue 18            # kaikki issue-18:n ajot
"$HOME/.claude/scripts/run-issues/cleanup-run.sh" --all                 # kaikki ei-completed ajot
```

## Käyttäjän antama argumentti

Korvaa `$ARGS` käyttäjän antamilla argumenteilla (esim. `--list`, `<run-id>`, `--issue 19`, `--all`):

```bash
"$HOME/.claude/scripts/run-issues/cleanup-run.sh" $ARGS
```

## Liput

- `--dry-run` — näytä komennot, älä aja
- `-y` / `--yes` — ohita vahvistus
- `--force` — salli myös `completed`-tilan ajojen siivous (oletuksena niitä ei kosketa, koska niillä on yleensä avoin PR)
- `--repo <path>` — eri kohderepo kuin nykyinen `pwd`

## Mitä siivotaan

Jokaisen ajon kohdalla skripti tekee `run.json`:n perusteella:

1. **GitHub-assignaatio + `needs-human`-label** (`gh issue edit --remove-assignee @me --remove-label needs-human`)
2. **Worktree** (`git worktree remove --force`)
3. **Branch** (`git branch -D`)
4. **DB-klooni** — **siivotaan automaattisesti** (`db-clone.sh cleanup`, best-effort). Jos drop epäonnistuu, skripti varoittaa eikä kaada siivousta — droppaa silloin manuaalisesti backend-kohtaisilla työkaluilla (`wp db drop`, `dropdb`, `docker compose down -v`).
5. **Arkisto** — olennaiset artefaktit (`run.json`, `state.jsonl`, `01-cycle-review.out`, `03-evolution.out`) kopioidaan hakemistoon `.claude/run-issues-archive/<run-id>/` ennen run-dirin poistoa.
6. **Run-kansio** (`rm -rf .claude/run-issues/<run-id>`)
7. **Paikallinen lukko** (`rm -rf ~/Library/Application Support/run-issues/locks/issue-N.lock`)

## Turvasäännöt

- `status=completed` -ajot ohitetaan ilman `--force` (PR yleensä auki)
- Vahvistuskysely ennen toimenpiteitä — voit hyväksyä kaikki `--yes`-lipulla
- Käytä `--dry-run` ensin jos epävarma
