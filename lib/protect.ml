let files =
  [ ".mcp.json"; "CLAUDE.md"; "CLAUDE.local.md"; ".envrc"; "mise.toml"; ".mise.toml" ]
  @ [ "mise.local.toml"; ".tool-versions"; ".npmrc" ]

let top_files = [ "flake.nix"; "flake.lock" ]
let dirs = [ ".claude"; ".vscode"; ".zed"; ".idea" ]
let pruned = [ "node_modules"; ".git"; ".data"; ".pnpm-store" ]
let max_depth = 5
let worktrees = ".claude/worktrees"
let ( / ) = Filename.concat
let same path = Policy.Ro_bind { src = path; dst = path }

let parse_hide text =
  let clean line =
    let line = List.hd (String.split_on_char '#' line) in
    String.concat ""
      (String.split_on_char ' ' (String.map (function '\t' | '\r' -> ' ' | c -> c) line))
  in
  let rec strip path =
    if String.ends_with ~suffix:"/" path then strip (String.sub path 0 (String.length path - 1))
    else path
  in
  let check path =
    let parts = String.split_on_char '/' path in
    if String.starts_with ~prefix:"/" path || List.mem ".." parts then
      Error (Printf.sprintf "hide: use paths inside the project, not '%s'" path)
    else Ok (strip path)
  in
  String.split_on_char '\n' text |> List.map clean
  |> List.filter (fun line -> line <> "")
  |> List.fold_left
       (fun acc line ->
         Result.bind acc (fun paths -> Result.map (fun p -> p :: paths) (check line)))
       (Ok [])
  |> Result.map List.rev

let real_dir root rel =
  let path = root / rel in
  match Fs.kind path with
  | Dir -> ()
  | Missing -> Fs.mkdir_p path
  | Link ->
      Msg.fail
        "%s is a symlink; hutch needs a real folder there to make it read-only in the sandbox" path
  | File | Other -> Msg.fail "%s is not a folder; hutch needs one there" path

let create root (rel, contents) =
  if Fs.kind (root / rel) <> Missing then None
  else begin
    Safe_write.write ~perm:0o644 ~root (root / rel) contents;
    Some rel
  end

(* Keeps hutch's local files out of commits without touching the project's .gitignore. *)
let exclude root created =
  let file = root / ".git/info/exclude" in
  let current = Option.value (Fs.read_opt file) ~default:"" in
  let lines = String.split_on_char '\n' current in
  let wanted =
    List.map
      (fun f -> "/" ^ f)
      ([ ".claude/settings.local.json"; ".claude/worktrees/"; ".data/" ] @ created)
  in
  match List.filter (fun line -> not (List.mem line lines)) wanted with
  | [] -> ()
  | missing ->
      let sep = if current = "" || String.ends_with ~suffix:"\n" current then "" else "\n" in
      Safe_write.write ~perm:0o644 ~root file (current ^ sep ^ String.concat "\n" missing ^ "\n")

let prepare ~root =
  List.iter (real_dir root) dirs;
  real_dir root worktrees;
  let created =
    List.filter_map (create root) [ (".mcp.json", "{ \"mcpServers\": {} }\n"); ("CLAUDE.md", "") ]
  in
  if Fs.kind (root / ".git") = Dir then begin
    real_dir root ".git/hooks";
    real_dir root ".git/info";
    exclude root created
  end

let linked_file ~project path =
  let target = try Some (Unix.realpath path) with Unix.Unix_error _ -> None in
  match target with
  | Some target when Fs.is_under ~root:project target && Fs.kind target = File ->
      Msg.info
        "%s is a symlink: its target is read-only in the sandbox, but the link itself can be \
         replaced there (make it a regular file to protect it fully)"
        path;
      [ same target ]
  | Some _ | None ->
      Msg.info "%s is a symlink hutch can't protect: it can be replaced inside the sandbox" path;
      []

(* Protected entries that exist below [root]. A protected folder is read-only as a whole, so
   there is nothing to look for inside it. *)
let existing ~project root =
  let found = ref [] in
  let visit ~rel ~name ~kind =
    let path = root / rel in
    let top = not (String.contains rel '/') in
    if List.mem name pruned then `Skip
    else if List.mem name dirs then begin
      if kind = Fs.Dir then found := same path :: !found;
      `Skip
    end
    else begin
      (if List.mem name files || (top && List.mem name top_files) then
         match kind with
         | Fs.File -> found := same path :: !found
         | Fs.Link -> found := List.rev_append (linked_file ~project path) !found
         | Fs.Dir | Fs.Missing | Fs.Other -> ());
      `Enter
    end
  in
  Fs.walk ~max_depth root ~visit;
  List.rev !found

let worktree_roots root =
  match Sys.readdir (root / worktrees) with
  | exception Sys_error _ -> []
  | names ->
      Array.sort String.compare names;
      Array.to_list names
      |> List.map (fun name -> root / worktrees / name)
      |> List.filter (fun path -> Fs.kind path = Fs.Dir)

(* [.git] is bound on itself first: its read-only parts alone would leave [.git] free to be
   renamed away and replaced by a folder with a config of the sandbox's choosing, which git on
   the host would then obey. *)
let git root =
  let dir = root / ".git" in
  if Fs.kind dir <> Fs.Dir then []
  else
    [
      Policy.Bind { src = dir; dst = dir };
      Policy.Ro_bind_try { src = dir / "config"; dst = dir / "config" };
      same (dir / "hooks");
      same (dir / "info");
    ]

let hidden root rel =
  let path = root / rel in
  match Fs.kind path with
  | Dir -> Some (Policy.Tmpfs path)
  | File -> Some (Policy.Hidden_file path)
  | Missing -> None
  | Link | Other ->
      Msg.fail "hide: %s is a symlink or a special file; list the real file or folder instead" path

let mounts ~root ~hide =
  List.concat
    [
      existing ~project:root root;
      [ Policy.Bind { src = root / worktrees; dst = root / worktrees } ];
      List.concat_map (existing ~project:root) (worktree_roots root);
      git root;
      List.filter_map (hidden root) hide;
    ]
