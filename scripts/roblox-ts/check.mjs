import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const tools = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(tools, "../..");
const project = path.join(tools, "consumer");
const negativePath = path.join(project, "src/negative.ts");
const compiler = path.join(tools, "node_modules/roblox-ts/out/CLI/cli.js");
const projectCheck = path.join(tools, "project-check.mjs");
const compilerArgs = [compiler, "-p", tools, "--rojo", path.join(project, "default.project.json"),
	"--includePath", path.join(project, "include")];

function run(command, args, expectedSuccess = true) {
	const result = spawnSync(command, args, { cwd: root, encoding: "utf8" });
	if (result.error) throw result.error;
	assert.equal(result.status === 0, expectedSuccess, `${command} ${args.join(" ")}\n${result.stdout}\n${result.stderr}`);
	return result;
}

function projectCheckFixture(parent, name, { rojoAssets = true, extraTypeRoot = false, rojoLuaPath = false } = {}) {
	const fixture = path.join(parent, name);
	fs.mkdirSync(fixture, { recursive: true });
	fs.cpSync(path.join(project, "src"), path.join(fixture, "src"), { recursive: true });
	fs.cpSync(path.join(tools, "node_modules/@rbxts"), path.join(fixture, "node_modules/@rbxts"), { recursive: true });
	fs.writeFileSync(path.join(fixture, "package.json"), JSON.stringify({ name: "relay-project-check-fixture", version: "0.0.0" }));
	const config = JSON.parse(fs.readFileSync(path.join(tools, "tsconfig.json"), "utf8"));
	config.compilerOptions.rootDir = "src";
	config.compilerOptions.outDir = "out";
	config.compilerOptions.typeRoots = ["node_modules/@rbxts", ...(extraTypeRoot ? ["type-roots"] : [])];
	config.include = ["src"];
	fs.writeFileSync(path.join(fixture, "tsconfig.json"), JSON.stringify(config));
	const rojo = JSON.parse(fs.readFileSync(path.join(project, "default.project.json"), "utf8"));
	rojo.tree.ReplicatedStorage.rbxts_include.node_modules["@rbxts"].$path = "node_modules/@rbxts";
	if (rojoAssets) {
		rojo.tree.ReplicatedStorage.ProjectCheckAssets = { $path: "assets" };
		fs.mkdirSync(path.join(fixture, "assets"));
	}
	if (rojoLuaPath) {
		rojo.tree.ReplicatedStorage.ProjectCheckLua = { $path: "script.lua" };
		fs.writeFileSync(path.join(fixture, "script.lua"), "-- original path");
	}
	fs.writeFileSync(path.join(fixture, "default.project.json"), JSON.stringify(rojo));
	if (extraTypeRoot) fs.mkdirSync(path.join(fixture, "type-roots"));
	return fixture;
}

function runProjectCheck(fixture, resultPath, expectedSuccess) {
	const child = spawnSync(process.execPath, [projectCheck, "--project", fixture, "--result", resultPath], { cwd: root, encoding: "utf8" });
	if (child.error) throw child.error;
	const result = JSON.parse(fs.readFileSync(resultPath, "utf8"));
	assert.equal(child.status === 0, expectedSuccess, `${child.stdout}\n${child.stderr}\n${JSON.stringify(result)}`);
	return result;
}

function assertProjectCheckDidNotWrite(fixture) {
	for (const output of ["out", "include", "types", "build.tsbuildinfo"])
		assert(!fs.existsSync(path.join(fixture, output)), `${output} must stay untouched`);
	assert.deepEqual(fs.readdirSync(fixture).filter(name => name.startsWith(".relay-tools-")), [], "temporary compiler files must be removed");
}

