-- Canonical tool catalog. scripts/update-tool-lock renders mise.toml from this
-- data; Mise owns downloads, dependency locks, installations and execution.
-- Keep this module free of Neovim APIs and side effects.
local M = {}

M.tools = {
	["actionlint"] = {
		["backend"] = "http:actionlint",
		["commands"] = { "actionlint" },
		["options"] = {
			["os"] = { "linux/arm64", "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-arm64"] = {
					["checksum"] = "sha256:325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6",
					["url"] = "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_arm64.tar.gz",
				},
				["linux-x64"] = {
					["checksum"] = "sha256:8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8",
					["url"] = "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
					["url"] = "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz",
				},
				["macos-x64"] = {
					["checksum"] = "sha256:5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644",
					["url"] = "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_amd64.tar.gz",
				},
			},
		},
		["version"] = "1.7.12",
	},
	["bash-language-server"] = {
		["backend"] = "npm:bash-language-server",
		["commands"] = { "bash-language-server" },
		["version"] = "5.6.0",
	},
	["clang-format"] = {
		["backend"] = "pypi:clang-format",
		["commands"] = { "clang-format", "clang-format-diff.py", "git-clang-format" },
		["version"] = "22.1.8",
	},
	["clangd"] = {
		["backend"] = "http:clangd",
		["commands"] = { "clangd" },
		["options"] = {
			["bin_path"] = "bin",
			["os"] = { "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-x64"] = {
					["checksum"] = "sha256:a9c77443af2e447ed467e84771848d3a6ac1c56f84bcfcde717e66318de77cfa",
					["url"] = "https://github.com/clangd/clangd/releases/download/22.1.6/clangd-linux-22.1.6.zip",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:631aef462556cbd74e0ebaae1778a38d1997d0ba3371652ca54f82652a179e7d",
					["url"] = "https://github.com/clangd/clangd/releases/download/22.1.6/clangd-mac-22.1.6.zip",
				},
				["macos-x64"] = {
					["checksum"] = "sha256:631aef462556cbd74e0ebaae1778a38d1997d0ba3371652ca54f82652a179e7d",
					["url"] = "https://github.com/clangd/clangd/releases/download/22.1.6/clangd-mac-22.1.6.zip",
				},
			},
			["strip_components"] = 1,
		},
		["version"] = "22.1.6",
	},
	["cmake-language-server"] = {
		["backend"] = "pypi:cmake-language-server",
		["commands"] = { "cmake-language-server" },
		["options"] = { ["with"] = { "pygls==1.3.1" } }, -- 0.1.11 uses the pre-2.0 server API.
		["version"] = "0.1.11",
	},
	["codelldb"] = {
		["backend"] = "http:codelldb",
		["commands"] = { "codelldb" },
		["options"] = {
			["bin_path"] = "extension/adapter",
			["format"] = "zip",
			["os"] = { "linux/arm64", "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-arm64"] = {
					["checksum"] = "sha256:f7c83ad67cc860fe6d753e8123b57a4db89c1fb00aef4b85a2f858334cdbaeb0",
					["url"] = "https://github.com/vadimcn/codelldb/releases/download/v1.12.2/codelldb-linux-arm64.vsix",
				},
				["linux-x64"] = {
					["checksum"] = "sha256:b85b45a8570051d535b0927c6c9da11c39f3a056c73559064647faf7f37f637d",
					["url"] = "https://github.com/vadimcn/codelldb/releases/download/v1.12.2/codelldb-linux-x64.vsix",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:c836b81c6f2da467b5920a376a7bfc849dc4b4d81b19779dedf1c685cb4aa1a0",
					["url"] = "https://github.com/vadimcn/codelldb/releases/download/v1.12.2/codelldb-darwin-arm64.vsix",
				},
				["macos-x64"] = {
					["checksum"] = "sha256:8270a342929bdc0deb6d7d3931c08d5ba6018265f840dd0508c4247fb8d32e8d",
					["url"] = "https://github.com/vadimcn/codelldb/releases/download/v1.12.2/codelldb-darwin-x64.vsix",
				},
			},
			["strip_components"] = 0,
		},
		["version"] = "1.12.2",
	},
	["debugpy"] = {
		["backend"] = "pypi:debugpy",
		["commands"] = { "debugpy-adapter", "debugpy" },
		["version"] = "1.8.21",
	},
	["devcontainers-cli"] = {
		["backend"] = "npm:@devcontainers/cli",
		["commands"] = { "devcontainer" },
		["version"] = "0.89.0",
	},
	["difftastic"] = {
		["backend"] = "http:difftastic",
		["commands"] = { "difft" },
		["options"] = {
			["os"] = { "linux/arm64", "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-arm64"] = {
					["checksum"] = "sha256:5f046098b36ff985d0f99fec6f22cf74961db60386ff9d40df39fd99660aae2c",
					["url"] = "https://github.com/Wilfred/difftastic/releases/download/0.71.0/difft-0.71.0-aarch64-unknown-linux-gnu.tar.gz",
				},
				["linux-x64"] = {
					["checksum"] = "sha256:0a65e6715df992b0adae012e606bd9cc74fa6cfe90eaf13bbae165a0a19b3086",
					["url"] = "https://github.com/Wilfred/difftastic/releases/download/0.71.0/difft-0.71.0-x86_64-unknown-linux-musl.tar.gz",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:92acf8890543b6d6f436a87a7a5ec64f82a4b8dbe3a7e564c1e5cbfe60823bc7",
					["url"] = "https://github.com/Wilfred/difftastic/releases/download/0.71.0/difft-0.71.0-aarch64-apple-darwin.tar.gz",
				},
				["macos-x64"] = {
					["checksum"] = "sha256:390b5299b0bc5059b5617f448eb1f3cb42c689933258fc57770c24d257a5d8a8",
					["url"] = "https://github.com/Wilfred/difftastic/releases/download/0.71.0/difft-0.71.0-x86_64-apple-darwin.tar.gz",
				},
			},
		},
		["version"] = "0.71.0",
	},
	["docker-language-server"] = {
		["backend"] = "http:docker-language-server",
		["commands"] = { "docker-language-server" },
		["options"] = {
			["bin"] = "docker-language-server",
			["format"] = "raw",
			["os"] = { "linux/arm64", "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-arm64"] = {
					["checksum"] = "sha256:bd56c7815e0a22cfb708669f3d5e817de91d9b54039ff7e52867142a132ad8d7",
					["url"] = "https://github.com/docker/docker-language-server/releases/download/v0.20.1/docker-language-server-linux-arm64-v0.20.1",
				},
				["linux-x64"] = {
					["checksum"] = "sha256:01907aa5b0eae11e44cffea0a993d08aa155542a9af570295dd1dff39e67692a",
					["url"] = "https://github.com/docker/docker-language-server/releases/download/v0.20.1/docker-language-server-linux-amd64-v0.20.1",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:5a9d48fd2b1334d7d20a62faf542e611cca32dc79a478553ad65c27437467fac",
					["url"] = "https://github.com/docker/docker-language-server/releases/download/v0.20.1/docker-language-server-darwin-arm64-v0.20.1",
				},
				["macos-x64"] = {
					["checksum"] = "sha256:2dbaec15645e940d1e02092f5b5e10148531a6206225e71faab7bfe71130b457",
					["url"] = "https://github.com/docker/docker-language-server/releases/download/v0.20.1/docker-language-server-darwin-amd64-v0.20.1",
				},
			},
		},
		["version"] = "0.20.1",
	},
	["hadolint"] = {
		["backend"] = "aqua:hadolint/hadolint",
		["commands"] = { "hadolint" },
		["version"] = "2.15.1",
	},
	["jq"] = {
		["backend"] = "aqua:jqlang/jq",
		["commands"] = { "jq" },
		["version"] = "1.7",
	},
	["json-lsp"] = {
		["backend"] = "npm:vscode-langservers-extracted",
		["commands"] = { "vscode-json-language-server" },
		["version"] = "4.10.0",
	},
	["lemminx"] = {
		["backend"] = "http:lemminx",
		["commands"] = { "lemminx" },
		["options"] = {
			["os"] = { "linux/arm64", "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-arm64"] = {
					["checksum"] = "sha256:0b88a49e83c2611282672f5123ce33abf1371c8e3c55cad6ee45ea00626ffa1b",
					["url"] = "https://github.com/redhat-developer/vscode-xml/releases/download/0.29.3/lemminx-linux-aarch_64.zip",
				},
				["linux-x64"] = {
					["checksum"] = "sha256:1acc44e24201c1d2f5ccb4e43e7426ed0df6909207a81ff199810e2808104d89",
					["url"] = "https://github.com/redhat-developer/vscode-xml/releases/download/0.29.3/lemminx-linux-x86_64.zip",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:185db5630ce85be43ea0fab034e7841b1327c2793db05ab481e029cf493d86ce",
					["url"] = "https://github.com/redhat-developer/vscode-xml/releases/download/0.29.3/lemminx-osx-aarch_64.zip",
				},
				["macos-x64"] = {
					["checksum"] = "sha256:9e56123194b5c1fdc7d87f1bd21c83cc996ba7be913def3a2836a13305bcd273",
					["url"] = "https://github.com/redhat-developer/vscode-xml/releases/download/0.29.3/lemminx-osx-x86_64.zip",
				},
			},
			["rename_exe"] = { ["lemminx-*"] = "lemminx" },
		},
		["version"] = "0.29.3",
	},
	["lua-language-server"] = {
		["backend"] = "aqua:LuaLS/lua-language-server",
		["commands"] = { "lua-language-server" },
		["version"] = "3.18.2",
	},
	["markdown-preview"] = {
		["backend"] = "http:markdown-preview",
		["commands"] = { "markdown-preview" },
		["options"] = {
			["os"] = { "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-x64"] = {
					["checksum"] = "sha256:95eb4d2774c62e93998c41361fe2276a5134ef173dddab29026d34ef80ad44ef",
					["rename_exe"] = {
						["markdown-preview-linux"] = "markdown-preview",
					},
					["url"] = "https://github.com/iamcco/markdown-preview.nvim/releases/download/v0.0.10/markdown-preview-linux.tar.gz",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:339f9a968fbbc4197259f811dd3f9780459f9d903532a29befcf16679b97babd",
					["rename_exe"] = {
						["markdown-preview-macos-arm64"] = "markdown-preview",
					},
					["url"] = "https://github.com/iamcco/markdown-preview.nvim/releases/download/v0.0.10/markdown-preview-macos-arm64.tar.gz",
				},
				["macos-x64"] = {
					["checksum"] = "sha256:580552e6506f858d9e7b2215888d62edbf5511e3201dd62c91afe502c3142204",
					["rename_exe"] = {
						["markdown-preview-macos"] = "markdown-preview",
					},
					["url"] = "https://github.com/iamcco/markdown-preview.nvim/releases/download/v0.0.10/markdown-preview-macos.tar.gz",
				},
			},
		},
		["version"] = "0.0.10",
	},
	["markdownlint-cli2"] = {
		["backend"] = "npm:markdownlint-cli2",
		["commands"] = { "markdownlint-cli2" },
		["version"] = "0.23.2",
	},
	["marksman"] = {
		["backend"] = "aqua:artempyanykh/marksman",
		["commands"] = { "marksman" },
		["version"] = "2026-02-08",
	},
	["mmdflux"] = {
		["backend"] = "http:mmdflux",
		["commands"] = { "mmdflux" },
		["options"] = {
			["os"] = { "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-x64"] = {
					["checksum"] = "sha256:533267ed07d70160a0f1fcd1bfc816bf1c39503c05688272902396d81527205b",
					["url"] = "https://github.com/kevinswiber/mmdflux/releases/download/mmdflux-v2.6.0/mmdflux-v2.6.0-linux-x86_64.tar.gz",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:157d5dbd07ca1947a90387ed9d1b7768b569ea30053f010dc0e004d63f082320",
					["url"] = "https://github.com/kevinswiber/mmdflux/releases/download/mmdflux-v2.6.0/mmdflux-v2.6.0-darwin-arm64.tar.gz",
				},
				["macos-x64"] = {
					["checksum"] = "sha256:51215858128001a4fed3e0376ed546e6cd5a2a48fc8534df1e1a2c8f5168135b",
					["url"] = "https://github.com/kevinswiber/mmdflux/releases/download/mmdflux-v2.6.0/mmdflux-v2.6.0-darwin-x86_64.tar.gz",
				},
			},
		},
		["version"] = "2.6.0",
	},
	["node"] = {
		["backend"] = "core:node",
		["commands"] = {}, -- Runtime dependencies stay inside mise exec's PATH.
		["version"] = "24.20.0",
	},
	["plantuml"] = {
		["backend"] = "http:plantuml",
		["commands"] = { "plantuml" },
		["options"] = {
			["os"] = { "linux/arm64", "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-arm64"] = {
					["checksum"] = "sha256:bacbf79948b48e56397c43f4a5146951b780fadfe391ff46f9eeffff9f962359",
					["url"] = "https://github.com/plantuml/plantuml/releases/download/v1.2026.6/native-plantuml-linux-arm64-1.2026.6.zip",
				},
				["linux-x64"] = {
					["checksum"] = "sha256:835c238634ed1b8638c3fdcfe4f94d005fc9664df3da2c88f80d0aaf4471b04b",
					["url"] = "https://github.com/plantuml/plantuml/releases/download/v1.2026.6/native-plantuml-linux-amd64-1.2026.6.zip",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:12222c236aada460e379a694aa6329ea594c0e3eee11aa411665b43c8562bbf2",
					["url"] = "https://github.com/plantuml/plantuml/releases/download/v1.2026.6/native-plantuml-macos-arm64-1.2026.6.zip",
				},
				["macos-x64"] = {
					["bin"] = "plantuml.jar",
					["checksum"] = "sha256:89948f14c93756c7a3fb7b69078ff37e8489fd79dd430c582b931e2f65358690",
					["format"] = "raw",
					["url"] = "https://github.com/plantuml/plantuml/releases/download/v1.2026.6/plantuml-1.2026.6.jar",
				},
			},
		},
		["version"] = "1.2026.6",
	},
	["prettierd"] = {
		["backend"] = "npm:@fsouza/prettierd",
		["commands"] = { "prettierd" },
		["version"] = "0.29.0",
	},
	["python"] = {
		["backend"] = "core:python",
		["commands"] = {},
		["version"] = "3.13.16",
	},
	["ruff"] = {
		["backend"] = "aqua:astral-sh/ruff",
		["commands"] = { "ruff" },
		["version"] = "0.16.6",
	},
	["shellcheck"] = {
		["backend"] = "http:shellcheck",
		["commands"] = { "shellcheck" },
		["options"] = {
			["os"] = { "linux/arm64", "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-arm64"] = {
					["checksum"] = "sha256:12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588",
					["url"] = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.aarch64.tar.xz",
				},
				["linux-x64"] = {
					["checksum"] = "sha256:8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198",
					["url"] = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f",
					["url"] = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.gz",
				},
				["macos-x64"] = {
					["checksum"] = "sha256:c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51",
					["url"] = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.x86_64.tar.gz",
				},
			},
		},
		["version"] = "0.11.0",
	},
	["shfmt"] = {
		["backend"] = "aqua:mvdan/sh",
		["commands"] = { "shfmt" },
		["version"] = "3.13.1",
	},
	["stylua"] = {
		["backend"] = "http:stylua",
		["commands"] = { "stylua" },
		["options"] = {
			["os"] = { "linux/arm64", "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-arm64"] = {
					["checksum"] = "sha256:b948df6b4bae41af9a70948174372f96a3c14d44e3e017288701539f3db8fb75",
					["url"] = "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.5.2/stylua-linux-aarch64-musl.zip",
				},
				["linux-x64"] = {
					["checksum"] = "sha256:ca6f1cf52eaf69e6632b81acef9c197aa24b85eb30d2455a35e7dbe28ae77c72",
					["url"] = "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.5.2/stylua-linux-x86_64-musl.zip",
				},
				["macos-arm64"] = {
					["checksum"] = "sha256:92ff0889e16324801bc072692974bb67f8161e62010fc90f96c62a17f81f32c7",
					["url"] = "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.5.2/stylua-macos-aarch64.zip",
				},
				["macos-x64"] = {
					["checksum"] = "sha256:53c50a1605d0a6345d160a1a5a21db40bcf2bf9cd23c17f7c277a63a1bff3a7f",
					["url"] = "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.5.2/stylua-macos-x86_64.zip",
				},
			},
		},
		["version"] = "2.5.2",
	},
	["tombi"] = {
		["backend"] = "aqua:tombi-toml/tombi",
		["commands"] = { "tombi" },
		["version"] = "1.2.7",
	},
	["tree-sitter-cli"] = {
		["backend"] = "http:tree-sitter-cli",
		["commands"] = { "tree-sitter" },
		["options"] = {
			["os"] = { "linux/arm64", "linux/x64", "macos/arm64", "macos/x64" },
			["platforms"] = {
				["linux-arm64"] = {
					["bin"] = "tree-sitter",
					["checksum"] = "sha256:e47dd59bf2f21ad7c15771546a724464ee3c008a60fbb61c6860bd19a44b3060",
					["url"] = "https://github.com/tree-sitter/tree-sitter/releases/download/v0.26.11/tree-sitter-linux-arm64.gz",
				},
				["linux-x64"] = {
					["bin"] = "tree-sitter",
					["checksum"] = "sha256:8dac3c89bb632eece700ea7a261ad963b251f2228c4aef3b58458ebea8dbe4eb",
					["url"] = "https://github.com/tree-sitter/tree-sitter/releases/download/v0.26.11/tree-sitter-linux-x64.gz",
				},
				["macos-arm64"] = {
					["bin"] = "tree-sitter",
					["checksum"] = "sha256:0bb646b2a29007233bd44855f00d0b8e238084d5b442f097d841b476318c2c90",
					["url"] = "https://github.com/tree-sitter/tree-sitter/releases/download/v0.26.11/tree-sitter-macos-arm64.gz",
				},
				["macos-x64"] = {
					["bin"] = "tree-sitter",
					["checksum"] = "sha256:0da547d2622ba1583e4c748bb44db5b79af56462da41acf377b9fdc2eb2cd49f",
					["url"] = "https://github.com/tree-sitter/tree-sitter/releases/download/v0.26.11/tree-sitter-macos-x64.gz",
				},
			},
		},
		["version"] = "0.26.11",
	},
	["ty"] = {
		["backend"] = "aqua:astral-sh/ty",
		["commands"] = { "ty" },
		["version"] = "0.0.77",
	},
	["uv"] = {
		["backend"] = "aqua:astral-sh/uv",
		["commands"] = {},
		["version"] = "0.12.23",
	},
	["vtsls"] = {
		["backend"] = "npm:@vtsls/language-server",
		["commands"] = { "vtsls" },
		["version"] = "0.3.0",
	},
	["yaml-language-server"] = {
		["backend"] = "npm:yaml-language-server",
		["commands"] = { "yaml-language-server" },
		["version"] = "1.24.0",
	},
}

