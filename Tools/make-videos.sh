#!/bin/sh
# Fabrique les vidéos décrites dans Tools/videos.txt.
#
#   ./Tools/make-videos.sh                 # tout le lot
#   ./Tools/make-videos.sh defrag-frontiere  # les lignes dont le nom commence ainsi
#
# Les vidéos vont dans .build/videos/. Une vidéo déjà présente n'est pas refaite :
# supprimer le fichier pour la reconstruire. JOBS règle le parallélisme (2) —
# chaque rendu occupe un cœur de simulation et un encodeur.
set -e
cd "$(dirname "$0")/.."

OUT_DIR="${OUT_DIR:-.build/videos}"
JOBS="${JOBS:-2}"
TOOLS="${TOOLS:-.build/tools}"
FILTER="$1"

mkdir -p "$OUT_DIR" "$TOOLS"
./Tools/build-render.sh "$TOOLS/rendertrace"

# Une ligne par vidéo à rendre : variables, puis chemin de sortie.
JOBLIST="$OUT_DIR/.jobs"
: > "$JOBLIST"
grep -v '^[[:space:]]*#' Tools/videos.txt | grep -v '^[[:space:]]*$' |
while IFS='|' read -r name vars variants; do
    name=$(echo "$name" | xargs)
    case "$name" in "$FILTER"*) ;; *) continue ;; esac
    for variant in $variants; do
        case "$variant" in
            full)      env="LAYOUT=landscape"; suffix="integrale" ;;
            fast:*)    env="LAYOUT=landscape FIT_SECONDS=${variant#fast:}"; suffix="acceleree" ;;
            short:*)   env="LAYOUT=short FIT_SECONDS=${variant#short:}"; suffix="short" ;;
            *) echo "déclinaison inconnue : $variant ($name)" >&2; exit 1 ;;
        esac
        output="$OUT_DIR/$name-$suffix.mp4"
        [ -f "$output" ] && { echo "déjà là : $output"; continue; }
        echo "$vars $env|$output" >> "$JOBLIST"
    done
done

[ -s "$JOBLIST" ] || { echo "rien à rendre"; exit 0; }

# shellcheck disable=SC2016 # développé par le sous-shell
tr '\n' '\0' < "$JOBLIST" | xargs -0 -P "$JOBS" -I{} sh -c '
    job="$1"; vars="${job%|*}"; output="${job#*|}"
    log="${output%.mp4}.log"
    echo "→ $output"
    if env $vars "$0" "$output" > "$log" 2>&1; then
        tail -1 "$log"
    else
        echo "échec : $output (voir $log)" >&2
    fi
' "$TOOLS/rendervideo" {}
rm -f "$JOBLIST"
