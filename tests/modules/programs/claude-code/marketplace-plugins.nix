{ config, ... }:

{
  programs.claude-code = {
    package = config.lib.test.mkStubPackage {
      name = "claude-code";
      buildScript = ''
        mkdir -p $out/bin
        touch $out/bin/claude
        chmod 755 $out/bin/claude
      '';
    };
    enable = true;

    marketplacePlugins = {
      test-market = {
        source = "directory";
        path = ./test-marketplace;
        plugins = [ "test-tool" ];
      };
    };
  };

  nmt.script = ''
    wrapperPath="$TESTED/home-path/bin/claude"
    normalizedWrapper=$(normalizeStorePaths "$wrapperPath")
    assertFileContent $normalizedWrapper ${./expected-marketplace-plugin-wrapper}

    test "$(grep -o -- '--plugin-dir ' "$wrapperPath" | wc -l)" -eq 1
    pluginDir=$(grep -o -- '--plugin-dir /nix/store/[^ ]*' "$wrapperPath")
    pluginDir="''${pluginDir#--plugin-dir }"
    assertFileContent "$pluginDir/.claude-plugin/plugin.json" ${./test-marketplace/plugins/test-tool/.claude-plugin/plugin.json}
  '';
}
