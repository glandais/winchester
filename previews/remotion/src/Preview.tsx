import {
  AbsoluteFill,
  Audio,
  Img,
  interpolate,
  OffthreadVideo,
  Sequence,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";

// La vidéo de l'App Store : les plans filmés dans l'app, bout à bout en fondu,
// chacun ouvert par le titre de sa carte Koubou ; une invitation à monter le
// son sur le premier, qu'on voit d'abord sans lui ; une carte de fin sous
// laquelle le son du dernier plan s'éteint.
//
// L'habillage reste léger, comme le veut App Store Connect : l'interface plein
// cadre, sans appareil autour, ni prix ni appel à télécharger.

export type Clip = {
  /** Sous public/ : le plan, déjà à la définition et à la cadence finales. */
  video: string;
  /** Sous public/ : son son, pris dans RenderTrace aux mêmes secondes de passe. */
  audio: string;
  /** En secondes, fondu compris. */
  duration: number;
  /** Le titre de la carte Koubou, traduit. */
  title: string;
};

export type PreviewProps = {
  device: "iphone" | "ipad";
  width: number;
  height: number;
  fps: number;
  /** Recouvrement de deux plans voisins, en secondes. */
  transition: number;
  /** Durée de la carte de fin, en secondes. */
  endCard: number;
  soundHint: string;
  appName: string;
  icon: string;
  clips: Clip[];
};

// La palette de l'app (Sources/UI/Theme.swift), celle des cartes Koubou.
const BG = "#0E0F12";
const PANEL = "#191B20";
const READ = "#FFB347";
const WRITE = "#5CD1D1";
const FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", Arial, sans-serif';

/** Où commence chaque plan, en images, et où commence la carte de fin. */
const layout = (p: PreviewProps) => {
  const f = (s: number) => Math.round(s * p.fps);
  const starts: number[] = [];
  let at = 0;
  for (const clip of p.clips) {
    starts.push(at);
    at += f(clip.duration) - f(p.transition);
  }
  const endStart = at;
  return { starts, endStart, total: endStart + f(p.endCard) + f(p.transition) };
};

export const previewDuration = (p: PreviewProps) => layout(p).total;

/** Le motif de l'icône et des cartes : des clusters rangés, un trou, un fragment. */
const Blocks = ({ size, reveal }: { size: number; reveal: number }) => {
  const colors = ["#2563EB", "#3B82F6", "#60A5FA", "#1E2438", READ, "#60A5FA", "#1E2438", WRITE];
  return (
    <div style={{ display: "flex", gap: size * 0.34 }}>
      {colors.map((color, i) => (
        <div
          key={i}
          style={{
            width: size,
            height: size,
            borderRadius: size * 0.22,
            background: color,
            opacity: interpolate(reveal * colors.length - i, [0, 1], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        />
      ))}
    </div>
  );
};

/** Le titre du plan, en haut, sur un voile : il entre, tient, et rend l'écran. */
const Title = ({ text, ipad }: { text: string; ipad: boolean }) => {
  const frame = useCurrentFrame();
  const { fps, width } = useVideoConfig();
  const enter = spring({ frame: frame - Math.round(0.15 * fps), fps, config: { damping: 200 } });
  const leave = interpolate(frame, [3.6 * fps, 4.2 * fps], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const opacity = Math.min(enter, leave);
  const unit = width / 100;
  const fontSize = ipad ? 5.4 * unit : 7.4 * unit;
  return (
    <AbsoluteFill style={{ opacity }}>
      <div
        style={{
          position: "absolute",
          inset: 0,
          bottom: "auto",
          height: ipad ? "30%" : "32%",
          background: `linear-gradient(180deg, ${BG}F5 0%, ${BG}E6 55%, ${BG}00 100%)`,
        }}
      />
      <div
        style={{
          position: "absolute",
          top: ipad ? "5.5%" : "7%",
          left: ipad ? "8%" : "7%",
          right: ipad ? "8%" : "7%",
          transform: `translateY(${(1 - enter) * 3 * unit}px)`,
        }}
      >
        <div
          style={{
            fontFamily: FONT,
            fontWeight: 800,
            fontSize,
            lineHeight: 1.05,
            letterSpacing: "-0.03em",
            color: "#FFFFFF",
            textWrap: "balance",
          }}
        >
          {text}
        </div>
        <div style={{ marginTop: 2.2 * unit }}>
          <Blocks size={(ipad ? 2 : 3) * unit} reveal={enter} />
        </div>
      </div>
    </AbsoluteFill>
  );
};

/** Un haut-parleur dont les ondes battent : l'app se regarde, mais s'écoute. */
const Speaker = ({ size }: { size: number }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const wave = (delay: number) =>
    interpolate(Math.sin(((frame / fps) * 2 - delay) * Math.PI), [-1, 1], [0.25, 1]);
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M4 9.5h3.2L12 5.5v13l-4.8-4H4z" fill="#FFFFFF" />
      <path d="M15.2 9.2a4 4 0 0 1 0 5.6" stroke={READ} strokeWidth="1.8" strokeLinecap="round" opacity={wave(0)} />
      <path d="M17.6 6.8a7.4 7.4 0 0 1 0 10.4" stroke={WRITE} strokeWidth="1.8" strokeLinecap="round" opacity={wave(0.35)} />
    </svg>
  );
};

/** L'invitation à monter le son, en bas du premier plan. */
const SoundHint = ({ text, ipad }: { text: string; ipad: boolean }) => {
  const frame = useCurrentFrame();
  const { fps, width } = useVideoConfig();
  const enter = spring({ frame: frame - Math.round(0.6 * fps), fps, config: { damping: 200 } });
  const unit = width / 100;
  const fontSize = ipad ? 2.6 * unit : 4 * unit;
  return (
    <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: "center" }}>
      <div
        style={{
          marginBottom: ipad ? "8%" : "14%",
          opacity: enter,
          transform: `translateY(${(1 - enter) * 2 * unit}px)`,
          display: "flex",
          alignItems: "center",
          gap: fontSize * 0.5,
          padding: `${fontSize * 0.55}px ${fontSize * 0.95}px`,
          borderRadius: fontSize * 2,
          background: `${PANEL}EB`,
          border: "1px solid rgba(255,255,255,0.14)",
          boxShadow: "0 12px 40px rgba(0,0,0,0.55)",
        }}
      >
        <Speaker size={fontSize * 1.35} />
        <span style={{ fontFamily: FONT, fontWeight: 600, fontSize, color: "#EBEBEB", letterSpacing: "-0.01em" }}>
          {text}
        </span>
      </div>
    </AbsoluteFill>
  );
};

/** La carte de fin : l'icône, le nom, le motif. */
const EndCard = ({ appName, icon, ipad }: { appName: string; icon: string; ipad: boolean }) => {
  const frame = useCurrentFrame();
  const { fps, width } = useVideoConfig();
  const enter = spring({ frame, fps, config: { damping: 200 }, durationInFrames: Math.round(0.7 * fps) });
  const unit = width / 100;
  const iconSize = (ipad ? 22 : 34) * unit;
  return (
    <AbsoluteFill
      style={{
        opacity: enter,
        background: [
          "radial-gradient(90% 55% at 50% 78%, rgba(92,209,209,0.18), rgba(92,209,209,0) 70%)",
          "radial-gradient(70% 40% at 15% 8%, rgba(255,179,71,0.14), rgba(255,179,71,0) 70%)",
          BG,
        ].join(", "),
        justifyContent: "center",
        alignItems: "center",
        gap: (ipad ? 3 : 5) * unit,
      }}
    >
      <Img
        src={staticFile(icon)}
        style={{
          width: iconSize,
          height: iconSize,
          borderRadius: iconSize * 0.2237,
          boxShadow: "0 30px 80px rgba(0,0,0,0.7)",
          transform: `scale(${0.92 + 0.08 * enter})`,
        }}
      />
      <div
        style={{
          fontFamily: FONT,
          fontWeight: 800,
          fontSize: (ipad ? 6 : 9) * unit,
          letterSpacing: "-0.03em",
          color: "#FFFFFF",
        }}
      >
        {appName}
      </div>
      <Blocks size={(ipad ? 2 : 3) * unit} reveal={enter} />
    </AbsoluteFill>
  );
};

/** Un plan qui entre en fondu par-dessus le précédent. */
const FadeIn = ({ frames, children }: { frames: number; children: React.ReactNode }) => {
  const frame = useCurrentFrame();
  const opacity = frames === 0 ? 1 : interpolate(frame, [0, frames], [0, 1], { extrapolateRight: "clamp" });
  return <AbsoluteFill style={{ opacity }}>{children}</AbsoluteFill>;
};

export const Preview = (p: PreviewProps) => {
  const { starts, endStart } = layout(p);
  const f = (s: number) => Math.round(s * p.fps);
  const fade = f(p.transition);
  const ipad = p.device === "ipad";
  const last = p.clips.length - 1;

  return (
    <AbsoluteFill style={{ background: BG }}>
      {p.clips.map((clip, i) => {
        const length = f(clip.duration);
        // Le son du dernier plan continue sous la carte de fin.
        const audioLength = i === last ? length + f(p.endCard) : length;
        return (
          <Sequence key={clip.video} from={starts[i]} durationInFrames={audioLength}>
            <Sequence durationInFrames={length}>
              <FadeIn frames={i === 0 ? 0 : fade}>
                <OffthreadVideo src={staticFile(clip.video)} muted />
                <Title text={clip.title} ipad={ipad} />
                {i === 0 && <SoundHint text={p.soundHint} ipad={ipad} />}
              </FadeIn>
            </Sequence>
            <Audio
              src={staticFile(clip.audio)}
              volume={(t) => {
                // Fondu enchaîné à puissance constante avec les plans voisins ;
                // le dernier s'éteint sur toute la carte de fin.
                const fadeIn = i === 0 ? 1 : Math.sin((Math.min(t / fade, 1) * Math.PI) / 2);
                const fadeOut =
                  i === last
                    ? interpolate(t, [length - fade, audioLength], [1, 0], {
                        extrapolateLeft: "clamp",
                        extrapolateRight: "clamp",
                      })
                    : Math.cos((Math.min(Math.max(t - (length - fade), 0) / fade, 1) * Math.PI) / 2);
                return fadeIn * fadeOut;
              }}
            />
          </Sequence>
        );
      })}
      <Sequence from={endStart}>
        <EndCard appName={p.appName} icon={p.icon} ipad={ipad} />
      </Sequence>
    </AbsoluteFill>
  );
};
