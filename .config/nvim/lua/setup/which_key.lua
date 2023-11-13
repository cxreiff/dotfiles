return function()
  local wk = require('which-key')
  wk.setup {}
  wk.register({
    ["<space>"] = { 'hop' },
    [";"] = { 'command' },
    a = { 'code actions' },
    e = { 'split line' },
    j = { 'move line down' },
    k = { 'move line up' },
    l = { 'copilot' },
    m = { 'duplicate line' },
    w = { 'close buffer' },
  }, {
    prefix = '<leader>',
  })
end