function checkProjectCheckBoundaries() {
	const tempRoot = path.resolve(os.tmpdir());
	const parent = fs.mkdtempSync(path.join(tempRoot, "relay-project-check-"));
	try {
		const normal = projectCheckFixture(parent, "normal");
		const passed = runProjectCheck(normal, path.join(parent, "normal-result.json"), true);
		assert.equal(passed.status, "passed");
		assert(passed.sourceFiles.some(file => file.path === "src/server.server.ts"));
		assertProjectCheckDidNotWrite(normal);

		const linked = projectCheckFixture(parent, "linked");
		const outside = path.join(parent, "outside");
		fs.mkdirSync(outside);
		fs.writeFileSync(path.join(outside, "sentinel.txt"), "external");
		fs.symlinkSync(outside, path.join(linked, "assets/linked"), "junction");
		const rejectedLink = runProjectCheck(linked, path.join(parent, "linked-result.json"), false);
		assert.equal(rejectedLink.status, "unsupported");
		assert.equal(rejectedLink.diagnostics[0].code, "UnsupportedReparsePath");
		assert.equal(rejectedLink.sourceId, "");
		assertProjectCheckDidNotWrite(linked);

		const converted = projectCheckFixture(parent, "converted", { rojoAssets: false, rojoLuaPath: true });
		fs.symlinkSync(outside, path.join(converted, "script.luau"), "junction");
		const rejectedConverted = runProjectCheck(converted, path.join(parent, "converted-result.json"), false);
		assert.equal(rejectedConverted.status, "unsupported");
		assert.equal(rejectedConverted.diagnostics[0].code, "UnsupportedReparsePath");
		assert(rejectedConverted.diagnostics[0].message.includes("script.luau"));
		assert.equal(rejectedConverted.sourceId, "");
		assertProjectCheckDidNotWrite(converted);

		const nested = projectCheckFixture(parent, "nested");
		fs.mkdirSync(path.join(nested, "assets/nested"), { recursive: true });
		fs.writeFileSync(path.join(nested, "assets/nested/default.project.json"), "{");
		const rejectedConfig = runProjectCheck(nested, path.join(parent, "nested-result.json"), false);
		assert.equal(rejectedConfig.status, "unsupported");
		assert.equal(rejectedConfig.diagnostics[0].code, "NestedRojoConfigUnsupported");
		assert.equal(rejectedConfig.sourceId, "");
		assertProjectCheckDidNotWrite(nested);

		const typeRoot = projectCheckFixture(parent, "type-root", { rojoAssets: false, extraTypeRoot: true });
		fs.symlinkSync(outside, path.join(typeRoot, "type-roots/linked"), "junction");
		const rejectedTypeRoot = runProjectCheck(typeRoot, path.join(parent, "type-root-result.json"), false);
		assert.equal(rejectedTypeRoot.status, "unsupported");
		assert.equal(rejectedTypeRoot.diagnostics[0].code, "UnsupportedReparsePath");
		assert.equal(rejectedTypeRoot.sourceId, "");
		assertProjectCheckDidNotWrite(typeRoot);

		const typeRootConfig = projectCheckFixture(parent, "type-root-config", { rojoAssets: false, extraTypeRoot: true });
		fs.mkdirSync(path.join(typeRootConfig, "type-roots/nested"), { recursive: true });
		fs.writeFileSync(path.join(typeRootConfig, "type-roots/nested/default.project.json"), JSON.stringify({
			name: "External", tree: { External: { $path: outside } },
		}));
		const rejectedTypeRootConfig = runProjectCheck(typeRootConfig, path.join(parent, "type-root-config-result.json"), false);
		assert.equal(rejectedTypeRootConfig.status, "unsupported");
		assert.equal(rejectedTypeRootConfig.diagnostics[0].code, "NestedRojoConfigUnsupported");
		assert(rejectedTypeRootConfig.diagnostics[0].message.includes("type-roots/nested/default.project.json"));
		assert.equal(rejectedTypeRootConfig.sourceId, "");
		assertProjectCheckDidNotWrite(typeRootConfig);
		console.log("project-check: consumer compiled; Rojo and type-root junctions, converted Lua paths, and nested project configs rejected before compiler output");
	} finally {
		const cleanupTarget = path.resolve(parent);
		const relative = path.relative(tempRoot, cleanupTarget);
		if (!relative || path.isAbsolute(relative) || relative === ".." || relative.startsWith(`..${path.sep}`)
			|| relative.includes(path.sep) || !path.basename(cleanupTarget).startsWith("relay-project-check-"))
			throw new Error(`Refusing to remove an unexpected project-check fixture path: ${cleanupTarget}`);
		fs.rmSync(cleanupTarget, { recursive: true, force: true });
	}
}

