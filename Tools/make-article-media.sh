#!/bin/sh
# Les sons et les vidéos du billet du site (docs/writing/simulating-a-hard-disk/),
# refaits à l'identique depuis le modèle : rien n'y est enregistré.
#
#   ./Tools/make-article-media.sh           # tout, ~5 min
#   ./Tools/make-article-media.sh audio     # les extraits seuls
#   ./Tools/make-article-media.sh video     # les deux vidéos seules
#
# Les extraits sont découpés dans un rendu complet de `RenderTrace`, sans
# normalisation : deux extraits d'une même paire gardent leur rapport de
# niveau. Les vidéos sont celles de `RenderVideo` en anglais (`VIDEO_LANG=en`),
# accélérées pour tenir en une minute, puis réduites en 720p : le site est
# servi par GitHub Pages, dont la bande passante est comptée.
#
# Les fichiers sortent dans le dossier `media/` du billet et sont versionnés :
# Pages ne sert que ce qui est dans le dépôt.
set -e
cd "$(dirname "$0")/.."

WHAT="${1:-all}"
OUT=docs/writing/simulating-a-hard-disk/media
WORK="${WORK:-.build/article-media}"
TOOLS="${TOOLS:-.build/tools}"
mkdir -p "$OUT" "$WORK" "$TOOLS"
./Tools/build-render.sh "$TOOLS/rendertrace"

# Un rendu complet, gardé dans $WORK : un second passage ne le refait pas.
render() {  # nom, variables…
    name=$1; shift
    [ -f "$WORK/$name.wav" ] && return
    echo "→ $name"
    env "$@" "$TOOLS/rendertrace" "$WORK/$name.wav" > "$WORK/$name.log" 2>&1
}

# Un extrait : début et durée en secondes, fondu court à l'entrée, plus long
# à la sortie. AAC en .m4a, que tous les navigateurs lisent.
clip() {  # rendu, extrait, début, durée
    fade_out=$(echo "$4 - 0.6" | bc)
    ffmpeg -hide_banner -loglevel error -y -ss "$3" -t "$4" -i "$WORK/$1.wav" \
        -af "afade=t=in:d=0.05,afade=t=out:st=$fade_out:d=0.6" \
        -c:a aac -b:a 128k -movflags +faststart "$OUT/$2.m4a" < /dev/null
    echo "   $2.m4a"
}

if [ "$WHAT" = all ] || [ "$WHAT" = audio ]; then
    # Le démarrage par défaut : secretaire-1999, Windows 98 sur un 4 Go à
    # 5 400 tr/min. Mise sous tension, noyau, pilotes — puis la tête seule,
    # puis la rotation seule, sur les mêmes secondes.
    render boot
    render boot-head        SPINDLE_GAIN=0
    render boot-spindle     TRANSIENT_GAIN=0
    # La rotation seule de deux disques de famille : roulement à billes en
    # 1996, palier fluide en 2003.
    render spin-1996        SCENARIO=boot:famille-1996 TRANSIENT_GAIN=0
    render spin-2003        SCENARIO=boot:famille-2003 TRANSIENT_GAIN=0
    # Un démarrage de XP : le préchargeur lit par lots, en balayages.
    render boot-xp          SCENARIO=boot:famille-2003
    # dev-1993, deux outils : celui de l'époque (24 min 42) et la frontière
    # (5 min 31), pour le même résultat.
    render defrag-dos       SCENARIO=dev-1993
    render defrag-frontier  SCENARIO=defrag

    clip boot            boot-1999          0   20
    clip boot-head       boot-1999-head     0   20
    clip boot-spindle    boot-1999-spindle  0   20
    clip spin-1996       spindle-1996-ball  22  10
    clip spin-2003       spindle-2003-fluid 22  10
    clip boot-xp         boot-xp-2003       5   15
    clip defrag-dos      defrag-dos-1993    600 15
    clip defrag-frontier defrag-frontier-1993 200 15
fi

if [ "$WHAT" = all ] || [ "$WHAT" = video ]; then
    subtitle="“Developer, 1993”: a 210 MB FAT16 volume aged by two years of builds"
    video() {  # nom, titre, variables…
        name=$1; title=$2; shift 2
        if [ ! -f "$WORK/$name.mp4" ]; then
            echo "→ $name.mp4"
            env "$@" VIDEO_LANG=en VIDEO_TITLE="$title" VIDEO_SUBTITLE="$subtitle" \
                LAYOUT=landscape FIT_SECONDS=60 ENCODER=x264 \
                "$TOOLS/rendervideo" "$WORK/$name.mp4" > "$WORK/$name-video.log" 2>&1
        fi
        ffmpeg -hide_banner -loglevel error -y -i "$WORK/$name.mp4" \
            -vf scale=1280:-2 -c:v libx264 -preset slow -crf 26 -tune animation \
            -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart "$OUT/$name.mp4" < /dev/null
        # L'affiche : la passe à mi-course, carte à moitié rangée.
        ffmpeg -hide_banner -loglevel error -y -ss 30 -i "$OUT/$name.mp4" \
            -frames:v 1 -q:v 5 "$OUT/$name.jpg" < /dev/null
        echo "   $name.mp4, $name.jpg"
    }
    video defrag-dos-1993      "MS-DOS 6 DEFRAG"     SCENARIO=dev-1993
    video defrag-frontier-1993 "Frontier compaction" SCENARIO=defrag
fi

du -sh "$OUT"
