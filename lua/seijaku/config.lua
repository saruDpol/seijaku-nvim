local M = {}

local defaults = {
  vault_dir = "~/Notes/seijaku",

  sidebar = {
    width = "auto",
    preview_width = "auto",
    position = "right",
    default_mode = "all",
    default_all_sort = "updated",
    all_mode_limit = 500,
    debounce_ms = 150,
  },

  editor = {
    open_cmd = "belowright split",
    wrap = true,
    linebreak = true,
    breakindent = true,
  },

  appearance = {
    palette = "auto",
    colors = {},
  },

  notes = {
    templates = {
      blank = {},
      journal = { "## {date}", "", "## Entry", "", "## Reflection", "" },
      meeting = {
        "## Attendees", "",
        "## Agenda", "",
        "## Notes", "",
        "## Decisions", "",
        "## Actions", "", "- [ ] ",
      },
      description = { "## Overview", "", "## Details", "", "## Context", "", "## References", "" },
      tasks = { "## Tasks", "", "- [ ] ", "" },
      idea = { "## Idea", "", "## Why now", "", "## Next step", "" },
      research = { "## Question", "", "## Notes", "", "## Sources", "", "## Conclusion", "" },
      project = { "## Goal", "", "## Scope", "", "## Plan", "", "## Open questions", "" },
    },
  },

  keymaps = {
    enable_default = true,
    toggle = "<A-o>",
    new_for_current = "<leader>a",
  },

  index = {
    save_debounce_ms = 500,
    reload_debounce_ms = 120,
    lock_timeout_ms = 2000,
    stale_lock_ms = 10000,
    watch_external_changes = true,
  },

  integrations = {
    oil = true,
    netrw = true,
    telescope = true,
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

  -- Lua configs sometimes quote numeric values while editing. Accept those
  -- values for preview_width so "0.2" behaves exactly like 0.2 (20%).
  local preview_width = options.sidebar.preview_width
  if type(preview_width) == "string" then
    local numeric_preview_width = tonumber(preview_width)
    if numeric_preview_width then
      options.sidebar.preview_width = numeric_preview_width
    end
  end
end

function M.get()
  return options
end

return M
