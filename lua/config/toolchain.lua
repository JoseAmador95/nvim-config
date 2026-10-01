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
	difftastic = "0.71.0",
	gumtree = "4.0.0",
	plantuml = "1.2026.6",
	["markdown-preview"] = "0.0.10",
}

local function release(repository, tag, executable, assets)
	return {
		repository = repository,
		tag = tag,
		executable = executable,
		executables = { [executable] = executable },
		version_probe = executable,
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

M.managed_order = { "mmdflux", "plantuml", "markdown-preview", "difftastic", "gumtree" }
M.managed_tools = {
	-- Complete compile/runtime closure of core, client, and client.diff 4.0.0,
	-- resolved from their published Maven POMs and inherited dependencyManagement.
	-- Test/provided/optional dependencies and language generators are excluded.
	-- SLF4J 2.0.18 wins the Spark 1.7.25 conflict, matching upstream Gradle.
	gumtree = {
		backend = "maven-release",
		repository = "GumTreeDiff/gumtree",
		tag = "v4.0.0",
		executable = "gumtree",
		executables = { gumtree = "gumtree" },
		version_probe = "gumtree",
		main_class = "com.github.gumtreediff.client.Run",
		launcher_version = 1,
		jars = {
			{
				coordinate = "com.fifesoft:rsyntaxtextarea:4.0.1",
				file = "rsyntaxtextarea-4.0.1.jar",
				url = "https://repo.maven.apache.org/maven2/com/fifesoft/rsyntaxtextarea/4.0.1/rsyntaxtextarea-4.0.1.jar",
				sha256 = "fbe88919231bc468f9dddbd4450ef30634612a6e2ef3f84dff4f2789c8fc508e",
			},
			{
				coordinate = "com.github.gumtreediff:client.diff:4.0.0",
				file = "client.diff-4.0.0.jar",
				url = "https://repo.maven.apache.org/maven2/com/github/gumtreediff/client.diff/4.0.0/client.diff-4.0.0.jar",
				sha256 = "c45290fa282b9ca5648ad432afa38d453d51b73e80b274eb0eb61e92941a7b7d",
			},
			{
				coordinate = "com.github.gumtreediff:client:4.0.0",
				file = "client-4.0.0.jar",
				url = "https://repo.maven.apache.org/maven2/com/github/gumtreediff/client/4.0.0/client-4.0.0.jar",
				sha256 = "b321d5be56699860d9c25732a4c3bd850c6c0ddedac2c795342e6bc304a7f5c7",
			},
			{
				coordinate = "com.github.gumtreediff:core:4.0.0",
				file = "core-4.0.0.jar",
				url = "https://repo.maven.apache.org/maven2/com/github/gumtreediff/core/4.0.0/core-4.0.0.jar",
				sha256 = "6dc49e1b87e1b261f8edfd74e741120b6b6f6dd993d04ce6914e73081c92f174",
			},
			{
				coordinate = "com.github.mpkorstanje:simmetrics-core:4.1.1",
				file = "simmetrics-core-4.1.1.jar",
				url = "https://repo.maven.apache.org/maven2/com/github/mpkorstanje/simmetrics-core/4.1.1/simmetrics-core-4.1.1.jar",
				sha256 = "8c7ee773956ad0fab4369c99f575736d862bc295ae14fe3c90ffa5e257cca729",
			},
			{
				coordinate = "com.google.code.gson:gson:2.14.0",
				file = "gson-2.14.0.jar",
				url = "https://repo.maven.apache.org/maven2/com/google/code/gson/gson/2.14.0/gson-2.14.0.jar",
				sha256 = "2cbd119bf1961c28788310963dc80ba65f58cdeec1dd139c8bdb1240faa2c36f",
			},
			{
				coordinate = "com.google.errorprone:error_prone_annotations:2.48.0",
				file = "error_prone_annotations-2.48.0.jar",
				url = "https://repo.maven.apache.org/maven2/com/google/errorprone/error_prone_annotations/2.48.0/error_prone_annotations-2.48.0.jar",
				sha256 = "b49c5c958316ed67a09c699dda9aa749caf434d51d863dea599ef36a49b9c855",
			},
			{
				coordinate = "com.google.guava:guava:19.0",
				file = "guava-19.0.jar",
				url = "https://repo.maven.apache.org/maven2/com/google/guava/guava/19.0/guava-19.0.jar",
				sha256 = "58d4cc2e05ebb012bbac568b032f75623be1cb6fb096f3c60c72a86f7f057de4",
			},
			{
				coordinate = "com.j2html:j2html:1.6.0",
				file = "j2html-1.6.0.jar",
				url = "https://repo.maven.apache.org/maven2/com/j2html/j2html/1.6.0/j2html-1.6.0.jar",
				sha256 = "fa77bd6436340394ffd913d3528775522afd2dcd836eb7057f1f7605cc608bae",
			},
			{
				coordinate = "com.sparkjava:spark-core:2.9.4",
				file = "spark-core-2.9.4.jar",
				url = "https://repo.maven.apache.org/maven2/com/sparkjava/spark-core/2.9.4/spark-core-2.9.4.jar",
				sha256 = "99f4717695184e29ace24735bc539a7497775452b381b8080335adae3a985c3a",
			},
			{
				coordinate = "commons-codec:commons-codec:1.10",
				file = "commons-codec-1.10.jar",
				url = "https://repo.maven.apache.org/maven2/commons-codec/commons-codec/1.10/commons-codec-1.10.jar",
				sha256 = "4241dfa94e711d435f29a4604a3e2de5c4aa3c165e23bd066be6fc1fc4309569",
			},
			{
				coordinate = "it.unimi.dsi:fastutil:8.5.19",
				file = "fastutil-8.5.19.jar",
				url = "https://repo.maven.apache.org/maven2/it/unimi/dsi/fastutil/8.5.19/fastutil-8.5.19.jar",
				sha256 = "c767a6bdcb7cb52fe1315ca1f4891389a75e63b2a15a6629865d7740dd3a8cf2",
			},
			{
				coordinate = "javax.servlet:javax.servlet-api:3.1.0",
				file = "javax.servlet-api-3.1.0.jar",
				url = "https://repo.maven.apache.org/maven2/javax/servlet/javax.servlet-api/3.1.0/javax.servlet-api-3.1.0.jar",
				sha256 = "af456b2dd41c4e82cf54f3e743bc678973d9fe35bd4d3071fa05c7e5333b8482",
			},
			{
				coordinate = "org.apfloat:apfloat:1.14.0",
				file = "apfloat-1.14.0.jar",
				url = "https://repo.maven.apache.org/maven2/org/apfloat/apfloat/1.14.0/apfloat-1.14.0.jar",
				sha256 = "14fa3dee487b9d8de6d0ff7c39526159405c0879a65c817f959c9575e4b14820",
			},
			{
				coordinate = "org.atteo.classindex:classindex:3.13",
				file = "classindex-3.13.jar",
				url = "https://repo.maven.apache.org/maven2/org/atteo/classindex/classindex/3.13/classindex-3.13.jar",
				sha256 = "8e537601db7d761bd0010834fb364be2372c2a67c5c86f16ccc3ff47a08eeea4",
			},
			{
				coordinate = "org.eclipse.jetty.websocket:websocket-api:9.4.48.v20220622",
				file = "websocket-api-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/websocket/websocket-api/9.4.48.v20220622/websocket-api-9.4.48.v20220622.jar",
				sha256 = "87fb052324d6c5e22f58fb729169913bb318d97921115640c3dca453c7eb19e1",
			},
			{
				coordinate = "org.eclipse.jetty.websocket:websocket-client:9.4.48.v20220622",
				file = "websocket-client-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/websocket/websocket-client/9.4.48.v20220622/websocket-client-9.4.48.v20220622.jar",
				sha256 = "432d9d85734be8acbdbc3656200d2b1d540574c9bebe0b4f75a3f8bbe402a2f1",
			},
			{
				coordinate = "org.eclipse.jetty.websocket:websocket-common:9.4.48.v20220622",
				file = "websocket-common-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/websocket/websocket-common/9.4.48.v20220622/websocket-common-9.4.48.v20220622.jar",
				sha256 = "1f630339e7e7f6de5d7f47f9496495d7689ad41fc11565aaf11ce9e22ff6ccda",
			},
			{
				coordinate = "org.eclipse.jetty.websocket:websocket-server:9.4.48.v20220622",
				file = "websocket-server-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/websocket/websocket-server/9.4.48.v20220622/websocket-server-9.4.48.v20220622.jar",
				sha256 = "32ad18b3c610a5036c33d2e6bdf76eb46759fb8e067483d7a96f94e3909a4285",
			},
			{
				coordinate = "org.eclipse.jetty.websocket:websocket-servlet:9.4.48.v20220622",
				file = "websocket-servlet-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/websocket/websocket-servlet/9.4.48.v20220622/websocket-servlet-9.4.48.v20220622.jar",
				sha256 = "28aeea9ac33a3f6d22e31ed2a6079abc35ce3ec1d5c80e1cc13859f536680b25",
			},
			{
				coordinate = "org.eclipse.jetty:jetty-client:9.4.48.v20220622",
				file = "jetty-client-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-client/9.4.48.v20220622/jetty-client-9.4.48.v20220622.jar",
				sha256 = "7f89fe0900d36b296275999992a6ad76d523be35487d613d8fb56434c34d1d15",
			},
			{
				coordinate = "org.eclipse.jetty:jetty-http:9.4.48.v20220622",
				file = "jetty-http-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-http/9.4.48.v20220622/jetty-http-9.4.48.v20220622.jar",
				sha256 = "c99914804c25288fde0470530411258ee4bab83b69ad764149c816c984f8175e",
			},
			{
				coordinate = "org.eclipse.jetty:jetty-io:9.4.48.v20220622",
				file = "jetty-io-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-io/9.4.48.v20220622/jetty-io-9.4.48.v20220622.jar",
				sha256 = "4d2f60a0348905a0a70bb266d1eb23a29959281391aba54d17d4a3a0460b8b47",
			},
			{
				coordinate = "org.eclipse.jetty:jetty-security:9.4.48.v20220622",
				file = "jetty-security-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-security/9.4.48.v20220622/jetty-security-9.4.48.v20220622.jar",
				sha256 = "43039b0f58a156a7f1b9b7750ad82f7fcdd5dba81717b970c381cb1b8618ff73",
			},
			{
				coordinate = "org.eclipse.jetty:jetty-server:9.4.48.v20220622",
				file = "jetty-server-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-server/9.4.48.v20220622/jetty-server-9.4.48.v20220622.jar",
				sha256 = "dbb2b64216b0f10db591319c313979c1389249a196afb9690c022a923c0f0f77",
			},
			{
				coordinate = "org.eclipse.jetty:jetty-servlet:9.4.48.v20220622",
				file = "jetty-servlet-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-servlet/9.4.48.v20220622/jetty-servlet-9.4.48.v20220622.jar",
				sha256 = "eabc36f43fb4080b7d02e1fbcad0b437e035d3adc7bfd7a89b3cdeb22247e682",
			},
			{
				coordinate = "org.eclipse.jetty:jetty-util-ajax:9.4.48.v20220622",
				file = "jetty-util-ajax-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-util-ajax/9.4.48.v20220622/jetty-util-ajax-9.4.48.v20220622.jar",
				sha256 = "b5d4b40be3cf9f48b3d5f8e5918066724a620cb901684939c9f1dd7ec1b930cb",
			},
			{
				coordinate = "org.eclipse.jetty:jetty-util:9.4.48.v20220622",
				file = "jetty-util-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-util/9.4.48.v20220622/jetty-util-9.4.48.v20220622.jar",
				sha256 = "24cafd449ca4b4bea9c2792b28fc6fe1c43beb628c0c1a0a72ee33afeac82b87",
			},
			{
				coordinate = "org.eclipse.jetty:jetty-webapp:9.4.48.v20220622",
				file = "jetty-webapp-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-webapp/9.4.48.v20220622/jetty-webapp-9.4.48.v20220622.jar",
				sha256 = "bdb33dd7e9a30ea428f301010d08c7f69b37ec75dda340b79a86e95149fec0b2",
			},
			{
				coordinate = "org.eclipse.jetty:jetty-xml:9.4.48.v20220622",
				file = "jetty-xml-9.4.48.v20220622.jar",
				url = "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-xml/9.4.48.v20220622/jetty-xml-9.4.48.v20220622.jar",
				sha256 = "fe94705c7f49fe56194abfc16050fafc44be0faf691a2e6dca13c5d343a2bea5",
			},
			{
				coordinate = "org.jgrapht:jgrapht-core:1.5.3",
				file = "jgrapht-core-1.5.3.jar",
				url = "https://repo.maven.apache.org/maven2/org/jgrapht/jgrapht-core/1.5.3/jgrapht-core-1.5.3.jar",
				sha256 = "a026a34523286e1bf510e4bd4625935e3c97ce0fc40e1891f4262309f3b64c3e",
			},
			{
				coordinate = "org.jheaps:jheaps:0.14",
				file = "jheaps-0.14.jar",
				url = "https://repo.maven.apache.org/maven2/org/jheaps/jheaps/0.14/jheaps-0.14.jar",
				sha256 = "49a9898da3758659388f1333c53ccadb6fbd142a7d18aa7b1a33577090684279",
			},
			{
				coordinate = "org.slf4j:slf4j-api:2.0.18",
				file = "slf4j-api-2.0.18.jar",
				url = "https://repo.maven.apache.org/maven2/org/slf4j/slf4j-api/2.0.18/slf4j-api-2.0.18.jar",
				sha256 = "44508fd1576500688c790b190acdd16fec4f8c79a3e0b900afd70503cf055f55",
			},
			{
				coordinate = "org.slf4j:slf4j-nop:2.0.18",
				file = "slf4j-nop-2.0.18.jar",
				url = "https://repo.maven.apache.org/maven2/org/slf4j/slf4j-nop/2.0.18/slf4j-nop-2.0.18.jar",
				sha256 = "40e6be27d583d884183ca466cd20203112691f2a075a650e9e8d5c2e51aa5f49",
			},
		},
		jre = {
			version = "17.0.20.1+1",
			repository = "adoptium/temurin17-binaries",
			tag = "jdk-17.0.20.1%2B1",
			archive_root = "jdk-17.0.20.1+1-jre",
			assets = {
				["darwin-arm64"] = {
					archive = "OpenJDK17U-jre_aarch64_mac_hotspot_17.0.20.1_1.tar.gz",
					java = "Contents/Home/bin/java",
					sha256 = "190480874ccceb358cbc840393207f77ac3e63a4c5f8129d0e23e9518b96ad05",
				},
				["darwin-x86_64"] = {
					archive = "OpenJDK17U-jre_x64_mac_hotspot_17.0.20.1_1.tar.gz",
					java = "Contents/Home/bin/java",
					sha256 = "333cb81123c36568586646c73c8fa2326dab8badc43f5ea388a90fff59c9df27",
				},
				["linux-arm64"] = {
					archive = "OpenJDK17U-jre_aarch64_linux_hotspot_17.0.20.1_1.tar.gz",
					java = "bin/java",
					sha256 = "b8efcd5acc9109fe8d35bed132499643048a257b4f6042906ece37d03c839d77",
				},
				["linux-x86_64"] = {
					archive = "OpenJDK17U-jre_x64_linux_hotspot_17.0.20.1_1.tar.gz",
					java = "bin/java",
					sha256 = "0b2b640e3046b64c8ec504de0ab9d91bb5610182bda21fad454681ce54d45a62",
				},
			},
		},
	},
	difftastic = release("Wilfred/difftastic", "0.71.0", "difft", {
		["darwin-arm64"] = {
			archive = "difft-0.71.0-aarch64-apple-darwin.tar.gz",
			kind = "tar.gz",
			member = "difft",
			sha256 = "92acf8890543b6d6f436a87a7a5ec64f82a4b8dbe3a7e564c1e5cbfe60823bc7",
		},
		["darwin-x86_64"] = {
			archive = "difft-0.71.0-x86_64-apple-darwin.tar.gz",
			kind = "tar.gz",
			member = "difft",
			sha256 = "390b5299b0bc5059b5617f448eb1f3cb42c689933258fc57770c24d257a5d8a8",
		},
		["linux-arm64"] = {
			archive = "difft-0.71.0-aarch64-unknown-linux-gnu.tar.gz",
			kind = "tar.gz",
			member = "difft",
			sha256 = "5f046098b36ff985d0f99fec6f22cf74961db60386ff9d40df39fd99660aae2c",
		},
		["linux-x86_64"] = {
			archive = "difft-0.71.0-x86_64-unknown-linux-musl.tar.gz",
			kind = "tar.gz",
			member = "difft",
			sha256 = "0a65e6715df992b0adae012e606bd9cc74fa6cfe90eaf13bbae165a0a19b3086",
		},
	}),
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
	["markdown-preview"] = release("iamcco/markdown-preview.nvim", "v0.0.10", "markdown-preview", {
		["darwin-arm64"] = {
			archive = "markdown-preview-macos-arm64.tar.gz",
			kind = "tar.gz",
			member = "markdown-preview-macos-arm64",
			sha256 = "339f9a968fbbc4197259f811dd3f9780459f9d903532a29befcf16679b97babd",
		},
		["darwin-x86_64"] = {
			archive = "markdown-preview-macos.tar.gz",
			kind = "tar.gz",
			member = "markdown-preview-macos",
			sha256 = "580552e6506f858d9e7b2215888d62edbf5511e3201dd62c91afe502c3142204",
		},
		["linux-x86_64"] = {
			archive = "markdown-preview-linux.tar.gz",
			kind = "tar.gz",
			member = "markdown-preview-linux",
			sha256 = "95eb4d2774c62e93998c41361fe2276a5134ef173dddab29026d34ef80ad44ef",
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

M.dynamic_order = { "devcontainers-cli" }
M.dynamic_tools = {
	["devcontainers-cli"] = {
		name = "devcontainers-cli",
		backend = "npm-release",
		package = "@devcontainers/cli",
		command = "devcontainer",
		metadata_url = "https://registry.npmjs.org/%40devcontainers%2fcli/latest",
		dist_tag = "latest",
		node = {
			version = "24.20.0",
			assets = {
				["darwin-arm64"] = {
					archive = "node-v24.20.0-darwin-arm64.tar.gz",
					sha256 = "40e5607e5ecb3db9192723776da2d75d966260fc74a7a9e731c1bd67dda96bc8",
				},
				["darwin-x86_64"] = {
					archive = "node-v24.20.0-darwin-x64.tar.gz",
					sha256 = "9e5b2644cf107befb6aefca676b96d3296bc10138096f022ed378d6233ed81f4",
				},
				["linux-arm64"] = {
					archive = "node-v24.20.0-linux-arm64.tar.gz",
					sha256 = "3515603e2487879a39bc75716f1a2affd027500c64ba50e845cf72cb33219013",
				},
				["linux-x86_64"] = {
					archive = "node-v24.20.0-linux-x64.tar.gz",
					sha256 = "855d581f8a4eb1a8117e3426de25fe02770592febcfb31369aee1ffbfee9e8ec",
				},
			},
		},
	},
}

M.mason_order = {
	"clangd",
	"docker-language-server",
	"lemminx",
	"lua-language-server",
	"marksman",
	"ruff",
	"tombi",
	"codelldb",
	"hadolint",
	"jq",
	"shellcheck",
	"shfmt",
	"stylua",
	"tree-sitter-cli",
	"bash-language-server",
	"json-lsp",
	"vtsls",
	"yaml-language-server",
	"markdownlint-cli2",
	"prettierd",
	"ty",
	"cmake-language-server",
	"clang-format",
	"debugpy",
}

local function mason(version, executables, manager, requirements)
	local entry = {
		version = version,
		executables = executables,
		version_probe = executables[1],
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
	ruff = mason("0.16.6", { "ruff" }, "prebuilt"),
	tombi = mason("v1.2.7", { "tombi" }, "prebuilt"),
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
	vtsls = mason("0.3.0", { "vtsls" }, "npm", { requires_all = { "node", "npm" } }),
	["yaml-language-server"] = mason("1.24.0", { "yaml-language-server" }, "npm", {
		requires_all = { "node", "npm" },
	}),
	["markdownlint-cli2"] = mason("0.23.2", { "markdownlint-cli2" }, "npm", {
		requires_all = { "node", "npm" },
	}),
	prettierd = mason("0.29.0", { "prettierd" }, "npm", {
		requires_all = { "node", "npm" },
	}),
	ty = mason("0.0.77", { "ty" }, "pypi", {
		requires_any = { "python3", "python" },
		requires_python_venv = true,
	}),
	["cmake-language-server"] = mason("0.1.11", { "cmake-language-server" }, "pypi", {
		requires_any = { "python3", "python" },
		requires_python_venv = true,
	}),
	["clang-format"] = mason("22.1.8", { "clang-format", "clang-format-diff.py", "git-clang-format" }, "pypi", {
		requires_any = { "python3", "python" },
		requires_python_venv = true,
	}),
	debugpy = mason("1.8.21", { "debugpy-adapter", "debugpy" }, "pypi", {
		requires_any = { "python3", "python" },
		requires_python_venv = true,
		version_probe = "debugpy",
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

function M.dynamic_entry(name)
	return M.dynamic_tools[name]
end

function M.node_release_url(node, asset)
	assert(node and node.version and asset and asset.archive, "Node release entry is incomplete")
	return ("https://nodejs.org/dist/v%s/%s"):format(node.version, asset.archive)
end

function M.executable_map(entry)
	if not entry then
		return nil
	end
	local result = {}
	if entry.executable then
		result[entry.executable] = entry.executable
	else
		for _, command in ipairs(entry.executables or {}) do
			result[command] = command
		end
	end
	return result
end

function M.release_layout(entry, asset)
	assert(entry and entry.name and entry.version and entry.executable, "release entry is incomplete")
	assert(asset and asset.sha256, "release asset is incomplete")
	local commands = { [entry.executable] = "bin/" .. entry.executable }
	local artifacts = {}
	if asset.kind == "jar" then
		artifacts[1] = table.concat({
			"share",
			entry.name,
			entry.version,
			asset.sha256:lower(),
			"plantuml.jar",
		}, "/")
	end
	return { commands = commands, artifacts = artifacts }
end

function M.mason_integrity(name, entry)
	entry = entry or M.mason_tools[name]
	assert(entry and entry.version, "Mason entry is incomplete")
	local commands = {}
	for command in pairs(M.executable_map(entry)) do
		commands[command] = "bin/" .. command
	end
	return {
		kind = "mason-local-integrity",
		receipt_path = ".verified-tools/receipts/" .. name .. ".json",
		receipt = { package = name, version = entry.version, source_version = entry.version },
		commands = commands,
	}
end

function M.identity(name, entry)
	entry = entry or M.mason_tools[name] or M.managed_tools[name]
	return entry and (name .. "@" .. entry.version) or nil
end

return M
