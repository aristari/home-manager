{ pkgs, ... }:
let
  codexPackage = pkgs.runCommand "codex-0.134.0" { } ''
    mkdir -p $out/bin
    echo '#!/bin/sh' > $out/bin/codex
    chmod +x $out/bin/codex
  '';
in
{
  programs.codex = {
    enable = true;
    package = codexPackage;
    enableSettingsAsProfile = true;
    settings = {
      model = "gemma3:latest";
      model_provider = "ollama";
      model_providers = {
        ollama = {
          name = "Ollama";
          baseURL = "http://localhost:11434/v1";
          envKey = "OLLAMA_API_KEY";
        };
      };
    };
  };
  nmt.script = ''
    wrapperPath="$TESTED/home-path/bin/codex"
    normalizedWrapper=$(normalizeStorePaths "$wrapperPath")
    assertFileContent "$normalizedWrapper" ${./expected-profile-wrapper}

    assertFileExists home-files/.codex/home-manager.config.toml
    assertFileContent home-files/.codex/home-manager.config.toml \
      ${./config.toml}
    assertFileNotRegex home-path/etc/profile.d/hm-session-vars.sh 'CODEX_HOME'
  '';
}
