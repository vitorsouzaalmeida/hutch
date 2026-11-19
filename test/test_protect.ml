open Hutch

let ( / ) = Filename.concat
let ro path = Policy.Ro_bind { src = path; dst = path }

let index mounts m =
  match List.find_index (( = ) m) mounts with
  | Some i -> i
  | None -> Alcotest.failf "mount of %s not found" (Policy.destination m)

let has mounts m = List.mem m mounts

let test_parse_hide () =
  let paths = Alcotest.(result (list string) string) in
  Alcotest.check paths "comments, blanks and trailing slashes"
    (Ok [ ".env"; "secrets"; "a/b.txt" ])
    (Protect.parse_hide "# mine\n.env\n\n  secrets/  # folder\na/b.txt");
  Alcotest.(check bool) "absolute" true (Result.is_error (Protect.parse_hide "/etc/passwd\n"));
  Alcotest.(check bool) "parent" true (Result.is_error (Protect.parse_hide "a/../../b\n"));
  Alcotest.check paths "dots in a name" (Ok [ "a..b" ]) (Protect.parse_hide "a..b\n")

let test_prepare () =
  Tmp.with_dir @@ fun root ->
  Fs.mkdir_p (root / ".git");
  Fs.write (root / "CLAUDE.md") "mine";
  Protect.prepare ~root;
  List.iter
    (fun d -> Alcotest.(check bool) d true (Fs.kind (root / d) = Fs.Dir))
    [ ".claude"; ".claude/worktrees"; ".vscode"; ".zed"; ".idea"; ".git/hooks"; ".git/info" ];
  Alcotest.(check string) ".mcp.json" "{ \"mcpServers\": {} }\n" (Fs.read (root / ".mcp.json"));
  Alcotest.(check string) "an existing file is kept" "mine" (Fs.read (root / "CLAUDE.md"));
  let exclude = "/.claude/settings.local.json\n/.claude/worktrees/\n/.data/\n/.mcp.json\n" in
  Alcotest.(check string) "exclude" exclude (Fs.read (root / ".git/info/exclude"));
  Protect.prepare ~root;
  Alcotest.(check string) "exclude, second run" exclude (Fs.read (root / ".git/info/exclude"))

let test_prepare_keeps_exclude () =
  Tmp.with_dir @@ fun root ->
  Fs.mkdir_p (root / ".git/info");
  Fs.write (root / ".git/info/exclude") "*.log\n/.data/";
  Protect.prepare ~root;
  Alcotest.(check string)
    "appended"
    "*.log\n/.data/\n/.claude/settings.local.json\n/.claude/worktrees/\n/.mcp.json\n/CLAUDE.md\n"
    (Fs.read (root / ".git/info/exclude"))

let test_prepare_refuses_links () =
  Tmp.with_dir @@ fun dir ->
  let root = dir / "project" and outside = dir / "outside" in
  Fs.mkdir_p root;
  Fs.mkdir_p outside;
  Unix.symlink outside (root / ".vscode");
  Tmp.raises_error "prepare" (fun () -> Protect.prepare ~root);
  Alcotest.(check bool) "the link is still there" true (Fs.kind (root / ".vscode") = Fs.Link);
  Alcotest.(check (list string)) "nothing created outside" [] (Array.to_list (Sys.readdir outside))

