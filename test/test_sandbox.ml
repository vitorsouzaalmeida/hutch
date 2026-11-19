open Hutch

let ( / ) = Filename.concat

let config =
  Config.make ~settings:Config.no_settings
    ~getenv:(Tmp.env [ ("HOME", "/h"); ("HUTCH_STATE", "/s") ])

let project = Result.get_ok (Project.of_cwd config ~cwd:"/h/Projects/shop")
let ro path = Policy.Ro_bind { src = path; dst = path }

let inputs : Sandbox.inputs =
  {
    uid = 1000;
    gid = 1000;
    shell = "/usr/bin/zsh";
    claude = [ ro "/h/.local/share/claude/versions/1" ];
    protect = [ ro "/h/Projects/shop/.claude"; ro "/h/Projects/shop/.mcp.json" ];
    token = Some (Ro_bind { src = "/s/shop.gen/claude-token"; dst = "/run/hutch/claude-token" });
    base = Some "/nix/store/abc-hutch-base";
    agent = true;
    host_ports = [ 5432 ];
    exists = (fun _ -> true);
  }

let policy = Sandbox.policy config project inputs

let index m =
  match List.find_index (( = ) m) policy.mounts with
  | Some i -> i
  | None -> Alcotest.failf "mount of %s not found" (Policy.destination m)

let test_order () =
  let home = Policy.Bind { src = project.home; dst = "/h" } in
  let root = Policy.Bind { src = project.root; dst = project.root } in
  List.iter
    (fun m -> Alcotest.(check bool) (Policy.destination m) true (index root < index m))
    inputs.protect;
  List.iter
    (fun (m : Policy.mount) ->
      let dst = Policy.destination m in
      if Fs.is_under ~root:"/h" dst && m <> home then
        Alcotest.(check bool) (dst ^ " is mounted on top of the home") true (index home < index m))
    policy.mounts;
  Alcotest.(check bool)
    "/run is emptied before anything is put in it" true
    (index (Tmpfs "/run") < index (Bind { src = project.agent; dst = "/run/ssh.sock" })
    && index (Tmpfs "/run") < index (Option.get inputs.token))

let test_generated_read_only () =
  List.iter
    (fun (m : Policy.mount) ->
      match m with
      | Bind { src; _ } | Ro_bind_try { src; _ } ->
          Alcotest.(check bool)
            (src ^ " is not a generated file")
            false
            (Fs.is_under ~root:project.gen src)
      | Ro_bind _ | Tmpfs _ | Hidden_file _ | Dir _ | Symlink _ | Proc _ | Dev _ -> ())
    policy.mounts;
  List.iter
    (fun (name, dst) ->
      Alcotest.(check bool)
        dst true
        (List.mem (Policy.Ro_bind { src = project.gen / name; dst }) policy.mounts))
    [
      ("zshrc", "/h/.zshrc");
      ("zshenv", "/h/.zshenv");
      ("hutch-env.sh", "/h/.hutch-env.sh");
      ("hosts", "/etc/hosts");
    ]

let test_only_host_socket () =
  let from_run (m : Policy.mount) =
    match m with
    | Bind { src; _ } | Ro_bind { src; _ } | Ro_bind_try { src; _ } -> Fs.is_under ~root:"/run" src
    | Tmpfs _ | Hidden_file _ | Dir _ | Symlink _ | Proc _ | Dev _ -> false
  in
  Alcotest.(check int)
    "nothing of the host's /run comes in" 0
    (List.length (List.filter from_run policy.mounts))

let test_optional () =
  let bare =
    Sandbox.policy config project
      { inputs with agent = false; token = None; base = None; exists = (fun _ -> false) }
  in
  let dsts = List.map Policy.destination bare.mounts in
  List.iter
    (fun dst -> Alcotest.(check bool) dst false (List.mem dst dsts))
    [
      "/run/ssh.sock";
      "/run/hutch/claude-token";
      "/opt/hutch-base";
      "/nix";
      "/nix/var/nix/daemon-socket";
    ];
  Alcotest.(check bool) "no agent variable" false (List.mem_assoc "SSH_AUTH_SOCK" bare.env);
  Alcotest.(check bool)
    "an agent variable when there is one" true
    (List.mem_assoc "SSH_AUTH_SOCK" policy.env)

