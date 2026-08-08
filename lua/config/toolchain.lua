-- Exact tool versions and release assets. Keep this module free of `vim` and
-- side effects: bootstrap scripts and isolated specs load it directly.

local M = {}

M.versions = {
	neovim = "0.12.4",
	stylua = "2.5.2",
	shellcheck = "0.11.0",
	actionlint = "1.7.12",
	tree_sitter = "0.26.11",
	mmdflux = "2.6.0",
	plantuml = "1.2026.6",
}

local function release(repository, tag, executable, assets)
	return {
		repository = repository,
		tag = tag,
		executable = executable,
		assets = assets,
	}
end

M.validation_order = { "stylua", "shellcheck", "actionlint", "tree_sitter" }
M.validation_tools = {
	stylua = release("JohnnyMorganz/StyLua", "v2.5.2", "stylua", {
		["darwin-arm64"] = {
			archive = "stylua-macos-aarch64.zip",
			kind = "zip",
			member = "stylua",
			sha256 = "92ff0889e16324801bc072692974bb67f8161e62010fc90f96c62a17f81f32c7",
		},
		["darwin-x86_64"] = {
			archive = "stylua-macos-x86_64.zip",
			kind = "zip",
			member = "stylua",
			sha256 = "53c50a1605d0a6345d160a1a5a21db40bcf2bf9cd23c17f7c277a63a1bff3a7f",
		},
		["linux-arm64"] = {
			archive = "stylua-linux-aarch64-musl.zip",
			kind = "zip",
			member = "stylua",
			sha256 = "b948df6b4bae41af9a70948174372f96a3c14d44e3e017288701539f3db8fb75",
		},
		["linux-x86_64"] = {
			archive = "stylua-linux-x86_64-musl.zip",
			kind = "zip",
			member = "stylua",
			sha256 = "ca6f1cf52eaf69e6632b81acef9c197aa24b85eb30d2455a35e7dbe28ae77c72",
		},
	}),
	shellcheck = release("koalaman/shellcheck", "v0.11.0", "shellcheck", {
		["darwin-arm64"] = {
			archive = "shellcheck-v0.11.0.darwin.aarch64.tar.gz",
			kind = "tar.gz",
			member = "shellcheck-v0.11.0/shellcheck",
			sha256 = "339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f",
		},
		["darwin-x86_64"] = {
			archive = "shellcheck-v0.11.0.darwin.x86_64.tar.gz",
			kind = "tar.gz",
			member = "shellcheck-v0.11.0/shellcheck",
			sha256 = "c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51",
		},
		["linux-arm64"] = {
			archive = "shellcheck-v0.11.0.linux.aarch64.tar.xz",
			kind = "tar.xz",
			member = "shellcheck-v0.11.0/shellcheck",
			sha256 = "12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588",
		},
		["linux-x86_64"] = {
			archive = "shellcheck-v0.11.0.linux.x86_64.tar.xz",
			kind = "tar.xz",
			member = "shellcheck-v0.11.0/shellcheck",
			sha256 = "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198",
		},
	}),
	actionlint = release("rhysd/actionlint", "v1.7.12", "actionlint", {
		["darwin-arm64"] = {
			archive = "actionlint_1.7.12_darwin_arm64.tar.gz",
			kind = "tar.gz",
			member = "actionlint",
			sha256 = "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
		},
		["darwin-x86_64"] = {
			archive = "actionlint_1.7.12_darwin_amd64.tar.gz",
			kind = "tar.gz",
			member = "actionlint",
			sha256 = "5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644",
		},
		["linux-arm64"] = {
			archive = "actionlint_1.7.12_linux_arm64.tar.gz",
			kind = "tar.gz",
			member = "actionlint",
			sha256 = "325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6",
		},
		["linux-x86_64"] = {
			archive = "actionlint_1.7.12_linux_amd64.tar.gz",
			kind = "tar.gz",
			member = "actionlint",
			sha256 = "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8",
		},
	}),
	tree_sitter = release("tree-sitter/tree-sitter", "v0.26.11", "tree-sitter", {
		["darwin-arm64"] = {
			archive = "tree-sitter-macos-arm64.gz",
			kind = "gzip",
			sha256 = "0bb646b2a29007233bd44855f00d0b8e238084d5b442f097d841b476318c2c90",
		},
		["darwin-x86_64"] = {
			archive = "tree-sitter-macos-x64.gz",
			kind = "gzip",
			sha256 = "0da547d2622ba1583e4c748bb44db5b79af56462da41acf377b9fdc2eb2cd49f",
		},
		["linux-arm64"] = {
			archive = "tree-sitter-linux-arm64.gz",
			kind = "gzip",
			sha256 = "e47dd59bf2f21ad7c15771546a724464ee3c008a60fbb61c6860bd19a44b3060",
		},
		["linux-x86_64"] = {
			archive = "tree-sitter-linux-x64.gz",
			kind = "gzip",
			sha256 = "8dac3c89bb632eece700ea7a261ad963b251f2228c4aef3b58458ebea8dbe4eb",
		},
	}),
}

