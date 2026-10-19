-- Perl library dirs for a project: <root>/lib plus <root>/*/lib (monorepos with per-app libs)
local function perl_lib_dirs(root)
  local dirs = {}
  for _, pattern in ipairs({ "lib", "*/lib" }) do
    for _, dir in ipairs(vim.fn.glob(root .. "/" .. pattern, false, true)) do
      if vim.fn.isdirectory(dir) == 1 then
        table.insert(dirs, dir)
      end
    end
  end
  return dirs
end

return {
  -- 1. Perl Language Server Configuration
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        perlnavigator = {
          settings = {
            perlnavigator = {
              perlPath = "perl",
              enableWarnings = true,
              perlcriticEnabled = true,
              perlcriticSeverity = 4,
            },
          },
          -- Resolved per workspace so `use Foo::Bar` finds the project's own lib dirs
          before_init = function(_, config)
            local root = config.root_dir or vim.uv.cwd()
            config.settings.perlnavigator.includePaths = perl_lib_dirs(root)
          end,
        },
      },
    },
  },

  -- 2. Syntax highlighting, folds and text objects
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "perl", "pod" })
    end,
  },

  -- 3. Formatting with perltidy (<leader>cf). Matches .editorconfig: 4 spaces, 120 cols.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = { perl = { "perltidy" } },
      formatters = {
        perltidy = { prepend_args = { "-l=120", "-i=4" } },
      },
    },
  },

  -- 4. Test runner: prove through neotest (<leader>tr nearest, <leader>tt file, <leader>ts summary)
  {
    "nvim-neotest/neotest",
    dependencies = { "yuu-no/neotest-prove" },
    -- prove runs from the project root, so the lib dirs come from the cwd nvim was started in
    opts = function(_, opts)
      local args = {}
      for _, dir in ipairs(perl_lib_dirs(vim.uv.cwd())) do
        vim.list_extend(args, { "-I", dir })
      end
      opts.adapters = opts.adapters or {}
      opts.adapters["neotest-prove"] = { prove_args = args }
    end,
  },

  -- 5. Debugger Configuration
  {
    "mfussenegger/nvim-dap",
    optional = true, -- Tells LazyVim to safely skip this if dap.core isn't enabled yet
    opts = function()
      local dap = require("dap")

      -- Register the Mason-installed perl-debug-adapter
      dap.adapters.perl = {
        type = "executable",
        command = vim.fn.stdpath("data") .. "/mason/bin/perl-debug-adapter",
        args = {},
      }

      -- Define launch configurations for Perl
      dap.configurations.perl = {
        {
          type = "perl",
          request = "launch",
          name = "Launch Perl Script",
          program = "${file}",
        },
      }
    end,
  },
}
