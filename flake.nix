{
  description = "BrowserOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      chromiumVersion = "146.0.7680.31";
      chromiumBaseCommit = lib.strings.removeSuffix "\n" (builtins.readFile ./packages/browseros/BASE_COMMIT);
      browserosVersion = "0.45.2";
      serverVersion = "0.0.93";

      chromiumSrc = pkgs.fetchurl {
        url = "https://chromium.googlesource.com/chromium/src/+archive/${chromiumBaseCommit}.tar.gz";
        hash = "sha256-OPFn/IMC7tLiX5CbbWXnYnDs6zOSZUSu8F6GAvSIQTQ=";
      };

      serverResourcesZip = pkgs.fetchurl {
        url = "https://cdn.browseros.com/artifacts/server/${serverVersion}/browseros-server-resources-linux-x64.zip";
        hash = "sha256-1IGelf/ltzQt1T4TpsCrlzj5if3iVNhRU/raXfIxYeg=";
      };

      python = pkgs.python312.withPackages (
        ps: with ps; [
          click
          typer
          pyyaml
          requests
          boto3
          python-dotenv
          pillow
          cryptography
        ]
      );

      llvm = pkgs.llvmPackages;

      runtimeLibs = with pkgs; [
        alsa-lib
        atk
        at-spi2-atk
        at-spi2-core
        cairo
        cups
        dbus-glib
        expat
        fontconfig
        freetype
        glib
        gtk3
        libdrm
        libgbm
        libGL
        libkrb5
        libsecret
        libva
        libxkbcommon
        nspr
        nss
        pango
        pipewire
        stdenv.cc.cc
        wayland
        libx11
        libxcomposite
        libxcursor
        libxdamage
        libxext
        libxfixes
        libxi
        libxrandr
        libxscrnsaver
        libxtst
        libxcb
        libxshmfence
        zlib
      ];

      buildDeps = with pkgs; runtimeLibs ++ [
        bison
        bzip2
        curl
        flac
        gperf
        libcap
        libevent
        libffi
        libepoxy
        libevdev
        libjpeg
        libopus
        libusb1
        libwebp
        libxml2
        libxslt
        llvm.bintools
        minizip
        nasm
        nodejs
        pciutils
        protobuf
        re2
        snappy
        speechd-minimal
        util-linux
      ];

      autoninja = pkgs.writeShellScriptBin "autoninja" ''
        exec ${pkgs.ninja}/bin/ninja "$@"
      '';

      browserosPrepared = pkgs.stdenv.mkDerivation {
        pname = "browseros-prepared";
        version = chromiumVersion;
        src = chromiumSrc;

        nativeBuildInputs = [
          autoninja
          pkgs.git
          pkgs.gn
          pkgs.gnutar
          pkgs.makeWrapper
          pkgs.nodejs
          pkgs.perl
          pkgs.pkg-config
          python
          pkgs.unzip
          pkgs.which
          pkgs.xz
          llvm.clang
          llvm.lld
        ];

        buildInputs = buildDeps;

        dontConfigure = true;
        dontBuild = true;

        unpackPhase = ''
          runHook preUnpack

          mkdir chromium-src
          tar -xzf "$src" -C chromium-src

          cp -r ${./packages/browseros} browseros-build
          chmod -R u+w chromium-src browseros-build

          mkdir -p browseros-build/resources/binaries/browseros_server/linux-x64
          unzip -qq ${serverResourcesZip} -d browseros-build/resources/binaries/browseros_server/linux-x64

          runHook postUnpack
        '';

        patchPhase = ''
          runHook prePatch

          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"

          # BrowserOS falls back to `git apply --3way` for some patches, which
          # requires a repository with the original blobs available locally.
          git -C chromium-src init -q
          git -C chromium-src add -A

          mkdir -p chromium-src/third_party/node/linux/node-linux-x64/bin
          ln -sf ${pkgs.nodejs}/bin/node chromium-src/third_party/node/linux/node-linux-x64/bin/node

          mkdir -p chromium-src/third_party/jdk/current/bin
          ln -sf ${pkgs.jdk17_headless}/bin/java chromium-src/third_party/jdk/current/bin/java

          substituteInPlace browseros-build/build/modules/setup/configure.py \
            --replace-fail "        if IS_LINUX():" "        if False and IS_LINUX():"

          cat >> browseros-build/build/config/gn/flags.linux.debug.gn <<EOF
          use_sysroot = false
          use_custom_libcxx = false
          clang_base_path = "${llvm.clang-unwrapped}"
          EOF

          export PATH="${lib.makeBinPath [ autoninja pkgs.gn pkgs.ninja llvm.clang llvm.lld pkgs.git pkgs.which ]}:$PATH"
          export PYTHONPATH="$PWD/browseros-build"

          python -m build.browseros build \
            --chromium-src "$PWD/chromium-src" \
            --arch x64 \
            --build-type debug \
            --modules resources,chromium_replace,string_replaces,patches,configure

          runHook postPatch
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p $out
          cp -r chromium-src $out/chromium-src
          cp -r browseros-build $out/browseros-build

          runHook postInstall
        '';
      };

      browseros = pkgs.stdenv.mkDerivation {
        pname = "browseros";
        version = browserosVersion;
        src = browserosPrepared;

        nativeBuildInputs = [
          autoninja
          pkgs.makeWrapper
          pkgs.nodejs
          pkgs.perl
          pkgs.pkg-config
          python
          pkgs.which
          llvm.clang
          llvm.lld
        ];

        buildInputs = buildDeps;

        dontConfigure = true;

        unpackPhase = ''
          runHook preUnpack

          cp -r $src/chromium-src chromium-src
          cp -r $src/browseros-build browseros-build
          chmod -R u+w chromium-src browseros-build

          runHook postUnpack
        '';

        buildPhase = ''
          runHook preBuild

          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"

          export PATH="${lib.makeBinPath [ autoninja pkgs.gn pkgs.ninja llvm.clang llvm.lld pkgs.git pkgs.which ]}:$PATH"
          export PYTHONPATH="$PWD/browseros-build"

          python -m build.browseros build \
            --chromium-src "$PWD/chromium-src" \
            --arch x64 \
            --build-type debug \
            --modules compile

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p $out/bin $out/libexec/browseros
          cp -r chromium-src/out/Default_x64/. $out/libexec/browseros/

          makeWrapper $out/libexec/browseros/browseros $out/bin/browseros \
            --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeLibs}:$out/libexec/browseros" \
            --set CHROME_WRAPPER browseros

          runHook postInstall
        '';

        meta = {
          mainProgram = "browseros";
          platforms = [ system ];
        };
      };
    in
    {
      packages.${system} = {
        default = browseros;
        browseros = browseros;
        prepared = browserosPrepared;
      };

      checks.${system} = {
        prepared = browserosPrepared;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${browseros}/bin/browseros";
        };
        browseros = {
          type = "app";
          program = "${browseros}/bin/browseros";
        };
      };
    };
}
