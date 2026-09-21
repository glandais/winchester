import { Config } from "@remotion/cli/config";

// Les plans arrivent déjà à la définition et à la cadence d'App Store Connect
// (scripts/previews.sh) : Remotion ne fait que les monter et les habiller.
Config.setVideoImageFormat("png");
Config.setOverwriteOutput(true);
