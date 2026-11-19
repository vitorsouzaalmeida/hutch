type settings = { projects : string option; claude_bin : string option; askpass : string option }

let no_settings = { projects = None; claude_bin = None; askpass = None }

type t = {
  home : string;
  projects : string;
  config : string;
  sb_root : string;
  state : string;
  inst : string;
  lan : bool;
  no_base : bool;
  claude_bin : string option;
  askpass : string option;
  path : string list;
}

let known_keys =
  [ ([], [ "projects"; "claude"; "ssh" ]); ([ "claude" ], [ "bin" ]); ([ "ssh" ], [ "askpass" ]) ]

let dotted path = String.concat "." path

let settings_of_toml text =
  let open Result.Syntax in
  let* toml = Otoml.Parser.from_string_result text in
  let keys path =
    match Otoml.find_opt toml Fun.id path with
    | None -> Ok []
    | Some (Otoml.TomlTable kvs | Otoml.TomlInlineTable kvs) -> Ok (List.map fst kvs)
    | Some _ -> Error (Printf.sprintf "%s must be a table" (dotted path))
  in
  let check (path, allowed) =
    let* found = keys path in
    match List.find_opt (fun k -> not (List.mem k allowed)) found with
    | None -> Ok ()
    | Some k -> Error (Printf.sprintf "unknown setting %s" (dotted (path @ [ k ])))
  in
  let string path =
    match Otoml.find_opt toml Fun.id path with
    | None -> Ok None
    | Some (Otoml.TomlString s) -> Ok (Some s)
    | Some _ -> Error (Printf.sprintf "%s must be a string" (dotted path))
  in
  let* () = List.fold_left (fun acc k -> Result.bind acc (fun () -> check k)) (Ok ()) known_keys in
  let* projects = string [ "projects" ] in
  let* claude_bin = string [ "claude"; "bin" ] in
  let+ askpass = string [ "ssh"; "askpass" ] in
  { projects; claude_bin; askpass }

let expand ~home path =
  if path = "~" then home
  else if String.starts_with ~prefix:"~/" path then home ^ String.sub path 1 (String.length path - 1)
  else path

let instance state = String.sub (Digest.BLAKE128.to_hex (Digest.BLAKE128.string state)) 0 12

let make ~getenv ~(settings : settings) =
  let env name = match getenv name with Some "" | None -> None | Some v -> Some v in
  let home = match env "HOME" with Some h -> h | None -> Msg.fail "HOME is not set" in
  let absolute what path =
    let path = expand ~home path in
    if Filename.is_relative path then Msg.fail "%s must be an absolute path, not '%s'" what path;
    path
  in
  let first what candidates = absolute what (List.find_map Fun.id candidates |> Option.get) in
  let xdg_config = Option.value (env "XDG_CONFIG_HOME") ~default:(home ^ "/.config") in
  let state =
    match (env "HUTCH_STATE", env "XDG_RUNTIME_DIR") with
    | Some s, _ -> absolute "HUTCH_STATE" s
    | None, Some run -> absolute "XDG_RUNTIME_DIR" run ^ "/hutch"
    | None, None -> Msg.fail "XDG_RUNTIME_DIR is not set (or set HUTCH_STATE)"
  in
  {
    home;
    projects =
      first "the projects folder"
        [ env "HUTCH_PROJECTS"; settings.projects; Some (home ^ "/Projects") ];
    config = first "HUTCH_CONFIG" [ env "HUTCH_CONFIG"; Some (xdg_config ^ "/hutch") ];
    sb_root = first "HUTCH_SB_ROOT" [ env "HUTCH_SB_ROOT"; Some (home ^ "/.sb") ];
    state;
    inst = instance state;
    lan = env "HUTCH_LAN" = Some "1";
    no_base = env "HUTCH_NO_BASE" = Some "1";
    claude_bin = Option.map (absolute "claude.bin") settings.claude_bin;
    askpass =
      Option.map (absolute "ssh.askpass")
        (List.find_map Fun.id [ settings.askpass; env "SSH_ASKPASS" ]);
    path = String.split_on_char ':' (Option.value (env "PATH") ~default:"");
  }

let real path = try Unix.realpath path with Unix.Unix_error _ -> path

let load () =
  let getenv = Sys.getenv_opt in
  let bare = make ~getenv ~settings:no_settings in
  let file = bare.config ^ "/config.toml" in
  let settings =
    match Fs.read_opt file with
    | None -> no_settings
    | Some text -> (
        match settings_of_toml text with Ok s -> s | Error e -> Msg.fail "%s: %s" file e)
  in
  let t = make ~getenv ~settings in
  { t with projects = real t.projects; sb_root = real t.sb_root }
