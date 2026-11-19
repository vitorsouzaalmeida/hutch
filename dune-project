(lang dune 3.20)

(name hutch)

(generate_opam_files true)

(license MIT)

(package
 (name hutch)
 (synopsis "Per-project sandboxes for web development with AI coding agents")
 (description
  "Runs a project's toolchain, its services and an AI coding agent inside bubblewrap, with pasta networking and a Nix-provided toolchain.")
 (depends
  (ocaml (>= 5.3))
  (cmdliner (>= 2.0))
  (otoml (>= 1.0))
  (yojson (>= 3.0))
  (alcotest :with-test)))
