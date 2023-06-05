return function()
  local wk = require('which-key')
  wk.setup {}
  wk.register({
    ["<space>"] = { 'hop' },
    [";"] = { 'command' },
    a = { 'code actions' },
    j = { 'move down' },
    k = { 'move up' },
    l = { 'copilot' },
    m = { 'duplicate line' },
    w = { 'close buffer' },
  }, {
    prefix = '<leader>',
  })
end

