return {
  -- C-h/j/k/l moves across nvim splits and tmux panes; pairs with ~/.tmux.conf
  {
    "christoomey/vim-tmux-navigator",
    cmd = {
      "TmuxNavigateLeft",
      "TmuxNavigateDown",
      "TmuxNavigateUp",
      "TmuxNavigateRight",
      "TmuxNavigatePrevious",
    },
    keys = {
      { "<c-h>", "<cmd>TmuxNavigateLeft<cr>", desc = "Navigate left" },
      { "<c-j>", "<cmd>TmuxNavigateDown<cr>", desc = "Navigate down" },
      { "<c-k>", "<cmd>TmuxNavigateUp<cr>", desc = "Navigate up" },
      { "<c-l>", "<cmd>TmuxNavigateRight<cr>", desc = "Navigate right" },
    },
  },
}
