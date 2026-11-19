open Hutch

let config =
  Config.make ~settings:Config.no_settings
    ~getenv:(Tmp.env [ ("HOME", "/h"); ("HUTCH_STATE", "/s") ])

let name cwd = Result.map (fun (p : Project.t) -> p.name) (Project.of_cwd config ~cwd)
let rejected cwd = Alcotest.(check bool) cwd true (Result.is_error (name cwd))

let test_name () =
  Alcotest.(check (result string string)) "root" (Ok "shop") (name "/h/Projects/shop");
  Alcotest.(check (result string string))
    "below" (Ok "shop")
    (name "/h/Projects/shop/.claude/worktrees/a/src")

let test_rejected () =
  rejected "/h/Projects";
  rejected "/h";
  rejected "/h/Projects-other/shop";
  rejected "/h/Projects/my shop";
  rejected "/h/Projects/.meta"

let test_paths () =
  match Project.of_cwd config ~cwd:"/h/Projects/shop/api" with
  | Error e -> Alcotest.fail e
  | Ok p ->
      Alcotest.(check string) "root" "/h/Projects/shop" p.root;
      Alcotest.(check string) "home" "/h/.sb/shop" p.home;
      Alcotest.(check string) "meta" "/h/.sb/.meta/shop" p.meta;
      Alcotest.(check string) "personal" "/h/.config/hutch/projects/shop" p.personal;
      Alcotest.(check string) "state file" "/s/shop.pid" p.state_file

let suite =
  [
    ( "project",
      [
        Alcotest.test_case "name" `Quick test_name;
        Alcotest.test_case "rejected" `Quick test_rejected;
        Alcotest.test_case "paths" `Quick test_paths;
      ] );
  ]
