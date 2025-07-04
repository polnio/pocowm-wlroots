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

      nativeBuildInputs =
        pkgs: with pkgs; [
          autoPatchelfHook
          pkg-config
          wayland-scanner
          wayland-protocols
          wlr-protocols
        ];
      buildInputs =
        pkgs: with pkgs; [
          wayland
          libxkbcommon
          pixman
          wlroots_0_18
        ];
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
          default = zig-env.package rec {
            src = lib.cleanSource ./.;
            nativeBuildInputs = nativeBuildInputs pkgs;
            buildInputs = buildInputs pkgs;
            zigWrapperLibs = buildInputs;
            zigBuildZonLock = ./build.zig.zon2json-lock;
          };
        }
      );
      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [ zig ] ++ (nativeBuildInputs pkgs) ++ (buildInputs pkgs);
          };
        }
      );
    };
}
