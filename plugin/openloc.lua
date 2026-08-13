-- Eager on purpose: a lazy-loaded plugin has not claimed its socket when the
-- first click arrives. Kept cheap; registry work waits for VimEnter.

if vim.g.loaded_openloc then
  return
end
vim.g.loaded_openloc = 1

local group = vim.api.nvim_create_augroup('openloc', { clear = true })

local function register()
  require('openloc').register()
end

if vim.v.vim_did_enter == 1 then
  register()
else
  vim.api.nvim_create_autocmd('VimEnter', { group = group, once = true, callback = register })
end

vim.api.nvim_create_autocmd('DirChanged', {
  group = group,
  callback = function()
    local openloc = package.loaded['openloc']
    if openloc then
      openloc.register()
    end
  end,
})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function()
    local openloc = package.loaded['openloc']
    if openloc then
      openloc.unregister()
    end
  end,
})