let test_mounts () =
  Tmp.with_dir @@ fun root ->
  Fs.mkdir_p (root / ".git");
  Fs.write (root / ".git/config") "";
  Protect.prepare ~root;
  List.iter Tmp.touch
    [
      root / "flake.nix";
      root / "apps/web/CLAUDE.md";
      root / "apps/web/.npmrc";
      root / "apps/web/flake.nix";
      root / "apps/web/.claude/settings.json";
      root / "apps/web/node_modules/pkg/CLAUDE.md";
      root / "a/b/c/d/CLAUDE.md";
      root / "a/b/c/d/e/CLAUDE.md";
      root / ".claude/worktrees/wt/CLAUDE.md";
      root / ".claude/worktrees/wt/flake.nix";
      root / ".claude/worktrees/wt/.claude/settings.json";
      root / ".claude/worktrees/wt/apps/web/api/CLAUDE.md";
    ];
  let mounts = Protect.mounts ~root ~hide:[] in
  let worktrees =
    Policy.Bind { src = root / ".claude/worktrees"; dst = root / ".claude/worktrees" }
  in
  List.iter
    (fun rel -> Alcotest.(check bool) rel true (has mounts (ro (root / rel))))
    [ ".claude"; ".vscode"; ".zed"; ".idea"; ".mcp.json"; "CLAUDE.md"; "flake.nix" ];
  List.iter
    (fun rel -> Alcotest.(check bool) rel true (has mounts (ro (root / rel))))
    [ "apps/web/CLAUDE.md"; "apps/web/.npmrc"; "apps/web/.claude"; "a/b/c/d/CLAUDE.md" ];
  List.iter
    (fun rel -> Alcotest.(check bool) rel false (has mounts (ro (root / rel))))
    [ "apps/web/flake.nix"; "apps/web/node_modules/pkg/CLAUDE.md"; "a/b/c/d/e/CLAUDE.md" ];
  Alcotest.(check bool)
    "worktrees stay writable, on top of .claude" true
    (index mounts (ro (root / ".claude")) < index mounts worktrees);
  List.iter
    (fun rel ->
      Alcotest.(check bool)
        rel true
        (index mounts worktrees < index mounts (ro (root / ".claude/worktrees/wt" / rel))))
    [ "CLAUDE.md"; "flake.nix"; ".claude"; "apps/web/api/CLAUDE.md" ];
  let git = Policy.Bind { src = root / ".git"; dst = root / ".git" } in
  Alcotest.(check bool)
    ".git is pinned before its read-only parts" true
    (index mounts git < index mounts (ro (root / ".git/hooks"))
    && index mounts git < index mounts (ro (root / ".git/info"))
    && index mounts git
       < index mounts
           (Policy.Ro_bind_try { src = root / ".git/config"; dst = root / ".git/config" }))

let test_hide () =
  Tmp.with_dir @@ fun root ->
  Protect.prepare ~root;
  Tmp.touch (root / ".env");
  Fs.mkdir_p (root / "secrets");
  Unix.symlink ".env" (root / ".env.link");
  let mounts = Protect.mounts ~root ~hide:[ ".env"; "secrets"; "missing" ] in
  Alcotest.(check bool) "a file" true (has mounts (Policy.Hidden_file (root / ".env")));
  Alcotest.(check bool) "a folder" true (has mounts (Policy.Tmpfs (root / "secrets")));
  Alcotest.(check bool)
    "missing" false
    (List.exists (fun m -> Policy.destination m = root / "missing") mounts);
  Tmp.raises_error "a link" (fun () -> Protect.mounts ~root ~hide:[ ".env.link" ])

let test_linked_file () =
  Tmp.with_dir @@ fun dir ->
  let root = dir / "project" in
  Fs.mkdir_p root;
  Protect.prepare ~root;
  Tmp.touch (root / "AGENTS.md");
  Tmp.touch (dir / "outside.toml");
  Unix.unlink (root / "CLAUDE.md");
  Unix.symlink "AGENTS.md" (root / "CLAUDE.md");
  Unix.symlink (dir / "outside.toml") (root / "mise.toml");
  let mounts = Protect.mounts ~root ~hide:[] in
  Alcotest.(check bool) "the target is protected" true (has mounts (ro (root / "AGENTS.md")));
  Alcotest.(check bool)
    "nothing is mounted on a link" false
    (List.exists
       (fun m -> List.mem (Policy.destination m) [ root / "CLAUDE.md"; root / "mise.toml" ])
       mounts);
  Alcotest.(check bool)
    "nothing outside the project" false
    (List.exists (fun m -> not (Fs.is_under ~root (Policy.destination m))) mounts)

let suite =
  [
    ( "protect",
      [
        Alcotest.test_case "parse hide" `Quick test_parse_hide;
        Alcotest.test_case "prepare" `Quick test_prepare;
        Alcotest.test_case "prepare keeps exclude" `Quick test_prepare_keeps_exclude;
        Alcotest.test_case "prepare refuses links" `Quick test_prepare_refuses_links;
        Alcotest.test_case "mounts" `Quick test_mounts;
        Alcotest.test_case "hide" `Quick test_hide;
        Alcotest.test_case "linked file" `Quick test_linked_file;
      ] );
  ]
