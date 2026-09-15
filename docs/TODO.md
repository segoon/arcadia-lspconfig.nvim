- restructure :checkhealth output
- more user-friendly readme
- more user-friendly vimdoc
- ya.make support


# gopls


vim.lsp.config("gopls", {
	cmd = { "ya", "tool", "gopls", "serve" },
	before_init = function(_, config)
		local service_dir = vim.fs.root(0, "service.yaml")
		if not service_dir then
			return
		end
		-- config.settings.gopls.arcadiaIndexDirs = { service_dir }
		config.settings.gopls.arcadiaIndexDirs = { "taxi/backend-go/lavka/pim/services/pim-contracts" }

        -- critical
		config.settings.gopls["local"] = "a.yandex-team.ru"
		config.settings.gopls.expandWorkspaceToModule = false
	end,
})
