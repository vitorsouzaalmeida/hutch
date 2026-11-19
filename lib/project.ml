type t = {
  name : string;
  root : string;
  home : string;
  meta : string;
  personal : string;
  gen : string;
  state_file : string;
  lock : string;
  agent : string;
  log : string;
  empty : string;
}

let valid_name name =
  let ok = function 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true | _ -> false in
  name <> "" && name.[0] <> '.' && String.for_all ok name

let of_cwd (c : Config.t) ~cwd =
  let prefix = c.projects ^ "/" in
  if not (String.starts_with ~prefix cwd) then
    Error (Printf.sprintf "run me inside %s/<project> (you are in %s)" c.projects cwd)
  else
    let rest = String.sub cwd (String.length prefix) (String.length cwd - String.length prefix) in
    let name = List.hd (String.split_on_char '/' rest) in
    if not (valid_name name) then Error (Printf.sprintf "unsupported project folder name: %s" name)
    else
      let state file = Filename.concat c.state file in
      Ok
        {
          name;
          root = prefix ^ name;
          home = Filename.concat c.sb_root name;
          meta = Filename.concat c.sb_root (".meta/" ^ name);
          personal = Filename.concat c.config ("projects/" ^ name);
          gen = state (name ^ ".gen");
          state_file = state (name ^ ".pid");
          lock = state (name ^ ".lock");
          agent = state (name ^ "-ssh.sock");
          log = state (name ^ ".log");
          empty = state "empty";
        }

(* The state and meta folders hold what the host trusts (the keeper's identity, hashes, the
   token copy), so only the user may enter them. *)
let ensure_dirs (c : Config.t) t =
  List.iter Fs.mkdir_p [ t.home; t.meta; c.state ];
  Unix.chmod c.state 0o700;
  Unix.chmod (Filename.concat c.sb_root ".meta") 0o700
