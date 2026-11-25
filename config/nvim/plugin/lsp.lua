vim.diagnostic.config({
  severity_sort = true,
  virtual_text = {
    severity = {
      min = vim.diagnostic.severity.ERROR,
    },
  },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = "",
      [vim.diagnostic.severity.WARN] = "",
      [vim.diagnostic.severity.INFO] = "",
      [vim.diagnostic.severity.HINT] = "󰌶",
    },
  },
})
-- Use an LspAttach event to only map the following keys
-- after the language server attaches to the current buffer
local setnmap = function (key, action, provide_opts) vim.keymap.set("n", key, action, provide_opts) end
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function (args)
    local bufnr = args.buf
    local bufopts = { noremap = true, silent = true, nowait = true, buffer = bufnr }
    vim.bo[bufnr].omnifunc = "v:lua.vim.lsp.omnifunc"
    setnmap("gD", vim.lsp.buf.declaration, bufopts)
    setnmap("gd", vim.lsp.buf.definition, bufopts)
    setnmap("gi", vim.lsp.buf.implementation, bufopts)
    setnmap("gr", vim.lsp.buf.references, bufopts)
    setnmap("K", vim.lsp.buf.hover, bufopts)
    setnmap("<leader>d", vim.lsp.buf.type_definition, bufopts)
    setnmap("<leader>r", vim.lsp.buf.rename, bufopts)
    setnmap("<leader>a", vim.lsp.buf.code_action, bufopts)
    setnmap("<leader>c", function () vim.lsp.codelens.run() end, bufopts)
    setnmap("<Space>d", vim.diagnostic.open_float, bufopts)
    setnmap("<Space>k", function () vim.diagnostic.jump({ count = -1, float = true }) end, bufopts)
    setnmap("<Space>j", function () vim.diagnostic.jump({ count = 1, float = true }) end, bufopts)
  end,
})

local capabilities = require("blink.cmp").get_lsp_capabilities()
local installed_servers = require("mason-lspconfig").get_installed_servers()
vim.lsp.config("*", {
  capabilities = capabilities,
})

local vue_lsp = vim.fn.stdpath("data")
  .. "/mason/packages/vue-language-server/node_modules/@vue/language-server"
local vue_plugin = {
  name = "@vue/typescript-plugin",
  location = vue_lsp,
  languages = { "vue" },
  configNamespace = "typescript",
}
vim.lsp.config("vtsls", {
  settings = {
    vtsls = {
      tsserver = {
        globalPlugins = {
          vue_plugin,
        },
      },
    },
  },
  filetypes = { "typescript", "javascript", "javascriptreact", "typescriptreact", "vue" },
})
vim.lsp.enable(installed_servers)
