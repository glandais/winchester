#!/usr/bin/env bash
#
# Les vidéos de l'App Store (app previews) : l'image filmée dans l'app, le son
# rendu hors-ligne, l'habillage monté par Remotion.
#
# Le simulateur ne sait filmer que l'écran, et le mode capture coupe le son
# exprès. Mais la démo de défragmentation est déterministe : `ScreenshotMode`
# l'avance jusqu'à la seconde demandée puis la joue en temps réel, et
# `RenderTrace` rend le même son, au bit près, du même modèle
# (`SCENARIO=defrag`). On filme donc chaque plan dans l'app, et on prend son son
# dans le rendu, aux mêmes secondes de passe.
#
# La synchronisation tient à l'horloge du Mac, que le simulateur partage :
# `scripts/sim-record.py` note l'instant de la première image, `ScreenshotMode`
# celui où la lecture part. Leur écart, plus la latence d'affichage (LATENCY),
# dit où la seconde de passe demandée tombe dans la vidéo.
#
# Les plans sont décrits dans `previews/montage.txt`. Pour chaque appareil et
# chaque langue : un enregistrement par plan, découpé et mis à la définition
# d'App Store Connect par `ffmpeg`, puis le montage par Remotion
# (`previews/remotion/`) — fondus, titres des cartes Koubou traduits,
# invitation à monter le son, carte de fin — et le son ramené à -16 LUFS.
#
# Sortie : previews/out/<IPHONE_65|IPAD_PRO_3GEN_129>/<locale>/01-defrag.mp4,
# non versionnée : elle se refait à l'identique, et App Store Connect garde
# l'exemplaire envoyé (`asc video-previews download`). Les enregistrements
# bruts restent sous previews/out/raw/.
#
# Usage : ./scripts/previews.sh [--iphone | --ipad] [locale ...]
#         (par défaut les deux appareils, et toutes les langues de
#          `knownRegions` dans project.yml)
#
# Un seul simulateur à la fois, comme `scripts/screenshots.sh`, dont il partage
# `scripts/sim-capture.sh`. Rien d'autre ne doit piloter le simulateur pendant
# ce temps. Demande `ffmpeg` et Node (`npm ci` se fait tout seul).
#
# Écrit pour le /bin/bash 3.2 de macOS : ni mapfile, ni tableaux associatifs.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sim-config.sh
source scripts/sim-capture.sh

MONTAGE="previews/montage.txt"
OUT_ROOT="previews/out"
REMOTION="previews/remotion"
# Ce que Remotion lit pour un rendu : ses fichiers statiques vivent sous public/.
STAGE="$REMOTION/public/build"
KOUBOU_TABLE="i18n/translations.json"

# Ce qu'on laisse passer après le témoin avant que le plan commence : le plein
# écran de la carte s'ouvre une seconde après.
SKIP=2.5
# L'image arrive à l'écran un peu après l'instant où la lecture part : 30 et
# 55 ms mesurés sur deux enregistrements du plateau, en corrélant le mouvement
# du bras aux attaques des seeks de RenderTrace (le 21 septembre 2026).
LATENCY=0.04
# Deux plans voisins se recouvrent le temps d'un fondu.
TRANSITION=0.5
# La carte de fin, sous laquelle le son du dernier plan continue et s'éteint.
END_CARD=2.5
FPS=30
# L'invitation à monter le son : une clé du catalogue Koubou, comme les titres.
SOUND_HINT="Turn the sound on"

command -v ffmpeg >/dev/null || { echo "✖ ffmpeg manque : brew install ffmpeg" >&2; exit 1; }
command -v npx >/dev/null || { echo "✖ Node manque : brew install node" >&2; exit 1; }

parse_capture_args "$@"

# Définition d'App Store Connect et type d'affichage d'`asc`, par appareil. Le
# simulateur filme en 1320 × 2868 (iPhone 17 Pro Max) et 2064 × 2752 (iPad Pro
# 13 M4) : le même rapport, à 0,3 % près pour l'iPhone, qu'on rogne.
display_type_for() {
  case "$1" in
    iphone) echo "IPHONE_65" ;;
    ipad)   echo "IPAD_PRO_3GEN_129" ;;
  esac
}
frame_size_for() {
  case "$1" in
    iphone) echo "886 1920" ;;
    ipad)   echo "1200 1600" ;;
  esac
}

# ---------------------------------------------------------------- plans

screens=(); starts=(); durations=(); titles=()
while IFS='|' read -r screen start duration title; do
  screens+=("$(echo "$screen" | xargs)")
  starts+=("$(echo "$start" | xargs)")
  durations+=("$(echo "$duration" | xargs)")
  titles+=("$(echo "$title" | sed 's/^ *//; s/ *$//')")
