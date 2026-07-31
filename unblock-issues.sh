#!/bin/bash
# unblock-issues.sh — poistaa `blocked`-labelin niiltä avoimilta issueilta,
# joiden KAIKKI natiivit blocked_by-riippuvuudet (GitHub issue dependencies)
# ovat suljettuja. Näin run-issues-poller — joka EI lue natiiveja riippuvuuksia
# vaan pelkkää `blocked`-labelia — nappaa issuen vasta kun sen edeltäjät ovat
# valmistuneet. Natiivi blocked_by-graafi on ainoa totuuden lähde.
#
# Käyttö:
#   unblock-issues.sh [-R owner/repo] [-l label] [-n] [-v]
#     -R, --repo      Kohderepo owner/repo (oletus: nykyisen hakemiston remote).
#     -l, --label     Estolabelin nimi (oletus: blocked).
#     -n, --dry-run   Näytä mitä tehtäisiin, älä muokkaa mitään.
#     -v, --verbose   Tulosta myös blokattuina pysyvät + niiden avoimet edeltäjät.
#     -h, --help      Tämä ohje.
#
# Vaatii: gh (autentikoitu, repo-scope) ja jq.
# Turvallista ajaa toistuvasti — idempotentti. Ei kosketa issueihin, joilla on
# `blocked`-label mutta EI yhtään natiivia blocked_by-riippuvuutta (orvot
# jätetään käsin hallittavaksi).

set -euo pipefail

REPO=""
LABEL="blocked"
DRY_RUN=0
VERBOSE=0

die() { echo "virhe: $*" >&2; exit 1; }

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo)    REPO="${2:-}"; shift 2 ;;
    -l|--label)   LABEL="${2:-}"; shift 2 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)    usage 0 ;;
    *)            die "tuntematon argumentti: $1 (ks. --help)" ;;
  esac
done

command -v gh >/dev/null 2>&1 || die "gh ei ole asennettu / PATH:issa"
command -v jq >/dev/null 2>&1 || die "jq ei ole asennettu / PATH:issa"

# Repon päättely, jos ei annettu -R:llä.
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) \
    || die "repoa ei annettu (-R) eikä sitä voitu päätellä (aja git-repossa tai anna -R owner/repo)"
fi

echo "# unblock-issues — repo: $REPO — label: $LABEL$([ "$DRY_RUN" = 1 ] && echo '  (DRY-RUN)')"

# Kaikki avoimet issuet, joilla on estolabeli. (while-read: bash 3.2 -yhteensopiva,
# macOS:n /bin/bash ei tue mapfilea.)
BLOCKED=()
while IFS= read -r num; do
  [ -n "$num" ] && BLOCKED+=("$num")
done < <(gh issue list --repo "$REPO" --state open --label "$LABEL" \
  --limit 500 --json number --jq '.[].number' | sort -n)

if [ "${#BLOCKED[@]}" -eq 0 ]; then
  echo "Ei avoimia \`$LABEL\`-issueita — ei tehtävää."
  exit 0
fi

released=0; kept=0; orphans=0

for n in "${BLOCKED[@]}"; do
  # Natiivit blocked_by-riippuvuudet. Endpoint palauttaa taulukon issue-objekteja
  # (kentät mm. number, state). Virhe / ei-taulukko -> ohita turvallisesti.
  resp=$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by" 2>/dev/null || true)
  if ! printf '%s' "$resp" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "  ?? #$n  blocked_by-tietoja ei saatu — ohitetaan (ei muutosta)"
    kept=$((kept + 1))
    continue
  fi

  total=$(printf '%s' "$resp" | jq 'length')
  if [ "$total" -eq 0 ]; then
    echo "  ~~ #$n  \`$LABEL\`-label ilman natiivia blocked_by-riippuvuutta — jätetään käsin hallittavaksi"
    orphans=$((orphans + 1))
    continue
  fi

  open_nums=$(printf '%s' "$resp" | jq -r '[.[] | select(.state != "closed") | "#\(.number)"] | join(", ")')

  if [ -z "$open_nums" ]; then
    # Kaikki edeltäjät suljettu -> vapauta.
    if [ "$DRY_RUN" = 1 ]; then
      echo "  -> #$n  VAPAUTETTAISIIN (kaikki $total edeltäjää suljettu)"
    else
      gh issue edit "$n" --repo "$REPO" --remove-label "$LABEL" >/dev/null
      echo "  ✔  #$n  VAPAUTETTU (kaikki $total edeltäjää suljettu)"
    fi
    released=$((released + 1))
  else
    [ "$VERBOSE" = 1 ] && echo "  ·  #$n  pysyy blokattuna — avoimet edeltäjät: $open_nums"
    kept=$((kept + 1))
  fi
done

echo "# yhteenveto: vapautettu=$released  pysyi=$kept  orpo=$orphans  (yhteensä ${#BLOCKED[@]})"
