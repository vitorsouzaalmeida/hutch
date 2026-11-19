open Hutch

let make ?(settings = Config.no_settings) pairs = Config.make ~settings ~getenv:(Tmp.env pairs)
let base = [ ("HOME", "/h"); ("XDG_RUNTIME_DIR", "/run/user/1") ]

let test_defaults () =
  let c = make base in
  Alcotest.(check string) "projects" "/h/Projects" c.projects;
  Alcotest.(check string) "config" "/h/.config/hutch" c.config;
  Alcotest.(check string) "sandbox homes" "/h/.sb" c.sb_root;
  Alcotest.(check string) "state" "/run/user/1/hutch" c.state;
  Alcotest.(check bool) "lan" false c.lan;
  Alcotest.(check (option string)) "claude" None c.claude_bin

let test_env () =
  let c =
    make
      (base
      @ [
          ("HUTCH_PROJECTS", "/p");
          ("HUTCH_STATE", "/s");
          ("XDG_CONFIG_HOME", "/x");
          ("HUTCH_LAN", "1");
          ("SSH_ASKPASS", "/usr/bin/ask");
          ("PATH", "/a:b:/c");
        ])
  in
  Alcotest.(check string) "projects" "/p" c.projects;
  Alcotest.(check string) "state" "/s" c.state;
  Alcotest.(check string) "config" "/x/hutch" c.config;
  Alcotest.(check bool) "lan" true c.lan;
  Alcotest.(check (option string)) "askpass" (Some "/usr/bin/ask") c.askpass;
  Alcotest.(check (list string)) "path" [ "/a"; "b"; "/c" ] c.path

let settings text =
  match Config.settings_of_toml text with Ok s -> s | Error e -> Alcotest.failf "toml: %s" e

let test_toml () =
  let s =
    settings "projects = \"~/code\"\n[claude]\nbin = \"~/bin/claude\"\n[ssh]\naskpass = \"/a\"\n"
  in
  let c = make ~settings:s base in
  Alcotest.(check string) "projects" "/h/code" c.projects;
  Alcotest.(check (option string)) "claude" (Some "/h/bin/claude") c.claude_bin;
  Alcotest.(check (option string)) "askpass" (Some "/a") c.askpass;
  let c = make ~settings:s (base @ [ ("HUTCH_PROJECTS", "/p") ]) in
  Alcotest.(check string) "the environment wins" "/p" c.projects

let test_toml_errors () =
  let rejected text =
    Alcotest.(check bool) text true (Result.is_error (Config.settings_of_toml text))
  in
  rejected "[cluade]\nbin = \"x\"\n";
  rejected "[claude]\nbinary = \"x\"\n";
  rejected "projects = 3\n";
  rejected "claude = \"x\"\n";
  rejected "projects = \n"

let test_fails () =
  Tmp.raises_error "no HOME" (fun () -> make [ ("XDG_RUNTIME_DIR", "/r") ]);
  Tmp.raises_error "no state" (fun () -> make [ ("HOME", "/h") ]);
  Tmp.raises_error "relative" (fun () -> make (base @ [ ("HUTCH_PROJECTS", "code") ]))

let test_instance () =
  Alcotest.(check string) "stable" (Config.instance "/a/dev") (Config.instance "/a/dev");
  Alcotest.(check bool)
    "same basename, other folder" false
    (Config.instance "/a/dev" = Config.instance "/b/dev")

let suite =
  [
    ( "config",
      [
        Alcotest.test_case "defaults" `Quick test_defaults;
        Alcotest.test_case "environment" `Quick test_env;
        Alcotest.test_case "toml" `Quick test_toml;
        Alcotest.test_case "toml errors" `Quick test_toml_errors;
        Alcotest.test_case "missing or relative" `Quick test_fails;
        Alcotest.test_case "instance" `Quick test_instance;
      ] );
  ]
