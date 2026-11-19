type t = { pid : int; nonce : string }
type claim = Ours of string | Foreign | Unrelated

let tag = "hutch-keeper"

let nonce () =
  let bytes =
    In_channel.with_open_bin "/dev/urandom" (fun ic -> In_channel.really_input_string ic 16)
  in
  match bytes with
  | Some bytes ->
      String.concat ""
        (List.map
           (fun ch -> Printf.sprintf "%02x" (Char.code ch))
           (List.of_seq (String.to_seq bytes)))
  | None -> Msg.fail "couldn't read /dev/urandom"

let args (c : Config.t) (p : Project.t) ~nonce = [ tag; p.name; c.inst; nonce ]

(* The keeper runs as [bash -c SCRIPT hutch-keeper NAME INST NONCE]. Any other command line that
   names this project as its keeper's is another hutch instance's, with another state folder. *)
let classify (c : Config.t) (p : Project.t) = function
  | "bash" :: "-c" :: _script :: tag' :: name :: rest when tag' = tag && name = p.name -> (
      match rest with [ inst; nonce ] when inst = c.inst -> Ours nonce | _ -> Foreign)
  | _ -> Unrelated

let claim c p pid =
  if not (Proc.mine pid) then Unrelated
  else match Proc.cmdline pid with Some argv -> classify c p argv | None -> Unrelated

let record (p : Project.t) t =
  Fs.write ~perm:0o600 p.state_file (Printf.sprintf "%d %s\n" t.pid t.nonce)

let forget (p : Project.t) = Fs.remove p.state_file

let recorded (p : Project.t) =
  match
    Option.map (fun text -> String.split_on_char ' ' (String.trim text)) (Fs.read_opt p.state_file)
  with
  | Some [ pid; nonce ] -> Option.map (fun pid -> { pid; nonce }) (int_of_string_opt pid)
  | Some _ | None -> None

let current c p =
  match recorded p with
  | Some t when claim c p t.pid = Ours t.nonce -> Some t
  | Some _ | None -> None

let leftovers c p =
  let sort (ours, foreign) pid =
    match claim c p pid with
    | Ours _ -> (pid :: ours, foreign)
    | Foreign -> (ours, pid :: foreign)
    | Unrelated -> (ours, foreign)
  in
  List.fold_left sort ([], []) (Proc.pids ())

let find c p ~nonce =
  let ours, _ = leftovers c p in
  Option.map
    (fun pid -> { pid; nonce })
    (List.find_opt (fun pid -> claim c p pid = Ours nonce) ours)

let stop ?(grace = 10.) c (p : Project.t) =
  let ours, _ = leftovers c p in
  if not (Proc.wait_gone ~seconds:grace ours) then begin
    List.iter (fun pid -> Proc.kill pid Sys.sigterm) ours;
    if not (Proc.wait_gone ~seconds:5. ours) then
      Msg.fail "couldn't stop the sandbox for '%s'" p.name
  end
