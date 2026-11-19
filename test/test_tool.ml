open Hutch

let ok c path = Result.is_ok (Tool.check c path)

let test_check () =
  Tmp.with_dir @@ fun dir ->
  let c = Tmp.config dir in
  let bin = Filename.concat dir "bin" in
  Tmp.touch ~perm:0o755 (bin ^ "/tool");
  Tmp.touch ~perm:0o644 (bin ^ "/data");
  Alcotest.(check bool) "an executable" true (ok c (bin ^ "/tool"));
  Alcotest.(check bool) "not executable" false (ok c (bin ^ "/data"));
  Alcotest.(check bool) "a folder" false (ok c bin);
  Alcotest.(check bool) "missing" false (ok c (bin ^ "/none"));
  Alcotest.(check bool) "relative" false (ok c "bin/tool")

let test_planted () =
  Tmp.with_dir @@ fun dir ->
  let c = Tmp.config dir in
  let planted = c.sb_root ^ "/shop/bin/bwrap" in
  Tmp.touch ~perm:0o755 planted;
  Tmp.touch ~perm:0o755 (c.projects ^ "/shop/bwrap");
  Fs.mkdir_p (dir ^ "/bin");
  Unix.symlink planted (dir ^ "/bin/bwrap");
  Alcotest.(check bool) "in a sandbox home" false (ok c planted);
  Alcotest.(check bool) "in a project" false (ok c (c.projects ^ "/shop/bwrap"));
  Alcotest.(check bool) "a link into a sandbox home" false (ok c (dir ^ "/bin/bwrap"))

let test_find () =
  Tmp.with_dir @@ fun dir ->
  Tmp.touch ~perm:0o755 (dir ^ "/projects/shop/tool");
  Tmp.touch ~perm:0o755 (dir ^ "/good/tool");
  let path =
    String.concat ":"
      [ "."; "projects/shop"; dir ^ "/projects/shop"; dir ^ "/missing"; dir ^ "/good" ]
  in
  let c = Tmp.config ~path dir in
  Alcotest.(check (option string))
    "the first trusted one"
    (Some (dir ^ "/good/tool"))
    (Option.map (fun t -> (t : Tool.t :> string)) (Tool.find_opt c "tool"));
  Alcotest.(check bool) "none" true (Tool.find_opt c "other" = None);
  Tmp.raises_error "find" (fun () -> Tool.find c "other")

let suite =
  [
    ( "tool",
      [
        Alcotest.test_case "check" `Quick test_check;
        Alcotest.test_case "planted" `Quick test_planted;
        Alcotest.test_case "find" `Quick test_find;
      ] );
  ]
