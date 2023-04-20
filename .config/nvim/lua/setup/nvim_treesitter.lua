return function()
  require('nvim-treesitter.configs').setup {
    auto_install = true,
    ensure_installed = { 'rust', 'toml' },
    highlight = {
      enable = true,
      additional_vim_regex_highlighting = false,
    },
    incremental_selection = { enable = true },
    -- indent = { enable = true },
    autotag = { enable = true },
    rainbow = {
      enable = true,
      extended_mode = true,
      max_file_lines = nil,
    },
    context_commentstring = {
      enable = true,
      enable_autocmd = false,
    },
  }
end
