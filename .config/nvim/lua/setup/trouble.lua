return function(use)
  use {
    'folke/trouble.nvim',
    config = function()
      require('trouble').setup {
        icons = false,
        fold_open = "v",
        fold_closed = ">",
        indent_lines = false,
        use_diagnostic_signs = true,
      }
    end
  }
end