// Copy source verbatim: the consumer executes the same Relay runtime as Luau users.
fs.cpSync(path.join(root, "src"), path.join(project, "src/Relay"), { recursive: true });
run("lune", ["run", "scripts/roblox-ts/generate.luau", "scripts/roblox-ts/consumer/src/Spec.luau",
	"scripts/roblox-ts/consumer/src/Network.d.ts"]);
if (process.argv.includes("--prepare")) process.exit(0);

assert(!fs.existsSync(negativePath), "remove a leftover generated consumer/src/negative.ts before running checks");
run(process.execPath, compilerArgs);
if (process.argv.includes("--build")) process.exit(0);

const client = fs.readFileSync(path.join(project, "out/client.client.luau"), "utf8");
const server = fs.readFileSync(path.join(project, "out/server.server.luau"), "utf8");
const contracts = fs.readFileSync(path.join(project, "out/contracts.luau"), "utf8");
for (const emitted of ["client:Start(", "client.events.Input:Send(", "client.events.Timed:Send(7)",
	"client.requests.Lookup:Request(", "pending:Await("]) assert(client.includes(emitted), emitted);
for (const emitted of ["server:Start(", "server.events.Input:Connect(", "server.events.Output:Send(",
	"server.requests.Lookup:ConnectWithContext(", "context:GetState("])
	assert(server.includes(emitted), emitted);
assert(!/\bNetwork:|\b_createClient:|\b_createServer:/.test(client + server), "module factories must use dot calls");
assert(client.includes("Active = true"), "set presence map must compile to member = true");
assert(contracts.includes("Enum.Material.Wood"), "native enum values must stay Roblox EnumItems");
for (const emitted of ["client:RefreshReadiness(true)", "client:RefreshReadiness()"])
	assert(contracts.includes(emitted), emitted);
assert(fs.existsSync(path.join(project, "out/Network.luau")), "Luau bridge must be copied by rbxtsc");
assert.equal(fs.readFileSync(path.join(project, "out/Relay/init.luau"), "utf8"),
	fs.readFileSync(path.join(root, "src/init.luau"), "utf8"));
checkProjectCheckBoundaries();

const negative = fs.readFileSync(path.join(root, "tests/roblox-ts/negative.ts"), "utf8")
	.replace("../../scripts/roblox-ts/consumer/src/Network", "./Network");
try {
	fs.writeFileSync(negativePath, negative);
	const configPath = path.join(tools, "tsconfig.json");
	const config = ts.readConfigFile(configPath, ts.sys.readFile);
	assert(!config.error);
	const parsed = ts.parseJsonConfigFileContent(config.config, ts.sys, tools);
	assert.equal(parsed.errors.length, 0);
	const program = ts.createProgram(parsed.fileNames, parsed.options);
	// Check consumer declarations too; rbxtsc does not type-check dependency internals.
	const diagnostics = [...program.getOptionsDiagnostics(), ...program.getGlobalDiagnostics()];
	for (const source of program.getSourceFiles()) {
		if (path.resolve(source.fileName).startsWith(path.join(project, "src") + path.sep))
			diagnostics.push(...program.getSyntacticDiagnostics(source), ...program.getSemanticDiagnostics(source));
	}
	const actual = new Set();
	for (const diagnostic of diagnostics) {
		assert.equal(path.resolve(diagnostic.file?.fileName ?? ""), negativePath,
			ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n"));
		actual.add(diagnostic.file.getLineAndCharacterOfPosition(diagnostic.start).line);
	}
	const expected = new Set(negative.split("\n").flatMap((line, i) => line.includes("// expect-error") ? [i] : []));
	assert(expected.size >= 25);
	assert.deepEqual(actual, expected, "every marked invalid consumer line must fail, with no unrelated diagnostics");
	run(process.execPath, compilerArgs, false);
	console.log(`roblox-ts: runnable consumer compiled; ${expected.size} invalid contract lines rejected; emitted call conventions checked`);
} finally {
	fs.unlinkSync(negativePath);
}
