open Cmdliner
open Hutch

let own_error = 125
let stopped = 3

let guarded f =
  let report message =
    Printf.eprintf "hutch: %s\n%!" message;
    own_error
  in
  try f () with
  | Msg.Error message -> report message
  | Sys_error message -> report message
  | Unix.Unix_error (error, call, "") ->
      report (Printf.sprintf "%s: %s" call (Unix.error_message error))
  | Unix.Unix_error (error, call, arg) ->
      report (Printf.sprintf "%s %s: %s" call arg (Unix.error_message error))

let with_project ?(create = true) f =
  guarded @@ fun () ->
  if Sys.getenv_opt "HUTCH_SANDBOX" <> None then
    Msg.fail "you are inside a sandbox already; run hutch from a terminal on the host";
  let c = Config.load () in
  let cwd = Sys.getcwd () in
  match Project.of_cwd c ~cwd with
  | Error message -> Msg.fail "%s" message
  | Ok p ->
      if create then Project.ensure_dirs c p;
      f c p ~cwd

let attach () =
  with_project @@ fun c p ~cwd ->
  ignore (Sandbox.up c p);
  if Unix.isatty Unix.stdin && Unix.isatty Unix.stdout then Sandbox.attach c p ~cwd else 0

let up () =
  with_project @@ fun c p ~cwd:_ ->
  (match Sandbox.up c p with
  | `Started -> ()
  | `Already_running -> Msg.info "sandbox '%s' is already running" p.name);
  0

let stop () =
  with_project @@ fun c p ~cwd:_ ->
  Sandbox.stop c p;
  0

let status () =
  with_project ~create:false @@ fun c p ~cwd:_ ->
  match Sandbox.running c p with
  | Some keeper ->
      Printf.printf "running (pid %d)\n" keeper.pid;
      0
  | None ->
      print_endline "stopped";
      stopped

let ssh_add keys = with_project @@ fun c p ~cwd:_ -> Ssh_agent.add c p keys
let exits = Cmd.Exit.info own_error ~doc:"on an error of $(tool) itself." :: Cmd.Exit.defaults

let envs =
  [
    Cmd.Env.info "HUTCH_LAN"
      ~doc:
        "If $(b,1), servers started inside are reachable from the LAN, not only from this \
         computer. Read when the sandbox starts.";
    Cmd.Env.info "HUTCH_NO_BASE"
      ~doc:"If $(b,1), the base tools are left out. Read when the sandbox starts.";
    Cmd.Env.info "HUTCH_PROJECTS"
      ~doc:"The folder holding the projects. Defaults to $(b,~/Projects).";
    Cmd.Env.info "HUTCH_CONFIG" ~doc:"The configuration folder. Defaults to $(b,~/.config/hutch).";
    Cmd.Env.info "HUTCH_SB_ROOT"
      ~doc:"The folder holding each sandbox's home. Defaults to $(b,~/.sb).";
    Cmd.Env.info "HUTCH_STATE"
      ~doc:"The folder for runtime state. Defaults to $(b,\\$XDG_RUNTIME_DIR/hutch).";
  ]

let info name ~doc ?(man = []) () = Cmd.info name ~doc ~man ~exits ~envs
let unit_cmd name ~doc ?man f = Cmd.make (info name ~doc ?man ()) Term.(const f $ const ())

let ssh_add_cmd =
  let doc = "Give the sandbox one SSH key. Every use of it asks for confirmation on the host." in
  let keys = Arg.(non_empty & pos_all string [] & info [] ~docv:"KEY" ~doc:"A private key file.") in
  Cmd.make (info "ssh-add" ~doc ()) Term.(const ssh_add $ keys)

let status_cmd =
  let doc = "Tell whether the sandbox is running." in
  let exits = Cmd.Exit.info stopped ~doc:"if the sandbox is stopped." :: exits in
  Cmd.make (Cmd.info "status" ~doc ~exits ~envs) Term.(const status $ const ())

let main =
  let doc = "one sandbox per project, with its toolchain, its services and Claude Code inside" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Run $(tool) inside a project folder. Without a command it starts the project's sandbox if \
         needed and opens a shell inside it, in the sandbox's tmux. Each terminal gets its own \
         view, so several can work side by side. Type $(b,claude) in that shell to run Claude \
         Code.";
      `P
        "Inside the sandbox the project and a per-project home are writable. The system, the Nix \
         store, your shell configuration, Claude Code and the project files that tools trust \
         ($(b,.claude), $(b,.mcp.json), $(b,CLAUDE.md), $(b,.git/config), $(b,.git/hooks) and \
         others) are read-only. Your real home, other projects and the host's services are absent.";
      `P "The internet is reachable. Servers started inside appear on this computer's 127.0.0.1.";
      `S Manpage.s_files;
      `P
        "$(b,~/.config/hutch/config.toml) holds the settings $(b,projects), $(b,claude.bin) and \
         $(b,ssh.askpass).";
      `P
        "$(b,~/.config/hutch/projects/)$(i,NAME)$(b,/) holds a project's personal $(b,flake.nix), \
         its $(b,hide) list and its $(b,host-ports).";
    ]
  in
  Cmd.group
    (Cmd.info "hutch" ~version:"0.1.0" ~doc ~man ~exits ~envs)
    ~default:Term.(const attach $ const ())
    [
      unit_cmd "up" ~doc:"Start the sandbox without attaching to it." up;
      unit_cmd "stop" ~doc:"Stop the sandbox. Every process inside ends." stop;
      status_cmd;
      ssh_add_cmd;
    ]

let () = exit (Cmd.eval' main)
