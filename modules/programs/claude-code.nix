{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    literalExpression
    mkOption
    nameValuePair
    optionalAttrs
    ;

  cfg = config.programs.claude-code;

  jsonFormat = pkgs.formats.json { };

  mkMcpServer =
    server:
    (removeAttrs server [ "disabled" ])
    // (optionalAttrs (server ? url) { type = "http"; })
    // (optionalAttrs (server ? command) { type = "stdio"; })
    // {
      enabled = !(server.disabled or false);
    };

  transformedMcpServers = optionalAttrs (cfg.enableMcpIntegration && config.programs.mcp.enable) (
    lib.mapAttrs (_name: mkMcpServer) config.programs.mcp.servers
  );

  mkContentOption =
    {
      description,
      example ? null,
    }:
    mkOption (
      {
        type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
        default = { };
        inherit description;
      }
      // optionalAttrs (example != null) { inherit example; }
    );

  mkDirOption =
    { description, example }:
    mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      inherit description example;
    };

  fetchMarketplace =
    name: mp:
    if mp.source == "github" then
      let
        parts = lib.splitString "/" mp.repo;
      in
      pkgs.fetchFromGitHub {
        owner = builtins.elemAt parts 0;
        repo = builtins.elemAt parts 1;
        rev = mp.rev;
        hash = mp.hash;
      }
    else if mp.source == "git" then
      pkgs.fetchgit {
        url = mp.url;
        rev = mp.rev;
        hash = mp.hash;
      }
    else if mp.source == "directory" then
      mp.path
    else
      throw "unsupported marketplace source: ${mp.source}";

  extractPlugin =
    marketplaceName: marketplaceSrc: pluginName:
    pkgs.runCommand "claude-plugin-${marketplaceName}-${pluginName}"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        manifest="${marketplaceSrc}/.claude-plugin/marketplace.json"
        if [ ! -f "$manifest" ]; then
          echo "error: .claude-plugin/marketplace.json not found in marketplace '${marketplaceName}'" >&2
          exit 1
        fi

        source=$(jq -r \
          '.plugins[] | select(.name == "${pluginName}") | .source' \
          "$manifest")

        if [ -z "$source" ] || [ "$source" = "null" ]; then
          echo "error: plugin '${pluginName}' not found in marketplace '${marketplaceName}'" >&2
          exit 1
        fi

        plugin_dir="${marketplaceSrc}/$source"
        if [ ! -d "$plugin_dir" ]; then
          echo "error: plugin '${pluginName}' source path is not a directory in marketplace '${marketplaceName}'" >&2
          exit 1
        fi

        cp -r "$plugin_dir" $out
      '';

  marketplacePluginPaths = lib.concatLists (
    lib.mapAttrsToList (
      mpName: mp:
      let
        src = fetchMarketplace mpName mp;
      in
      map (pName: extractPlugin mpName src pName) mp.plugins
    ) cfg.marketplacePlugins
  );
