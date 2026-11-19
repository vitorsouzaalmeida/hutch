{
  description = "hutch: per-project sandboxes for web development with AI coding agents";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      ocamlPackages = pkgs.ocamlPackages;

      # Runtime libraries. Later phases add eio_main, tls-eio, x509, dns-*, ctypes...
      deps = with ocamlPackages; [ cmdliner otoml yojson ];
      testDeps = with ocamlPackages; [ alcotest ];
    in
    {
      packages.${system}.default = ocamlPackages.buildDunePackage {
        pname = "hutch";
        version = "0.1.0";
        src = self;
        buildInputs = deps;
        checkInputs = testDeps;
        doCheck = true;
      };

      devShells.${system}.default = pkgs.mkShell {
        inputsFrom = [ self.packages.${system}.default ];
        packages = testDeps ++ (with ocamlPackages; [ ocaml-lsp ocamlformat utop ]);
      };
    };
}
