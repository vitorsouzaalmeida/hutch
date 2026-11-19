open Hutch

let ( / ) = Filename.concat

let json =
  Alcotest.testable
    (fun ppf j -> Format.pp_print_string ppf (Yojson.Safe.to_string j))
    Yojson.Safe.equal

let j = Yojson.Safe.from_string

let test_parse () =
  Alcotest.(check (option json)) "an object" (Some (j {|{"a": 1}|})) (Claude.parse {|{"a": 1}|});
  Alcotest.(check (option json)) "not an object" None (Claude.parse "[1, 2]");
  Alcotest.(check (option json)) "truncated" None (Claude.parse {|{"a": |});
  Alcotest.(check (option json)) "empty" None (Claude.parse "");
  Alcotest.(check (option json)) "nested too deep" None (Claude.parse (String.make 2_000_000 '['))

let test_settings () =
  Alcotest.check json "the sandbox section goes, the rest stays in order"
    (j {|{"model": "opus", "permissions": {"defaultMode": "auto"}}|})
    (Claude.sandbox_settings
       (j
          {|{"model": "opus", "sandbox": {"enabled": true}, "permissions": {"defaultMode": "auto"}}|}))

let test_initial_state () =
  let host =
    j
      {|{"hasCompletedOnboarding": true, "installMethod": "native", "lastOnboardingVersion": null, "oauthAccount": {"email": "x"}, "projects": {}}|}
  in
  Alcotest.check json "only onboarding is kept"
    (j {|{"hasCompletedOnboarding": true, "installMethod": "native", "autoUpdates": false}|})
    (Claude.initial_state ~host:(Some host));
  Alcotest.check json "no host file" (j {|{"autoUpdates": false}|})
    (Claude.initial_state ~host:None)

let test_mcp () =
  let servers = [ ("browser", j {|{"command": "/opt/hutch-base/bin/browser"}|}) ] in
  Alcotest.check json "added"
    (j {|{"a": 1, "mcpServers": {"browser": {"command": "/opt/hutch-base/bin/browser"}}}|})
    (Claude.with_mcp ~servers (j {|{"a": 1}|}));
  Alcotest.check json "same name replaced, others kept"
    (j
       {|{"mcpServers": {"mine": {"command": "x"}, "browser": {"command": "/opt/hutch-base/bin/browser"}}, "z": 1}|})
    (Claude.with_mcp ~servers
       (j {|{"mcpServers": {"browser": {"command": "old"}, "mine": {"command": "x"}}, "z": 1}|}))

let setup dir =
  let c = Tmp.config dir in
  let p = Result.get_ok (Project.of_cwd c ~cwd:(c.projects / "shop")) in
  List.iter Fs.mkdir_p [ p.root; p.home; p.meta; p.gen; c.home / ".claude"; c.config ];
  (c, p)

let test_prepare () =
  Tmp.with_dir @@ fun dir ->
  let c, p = setup dir in
  Fs.write (c.home / ".claude/settings.json") {|{"model": "opus", "sandbox": {"enabled": true}}|};
  Fs.write (c.home / ".claude.json")
    {|{"hasCompletedOnboarding": true, "oauthAccount": {"email": "x"}}|};
  Claude.prepare c p;
  let settings = p.home / ".claude/settings.json" and state = p.home / ".claude.json" in
  Alcotest.check json "settings copied" (j {|{"model": "opus"}|}) (j (Fs.read settings));
  Alcotest.check json "state created"
    (j {|{"hasCompletedOnboarding": true, "autoUpdates": false, "mcpServers": {}}|})
    (j (Fs.read state));
  Fs.write settings {|{"model": "haiku"}|};
  Fs.write state {|{"mine": true}|};
  Claude.prepare c p;
  Alcotest.check json "edits made inside last" (j {|{"model": "haiku"}|}) (j (Fs.read settings));
  Alcotest.check json "the state is left alone" (j {|{"mine": true}|}) (j (Fs.read state));
  Fs.write (c.home / ".claude/settings.json") {|{"model": "sonnet"}|};
  Claude.prepare c p;
  Alcotest.check json "until the host's settings change" (j {|{"model": "sonnet"}|})
    (j (Fs.read settings))

let test_prepare_mcp () =
  Tmp.with_dir @@ fun dir ->
  let c, p = setup dir in
  let state = p.home / ".claude.json" in
  Fs.mkdir_p (c.config / "base");
  Fs.write (c.config / "base/mcp.json") {|{"mcpServers": {"browser": {"command": "b"}}}|};
  Fs.write state {|{"mine": true}|};
  Claude.prepare c p;
  Alcotest.check json "registered"
    (j {|{"mine": true, "mcpServers": {"browser": {"command": "b"}}}|})
    (j (Fs.read state));
  Fs.write state "{ not json";
  Claude.prepare c p;
  Alcotest.(check string) "an invalid file is left alone" "{ not json" (Fs.read state);
  Fs.write (c.config / "base/mcp.json") {|["browser"]|};
  Tmp.raises_error "a bad mcp.json" (fun () -> Claude.prepare c p)

let test_prepare_links () =
  Tmp.with_dir @@ fun dir ->
  let c, p = setup dir in
  let outside = dir / "outside" in
  Fs.mkdir_p outside;
  Fs.write (outside / "target.json") "host";
  Fs.write (c.home / ".claude/settings.json") {|{"model": "opus"}|};
  Unix.symlink outside (p.home / ".claude");
  Unix.symlink (outside / "target.json") (p.home / ".claude.json");
  Claude.prepare c p;
  Alcotest.(check (list string))
    "nothing new outside" [ "target.json" ]
    (Array.to_list (Sys.readdir outside));
  Alcotest.(check string) "the linked file is untouched" "host" (Fs.read (outside / "target.json"));
  Alcotest.(check bool) "real folder" true (Fs.kind (p.home / ".claude") = Fs.Dir);
  Alcotest.(check bool) "real file" true (Fs.kind (p.home / ".claude.json") = Fs.File)

let test_mounts () =
  Tmp.with_dir @@ fun dir ->
  let c = Tmp.config ~path:(dir / "bin") dir in
  Tmp.touch ~perm:0o755 (dir / "versions/1.2.3");
  Fs.mkdir_p (dir / "bin");
  Unix.symlink (dir / "versions/1.2.3") (dir / "bin/claude");
  Fs.mkdir_p (c.home / ".claude/skills");
  let binary = Claude.binary c in
  Alcotest.(check (option string)) "found through its link" (Some (dir / "versions/1.2.3")) binary;
  let real = dir / "versions/1.2.3" and claude = c.home / ".claude" in
  Alcotest.(check bool)
    "mounts" true
    (Claude.mounts c binary
    = [
        Ro_bind { src = real; dst = real };
        Ro_bind { src = real; dst = c.home / ".local/bin/claude" };
        Ro_bind_try { src = claude / "CLAUDE.md"; dst = claude / "CLAUDE.md" };
        Ro_bind { src = claude / "skills"; dst = claude / "skills" };
      ]);
  Tmp.raises_error "claude.bin in a project" (fun () ->
      Tmp.touch ~perm:0o755 (c.projects / "shop/claude");
      Claude.binary { c with claude_bin = Some (c.projects / "shop/claude") })

let test_token () =
  Tmp.with_dir @@ fun dir ->
  let c, p = setup dir in
  Alcotest.(check bool) "none saved" true (Claude.token_mount c p = None);
  Fs.write (c.config / "claude-oauth-token") "  sk-token\n";
  Alcotest.(check bool)
    "a read-only file" true
    (Claude.token_mount c p
    = Some (Ro_bind { src = p.gen / "claude-token"; dst = "/run/hutch/claude-token" }));
  Alcotest.(check string) "without the blanks" "sk-token" (Fs.read (p.gen / "claude-token"));
  Alcotest.(check int) "private" 0o600 ((Unix.stat (p.gen / "claude-token")).st_perm land 0o777)

let suite =
  [
    ( "claude",
      [
        Alcotest.test_case "parse" `Quick test_parse;
        Alcotest.test_case "settings" `Quick test_settings;
        Alcotest.test_case "initial state" `Quick test_initial_state;
        Alcotest.test_case "mcp" `Quick test_mcp;
        Alcotest.test_case "prepare" `Quick test_prepare;
        Alcotest.test_case "prepare mcp" `Quick test_prepare_mcp;
        Alcotest.test_case "prepare links" `Quick test_prepare_links;
        Alcotest.test_case "mounts" `Quick test_mounts;
        Alcotest.test_case "token" `Quick test_token;
      ] );
  ]
