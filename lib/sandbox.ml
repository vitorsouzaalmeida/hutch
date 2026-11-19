let ( / ) = Filename.concat

type inputs = {
  uid : int;
  gid : int;
  shell : string;
  claude : Policy.mount list;
  protect : Policy.mount list;
  token : Policy.mount option;
  base : string option;
  agent : bool;
  host_ports : int list;
  exists : string -> bool;
}

let same path = Policy.Ro_bind { src = path; dst = path }

(* The user's own shell, prompt, tmux and git configuration, read-only. *)
let home_files =
  [ (".gitconfig", ".gitconfig"); (".zshrc", ".zshrc.host"); (".p10k.zsh", ".p10k.zsh") ]
  @ [ (".config/starship.toml", ".config/starship.toml"); (".oh-my-zsh", ".oh-my-zsh") ]
  @ [ (".tmux.conf", ".tmux.conf"); (".config/tmux", ".config/tmux") ]

let policy (c : Config.t) (p : Project.t) (i : inputs) : Policy.t =
  let open Policy in
  let home = c.home in
  let hostname = "hutch-" ^ p.name in
  let runtime = Printf.sprintf "/run/user/%d" i.uid in
  let generated name dst = Ro_bind { src = p.gen / name; dst } in
  let if_exists path mount = if i.exists path then [ mount ] else [] in
  let system =
    [ same "/usr"; Symlink { target = "usr/bin"; link = "/bin" } ]
    @ [
        Symlink { target = "usr/bin"; link = "/sbin" };
        Symlink { target = "usr/lib"; link = "/lib" };
      ]
    @ [ Symlink { target = "usr/lib"; link = "/lib64" }; same "/etc" ]
    @ if_exists "/etc/ssh/ssh_config.d" (Tmpfs "/etc/ssh/ssh_config.d")
    @ [ generated "hosts" "/etc/hosts" ]
    @ if_exists "/nix" (same "/nix")
    @ if_exists "/nix/var/nix/daemon-socket" (Tmpfs "/nix/var/nix/daemon-socket")
    @ [ Proc "/proc"; Dev "/dev"; Tmpfs "/dev/shm"; Tmpfs "/tmp"; Tmpfs "/run" ]
    @ [ Dir { path = runtime; perms = Some 0o700 } ]
  in
  let user =
    [ Bind { src = p.home; dst = home }; generated "zshrc" (home / ".zshrc") ]
    @ [ generated "zshenv" (home / ".zshenv"); generated "hutch-env.sh" (home / ".hutch-env.sh") ]
    @ List.map (fun (src, dst) -> Ro_bind_try { src = home / src; dst = home / dst }) home_files
    @ i.claude
    @ (match i.base with
      | Some b -> [ Symlink { target = b; link = "/opt/hutch-base" } ]
      | None -> [])
    @ Option.to_list i.token
  in
  let project =
    [ Bind { src = p.root; dst = p.root } ]
    @ i.protect
    @ if i.agent then [ Bind { src = p.agent; dst = "/run/ssh.sock" } ] else []
  in
  {
    hostname;
    uid = i.uid;
    gid = i.gid;
    mounts = system @ user @ project;
    env =
      [ ("XDG_RUNTIME_DIR", runtime) ]
      @ (if i.agent then [ ("SSH_AUTH_SOCK", "/run/ssh.sock") ] else [])
      @ [
          ("HUTCH_SANDBOX", p.name); ("PROJECT_ROOT", p.root); ("SHELL", i.shell); ("TMPDIR", "/tmp");
        ]
      @ [
          ("BASH_ENV", home / ".hutch-env.sh"); ("DISABLE_AUTOUPDATER", "1"); ("container", "hutch");
        ];
    unset_env = [ "TMUX"; "TMUX_PANE" ];
    chdir = Some p.root;
    net = { lan = c.lan; host_ports = i.host_ports };
  }

let is_locale name =
  String.starts_with ~prefix:"LC_" name
  && String.length name > 3
  && String.for_all
       (function 'A' .. 'Z' -> true | _ -> false)
       (String.sub name 3 (String.length name - 3))

let clean_env (c : Config.t) ~user ~env =
  let get name default =
    match List.assoc_opt name env with Some v when v <> "" -> v | _ -> default
  in
  let passed (name, _) = is_locale name || name = "TZ" || name = "COLORTERM" in
  [ ("HOME", c.home); ("USER", user); ("LOGNAME", user); ("SHELL", get "SHELL" "/bin/bash") ]
  @ [ ("PATH", c.home ^ "/.local/bin:/usr/local/bin:/usr/bin") ]
  @ [ ("TERM", get "TERM" "xterm-256color"); ("LANG", get "LANG" "C.UTF-8") ]
  @ List.filter passed env

let join_env (c : Config.t) ~env =
  let term = match List.assoc_opt "TERM" env with Some t when t <> "" -> t | _ -> "dumb" in
  [ ("HOME", c.home); ("TERM", term) ]
  @
  match List.assoc_opt "COLORTERM" env with
  | Some v when v <> "" -> [ ("COLORTERM", v) ]
  | _ -> []

(* The namespaces are listed one by one: --all would also try the time namespace, which the
   sandbox doesn't create. --root and --wd without a value mean the keeper's own. *)
let join_args ~pid ~cwd command =
  [ "--target"; string_of_int pid; "--user"; "--mount"; "--net"; "--pid"; "--ipc"; "--uts" ]
  @ [ "--cgroup"; "--preserve-credentials"; "--root"; "--wd" ]
  @ [ "/usr/bin/bash"; "-c"; Scripts.join; "hutch"; cwd ]
  @ command

let tmux (c : Config.t) args = "tmux" :: "-S" :: (c.home / "tmux.sock") :: args

(* tmux reads a dot in a target as the start of a window or pane name, so the session is named
   without dots. The keeper script does the same. *)
let session (p : Project.t) = String.map (function '.' -> '_' | ch -> ch) p.name

let host_env () =
  let pair entry =
    match String.index_opt entry '=' with
    | Some i -> (String.sub entry 0 i, String.sub entry (i + 1) (String.length entry - i - 1))
    | None -> (entry, "")
  in
  List.map pair (Array.to_list (Unix.environment ()))

let to_env pairs = Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v) pairs)