let test_env () =
  Alcotest.(check (option string)) "name" (Some "shop") (List.assoc_opt "HUTCH_SANDBOX" policy.env);
  Alcotest.(check bool)
    "the token is never an argument" false
    (List.exists (fun (name, _) -> name = "CLAUDE_CODE_OAUTH_TOKEN") policy.env);
  Alcotest.(check bool) "host ports" true (policy.net = { lan = false; host_ports = [ 5432 ] })

let test_clean_env () =
  let env =
    [
      ("HOME", "/evil"); ("PATH", "/evil/bin"); ("AWS_SECRET_ACCESS_KEY", "s"); ("GITHUB_TOKEN", "t");
    ]
    @ [
        ("LD_PRELOAD", "/evil.so");
        ("TERM", "xterm-kitty");
        ("LC_ALL", "pt_BR.UTF-8");
        ("LC_evil", "x");
      ]
    @ [ ("TZ", "America/Sao_Paulo"); ("COLORTERM", "truecolor"); ("SHELL", "/usr/bin/zsh") ]
  in
  Alcotest.(check (list (pair string string)))
    "an allowlist, nothing else"
    [
      ("HOME", "/h");
      ("USER", "u");
      ("LOGNAME", "u");
      ("SHELL", "/usr/bin/zsh");
      ("PATH", "/h/.local/bin:/usr/local/bin:/usr/bin");
      ("TERM", "xterm-kitty");
      ("LANG", "C.UTF-8");
      ("LC_ALL", "pt_BR.UTF-8");
      ("TZ", "America/Sao_Paulo");
      ("COLORTERM", "truecolor");
    ]
    (Sandbox.clean_env config ~user:"u" ~env)

let test_join () =
  let env =
    [
      ("PATH", "/h/.opam/default/bin:/usr/bin");
      ("GITHUB_TOKEN", "t");
      ("TERM", "xterm");
      ("COLORTERM", "truecolor");
    ]
  in
  Alcotest.(check (list (pair string string)))
    "three variables at most"
    [ ("HOME", "/h"); ("TERM", "xterm"); ("COLORTERM", "truecolor") ]
    (Sandbox.join_env config ~env);
  Alcotest.(check (list (pair string string)))
    "defaults"
    [ ("HOME", "/h"); ("TERM", "dumb") ]
    (Sandbox.join_env config ~env:[]);
  let args = Sandbox.join_args ~pid:42 ~cwd:"/h/Projects/shop/api" [ "pnpm"; "test" ] in
  let rec after_wd = function "--wd" :: rest -> rest | _ :: rest -> after_wd rest | [] -> [] in
  (match after_wd args with
  | program :: "-c" :: _script :: _name :: rest ->
      Alcotest.(check string) "the first program is an absolute path" "/usr/bin/bash" program;
      Alcotest.(check (list string))
        "then the folder and the command"
        [ "/h/Projects/shop/api"; "pnpm"; "test" ]
        rest
  | _ -> Alcotest.fail "unexpected arguments");
  Alcotest.(check bool) "the keeper is the target" true (List.mem "42" args)

let test_session () =
  let dotted = Result.get_ok (Project.of_cwd config ~cwd:"/h/Projects/my.app") in
  Alcotest.(check string) "plain" "shop" (Sandbox.session project);
  Alcotest.(check string)
    "no dots, which tmux would read as a window" "my_app" (Sandbox.session dotted)

let suite =
  [
    ( "sandbox",
      [
        Alcotest.test_case "session name" `Quick test_session;
        Alcotest.test_case "mount order" `Quick test_order;
        Alcotest.test_case "generated files" `Quick test_generated_read_only;
        Alcotest.test_case "host /run" `Quick test_only_host_socket;
        Alcotest.test_case "optional parts" `Quick test_optional;
        Alcotest.test_case "environment inside" `Quick test_env;
        Alcotest.test_case "clean environment" `Quick test_clean_env;
        Alcotest.test_case "join" `Quick test_join;
      ] );
  ]
