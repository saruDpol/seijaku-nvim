local M = {}

local defaults = {
  vault_dir = "~/Notes/seijaku",

  sidebar = {
    width = 40,
    position = "right",
    default_mode = "all",
    all_mode_limit = 500,
    debounce_ms = 150,
  },

  editor = {
    open_cmd = "belowright split",
  },

  keymaps = {
    enable_default = true,
    toggle = "<A-o>",
  },

  index = {
    save_debounce_ms = 500,
  },

  integrations = {
    oil = true,
    netrw = true,
    telescope = true,
  },

  backup = {
    auto_on_exit = true,
    manual_snapshots = true,
    compress = true,
    canonical_name = "seijaku-latest.tar.gz",
  },
}

local options = vim.deepcopy(defaults)

local function normalize_vault_dir(path)
  path = vim.fn.expand(path)
  return vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
end

function M.setup(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  options.vault_dir = normalize_vault_dir(options.vault_dir)
end

function M.get()
  return options
end

return M
