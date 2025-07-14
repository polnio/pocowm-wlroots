{
  description = "A Wayland compositor library";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zig2nix = {
      url = "github:Cloudef/zig2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      zig2nix,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f rec {
            pkgs = nixpkgs.legacyPackages.${system};
            lib = pkgs.lib;
            zig-env = zig2nix.outputs.zig-env.${system} { };
          }
        );

      # Needs to be dynamic, the static library has a bug
      shared-ckdl =
        pkgs:
        pkgs.ckdl.lib.overrideAttrs (old: {
          cmakeFlags = old.cmakeFlags ++ [
            "-DBUILD_SHARED_LIBS=true"
            "-DCMAKE_SKIP_BUILD_RPATH=ON"
          ];
        });

      nativeBuildInputs =
        pkgs: with pkgs; [
          autoPatchelfHook
          pkg-config
          wayland-scanner
          wayland-protocols
          wlr-protocols
          (shared-ckdl pkgs)
        ];
      buildInputs =
        pkgs: with pkgs; [
          wayland
          libxkbcommon
          pixman
          wlroots_0_18
        ];

      ZIG_SYSTEM_INCLUDE_PATH = pkgs: pkgs.ckdl.dev + "/include";
      ZIG_SYSTEM_LIB_PATH = pkgs: (shared-ckdl pkgs) + "/lib";
    in
    {
      packages = forAllSystems (
        {
          pkgs,
          lib,
          zig-env,
          ...
        }:
        {
          default = zig-env.package {
            src = lib.cleanSource ./.;
            nativeBuildInputs = nativeBuildInputs pkgs;
            buildInputs = buildInputs pkgs;
            zigWrapperLibs = buildInputs pkgs;
            zigBuildZonLock = ./build.zig.zon2json-lock;
            ZIG_SYSTEM_INCLUDE_PATH = ZIG_SYSTEM_INCLUDE_PATH pkgs;
            ZIG_SYSTEM_LIB_PATH = ZIG_SYSTEM_LIB_PATH pkgs;
          };
        }
      );
      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [ zig ] ++ (nativeBuildInputs pkgs) ++ (buildInputs pkgs);
            ZIG_SYSTEM_INCLUDE_PATH = ZIG_SYSTEM_INCLUDE_PATH pkgs;
            ZIG_SYSTEM_LIB_PATH = ZIG_SYSTEM_LIB_PATH pkgs;
          };
        }
      );
    };
}
