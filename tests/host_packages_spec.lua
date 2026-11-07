local T = MiniTest.new_set()

local host_packages = require("config.host_packages")

local function none()
	return ""
end

local function only(...)
	local present = {}
	for _, name in ipairs({ ... }) do
		present[name] = true
	end
	return function(name)
		return present[name] and ("/usr/bin/" .. name) or ""
	end
end

local function linux(os_release, exepath)
	return host_packages.detect({ sysname = "Linux", os_release = os_release, exepath = exepath or none })
end

local UBUNTU_2404 = 'PRETTY_NAME="Ubuntu 24.04.5 LTS"\nID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n'
local UBUNTU_2604 = 'PRETTY_NAME="Ubuntu 26.04 LTS"\nID=ubuntu\nID_LIKE=debian\nVERSION_ID="26.04"\n'
local FEDORA_43 = 'NAME="Fedora Linux"\nID=fedora\nVERSION_ID=43\nPRETTY_NAME="Fedora Linux 43 (Workstation Edition)"\n'
local MINT_22 = 'PRETTY_NAME="Linux Mint 22.1"\nID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID="22.1"\n'
local ARCH = 'PRETTY_NAME="Arch Linux"\nID=arch\n'

T["os-release detection selects the package manager and release"] = function()
	local ubuntu = linux(UBUNTU_2404)
	assert(ubuntu.os == "linux" and ubuntu.manager == "apt" and ubuntu.distro == "ubuntu" and ubuntu.version == "24.04")
	assert(ubuntu.name == "Ubuntu 24.04.5 LTS")
	assert(host_packages.describe(ubuntu) == "Ubuntu 24.04.5 LTS; fixes use apt")

	local fedora = linux(FEDORA_43)
	assert(fedora.manager == "dnf" and fedora.distro == "fedora" and fedora.version == "43")

	local mint = linux(MINT_22)
	assert(mint.manager == "apt" and mint.distro == nil, "derivatives use apt without Ubuntu release gates")

	local arch = linux(ARCH, only("brew"))
	assert(arch.manager == nil and arch.brew)
	assert(host_packages.describe(arch) == "Arch Linux; fixes use Homebrew")
	assert(host_packages.describe(linux(ARCH)):find("fixes name the packages", 1, true))

	local mac = host_packages.detect({ sysname = "Darwin", exepath = none })
	assert(mac.os == "macos" and not mac.brew)
	assert(host_packages.describe(mac):find("https://brew.sh", 1, true), "missing Homebrew was not pointed out")
end

T["Ubuntu and Fedora get their own package names"] = function()
	local ubuntu, fedora = linux(UBUNTU_2404), linux(FEDORA_43)
	local expected = {
		{ "git", "sudo apt install git", "sudo dnf install git" },
		{ "cc", "sudo apt install build-essential", "sudo dnf install gcc" },
		{ "sqlite3", "sudo apt install sqlite3", "sudo dnf install sqlite" },
		{ "rsvg-convert", "sudo apt install librsvg2-bin", "sudo dnf install librsvg2-tools" },
	}
	for _, case in ipairs(expected) do
		assert(vim.deep_equal(host_packages.advice(case[1], ubuntu), { case[2] }), case[1] .. " on Ubuntu")
		assert(vim.deep_equal(host_packages.advice(case[1], fedora), { case[3] }), case[1] .. " on Fedora")
	end
	assert(host_packages.advice("rust-analyzer", fedora)[1] == "sudo dnf install rust-analyzer")
end

T["releases without a package fall back to Homebrew or upstream"] = function()
	local noble = linux(UBUNTU_2404)
	assert(host_packages.advice("lazygit", noble)[1]:find("jesseduffield/lazygit/releases", 1, true))
	assert(host_packages.advice("nvimpager", noble)[1]:find("lucc/nvimpager", 1, true))
	assert(host_packages.advice("rust-analyzer", noble)[1]:find("rustup", 1, true))
	assert(host_packages.advice("lazygit", linux(FEDORA_43))[1]:find("releases", 1, true), "Fedora has no lazygit")
	assert(host_packages.advice("lazygit", linux(MINT_22))[1]:find("releases", 1, true), "gates need a known release")

	local resolute = linux(UBUNTU_2604, only("brew"))
	assert(vim.deep_equal(host_packages.advice("lazygit", resolute), {
		"sudo apt install lazygit",
		"Or: brew install lazygit",
	}))
	assert(vim.deep_equal(host_packages.advice("nvimpager", resolute), { "brew install nvimpager" }))
	assert(vim.deep_equal(host_packages.advice("cc", resolute), { "sudo apt install build-essential" }))

	local arch = linux(ARCH)
	assert(host_packages.advice("git", arch)[1] == "Install git with your package manager")
	assert(host_packages.advice("cc", arch)[1]:find("Debian/Ubuntu: build-essential; Fedora: gcc", 1, true))
end

T["macOS uses Homebrew and the system tools"] = function()
	local mac = host_packages.detect({ sysname = "Darwin", exepath = only("brew") })
	assert(vim.deep_equal(host_packages.advice("git", mac), { "xcode-select --install", "Or: brew install git" }))
	assert(vim.deep_equal(host_packages.advice("cc", mac), { "xcode-select --install" }))
	assert(vim.deep_equal(host_packages.advice("rsvg-convert", mac), { "brew install librsvg" }))
	assert(vim.deep_equal(host_packages.advice("lazygit", mac), { "brew install lazygit" }))
	local sqlite = host_packages.advice("sqlite3", mac)
	assert(#sqlite == 1 and sqlite[1]:find("/usr/bin/sqlite3", 1, true), "keg-only Homebrew sqlite was suggested")

	local rustup = host_packages.detect({ sysname = "Darwin", exepath = only("brew", "rustup") })
	assert(vim.deep_equal(host_packages.advice("rust-analyzer", rustup), {
		"rustup component add rust-analyzer",
		"Or: brew install rust-analyzer",
	}))
end

T["detection reads files only"] = function()
	local original_system = vim.system
	vim.system = function()
		error("host package detection started a process")
	end
	local ok, err = pcall(host_packages.detect)
	vim.system = original_system
	assert(ok, err)
	assert(host_packages.parse_os_release("ID='debian'\n# comment\nVERSION_ID=\"13\"").ID == "debian")
end

return T
