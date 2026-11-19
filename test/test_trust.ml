open Hutch

let ( / ) = Filename.concat

let project root =
  Fs.mkdir_p root;
  Fs.write (root / "flake.nix") "{ }";
  Fs.write (root / "flake.lock") "{}";
  Fs.mkdir_p (root / "nix");
  Fs.write (root / "nix/shell.nix") "{ }"

let test_stable () =
  Tmp.with_dir @@ fun dir ->
  project (dir / "a");
  project (dir / "b");
  Alcotest.(check string)
    "same contents, same digest"
    (Trust.digest (dir / "a"))
    (Trust.digest (dir / "b"));
  Fs.write (dir / "a/README.md") "x";
  Fs.mkdir_p (dir / "a/node_modules/pkg");
  Fs.write (dir / "a/node_modules/pkg/default.nix") "x";
  Fs.mkdir_p (dir / "a/.claude/worktrees/wt");
  Fs.write (dir / "a/.claude/worktrees/wt/flake.nix") "x";
  Alcotest.(check string)
    "other files don't count"
    (Trust.digest (dir / "a"))
    (Trust.digest (dir / "b"))

let changes name edit =
  Tmp.with_dir @@ fun root ->
  project root;
  let before = Trust.digest root in
  edit root;
  Alcotest.(check bool) name false (before = Trust.digest root)

let test_changes () =
  changes "flake.nix edited" (fun root -> Fs.write (root / "flake.nix") "{ evil = 1; }");
  changes "flake.lock edited" (fun root -> Fs.write (root / "flake.lock") "{ }");
  changes "a deeper file edited" (fun root -> Fs.write (root / "nix/shell.nix") "x");
  changes "a new .nix file" (fun root -> Fs.write (root / "nix/extra.nix") "");
  changes "a file renamed" (fun root ->
      Unix.rename (root / "nix/shell.nix") (root / "nix/other.nix"));
  changes "a file replaced by a link" (fun root ->
      Unix.unlink (root / "nix/shell.nix");
      Unix.symlink "/etc/hostname" (root / "nix/shell.nix"))

let test_link_target () =
  Tmp.with_dir @@ fun root ->
  project root;
  Unix.symlink "a.txt" (root / "extra.nix");
  let before = Trust.digest root in
  Unix.unlink (root / "extra.nix");
  Unix.symlink "b.txt" (root / "extra.nix");
  Alcotest.(check bool) "a retargeted link" false (before = Trust.digest root)

let test_approved () =
  Tmp.with_dir @@ fun dir ->
  let file = dir / "flake-approval" in
  Alcotest.(check bool) "no file" false (Trust.approved ~file "abc");
  Fs.write file "abc\n";
  Alcotest.(check bool) "match" true (Trust.approved ~file "abc");
  Alcotest.(check bool) "other digest" false (Trust.approved ~file "abd")

let suite =
  [
    ( "trust",
      [
        Alcotest.test_case "stable" `Quick test_stable;
        Alcotest.test_case "changes" `Quick test_changes;
        Alcotest.test_case "link target" `Quick test_link_target;
        Alcotest.test_case "approved" `Quick test_approved;
      ] );
  ]
