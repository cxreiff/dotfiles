return function()
  local telescope = require('telescope')
  local actions = require('telescope.actions')
  telescope.setup {
    defaults = {
      file_ignore_patterns = {
        '.git',
        'node_modules',
        'build',
      },
      mappings = {
        i = {
          ['<C-n>'] = actions.cycle_history_next,
          ['<C-p>'] = actions.cycle_history_prev,
          ['<C-j>'] = actions.move_selection_next,
          ['<C-k>'] = actions.move_selection_previous,
          ['<ESC>'] = actions.close,
        },
      },
    },
    pickers = {
      buffers = {
        mappings = {
          i = {
            ['<C-d>'] = 'delete_buffer',
          },
        },
      },
    },
  }
  telescope.load_extension('fzf')
  telescope.load_extension('ui-select')
  telescope.load_extension('termfinder')
end

