local opt = vim.opt
local g = vim.g
vim.scriptencoding = 'utf-8'
opt.encoding = 'utf-8'
opt.fileencoding = 'utf-8'
opt.number = true
opt.relativenumber = true
opt.scrolloff = 2
opt.title = true
opt.wildmenu = true
opt.showmatch = true
opt.hlsearch = true
opt.backup = false
opt.swapfile = false
opt.showcmd = true
opt.autowriteall = true
opt.cmdheight = 1
opt.laststatus = 3
opt.showmode = false
opt.hidden = true
opt.ignorecase = true
opt.smartcase = true
opt.autoindent = true
opt.smartindent = true
opt.cindent = true
opt.expandtab = true
opt.shiftround = true
opt.tabstop = 4
opt.shiftwidth = 4
opt.softtabstop = 4
opt.mousehide = true
opt.mouse = ''
opt.signcolumn = 'yes'
opt.cursorline = true
opt.cursorlineopt="number"
opt.winborder = "rounded"
opt.linebreak = true
opt.splitright = true
opt.splitbelow = true
opt.smoothscroll = true
opt.shortmess:append('W')
opt.clipboard:append("unnamedplus")
opt.list = true
opt.listchars = {
  tab = "  \\u00B7",
  trail = "\\u00B7",
}
opt.shada = "'100,<50,s10,h,r/tmp,r/run,r/media"
opt.shell = "/bin/bash"
opt.guicursor = "n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20,t:ver25-blinkon0-TermCursor"

g.clipboard = {
  name = "xsel",
  copy = {
    ["+"] = "xsel --nodetach -ib",
    ["*"] = "xsel --nodetach -ip"
  },
  paste = {
    ["+"] = "xsel -ob",
    ["*"] = "xsel -op"
  },
  cache_enabled = true,
}
g.markdown_fenced_languages = {
  "ts=typescript"
}
g.java_ignore_markdown = 1
vim.filetype.add({
  extension = {
    ['log'] = 'log',
  },
})
