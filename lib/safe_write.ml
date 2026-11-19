let below ~root path =
  if not (Fs.is_under ~root path) then invalid_arg (Printf.sprintf "%s is not under %s" path root);
  if path = root then []
  else
    let rest =
      String.sub path (String.length root + 1) (String.length path - String.length root - 1)
    in
    let step (dir, acc) part =
      let p = Filename.concat dir part in
      (p, p :: acc)
    in
    List.rev (snd (List.fold_left step (root, []) (String.split_on_char '/' rest)))

let is_link path = Fs.kind path = Fs.Link
let no_links ~root path = not (List.exists is_link (root :: below ~root path))
let drop_link path = if is_link path then Unix.unlink path

let drop_links ~root path =
  let drop p =
    is_link p
    &&
    (Unix.unlink p;
     true)
  in
  List.filter drop (below ~root path)

let counter = ref 0

let write ?(perm = 0o600) ~root path contents =
  let dir = Filename.dirname path in
  if not (no_links ~root dir) then
    Msg.fail "refusing to write %s: a folder on its path is a symlink" path;
  Fs.mkdir_p dir;
  incr counter;
  let tmp = Printf.sprintf "%s/.hutch-tmp.%d.%d" dir (Unix.getpid ()) !counter in
  Fs.remove tmp;
  (* [O_EXCL] refuses an existing name, link or not, and the rename below replaces a link at
     [path] instead of writing through it. *)
  let fd = Unix.openfile tmp [ O_WRONLY; O_CREAT; O_EXCL; O_CLOEXEC ] perm in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> ignore (Unix.write_substring fd contents 0 (String.length contents)));
  Unix.rename tmp path
