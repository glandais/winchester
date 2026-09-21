import { Composition } from "remotion";
import { Preview, previewDuration, type PreviewProps } from "./Preview";

// Des valeurs d'exemple pour `npm run studio` ; scripts/previews.sh passe les
// vraies par --props (public/build/<appareil>-<locale>/props.json).
const sample: PreviewProps = {
  device: "iphone",
  width: 886,
  height: 1920,
  fps: 30,
  transition: 0.5,
  endCard: 2.5,
  soundHint: "Turn the sound on",
  appName: "Winchester",
  icon: "build/icon.png",
  clips: [
    { video: "build/iphone-en-US/01-fullmap.mp4", audio: "build/iphone-en-US/01-fullmap.wav", duration: 9.5, title: "Hear a hard disk tidy itself" },
    { video: "build/iphone-en-US/02-platter.mp4", audio: "build/iphone-en-US/02-platter.wav", duration: 10, title: "Watch the arm cross the platter" },
    { video: "build/iphone-en-US/03-pass.mp4", audio: "build/iphone-en-US/03-pass.wav", duration: 8.5, title: "Every seek computed, not sampled" },
  ],
};

export const RemotionRoot = () => (
  <Composition
    id="Preview"
    component={Preview}
    defaultProps={sample}
    width={sample.width}
    height={sample.height}
    fps={sample.fps}
    durationInFrames={previewDuration(sample)}
    calculateMetadata={({ props }) => ({
      width: props.width,
      height: props.height,
      fps: props.fps,
      durationInFrames: previewDuration(props),
    })}
  />
);