let run_inside c (p : Project.t) (k : Keeper.t) command =
  Proc.run ~output:Null
    ~env:(to_env (join_env c ~env:(host_env ())))
    (Tool.find c "nsenter")
    (join_args ~pid:k.pid ~cwd:p.root command)

let ready c p k = run_inside c p k (tmux c [ "has-session"; "-t"; "=" ^ session p ]) = 0

let running c p =
  match Keeper.current c p with Some k when ready c p k -> Some k | Some _ | None -> None

let join c p ~cwd command =
  match Keeper.current c p with
  | None -> Msg.fail "no sandbox is running for '%s' (start it with: hutch up)" p.Project.name
  | Some k ->
      Proc.exec
        ~env:(to_env (join_env c ~env:(host_env ())))
        (Tool.find c "nsenter")
        (join_args ~pid:k.pid ~cwd command)

(* Each terminal gets a session of its own in the group of the project's session: the same
   windows, but its own current one, so two terminals don't mirror each other. It ends when its
   terminal detaches or closes, and the windows stay. A terminal that isn't the first one also
   gets a new window. *)
let attach c p ~cwd =
  let view = Printf.sprintf "%s-%d" (session p) (Unix.getpid ()) in
  let others_attached = "#{e|>|:#{session_group_attached},1}" in
  join c p ~cwd
    (tmux c
       ([ "new-session"; "-t"; session p; "-s"; view; ";" ]
       @ [ "set-option"; "destroy-unattached"; "on"; ";" ]
       @ [ "if-shell"; "-F"; others_attached; "new-window -c '#{client_cwd}'" ]))

let with_lock (p : Project.t) f =
  let fd = Unix.openfile p.lock [ O_RDWR; O_CREAT; O_CLOEXEC ] 0o600 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      (try Unix.lockf fd F_TLOCK 0
       with Unix.Unix_error ((EAGAIN | EACCES), _, _) ->
         Msg.info "waiting for another hutch that is working on '%s'..." p.name;
         Unix.lockf fd F_LOCK 0);
      f ())