M.managed_order = { "mmdflux", "plantuml" }
M.managed_tools = {
	mmdflux = release("kevinswiber/mmdflux", "mmdflux-v2.6.0", "mmdflux", {
		["darwin-arm64"] = {
			archive = "mmdflux-v2.6.0-darwin-arm64.tar.gz",
			kind = "tar.gz",
			member = "mmdflux",
			sha256 = "157d5dbd07ca1947a90387ed9d1b7768b569ea30053f010dc0e004d63f082320",
		},
		["darwin-x86_64"] = {
			archive = "mmdflux-v2.6.0-darwin-x86_64.tar.gz",
			kind = "tar.gz",
			member = "mmdflux",
			sha256 = "51215858128001a4fed3e0376ed546e6cd5a2a48fc8534df1e1a2c8f5168135b",
		},
		["linux-x86_64"] = {
			archive = "mmdflux-v2.6.0-linux-x86_64.tar.gz",
			kind = "tar.gz",
			member = "mmdflux",
			sha256 = "533267ed07d70160a0f1fcd1bfc816bf1c39503c05688272902396d81527205b",
		},
	}),
	plantuml = release("plantuml/plantuml", "v1.2026.6", "plantuml", {
		["darwin-arm64"] = {
			archive = "native-plantuml-macos-arm64-1.2026.6.zip",
			kind = "zip",
			member = "plantuml",
			sha256 = "12222c236aada460e379a694aa6329ea594c0e3eee11aa411665b43c8562bbf2",
		},
		["darwin-x86_64"] = {
			archive = "plantuml-1.2026.6.jar",
			kind = "jar",
			member = "plantuml-1.2026.6.jar",
			requires_all = { "java" },
			sha256 = "89948f14c93756c7a3fb7b69078ff37e8489fd79dd430c582b931e2f65358690",
			wrapper = { "java", "-jar", "{artifact}" },
		},
		["linux-arm64"] = {
			archive = "native-plantuml-linux-arm64-1.2026.6.zip",
			kind = "zip",
			member = "plantuml",
			sha256 = "bacbf79948b48e56397c43f4a5146951b780fadfe391ff46f9eeffff9f962359",
		},
		["linux-x86_64"] = {
			archive = "native-plantuml-linux-amd64-1.2026.6.zip",
			kind = "zip",
			member = "plantuml",
			sha256 = "835c238634ed1b8638c3fdcfe4f94d005fc9664df3da2c88f80d0aaf4471b04b",
		},
	}),
}

for name, entry in pairs(M.managed_tools) do
	entry.name = name
	entry.version = M.versions[name]
end
for name, entry in pairs(M.validation_tools) do
	entry.name = name
	entry.version = M.versions[name]
end

M.mason_order = {
	"clangd",
	"docker-language-server",
	"lemminx",
	"lua-language-server",
	"marksman",
	"ruff",
	"taplo",
	"codelldb",
	"hadolint",
	"jq",
	"shellcheck",
	"shfmt",
	"stylua",
	"tree-sitter-cli",
	"bash-language-server",
	"json-lsp",
	"pyright",
	"vtsls",
	"yaml-language-server",
	"markdownlint-cli2",
	"prettierd",
	"cmake-language-server",
	"clang-format",
	"debugpy",
}

local function mason(version, executables, manager, requirements)
	local entry = {
		version = version,
		executables = executables,
		manager = manager,
	}
	for key, value in pairs(requirements or {}) do
		entry[key] = value
	end
	return entry
