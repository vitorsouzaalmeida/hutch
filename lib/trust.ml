let pruned = [ "node_modules"; ".git"; ".data"; ".pnpm-store" ]
let relevant name = name = "flake.lock" || Filename.check_suffix name ".nix"
let hex_of_file path = Digest.BLAKE256.(to_hex (file path))

let digest root =
  let buf = Buffer.create 1024 in
  let visit ~rel ~name ~kind =
    if List.mem name pruned || rel = ".claude/worktrees" then `Skip
    else begin
      let path = Filename.concat root rel in
      (match kind with
      | Fs.File when relevant name -> Printf.bprintf buf "%s\000f%s\n" rel (hex_of_file path)
      | Fs.Link when relevant name -> Printf.bprintf buf "%s\000l%s\n" rel (Unix.readlink path)
      | Fs.File | Fs.Link | Fs.Dir | Fs.Missing | Fs.Other -> ());
      `Enter
    end
  in
  Fs.walk root ~visit;
  Digest.BLAKE256.(to_hex (string (Buffer.contents buf)))

let approved ~file digest =
  match Fs.read_opt file with Some stored -> String.trim stored = digest | None -> false

let ask () =
  prerr_string "Use this flake? [y/N] ";
  flush stderr;
  match In_channel.input_line stdin with Some ("y" | "Y") -> true | Some _ | None -> false

let ensure (p : Project.t) =
  let file = Filename.concat p.personal "flake-approval" in
  let digest = digest p.root in
  if not (approved ~file digest) then begin
    if not (Unix.isatty Unix.stdin && Unix.isatty Unix.stderr) then
      Msg.fail
        "%s/flake.nix is new or changed since you approved it; run `hutch` in a terminal to review \
         it"
        p.root;
    Msg.info
      "%s/flake.nix (or flake.lock, or another .nix file) is new or changed since you last \
       approved it."
      p.root;
    Msg.info
      "It runs on your HOST, outside the sandbox. Review it first (git diff / git log -p -- \
       '*.nix' flake.lock).";
    if not (ask ()) then
      Msg.fail "repo flake not approved; put a personal one in %s/flake.nix instead" p.personal;
    Fs.mkdir_p p.personal;
    Fs.write file (digest ^ "\n")
  end
