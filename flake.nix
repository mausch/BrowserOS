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

      depotTools = pkgs.fetchgit {
        url = "https://chromium.googlesource.com/chromium/tools/depot_tools.git";
        rev = "f3ce14babd2bdfe949b8df1908e4d8c3029a8fb3";
        sha256 = "1i8vybrvvlza77pgrp0ynvslfwbcr7adacspm1sqpi77nmg9cafr";
      };

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
        git
        gnutar
        gn
        gperf
        jdk17_headless
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
        ninja
        nodejs
        pciutils
        perl
        pkg-config
        protobuf
        re2
        snappy
        speechd-minimal
        unzip
        util-linux
        which
        xz
        llvm.clang
        llvm.lld
      ];

      nixRunBrowseros = pkgs.writeShellApplication {
        name = "nix-run-browseros";
        runtimeInputs = buildDeps ++ [ python ];
        text = ''
          show_help() {
            cat <<'EOF'
Usage: nix run . [-- [runner-options] [-- browseros-build-args...]]

Bootstrap, build, and run BrowserOS.

Runner options:
  --workspace PATH   Writable workspace for Chromium checkout
                     (default: .cache/browseros-chromium under repo root)
  --build-only       Build but do not launch the browser
  --help             Show this help

Any remaining arguments are passed to:
  python -m build.browseros build

Default BrowserOS args:
  --setup --prep --build --arch x64 --build-type debug
EOF
          }

          build_only=0
          repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || pwd)"
          workspace="''${BROWSEROS_NIX_WORKSPACE:-$repo_root/.cache/browseros-chromium}"
          browseros_args=()

          while (($#)); do
            case "$1" in
              --help)
                show_help
                exit 0
                ;;
              --build-only)
                build_only=1
                shift
                ;;
              --workspace)
                if (($# < 2)); then
                  printf 'Missing value for --workspace\n' >&2
                  exit 1
                fi
                workspace="$2"
                shift 2
                ;;
              --workspace=*)
                workspace="''${1#--workspace=}"
                shift
                ;;
              --)
                shift
                browseros_args=("$@")
                break
                ;;
              *)
                browseros_args+=("$1")
                shift
                ;;
            esac
          done

          browseros_dir="$repo_root/packages/browseros"

          if [[ ! -f "$browseros_dir/build/browseros.py" ]]; then
            printf 'BrowserOS build CLI not found at %s\n' "$browseros_dir" >&2
            exit 1
          fi

          if [[ ! -f "$browseros_dir/CHROMIUM_VERSION" ]]; then
            printf 'CHROMIUM_VERSION not found under %s\n' "$browseros_dir" >&2
            exit 1
          fi

          mkdir -p "$workspace"
          chromium_root="$workspace/chromium"
          chromium_src="$chromium_root/src"
          depot_tools_dir="$workspace/depot_tools"
          out_dir="out/Default_x64"
          browseros_bin="$chromium_src/$out_dir/browseros"

          export LD_LIBRARY_PATH="${lib.makeLibraryPath runtimeLibs}:''${LD_LIBRARY_PATH:-}"
          export DEPOT_TOOLS_UPDATE=0

          if (( ! build_only )) && [[ -x "$browseros_bin" ]]; then
            printf 'BrowserOS binary found, launching...\n'
            exec "$browseros_bin" "''${@}"
          fi

          if [[ ! -d "$depot_tools_dir" ]]; then
            printf 'Copying depot_tools to writable workspace...\n'
            cp -r "${depotTools}" "$depot_tools_dir"
            chmod -R u+w "$depot_tools_dir"
          fi
          export PATH="$depot_tools_dir:$PATH"

          if [[ -d "$chromium_src/.git" ]]; then
            printf 'Chromium checkout found, skipping fetch.\n'
          elif [[ -f "$chromium_root/.gclient" ]]; then
            printf 'Partial Chromium checkout detected, re-running gclient sync...\n'
            ( cd "$chromium_root"; gclient sync -D --no-history --shallow )
          else
            printf 'No Chromium checkout found, running fetch...\n'
            mkdir -p "$chromium_root"
            ( cd "$chromium_root"; fetch --nohooks chromium )
          fi

          printf 'Building BrowserOS...\n'
          cd "$browseros_dir"
          python -m build.browseros build \
            --setup --prep --build \
            --arch x64 --build-type debug \
            --chromium-src "$chromium_src" \
            "''${browseros_args[@]}"

          if [[ ! -x "$browseros_bin" ]]; then
            printf 'BrowserOS binary not found at %s\n' "$browseros_bin" >&2
            printf 'Build may have failed or produced a different binary name.\n' >&2
            exit 1
          fi

          if (( build_only )); then
            printf 'Build complete (--build-only specified, not launching browser).\n'
            exit 0
          fi

          printf 'Launching BrowserOS...\n'
          exec "$browseros_bin" "''${@}"
        '';
      };
    in
    {
      packages.${system} = {
        default = nixRunBrowseros;
        nix-run-browseros = nixRunBrowseros;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${nixRunBrowseros}/bin/nix-run-browseros";
        };
        browseros = {
          type = "app";
          program = "${nixRunBrowseros}/bin/nix-run-browseros";
        };
      };
    };
}