open Hutch

let args = Alcotest.(list string)
let render = Policy.to_bwrap_args ~empty_file:"/run/hutch/empty"
let empty = Policy.empty ~hostname:"h" ~uid:1000 ~gid:985

let base =
  [ "--unshare-all"; "--share-net"; "--die-with-parent"; "--uid"; "1000"; "--gid"; "985" ]
  @ [ "--hostname"; "h" ]

let test_base () =
  Alcotest.check args "an empty policy still isolates everything but the network" base
    (render empty)

let test_mount_order () =
  let p =
    {
      empty with
      mounts =
        [
          Ro_bind { src = "/p/.claude"; dst = "/p/.claude" };
          Bind { src = "/p/.claude/worktrees"; dst = "/p/.claude/worktrees" };
        ];
    }
  in
  Alcotest.check args "the writable folder is mounted after (on top of) the read-only one"
    (base
    @ [ "--ro-bind"; "/p/.claude"; "/p/.claude" ]
    @ [ "--bind"; "/p/.claude/worktrees"; "/p/.claude/worktrees" ])
    (render p)

let test_hidden_and_perms () =
  let p =
    {
      empty with
      mounts =
        [
          Hidden_file "/p/.env";
          Dir { path = "/run/user/1000"; perms = Some 0o700 };
          Proc "/proc";
          Dev "/dev";
          Symlink { target = "usr/bin"; link = "/bin" };
        ];
      env = [ ("XDG_RUNTIME_DIR", "/run/user/1000") ];
      unset_env = [ "TMUX" ];
      chdir = Some "/p";
    }
  in
  Alcotest.check args "hidden files get the empty file; perms precede their dir"
    (base
    @ [ "--ro-bind"; "/run/hutch/empty"; "/p/.env"; "--perms"; "0700"; "--dir"; "/run/user/1000" ]
    @ [ "--proc"; "/proc"; "--dev"; "/dev"; "--symlink"; "usr/bin"; "/bin" ]
    @ [ "--setenv"; "XDG_RUNTIME_DIR"; "/run/user/1000"; "--unsetenv"; "TMUX"; "--chdir"; "/p" ])
    (render p)

let test_destination () =
  Alcotest.(check (list string))
    "what each mount covers" [ "/a"; "/b"; "/c"; "/d" ]
    (List.map Policy.destination
       [
         Ro_bind { src = "/x"; dst = "/a" };
         Tmpfs "/b";
         Symlink { target = "/x"; link = "/c" };
         Hidden_file "/d";
       ])

let pasta lan host_ports = Policy.to_pasta_args { lan; host_ports }

let test_pasta () =
  let common = [ "--config-net"; "--quiet"; "--host-lo-to-ns-lo" ] in
  Alcotest.check args "closed by default"
    (common @ [ "-t"; "127.0.0.1/auto"; "-u"; "none"; "-T"; "none"; "-U"; "none"; "--no-map-gw" ])
    (pasta false []);
  Alcotest.check args "LAN and host ports"
    (common @ [ "-t"; "auto"; "-u"; "none"; "-T"; "5432,11434"; "-U"; "none"; "--no-map-gw" ])
    (pasta true [ 5432; 11434 ])

let test_host_ports () =
  let ports = Alcotest.(result (list int) string) in
  Alcotest.check ports "lines, commas and comments"
    (Ok [ 11434; 5432; 80 ])
    (Policy.parse_host_ports "# ollama\n11434\n5432, 80 # db and web\n\n");
  Alcotest.check ports "empty" (Ok []) (Policy.parse_host_ports "# nothing\n");
  Alcotest.(check bool) "a word" true (Result.is_error (Policy.parse_host_ports "ollama\n"));
  Alcotest.(check bool) "out of range" true (Result.is_error (Policy.parse_host_ports "70000\n"))

let suite =
  [
    ( "policy",
      [
        Alcotest.test_case "base" `Quick test_base;
        Alcotest.test_case "mount order" `Quick test_mount_order;
        Alcotest.test_case "hidden files and perms" `Quick test_hidden_and_perms;
        Alcotest.test_case "destination" `Quick test_destination;
        Alcotest.test_case "pasta" `Quick test_pasta;
        Alcotest.test_case "host ports" `Quick test_host_ports;
      ] );
  ]