end

M.mason_tools = {
	clangd = mason("22.1.6", { "clangd" }, "prebuilt"),
	["docker-language-server"] = mason("v0.20.1", { "docker-language-server" }, "prebuilt"),
	lemminx = mason("0.29.3", { "lemminx" }, "prebuilt"),
	["lua-language-server"] = mason("3.18.2", { "lua-language-server" }, "prebuilt"),
	marksman = mason("2026-02-08", { "marksman" }, "prebuilt"),
	ruff = mason("0.16.1", { "ruff" }, "prebuilt"),
	taplo = mason("0.10.0", { "taplo" }, "prebuilt"),
	codelldb = mason("v1.12.2", { "codelldb" }, "prebuilt"),
	hadolint = mason("v2.15.1", { "hadolint" }, "prebuilt"),
	jq = mason("jq-1.7", { "jq" }, "prebuilt"),
	shellcheck = mason("v0.11.0", { "shellcheck" }, "prebuilt"),
	shfmt = mason("v3.13.1", { "shfmt" }, "prebuilt"),
	stylua = mason("v2.5.2", { "stylua" }, "prebuilt"),
	["tree-sitter-cli"] = mason("v0.26.11", { "tree-sitter" }, "prebuilt"),
	["bash-language-server"] = mason("5.6.0", { "bash-language-server" }, "npm", {
		requires_all = { "node", "npm" },
	}),
	["json-lsp"] = mason("4.10.0", { "vscode-json-language-server" }, "npm", {
		requires_all = { "node", "npm" },
	}),
	pyright = mason("1.1.411", { "pyright-langserver", "pyright" }, "npm", {
		requires_all = { "node", "npm" },
	}),
	vtsls = mason("0.3.0", { "vtsls" }, "npm", { requires_all = { "node", "npm" } }),
	["yaml-language-server"] = mason("1.24.0", { "yaml-language-server" }, "npm", {
		requires_all = { "node", "npm" },
	}),
	["markdownlint-cli2"] = mason("0.23.2", { "markdownlint-cli2" }, "npm", {
		requires_all = { "node", "npm" },
	}),
	prettierd = mason("0.29.0", { "prettierd" }, "npm", {
		requires_all = { "node", "npm" },
		satisfies_any = { "prettierd", "prettier" },
	}),
	["cmake-language-server"] = mason("0.1.11", { "cmake-language-server" }, "pypi", {
		requires_any = { "python3", "python" },
		requires_python_venv = true,
	}),
	["clang-format"] = mason("22.1.8", { "clang-format" }, "pypi", {
		requires_any = { "python3", "python" },
		requires_python_venv = true,
	}),
	debugpy = mason("1.8.21", { "debugpy-adapter", "debugpy" }, "pypi", {
		requires_any = { "python3", "python" },
		requires_python_venv = true,
	}),
}

for name, entry in pairs(M.mason_tools) do
	entry.name = name
end

local os_aliases = {
	darwin = "darwin",
	mac = "darwin",
	macos = "darwin",
	linux = "linux",
}

local arch_aliases = {
	aarch64 = "arm64",
	arm64 = "arm64",
	amd64 = "x86_64",
	x64 = "x86_64",
	x86_64 = "x86_64",
}

function M.target_key(os_name, arch)
	local normalized_os = os_aliases[tostring(os_name):lower()]
	local normalized_arch = arch_aliases[tostring(arch):lower()]
	if not normalized_os or not normalized_arch then
		return nil
	end
	return normalized_os .. "-" .. normalized_arch
end

function M.asset_for(entry, os_name, arch)
	local key = M.target_key(os_name, arch)
	return key and entry and entry.assets and entry.assets[key] or nil, key
end

function M.release_url(entry, asset)
	assert(entry and entry.repository and entry.tag, "release entry is incomplete")
	assert(asset and asset.archive, "release asset is incomplete")
	return ("https://github.com/%s/releases/download/%s/%s"):format(entry.repository, entry.tag, asset.archive)
end

function M.mason_entry(name)
	return M.mason_tools[name]
end

function M.identity(name, entry)
	entry = entry or M.mason_tools[name] or M.managed_tools[name]
	return entry and (name .. "@" .. entry.version) or nil
end

return M
