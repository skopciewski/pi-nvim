let
  pkgs = import <nixpkgs> { };

  containerScripts = pkgs.project_pi_helpers_builder {
    inherit pkgs;
    projectPackages = with pkgs; [
      lua
      stylua
      neovim-unwrapped
    ];
    projectContainer = "pi-nvim-env";
    currentDir = toString ./.;
  };
in
pkgs.mkShell {
  packages = with pkgs; [
    containerScripts
  ];
}
