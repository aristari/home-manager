{pkgs, lib, ...}:

# This should succeed.
lib.mkIf true {
  home.file = {
    "foo" = {
      source = pkgs.runCommand "foo-recursive" {} ''
        mkdir $out
        echo -n foo > $out/foo
        echo -n bar > $out/bar
      '';
      recursive = true;
    };
    "foo/bar".text = "bar override";
  };

  nmt.script = ''
    assertFileExists 'home-files/foo/foo';
    assertFileContent 'home-files/foo/foo' \
      ${builtins.toFile "foo-expected" "foo"}

    assertFileExists 'home-files/foo/bar';
    assertFileContent 'home-files/foo/bar' \
      ${builtins.toFile "bar-expected" "bar override"}
  '';
}