in
{
  meta.maintainers = [ lib.maintainers.khaneliman ];

  options.programs.claude-code = {
    enable = lib.mkEnableOption "Claude Code, Anthropic's official CLI";

    package = lib.mkPackageOption pkgs "claude-code" { nullable = true; };

    finalPackage = mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "Resulting customized claude-code package.";
    };

    enableMcpIntegration = mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to integrate the MCP servers config from
        {option}`programs.mcp.servers` into
        {option}`programs.opencode.settings.mcp`.

        Note: Settings defined in {option}`programs.mcp.servers` are merged
        with {option}`programs.claude-code.mcpServers`, with Claude Code servers
        taking precedence.
      '';
    };

    settings = mkOption {
      inherit (jsonFormat) type;
      default = { };
      example = {
        theme = "dark";
        permissions = {
          allow = [
            "Bash(git diff:*)"
            "Edit"
          ];
          ask = [ "Bash(git push:*)" ];
          deny = [
            "WebFetch"
            "Bash(curl:*)"
            "Read(./.env)"
            "Read(./secrets/**)"
          ];
          additionalDirectories = [ "../docs/" ];
          defaultMode = "acceptEdits";
          disableBypassPermissionsMode = "disable";
        };
        model = "claude-3-5-sonnet-20241022";
        hooks = {
          PreToolUse = [
            {
              matcher = "Bash";
              hooks = [
                {
                  type = "command";
                  command = "echo 'Running command: $CLAUDE_TOOL_INPUT'";
                }
              ];
            }
          ];
          PostToolUse = [
            {
              matcher = "Edit|MultiEdit|Write";
              hooks = [
                {
                  type = "command";
                  command = "nix fmt $(jq -r '.tool_input.file_path' <<< '$CLAUDE_TOOL_INPUT')";
                }
              ];
            }
          ];
        };
        statusLine = {
          type = "command";
          command = "input=$(cat); echo \"[$(echo \"$input\" | jq -r '.model.display_name')] 📁 $(basename \"$(echo \"$input\" | jq -r '.workspace.current_dir')\")\"";
          padding = 0;
        };
        includeCoAuthoredBy = false;
      };
      description = "JSON configuration for Claude Code settings.json";
    };

    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Plugin directories to load into Claude Code via `--plugin-dir`.
        Each entry should be a path to a directory containing a valid
        Claude Code plugin.
      '';
      example = lib.literalExpression "[ ./my-local-plugin ]";
    };

    marketplacePlugins = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.enum [
                "github"
                "git"
                "directory"
              ];
              description = "Source type for the marketplace.";
            };

            repo = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''GitHub repository in "owner/repo" format. Required when source = "github".'';
            };

            url = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''Git repository URL. Required when source = "git".'';
            };

            path = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = ''Path to a local marketplace directory. Required when source = "directory".'';
            };

            rev = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Git revision (commit, tag, or branch). Used with github and git sources.";
            };

            hash = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "SRI hash of the source for reproducible fetching. Required for github and git sources.";
            };

            plugins = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Plugin names to install from this marketplace.";
            };
          };
        }
      );
      default = { };
      description = ''
        Install plugins from Claude Code marketplaces. The module fetches the
        marketplace source, reads `.claude-plugin/marketplace.json`, extracts
        selected plugins, and loads them via `--plugin-dir`.

        Only plugins with relative-path sources within the marketplace repo
        are supported.
      '';
      example = lib.literalExpression ''
        {
          company-tools = {
            source = "github";
            repo = "mycompany/claude-marketplace";
            rev = "v2.0.0";
            hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            plugins = [ "code-reviewer" "deployment-tools" ];
          };

          internal-tools = {
            source = "git";
            url = "https://gitlab.example.com/team/claude-plugins.git";
            rev = "abc1234";
            hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
            plugins = [ "lint-checker" ];
          };

          local-plugins = {
            source = "directory";
            path = ./my-marketplace;
            plugins = [ "custom-linter" ];
          };
        }
      '';
    };

    agents = mkContentOption {
      description = ''
        Custom agents for Claude Code.
        The attribute name becomes the agent filename, and the value is either:
        - Inline content as a string with frontmatter
        - A path to a file containing the agent content with frontmatter
        Agents are stored in .claude/agents/ directory.
      '';
      example = literalExpression ''
        {
          code-reviewer = '''
            ---
            name: code-reviewer
            description: Specialized code review agent
            tools: Read, Edit, Grep
            ---

            You are a senior software engineer specializing in code reviews.
            Focus on code quality, security, and maintainability.
          ''';
          documentation = ./agents/documentation.md;
        }
      '';
    };

    commands = mkContentOption {
      description = ''
        Custom commands for Claude Code.
        The attribute name becomes the command filename, and the value is either:
        - Inline content as a string
        - A path to a file containing the command content
        Commands are stored in .claude/commands/ directory.
      '';
      example = literalExpression ''
        {
          changelog = '''
            ---
            allowed-tools: Bash(git log:*), Bash(git diff:*)
            argument-hint: [version] [change-type] [message]
            description: Update CHANGELOG.md with new entry
            ---
            Parse the version, change type, and message from the input
            and update the CHANGELOG.md file accordingly.
          ''';
          fix-issue = ./commands/fix-issue.md;
          commit = '''
            ---
            allowed-tools: Bash(git add:*), Bash(git status:*), Bash(git commit:*)
            description: Create a git commit with proper message
            ---
            ## Context

            - Current git status: !`git status`
            - Current git diff: !`git diff HEAD`
            - Recent commits: !`git log --oneline -5`

            ## Task

            Based on the changes above, create a single atomic git commit with a descriptive message.
          ''';
        }
      '';
    };

    hooks = mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = ''
        Custom hooks for Claude Code.
        The attribute name becomes the hook filename, and the value is the hook script content.
        Hooks are stored in .claude/hooks/ directory.
      '';
      example = {
        pre-edit = ''
          #!/usr/bin/env bash
          echo "About to edit file: $1"
        '';
        post-commit = ''
          #!/usr/bin/env bash
          echo "Committed with message: $1"
        '';
      };
    };

    memory = {
      text = mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = ''
          Inline memory content for CLAUDE.md.
          This option is mutually exclusive with memory.source.
        '';
        example = ''
          # Project Memory

          ## Current Task
          Implementing enhanced claude-code module for home-manager.

          ## Key Files
          - claude-code.nix: Main module implementation
        '';
      };

      source = mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing memory content for CLAUDE.md.
          This option is mutually exclusive with memory.text.
        '';
        example = literalExpression "./claude-memory.md";
      };
    };

    rules = mkContentOption {
      description = ''
        Modular rule files for Claude Code.
        The attribute name becomes the rule filename, and the value is either:
        - Inline content as a string
        - A path to a file containing the rule content
        Rules are stored in .claude/rules/ directory.
        All markdown files in .claude/rules/ are automatically loaded as project memory.
      '';
      example = literalExpression ''
        {
          code-style = '''
            # Code Style Guidelines

            - Use consistent formatting
            - Follow language conventions
          ''';
          testing = '''
            # Testing Conventions

            - Write tests for all new features
            - Maintain test coverage above 80%
          ''';
          security = ./rules/security.md;
        }
      '';
    };

    rulesDir = mkDirOption {
      description = ''
        Path to a directory containing rule files for Claude Code.
        Rule files from this directory will be symlinked to .claude/rules/.
        All markdown files in this directory are automatically loaded as project memory.
      '';
      example = literalExpression "./rules";
    };

    agentsDir = mkDirOption {
      description = ''
        Path to a directory containing agent files for Claude Code.
        Agent files from this directory will be symlinked to .claude/agents/.
      '';
      example = literalExpression "./agents";
    };

    commandsDir = mkDirOption {
      description = ''
        Path to a directory containing command files for Claude Code.
        Command files from this directory will be symlinked to .claude/commands/.
      '';
      example = literalExpression "./commands";
    };

    hooksDir = mkDirOption {
      description = ''
        Path to a directory containing hook files for Claude Code.
        Hook files from this directory will be symlinked to .claude/hooks/.
      '';
      example = literalExpression "./hooks";
    };

    outputStyles = mkContentOption {
      description = ''
        Custom output styles for Claude Code.
        The attribute name becomes the base of the output style filename.
        The value is either:
          - Inline content as a string
          - A path to a file
        In both cases, the contents will be written to .claude/output-styles/<name>.md
      '';
      example = literalExpression ''
        {
          concise = ./output-styles/concise.md;
          detailed = '''
            # Detailed Output Style

            Contents will be used verbatim for the detailed output format.
          ''';
        }
      '';
    };

    skills = mkContentOption {
      description = ''
        Custom skills for Claude Code.
        The attribute name becomes the skill directory name, and the value is either:
        - Inline content as a string (creates .claude/skills/<name>/SKILL.md)
        - A path to a file (creates .claude/skills/<name>/SKILL.md)
        - A path to a directory (creates .claude/skills/<name>/ with all files)
      '';
      example = literalExpression ''
        {
          xlsx = ./skills/xlsx/SKILL.md;
          data-analysis = ./skills/data-analysis;
          pdf-processing = '''
            ---
            name: pdf-processing
            description: Extract text and tables from PDF files, fill forms, merge documents. Use when working with PDF files or when the user mentions PDFs, forms, or document extraction.
            ---

            # PDF Processing

            ## Quick start

            Use pdfplumber to extract text from PDFs:

            ```python
            import pdfplumber

            with pdfplumber.open("document.pdf") as pdf:
                text = pdf.pages[0].extract_text()
            ```
          ''';
        }
      '';
    };

    skillsDir = mkDirOption {
      description = ''
        Path to a directory containing skill directories for Claude Code.
        Each skill directory should contain a SKILL.md entrypoint file.
        Skill directories from this path will be symlinked to .claude/skills/.
      '';
      example = literalExpression "./skills";
    };

    lspServers = mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = { };
      description = ''
        LSP (Language Server Protocol) servers configuration.
      '';
      example = {
        go = {
          command = "gopls";
          args = [ "serve" ];
          extensionToLanguage = {
            ".go" = "go";
          };
        };
        typescript = {
          command = "typescript-language-server";
          args = [ "--stdio" ];
          extensionToLanguage = {
            ".ts" = "typescript";
            ".tsx" = "typescriptreact";
            ".js" = "javascript";
            ".jsx" = "javascriptreact";
          };
        };
      };
    };

    mcpServers = mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = { };
      description = "MCP (Model Context Protocol) servers configuration";
      example = {
        github = {
          type = "http";
          url = "https://api.githubcopilot.com/mcp/";
        };
        filesystem = {
          type = "stdio";
          command = "npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-filesystem"
            "/tmp"
          ];
        };
        database = {
          type = "stdio";
          command = "npx";
          args = [
            "-y"
            "@bytebase/dbhub"
            "--dsn"
            "postgresql://user:pass@localhost:5432/db"
          ];
          env = {
            DATABASE_URL = "postgresql://user:pass@localhost:5432/db";
          };
        };
        customTransport = {
          type = "websocket";
          url = "wss://example.com/mcp";
          customOption = "value";
          timeout = 5000;
        };
      };
    };
  };

  config =
    let
      mkSourceEntry = content: if lib.isPath content then { source = content; } else { text = content; };

      mkMarkdownEntries =
        subdir: attrs:
        lib.mapAttrs' (
          name: content: nameValuePair ".claude/${subdir}/${name}.md" (mkSourceEntry content)
        ) attrs;

      mkTextEntries =
        subdir: attrs:
        lib.mapAttrs' (name: content: nameValuePair ".claude/${subdir}/${name}" { text = content; }) attrs;

      mkRecursiveDirAttrs =
        subdir: dir:
        optionalAttrs (dir != null) {
          ".claude/${subdir}" = {
            source = dir;
            recursive = true;
          };
        };

      mkSkillEntry =
        name: content:
        if lib.isPath content && lib.pathIsDirectory content then
          nameValuePair ".claude/skills/${name}" {
            source = content;
            recursive = true;
          }
        else
          nameValuePair ".claude/skills/${name}/SKILL.md" (mkSourceEntry content);
    in
    lib.mkIf cfg.enable {
      assertions =
        let
          exclusiveInlineDirNames = [
            "rules"
            "agents"
            "commands"
            "hooks"
            "skills"
          ];

          mkExclusiveAssertion = inline: {
            assertion = !(cfg.${inline} != { } && cfg.${inline + "Dir"} != null);
            message = "Cannot specify both `programs.claude-code.${inline}` and `programs.claude-code.${inline}Dir`";
          };
        in
        [
          {
            assertion =
              (
                cfg.mcpServers == { }
                && cfg.lspServers == { }
                && !cfg.enableMcpIntegration
                && cfg.plugins == [ ]
                && cfg.marketplacePlugins == [ ]
              )
              || cfg.package != null;
            message = "`programs.claude-code.package` cannot be null when `mcpServers`, `lspServers`, `enableMcpIntegration`, `plugins`, or `marketplacePlugins` is configured";
          }
          {
            assertion = !(cfg.memory.text != null && cfg.memory.source != null);
            message = "Cannot specify both `programs.claude-code.memory.text` and `programs.claude-code.memory.source`";
          }
        ]
        ++ map mkExclusiveAssertion exclusiveInlineDirNames
        ++ lib.mapAttrsToList (name: mp: {
          assertion = mp.source == "github" -> (mp.repo != null && mp.hash != null);
          message = "marketplacePlugins.${name}: `repo` and `hash` are required when source = \"github\"";
        }) cfg.marketplacePlugins
        ++ lib.mapAttrsToList (name: mp: {
          assertion = mp.source == "git" -> (mp.url != null && mp.hash != null);
          message = "marketplacePlugins.${name}: `url` and `hash` are required when source = \"git\"";
        }) cfg.marketplacePlugins
        ++ lib.mapAttrsToList (name: mp: {
          assertion = mp.source == "directory" -> mp.path != null;
          message = "marketplacePlugins.${name}: `path` is required when source = \"directory\"";
        }) cfg.marketplacePlugins;

      programs.claude-code.finalPackage =
        let
          mergedMcpServers = transformedMcpServers // cfg.mcpServers;
          pluginFiles =
            lib.optional (mergedMcpServers != { }) {
              name = ".mcp.json";
              path = jsonFormat.generate "claude-code-mcp.json" { mcpServers = mergedMcpServers; };
            }
            ++ lib.optional (cfg.lspServers != { }) {
              name = ".lsp.json";
              path = jsonFormat.generate "claude-code-lsp.json" cfg.lspServers;
            };
          pluginDir = pkgs.runCommand "claude-code-hm-plugin" { } (
            ''
              install -Dm644 ${
                jsonFormat.generate "claude-code-plugin.json" {
                  name = "claude-code-home-manager";
                }
              } $out/.claude-plugin/plugin.json
            ''
            + lib.concatLines (
              map (pluginFile: "install -Dm644 ${pluginFile.path} $out/${pluginFile.name}") pluginFiles
            )
          );
          allPluginPaths =
            (if pluginFiles != [ ] then [ pluginDir ] else [ ]) ++ cfg.plugins ++ marketplacePluginPaths;
          wrapperArgs = lib.flatten (
            map (p: [
              "--plugin-dir"
              "${p}"
            ]) allPluginPaths
          );
        in
        if allPluginPaths != [ ] then
          pkgs.symlinkJoin {
            name = "claude-code";
            paths = [ cfg.package ];
            postBuild = ''
              mv $out/bin/claude $out/bin/.claude-wrapped
              cat > $out/bin/claude <<EOF
              #! ${pkgs.bash}/bin/bash -e
              exec -a "\$0" "$out/bin/.claude-wrapped" ${lib.escapeShellArgs wrapperArgs} "\$@"
              EOF
              chmod +x $out/bin/claude
            '';
            inherit (cfg.package) meta;
          }
        else
          cfg.package;

      home = {
        packages = lib.mkIf (cfg.package != null) [ cfg.finalPackage ];

        file = lib.mkMerge [
          (lib.mkIf (cfg.settings != { }) {
            ".claude/settings.json".source = jsonFormat.generate "claude-code-settings.json" (
              cfg.settings
              // {
                "$schema" = "https://json.schemastore.org/claude-code-settings.json";
              }
            );
          })
          (lib.mkIf (cfg.memory.text != null) {
            ".claude/CLAUDE.md".text = cfg.memory.text;
          })
          (lib.mkIf (cfg.memory.source != null) {
            ".claude/CLAUDE.md".source = cfg.memory.source;
          })
          (mkMarkdownEntries "agents" cfg.agents)
          (mkMarkdownEntries "commands" cfg.commands)
          (mkMarkdownEntries "rules" cfg.rules)
          (mkRecursiveDirAttrs "agents" cfg.agentsDir)
          (mkRecursiveDirAttrs "commands" cfg.commandsDir)
          (mkRecursiveDirAttrs "hooks" cfg.hooksDir)
          (mkRecursiveDirAttrs "rules" cfg.rulesDir)
          (mkRecursiveDirAttrs "skills" cfg.skillsDir)
          (mkTextEntries "hooks" cfg.hooks)
          (lib.mapAttrs' mkSkillEntry cfg.skills)
          (mkMarkdownEntries "output-styles" cfg.outputStyles)
        ];
      };
    };
}
