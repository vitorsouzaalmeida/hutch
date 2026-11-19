let ( / ) = Filename.concat
let same path = Policy.Ro_bind { src = path; dst = path }

let binary (c : Config.t) =
  let tool =
    match c.claude_bin with
    | None -> Tool.find_opt c "claude"
    | Some path -> (
        match Tool.check c path with Ok t -> Some t | Error e -> Msg.fail "claude.bin: %s" e)
  in
  Option.map Tool.real tool

let host_dirs = [ "skills"; "agents"; "commands"; "output-styles" ]
let is_dir path = try Sys.is_directory path with Sys_error _ -> false

let mounts (c : Config.t) binary =
  let claude = c.home / ".claude" in
  let program =
    match binary with
    | None -> []
    | Some real -> [ same real; Ro_bind { src = real; dst = c.home / ".local/bin/claude" } ]
  in
  let dirs = List.filter is_dir (List.map (fun d -> claude / d) host_dirs) in
  program
  @ [ Policy.Ro_bind_try { src = claude / "CLAUDE.md"; dst = claude / "CLAUDE.md" } ]
  @ List.map same dirs

let token_mount (c : Config.t) (p : Project.t) =
  match Fs.read_opt (c.config / "claude-oauth-token") with
  | None -> None
  | Some text ->
      let blank = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false in
      let token = String.of_seq (Seq.filter (fun ch -> not (blank ch)) (String.to_seq text)) in
      let file = p.gen / "claude-token" in
      Fs.write ~perm:0o600 file token;
      Some (Policy.Ro_bind { src = file; dst = "/run/hutch/claude-token" })

(* JSON edits. Some of these files are written by the sandbox, so reading one must never fail or
   use unbounded memory, whatever it holds. *)

let max_size = 64 * 1024 * 1024

let parse text =
  if String.length text > max_size then None
  else
    match Yojson.Safe.from_string text with
    | `Assoc _ as json -> Some json
    | _ -> None
    | exception (Yojson.Json_error _ | Yojson.End_of_input | Failure _ | Stack_overflow) -> None

let read_host path = Option.bind (Fs.read_opt path) parse

(* For a file the sandbox can write: only a regular file of a sane size is opened, so a link, a
   pipe or a huge file left there is ignored. *)
let read_untrusted path =
  match Unix.lstat path with
  | { st_kind = S_REG; st_size; _ } when st_size <= max_size -> read_host path
  | _ -> None
  | exception Unix.Unix_error _ -> None

let to_text json = Yojson.Safe.pretty_to_string json ^ "\n"
let member key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let remove key = function `Assoc fields -> `Assoc (List.remove_assoc key fields) | json -> json

let set key value = function
  | `Assoc fields when List.mem_assoc key fields ->
      `Assoc (List.map (fun (k, v) -> if k = key then (k, value) else (k, v)) fields)
  | `Assoc fields -> `Assoc (fields @ [ (key, value) ])
  | json -> json

let sandbox_settings json = remove "sandbox" json

let onboarding_keys =
  [ "hasCompletedOnboarding"; "lastOnboardingVersion"; "installMethod" ]
  @ [ "shiftEnterKeyBindingInstalled"; "effortCalloutDismissed"; "effortCalloutV2Dismissed" ]

let initial_state ~host =
  let kept key =
    match Option.bind host (member key) with
    | None | Some `Null -> None
    | Some value -> Some (key, value)
  in
  `Assoc (List.filter_map kept onboarding_keys @ [ ("autoUpdates", `Bool false) ])

let with_mcp ~servers json =
  let current = match member "mcpServers" json with Some (`Assoc s) -> s | _ -> [] in
  let kept = List.filter (fun (name, _) -> not (List.mem_assoc name servers)) current in
  set "mcpServers" (`Assoc (kept @ servers)) json

let mcp_servers (c : Config.t) =
  let file = c.config / "base/mcp.json" in
  if c.no_base || Fs.kind file = Fs.Missing then []
  else
    match Option.bind (read_host file) (member "mcpServers") with
    | Some (`Assoc servers) -> servers
    | _ -> Msg.fail "%s must look like {\"mcpServers\": { ... }}" file

let copy_settings (c : Config.t) (p : Project.t) =
  let host = c.home / ".claude/settings.json" in
  let dest = p.home / ".claude/settings.json" and sum_file = p.meta / "settings.sum" in
  match Fs.read_opt host with
  | None -> ()
  | Some text -> (
      let sum = Digest.BLAKE256.(to_hex (string text)) in
      if Fs.kind dest <> Fs.File || Fs.read_opt sum_file <> Some sum then
        match parse text with
        | None -> Msg.info "%s isn't valid JSON; not copied into the sandbox" host
        | Some json ->
            Safe_write.write ~root:p.home dest (to_text (sandbox_settings json));
            Fs.write sum_file sum)

let prepare_state (c : Config.t) (p : Project.t) =
  let file = p.home / ".claude.json" in
  let servers = mcp_servers c in
  Safe_write.drop_link file;
  match Fs.kind file with
  | Missing ->
      let state = initial_state ~host:(read_host (c.home / ".claude.json")) in
      Safe_write.write ~root:p.home file (to_text (with_mcp ~servers state))
  | File when servers <> [] -> (
      match read_untrusted file with
      | Some json -> Safe_write.write ~root:p.home file (to_text (with_mcp ~servers json))
      | None ->
          Msg.info "%s isn't valid JSON; leaving it alone (MCP servers not registered this time)"
            file)
  | File | Dir | Link | Other -> ()

let prepare c (p : Project.t) =
  let dir = p.home / ".claude" in
  List.iter
    (Msg.info "removed the symlink %s (left by the sandbox?)")
    (Safe_write.drop_links ~root:p.home dir);
  Fs.mkdir_p dir;
  copy_settings c p;
  prepare_state c p
