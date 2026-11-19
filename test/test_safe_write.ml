open Hutch

let test_write () =
  Tmp.with_dir @@ fun root ->
  let file = root ^ "/a/b/file" in
  Safe_write.write ~root file "one";
  Alcotest.(check string) "created with its folders" "one" (Fs.read file);
  Safe_write.write ~root file "two";
  Alcotest.(check string) "replaced" "two" (Fs.read file);
  Alcotest.(check (list string))
    "no temporary file left" [ "file" ]
    (Array.to_list (Sys.readdir (root ^ "/a/b")))

let test_linked_parent () =
  Tmp.with_dir @@ fun dir ->
  let root = dir ^ "/home" and outside = dir ^ "/outside" in
  Fs.mkdir_p root;
  Fs.mkdir_p outside;
  Unix.symlink outside (root ^ "/.claude");
  Tmp.raises_error "write" (fun () -> Safe_write.write ~root (root ^ "/.claude/settings.json") "x");
  Alcotest.(check (list string)) "nothing written outside" [] (Array.to_list (Sys.readdir outside))

let test_linked_file () =
  Tmp.with_dir @@ fun dir ->
  let root = dir ^ "/home" and target = dir ^ "/target" in
  Fs.mkdir_p root;
  Fs.write target "host";
  Unix.symlink target (root ^ "/file");
  Safe_write.write ~root (root ^ "/file") "sandbox";
  Alcotest.(check string) "the target is untouched" "host" (Fs.read target);
  Alcotest.(check bool) "the link became a file" true (Fs.kind (root ^ "/file") = Fs.File)

let test_no_links () =
  Tmp.with_dir @@ fun dir ->
  let root = dir ^ "/home" in
  Fs.mkdir_p (root ^ "/a");
  Unix.symlink root (dir ^ "/alias");
  Unix.symlink "/etc" (root ^ "/a/etc");
  Alcotest.(check bool) "root itself" true (Safe_write.no_links ~root root);
  Alcotest.(check bool) "missing below" true (Safe_write.no_links ~root (root ^ "/a/b/c"));
  Alcotest.(check bool)
    "a link on the way" false
    (Safe_write.no_links ~root (root ^ "/a/etc/passwd"));
  Alcotest.(check bool) "the last part" false (Safe_write.no_links ~root (root ^ "/a/etc"));
  Alcotest.(check bool)
    "a linked root" false
    (Safe_write.no_links ~root:(dir ^ "/alias") (dir ^ "/alias/a"));
  Alcotest.check_raises "outside the root" (Invalid_argument "/etc is not under /nope") (fun () ->
      ignore (Safe_write.no_links ~root:"/nope" "/etc"))

let test_drop_links () =
  Tmp.with_dir @@ fun dir ->
  let root = dir ^ "/home" and outside = dir ^ "/outside" in
  Fs.mkdir_p (root ^ "/.config");
  Tmp.touch (outside ^ "/keep");
  Unix.symlink outside (root ^ "/.config/tmux");
  Alcotest.(check (list string))
    "removed"
    [ root ^ "/.config/tmux" ]
    (Safe_write.drop_links ~root (root ^ "/.config/tmux/tmux.conf"));
  Alcotest.(check bool) "the target is kept" true (Sys.file_exists (outside ^ "/keep"));
  Alcotest.(check (list string))
    "nothing left to remove" []
    (Safe_write.drop_links ~root (root ^ "/.config/tmux"))

let suite =
  [
    ( "safe_write",
      [
        Alcotest.test_case "write" `Quick test_write;
        Alcotest.test_case "linked parent" `Quick test_linked_parent;
        Alcotest.test_case "linked file" `Quick test_linked_file;
        Alcotest.test_case "no_links" `Quick test_no_links;
        Alcotest.test_case "drop_links" `Quick test_drop_links;
      ] );
  ]
