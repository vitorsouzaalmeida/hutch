let () =
  Alcotest.run "hutch"
    (List.concat
       [
         Test_config.suite;
         Test_project.suite;
         Test_tool.suite;
         Test_safe_write.suite;
         Test_policy.suite;
         Test_protect.suite;
         Test_trust.suite;
         Test_claude.suite;
         Test_keeper.suite;
         Test_sandbox.suite;
       ])