done < <(grep -v '^[[:space:]]*#' "$MONTAGE" | grep -v '^[[:space:]]*$')
[ "${#screens[@]}" -gt 0 ] || { echo "✖ $MONTAGE ne décrit aucun plan" >&2; exit 1; }

total=$(python3 -c '
import sys
d = [float(x) for x in sys.argv[3:]]
print(round(sum(d) - float(sys.argv[1]) * (len(d) - 1) + float(sys.argv[2]), 2))
' "$TRANSITION" "$END_CARD" "${durations[@]}")
python3 -c 'import sys; t = float(sys.argv[1]); sys.exit(0 if 15 <= t <= 30 else 1)' "$total" || {
  echo "✖ la vidéo durerait $total s : App Store Connect veut 15 à 30 s" >&2; exit 1; }
echo "▸ ${#screens[@]} plans, $total s carte de fin comprise"

# Un titre traduit : la clé est la phrase anglaise, la valeur celle de la locale.
translate() {
  python3 - "$KOUBOU_TABLE" "$1" "$2" <<'PY'
import json, sys
path, key, locale = sys.argv[1:4]
keys = json.load(open(path, encoding="utf-8"))["tables"]["Koubou"]["keys"]
if key not in keys:
    sys.exit(f"« {key} » n'est pas une clé du catalogue Koubou ({path})")
value = keys[key]["translations"].get(locale, key)
print(value["value"] if isinstance(value, dict) else value)
PY
}

# ---------------------------------------------------------------- son

TOOLS=".build/tools"
AUDIO="$OUT_ROOT/audio/defrag.wav"
mkdir -p "$TOOLS" "$(dirname "$AUDIO")"
echo "▸ son de la passe (RenderTrace, SCENARIO=defrag)"
./Tools/build-render.sh "$TOOLS/rendertrace" >/dev/null
SCENARIO=defrag "$TOOLS/rendertrace" "$AUDIO" > "$OUT_ROOT/audio/defrag.log" 2>&1

# ---------------------------------------------------------------- Remotion

if [ ! -d "$REMOTION/node_modules" ]; then
  echo "▸ npm ci (previews/remotion)"
  (cd "$REMOTION" && npm ci --no-audit --no-fund >/dev/null)
fi

# ---------------------------------------------------------------- tournage

build_capture_app

# Filme `$1` (écran) dans la langue `$2`, avec la démo avancée à `$3` secondes
# moins SKIP, assez longtemps pour `$4` secondes de plan. Écrit la vidéo brute
# et, dans `$5.offset`, la seconde de la vidéo où commence le plan.
record_clip() {
  local screen="$1" locale="$2" start="$3" duration="$4" raw="$5" started recorder playback
  started="$raw.started"
  rm -f "$raw" "$started"
  scripts/sim-record.py "$CURRENT" "$raw" "$started" &
  recorder=$!
  until [ -s "$started" ]; do sleep 0.05; done
  launch_staged "$screen" "$locale" \
    -screenshotAt "$(python3 -c "print(float('$start') - $SKIP)")"
  playback="$(awk '{ print $2 }' "$(ready_marker)")"
  sleep "$(python3 -c "print($SKIP + float('$duration') + 1)")"
  kill -INT "$recorder"
  wait "$recorder"
  python3 -c "print(round($playback - $(cat "$started") + $LATENCY + $SKIP, 3))" > "$raw.offset"
}

for device in "${devices[@]}"; do
  udid=$(udid_for "$device")
  display="$(display_type_for "$device")"
  read -r width height <<< "$(frame_size_for "$device")"
  echo "▸ $device : ${udid}"
  use_simulator "$udid"
  install_fresh

  for locale in "${locales[@]}"; do
    prepare_locale "$locale"
    raw_dir="$OUT_ROOT/raw/$device/$locale"
    stage_dir="$STAGE/$device-$locale"
    rm -rf "$raw_dir" "$stage_dir"
    mkdir -p "$raw_dir" "$stage_dir"
    echo "▸ $device · $locale"

    clips_json="["
    last=$(( ${#screens[@]} - 1 ))
    for i in "${!screens[@]}"; do
      n=$(printf "%02d" $((i + 1)))
      name="$n-${screens[$i]}"
      raw="$raw_dir/$name.mov"
      record_clip "${screens[$i]}" "$locale" "${starts[$i]}" "${durations[$i]}" "$raw"
      offset="$(cat "$raw.offset")"

      # L'image : le plan seul, à cadence fixe, à la définition d'App Store
      # Connect. La vidéo du simulateur n'a d'images que quand l'écran change.
      ffmpeg -v error -y -ss "$offset" -i "$raw" -t "${durations[$i]}" -an \
        -vf "fps=$FPS,scale=$width:-2:flags=lanczos,crop=$width:$height" \
        -c:v libx264 -preset slow -crf 14 -pix_fmt yuv420p \
        "$stage_dir/$name.mp4"

      # Le son : les mêmes secondes de passe, prises dans le rendu. Le dernier
      # plan continue sous la carte de fin.
      audio_length="${durations[$i]}"
      [ "$i" -eq "$last" ] && audio_length="$(python3 -c "print(float('${durations[$i]}') + $END_CARD)")"
      ffmpeg -v error -y -ss "${starts[$i]}" -t "$audio_length" -i "$AUDIO" \
        -c:a pcm_s16le "$stage_dir/$name.wav"

      title="$(translate "${titles[$i]}" "$locale")"
      [ "$i" -gt 0 ] && clips_json="$clips_json,"
      clips_json="$clips_json$(python3 -c '
import json, sys
print(json.dumps({"video": sys.argv[1], "audio": sys.argv[2],
                  "duration": float(sys.argv[3]), "title": sys.argv[4]}, ensure_ascii=False))
' "build/$device-$locale/$name.mp4" "build/$device-$locale/$name.wav" "${durations[$i]}" "$title")"
      echo "   · $name (plan à ${offset} s de la vidéo brute)"
    done
    clips_json="$clips_json]"

    cp Sources/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png "$STAGE/icon.png"
    props="$stage_dir/props.json"
    python3 - "$props" "$device" "$width" "$height" "$FPS" "$TRANSITION" "$END_CARD" \
      "$(translate "$SOUND_HINT" "$locale")" "$clips_json" <<'PY'
import json, sys
path, device, width, height, fps, transition, end_card, hint, clips = sys.argv[1:10]
json.dump({
    "device": device, "width": int(width), "height": int(height), "fps": int(fps),
    "transition": float(transition), "endCard": float(end_card),
    "soundHint": hint, "appName": "Winchester", "icon": "build/icon.png",
    "clips": json.loads(clips),
}, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY

    out_dir="$OUT_ROOT/$display/$locale"
    mkdir -p "$out_dir"
    # Du H.264 en Matroska : le seul conteneur où Remotion garde le son en PCM,
    # qu'on ne compresse ainsi qu'une fois, après la normalisation.
    montage="$stage_dir/montage.mkv"
    echo "   · montage (Remotion)"
    (cd "$REMOTION" && npx remotion render src/index.ts Preview "../../$montage" \
      --props="../../$props" --codec=h264-mkv --crf=16 --audio-codec=pcm-16 --log=error)
    # Le son à -16 LUFS, celui d'une app qu'on écoute sur un téléphone, en AAC
    # stéréo 256 kb/s comme le demande App Store Connect ; l'image ne bouge pas.
    ffmpeg -v error -y -i "$montage" -c:v copy \
      -af "loudnorm=I=-16:TP=-1.5:LRA=11" -c:a aac -b:a 256k -ar 48000 -ac 2 \
      -movflags +faststart "$out_dir/01-defrag.mp4"
    echo "   · $out_dir/01-defrag.mp4"
  done
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------- vérifications

echo "▸ forme des vidéos"
for device in "${devices[@]}"; do
  read -r width height <<< "$(frame_size_for "$device")"
  for locale in "${locales[@]}"; do
    file="$OUT_ROOT/$(display_type_for "$device")/$locale/01-defrag.mp4"
    python3 - "$file" "$width" "$height" "$FPS" <<'PY'
import json, subprocess, sys
path, width, height, fps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
probe = json.loads(subprocess.run(
    ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path],
    capture_output=True, text=True, check=True).stdout)
video = next(s for s in probe["streams"] if s["codec_type"] == "video")
audio = [s for s in probe["streams"] if s["codec_type"] == "audio"]
duration = float(probe["format"]["duration"])
problems = []
if (video["width"], video["height"]) != (width, height):
    problems.append(f"{video['width']}x{video['height']} au lieu de {width}x{height}")
if video["codec_name"] != "h264":
    problems.append(f"image en {video['codec_name']}, pas en H.264")
num, den = (int(x) for x in video["avg_frame_rate"].split("/"))
if abs(num / den - fps) > 0.01:
    problems.append(f"{num / den:.2f} i/s au lieu de {fps}")
if not 15 <= duration <= 30:
    problems.append(f"{duration:.2f} s, hors de 15 à 30 s")
if len(audio) != 1 or audio[0]["codec_name"] != "aac" or audio[0]["channels"] != 2:
    problems.append("pas une piste AAC stéréo")
if problems:
    sys.exit(f"✖ {path} : " + " ; ".join(problems))
print(f"   · {path} : {width}x{height}, {fps} i/s, {duration:.2f} s, AAC stéréo")
PY
  done
done

echo "▸ fini. Envoi : voir « App previews » dans CLAUDE.md."