(* A sandboxed program runs in the user's terminal. With TIOCSTI it could push characters into
   that terminal's input, which the host shell would run once the program exits. *)
let check_terminal_injection () =
  match Option.map String.trim (Fs.read_opt "/proc/sys/dev/tty/legacy_tiocsti") with
  | Some "0" -> ()
  | Some _ | None ->
      Msg.fail
        "this kernel lets a program type into the terminal it runs in, so a sandboxed program \
         could run commands in your shell. Turn that off first: sudo sysctl \
         dev.tty.legacy_tiocsti=0"

(* Two sandboxes of one project would share its home folder (tmux socket, database files). *)
let clear_leftovers c (p : Project.t) =
  match Keeper.leftovers c p with
  | _, pid :: _ ->
      Msg.fail
        "another hutch instance already runs a sandbox for '%s' (process %d). Stop it with that \
         one first."
        p.name pid
  | [], [] -> ()
  | _ :: _, [] ->
      Msg.info "cleaning up a leftover sandbox for '%s'" p.name;
      Keeper.stop ~grace:2. c p

(* A personal flake, outside the project and invisible to the sandbox, wins over the project's
   own, which needs approval because the sandbox can write the project. *)
let flake (p : Project.t) =
  if Sys.file_exists (p.personal / "flake.nix") then Some ("path:" ^ p.personal)
  else if Sys.file_exists (p.root / "flake.nix") then begin
    Trust.ensure p;
    Some p.root
  end
  else None

(* Tools every sandbox gets, from a flake the user owns, at the end of PATH so that the project's
   own toolchain always wins. *)
let build_base (c : Config.t) (p : Project.t) =
  let dir = c.config / "base" in
  if c.no_base || not (Sys.file_exists (dir / "flake.nix")) then None
  else
    let link = p.meta / "base" in
    let built =
      Proc.run ~output:(Append p.log) (Tool.find c "nix")
        [ "build"; "path:" ^ dir; "--out-link"; link ]
    in
    if built = 0 then Some (Unix.realpath link)
    else begin
      Msg.info "the base tools (%s) failed to build, continuing without them (log: %s)" dir p.log;
      None
    end

let write_generated (p : Project.t) =
  Fs.remove_tree p.gen;
  Unix.mkdir p.gen 0o700;
  List.iter
    (fun (name, text) -> Fs.write (p.gen / name) text)
    [
      ("zshrc", Scripts.zshrc);
      ("zshenv", Scripts.zshenv);
      ("hutch-env.sh", Scripts.load_env);
      ("hosts", Scripts.hosts ~hostname:("hutch-" ^ p.name));
    ];
  if Fs.kind p.empty = Fs.Missing then Fs.write ~perm:0o444 p.empty ""

let personal_list (p : Project.t) name parse =
  match Fs.read_opt (p.personal / name) with
  | None -> []
  | Some text -> (
      match parse text with Ok l -> l | Error e -> Msg.fail "%s: %s" (p.personal / name) e)

(* bwrap follows a symlink found at a mount destination, and while it sets the sandbox up the
   host's files are still reachable. So no destination in a folder the sandbox can write may be,
   or be reached through, a symlink. In the sandbox's home the link is removed. In the project it
   may be the user's, so it is reported instead. *)
let check_destinations (c : Config.t) (p : Project.t) (policy : Policy.t) =
  let check dst =
    if dst <> p.root && Fs.is_under ~root:p.root dst then
      begin if not (Safe_write.no_links ~root:p.root dst) then
        Msg.fail
          "%s is, or is inside, a symlink: hutch can't protect it. Replace the link with a real \
           file or folder."
          dst
      end
    else if dst <> c.home && Fs.is_under ~root:c.home dst then
      let inside =
        p.home ^ String.sub dst (String.length c.home) (String.length dst - String.length c.home)
      in
      List.iter
        (Msg.info "removed the symlink %s (left by the sandbox?)")
        (Safe_write.drop_links ~root:p.home inside)
  in
  List.iter (fun mount -> check (Policy.destination mount)) policy.mounts

let user_name () =
  match Sys.getenv_opt "USER" with
  | Some user when user <> "" -> user
  | Some _ | None -> (Unix.getpwuid (Unix.getuid ())).pw_name

let chain c (p : Project.t) (policy : Policy.t) ~flake ~nonce =
  let tool name = (Tool.find c name :> string) in
  let sandbox =
    (tool "pasta" :: Policy.to_pasta_args policy.net)
    @ ("--" :: tool "bwrap" :: Policy.to_bwrap_args ~empty_file:p.empty policy)
    @ [ "--"; "bash"; "-c"; Scripts.keeper ]
    @ Keeper.args c p ~nonce
  in
  match flake with
  | None -> sandbox
  | Some flake -> [ tool "nix"; "develop"; flake; "--command" ] @ sandbox

let log_tail (p : Project.t) =
  let lines = String.split_on_char '\n' (Option.value (Fs.read_opt p.log) ~default:"") in
  let skip = max 0 (List.length lines - 31) in
  String.concat "\n" (List.filteri (fun i _ -> i >= skip) lines)

let wait_ready c (p : Project.t) ~launcher ~nonce =
  let started = Unix.gettimeofday () in
  let failed what = Msg.fail "%s. Log (%s):\n%s" what p.log (log_tail p) in
  let find = function
    | Some keeper -> Some keeper
    | None ->
        let keeper = Keeper.find c p ~nonce in
        Option.iter (Keeper.record p) keeper;
        keeper
  in
  let rec loop keeper told =
    let keeper = find keeper in
    let elapsed = Unix.gettimeofday () -. started in
    match keeper with
    | Some k when ready c p k -> ()
    | Some _ | None ->
        if Proc.exited launcher then failed "the sandbox exited during startup";
        if elapsed > 900. then failed "timed out waiting for the sandbox";
        let told =
          told
          || elapsed > 3.
             &&
             (Msg.info
                "still preparing the sandbox (a first Nix build can take a few minutes; log: %s)"
                p.log;
              true)
        in
        Unix.sleepf 0.05;
        loop keeper told
  in
  loop None false

let start (c : Config.t) (p : Project.t) =
  check_terminal_injection ();
  clear_leftovers c p;
  Keeper.forget p;
  Fs.write ~perm:0o600 p.log "";
  let flake = flake p in
  Protect.prepare ~root:p.root;
  let agent = Ssh_agent.ensure c p in
  let base = build_base c p in
  Claude.prepare c p;
  write_generated p;
  Fs.remove (p.home / ".hutch-env0");
  let env = host_env () in
  let policy =
    policy c p
      {
        uid = Unix.getuid ();
        gid = Unix.getgid ();
        shell =
          (match List.assoc_opt "SHELL" env with Some s when s <> "" -> s | _ -> "/bin/bash");
        claude = Claude.mounts c (Claude.binary c);
        protect = Protect.mounts ~root:p.root ~hide:(personal_list p "hide" Protect.parse_hide);
        token = Claude.token_mount c p;
        base;
        agent;
        host_ports = personal_list p "host-ports" Policy.parse_host_ports;
        exists = Sys.file_exists;
      }
  in
  check_destinations c p policy;
  let nonce = Keeper.nonce () in
  let launcher =
    Proc.spawn ~output:(Append p.log)
      ~env:(to_env (clean_env c ~user:(user_name ()) ~env))
      (Tool.find c "setsid") (chain c p policy ~flake ~nonce)
  in
  wait_ready c p ~launcher ~nonce;
  Msg.info "sandbox '%s' is up (dev servers appear on 127.0.0.1%s)" p.name
    (if c.lan then " and the LAN" else "")

let up c p =
  with_lock p (fun () ->
      match running c p with
      | Some _ -> `Already_running
      | None ->
          start c p;
          `Started)

let stop c (p : Project.t) =
  with_lock p (fun () ->
      (match Keeper.current c p with
      | Some k ->
          ignore (run_inside c p k [ "sh"; "-c"; Scripts.graceful ]);
          ignore (run_inside c p k (tmux c [ "kill-server" ]))
      | None -> ());
      Keeper.stop c p;
      Ssh_agent.stop p;
      Keeper.forget p;
      Msg.info "sandbox '%s' stopped" p.name)