M.versions = { neovim = "0.12.4", mise = "2026.10.4" }
M.tool_order = {}
for name, entry in pairs(M.tools) do
	M.tool_order[#M.tool_order + 1] = name
	M.versions[name] = entry.version
end
table.sort(M.tool_order)
M.versions.tree_sitter = M.versions["tree-sitter-cli"]
M.validation_order = { "stylua", "shellcheck", "actionlint", "tree-sitter-cli" }

-- Test-only dependencies are installed explicitly, outside the editor runtime.
M.test_dependencies = {
	mini_test = {
		url = "https://github.com/echasnovski/mini.test.git",
		version = "0.18.0",
		commit = "35c67cb7f2dc697ed0c7c06400fcf29a8a521d7d",
	},
}

-- Mise requires configured install dependencies to be included in named requests.
function M.request_tools(name)
	local backend = assert(M.tools[name], "unknown tool: " .. name).backend
	if backend:match("^npm:") then
		return { "node", name }
	elseif backend:match("^pypi:") then
		return { "python", "uv", name }
	end
	return { name }
end

M.mise_checksums = {
	["linux-arm64"] = "8760841cdbf964ecf9902a50c94716c77185a99af7f8eb55c9c51ec73ecd8880",
	["linux-x64"] = "2fc793020b442d08163603400236b2c693f8cede810c7e432fc77220e6c9e8a1",
	["macos-arm64"] = "744ae45f9b7c2a443adfa61df48397930e88b13c541834b7bd22ca31d4dfcfcd",
	["macos-x64"] = "3bf65cfdb543f69685afde3ae9ccd0b819b8f5ea5d12c67c73487bf2a1b16bf4",
}

function M.target_key(os_name, arch)
	local os = ({
		Darwin = "macos",
		macOS = "macos",
		darwin = "macos",
		macos = "macos",
		Linux = "linux",
		linux = "linux",
	})[os_name]
	local cpu = ({ arm64 = "arm64", aarch64 = "arm64", x86_64 = "x64", amd64 = "x64", x64 = "x64" })[arch]
	return os and cpu and (os .. "-" .. cpu) or nil
end

function M.supported(name, target)
	local entry = M.tools[name]
	if not entry or not target then
		return false
	end
	local platforms = entry.options and entry.options.os
	if not platforms then
		return true
	end
	for _, platform in ipairs(platforms) do
		if platform:gsub("/", "-") == target then
			return true
		end
	end
	return false
end

local function sorted_keys(value)
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

local function toml(value)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	local result = {}
	if #value > 0 then
		for _, item in ipairs(value) do
			result[#result + 1] = toml(item)
		end
		return "[" .. table.concat(result, ", ") .. "]"
	end
	for _, key in ipairs(sorted_keys(value)) do
		result[#result + 1] = toml(key) .. " = " .. toml(value[key])
	end
	return "{ " .. table.concat(result, ", ") .. " }"
end

function M.mise_config()
	local lines = {
		"# Generated by scripts/update-tool-lock from lua/config/toolchain.lua.",
		"# Commit this file, mise.lock and .mise/locks together.",
		"min_version = " .. toml(M.versions.mise),
		"[settings]",
		"lockfile = true",
		"[tool_alias]",
	}
	for _, name in ipairs(M.tool_order) do
		lines[#lines + 1] = toml(name) .. " = " .. toml(M.tools[name].backend)
	end
	lines[#lines + 1] = "[tools]"
	for _, name in ipairs(M.tool_order) do
		local entry = M.tools[name]
		local options = { version = entry.version }
		for key, value in pairs(entry.options or {}) do
			options[key] = value
		end
		lines[#lines + 1] = toml(name) .. " = " .. toml(options)
	end
	return table.concat(lines, "\n") .. "\n"
end

return M
