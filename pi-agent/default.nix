{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs_22,
  pkg-config,
  python3,
  cairo,
  pango,
  libpng,
  libjpeg,
  giflib,
  pixman,
  librsvg,
}:

buildNpmPackage (finalAttrs: {
  pname = "pi-coding-agent";
  version = "v0.52.12";
  nodejs = nodejs_22;

  src = fetchFromGitHub {
    owner = "badlogic";
    repo = "pi-mono";
    rev = finalAttrs.version;
    hash = "sha256-SJCnibEcfUBVmCOS/eOFIFWjN92IDd/DnM7lBEVy7+k=";
  };

  npmDepsHash = "sha256-OqVji8bRt/TRvtTnkGBzGTMBXTX3LwxdpSeZcC82vmI=";
  npmWorkspace = "packages/coding-agent";
  npmPackFlags = [ "--workspace=@mariozechner/pi-coding-agent" ];
  npmInstallFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [
    pkg-config
    python3
  ];

  buildInputs = [
    cairo
    pango
    libpng
    libjpeg
    giflib
    pixman
    librsvg
  ];

  # TODO remove
  postPatch = ''
    substituteInPlace packages/ai/src/models.ts \
      --replace-fail "TProvider extends KnownProvider" "TProvider extends keyof (typeof MODELS) & KnownProvider"
    substituteInPlace packages/ai/src/utils/oauth/github-copilot.ts \
      --replace-fail "getModels(\"github-copilot\")" "getModels(\"github-copilot\" as never)"
    substituteInPlace packages/agent/src/agent.ts \
      --replace-fail "getModel(\"google\", \"gemini-2.5-flash-lite-preview-06-17\")" "getModel(\"google\" as never, \"gemini-2.5-flash-lite-preview-06-17\")"
    substituteInPlace packages/coding-agent/src/core/model-registry.ts \
      --replace-fail "getModels(provider as KnownProvider)" "getModels(provider as never)"
  '';

  preBuild = ''
    npm run build --workspace @mariozechner/pi-tui
    npm run build --workspace @mariozechner/pi-ai
    npm run build --workspace @mariozechner/pi-agent-core
  '';

  postInstall = ''
    cp -r packages "$out/lib/node_modules/pi-monorepo/"
  '';

  dontCheckForBrokenSymlinks = true;

  meta = {
    description = "AI coding agent CLI";
    homepage = "https://github.com/badlogic/pi-mono";
    license = lib.licenses.mit;
    mainProgram = "pi";
  };
})
