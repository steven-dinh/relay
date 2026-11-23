import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
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

function runProjectCheck(fixture, resultPath, expectedSuccess, hook) {
	const args = [...(hook?.preload ? ["--import", pathToFileURL(hook.preload).href] : []), projectCheck,
		"--project", fixture, "--result", resultPath, ...(hook?.workspace ? ["--workspace", hook.workspace] : [])];
	const env = hook?.preload ? { ...process.env, RELAY_TEST_READ_PATH: path.join(fixture, hook.file ?? "tsconfig.json"),
		RELAY_TEST_READ_NUMBER: String(hook.readNumber), RELAY_TEST_READ_ACTION: hook.action } : process.env;
	const child = spawnSync(process.execPath, args, { cwd: root, encoding: "utf8", env });
	if (child.error) throw child.error;
	assert(fs.existsSync(resultPath), `project-check did not write its result\n${child.stdout}\n${child.stderr}`);
	const result = JSON.parse(fs.readFileSync(resultPath, "utf8"));
	assert.equal(child.status, result.exitCode, `${child.stdout}\n${child.stderr}\n${JSON.stringify(result)}`);
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
		const normalRojo = path.join(normal, "default.project.json");
		const rojo = JSON.parse(fs.readFileSync(normalRojo, "utf8"));
		rojo.tree.ReplicatedStorage.ProjectCheckAssets.$path = { optional: "assets" };
		rojo.tree.ReplicatedStorage.Absent = { $path: { optional: "absent-asset" } };
		rojo.tree.ReplicatedStorage.RelayExample.Network.$path = { optional: "out/Network.luau" };
		fs.writeFileSync(normalRojo, JSON.stringify(rojo));
		const normalConfig = path.join(normal, "tsconfig.json");
		const defaultGlob = JSON.parse(fs.readFileSync(normalConfig, "utf8"));
		delete defaultGlob.include;
		defaultGlob.compilerOptions.declaration = true;
		fs.writeFileSync(normalConfig, JSON.stringify(defaultGlob));
		const workspace = path.join(normal, "relay-tools-0123456789abcdef01234567");
		fs.mkdirSync(workspace);
		const passed = runProjectCheck(normal, path.join(parent, "normal-result.json"), true, { workspace });
		assert.equal(passed.status, "passed");
		assert(passed.sourceFiles.some(file => file.path === "src/server.server.ts"));
		assert.deepEqual(fs.readdirSync(workspace), []);
		assertProjectCheckDidNotWrite(normal);

		for (const suffix of [".tsconfig.json", ".project.json"]) {
			const shadow = path.join(normal, `.relay-tools-${path.basename(workspace)}${suffix}`);
			fs.writeFileSync(shadow, "existing shadow");
			const collision = runProjectCheck(normal, path.join(parent, `collision${suffix}`), false, { workspace });
			assert.equal(collision.exitCode, 2);
			assert.equal(fs.readFileSync(shadow, "utf8"), "existing shadow");
			fs.unlinkSync(shadow);
			assert.deepEqual(fs.readdirSync(workspace), []);
			assertProjectCheckDidNotWrite(normal);
		}
		const occupied = path.join(workspace, "roblox-ts");
		fs.mkdirSync(occupied);
		fs.writeFileSync(path.join(occupied, "keep.txt"), "existing scratch");
		const nonfresh = runProjectCheck(normal, path.join(parent, "nonfresh-result.json"), false, { workspace });
		assert.equal(nonfresh.diagnostics[0].code, "WorkspaceNotFresh");
		assert.equal(fs.readFileSync(path.join(occupied, "keep.txt"), "utf8"), "existing scratch");

		fs.mkdirSync(path.join(normal, "out"));
		const oldDeclaration = path.join(normal, "out/old.d.ts");
		const oldType = "OldOutputOnly" + "語".repeat(400);
		const oldContents = `type ${oldType} = number;`;
		fs.writeFileSync(oldDeclaration, oldContents);
		fs.writeFileSync(path.join(normal, "src/uses-old.ts"), `export const bad: ${oldType} = 9;`);
		const excluded = runProjectCheck(normal, path.join(parent, "excluded-output-result.json"), false);
		assert.equal(excluded.exitCode, 1);
		const issue = excluded.diagnostics.find(item => item.path === "src/uses-old.ts" && item.code === "TS2304");
		assert(issue && issue.message.includes("語".repeat(300)));
		assert(Buffer.byteLength(issue.message) <= 1024 && !issue.message.includes("\uFFFD"));
		assert(!excluded.sourceFiles.some(file => file.path === "out/old.d.ts"));
		assert.equal(fs.readFileSync(oldDeclaration, "utf8"), oldContents);

		const warnings = projectCheckFixture(parent, "warnings");
		const warningsConfig = path.join(warnings, "tsconfig.json");
		const config = JSON.parse(fs.readFileSync(warningsConfig, "utf8"));
		config.rbxts = { logTruthyChanges: true };
		fs.writeFileSync(warningsConfig, JSON.stringify(config));
		fs.writeFileSync(path.join(warnings, "src/warnings.ts"), "export function sample(n: number) {\n"
			+ "if (n) { print(n); }\n".repeat(65) + "for (const key in { good: true }) { print(key); }\n}");
		const rejectedWarnings = runProjectCheck(warnings, path.join(parent, "warnings-result.json"), false);
		assert.equal(rejectedWarnings.failureKind, "compile");
		assert.equal(rejectedWarnings.exitCode, 1);
		assert.equal(rejectedWarnings.diagnostics.length, 64);
		assert(rejectedWarnings.diagnostics.some(item => item.severity === "error" && item.message.includes("for-in")));
		assertProjectCheckDidNotWrite(warnings);

		const changing = projectCheckFixture(parent, "changing");
		const preload = path.join(parent, "change-config-on-reread.mjs");
		fs.writeFileSync(preload, `import fs from "node:fs";
import path from "node:path";
const target = path.resolve(process.env.RELAY_TEST_READ_PATH);
const readFileSync = fs.readFileSync;
const targetRead = Number(process.env.RELAY_TEST_READ_NUMBER);
const action = process.env.RELAY_TEST_READ_ACTION;
let reads = 0;
fs.readFileSync = function (file, ...args) {
	if (typeof file === "string" && path.resolve(file) === target && ++reads === targetRead) {
		if (action === "edit-source") {
			fs.appendFileSync(path.join(path.dirname(target), "src/server.server.ts"), "\\nexport const bad: string = 9;");
			return readFileSync.call(fs, file, ...args);
		}
		if (action === "add-source") {
			fs.writeFileSync(path.join(path.dirname(target), "added.ts"), "export const bad: string = 42;");
			return readFileSync.call(fs, file, ...args);
		}
		if (action === "shadow-import") {
			fs.writeFileSync(path.join(path.dirname(target), "../choice.d.ts"), "export type Choice = string;");
			return readFileSync.call(fs, file, ...args);
		}
		if (action === "remove-before-read") fs.unlinkSync(target);
		if (action === "grow-before-read") fs.writeFileSync(target, Buffer.alloc(4 * 1024 * 1024 + 1));
		const bytes = readFileSync.call(fs, file, ...args);
		if (action === "remove") {
			fs.unlinkSync(target);
			return bytes;
		}
		if (action === "grow-before-read") return bytes;
		fs.writeFileSync(target, Buffer.concat([bytes, Buffer.from("\\n")]));
	}
	return readFileSync.call(fs, file, ...args);
};
`);
		const changed = runProjectCheck(changing, path.join(parent, "changing-result.json"), false,
			{ preload, readNumber: 3, action: "change" });
		assert.equal(changed.status, "stale");
		assert.equal(changed.exitCode, 1);
		assert.equal(changed.diagnostics[0].code, "SourceChangedDuringCheck");
		assert.match(changed.sourceId, /^sha256:/);
		assertProjectCheckDidNotWrite(changing);

		const editing = projectCheckFixture(parent, "editing");
		const edited = runProjectCheck(editing, path.join(parent, "edit-during-discovery-result.json"), false,
			{ preload, readNumber: 4, action: "edit-source" });
		assert.equal(edited.status, "stale");
		assert.equal(edited.diagnostics[0].code, "SourceChangedDuringCheck");
		assertProjectCheckDidNotWrite(editing);

		const adding = projectCheckFixture(parent, "adding");
		const added = runProjectCheck(adding, path.join(parent, "adding-result.json"), false,
			{ preload, file: "src/server.server.ts", readNumber: 1, action: "add-source" });
		assert.equal(added.status, "stale");
		assert.equal(added.diagnostics[0].code, "SourceChangedDuringCheck");
		assert.match(added.sourceId, /^sha256:/);
		const rerun = runProjectCheck(adding, path.join(parent, "added-result.json"), false);
		assert(rerun.diagnostics.some(item => item.path === "src/added.ts" && item.code === "TS2322"));
		assertProjectCheckDidNotWrite(adding);

		const imports = projectCheckFixture(parent, "shadowed-import");
		const importsConfig = path.join(imports, "tsconfig.json");
		const explicit = JSON.parse(fs.readFileSync(importsConfig, "utf8"));
		explicit.include = [];
		explicit.files = ["src/server.server.ts", "src/client.client.ts", "src/contracts.ts"];
		fs.writeFileSync(importsConfig, JSON.stringify(explicit));
		fs.mkdirSync(path.join(imports, "src/choice"));
		fs.writeFileSync(path.join(imports, "src/choice/index.d.ts"), "export type Choice = number;");
		fs.appendFileSync(path.join(imports, "src/server.server.ts"), '\nimport type { Choice } from "./choice";\nexport const chosen: Choice = 42;');
		const shadowed = runProjectCheck(imports, path.join(parent, "shadowed-import-result.json"), false,
			{ preload, file: "src/choice/index.d.ts", readNumber: 1, action: "shadow-import" });
		assert.equal(shadowed.status, "stale");
		assert.equal(shadowed.diagnostics[0].code, "SourceChangedDuringCheck");
		const resolved = runProjectCheck(imports, path.join(parent, "shadowed-import-rerun.json"), false);
		assert(resolved.diagnostics.some(item => item.path === "src/server.server.ts" && item.code === "TS2322"));
		assertProjectCheckDidNotWrite(imports);

		const disappearing = projectCheckFixture(parent, "disappearing");
		const removed = runProjectCheck(disappearing, path.join(parent, "disappearing-result.json"), false,
			{ preload, readNumber: 2, action: "remove" });
		assert.equal(removed.status, "stale");
		assert.equal(removed.exitCode, 1);
		assert.equal(removed.diagnostics[0].code, "SourceChangedDuringCheck");
		assert.match(removed.sourceId, /^sha256:/);
		assertProjectCheckDidNotWrite(disappearing);

		const disappearingDuringRead = projectCheckFixture(parent, "disappearing-during-read");
		const removedDuringRead = runProjectCheck(disappearingDuringRead,
			path.join(parent, "disappearing-during-read-result.json"), false,
			{ preload, readNumber: 2, action: "remove-before-read" });
		assert.equal(removedDuringRead.status, "stale");
		assert.equal(removedDuringRead.exitCode, 1);
		assert.equal(removedDuringRead.diagnostics[0].code, "SourceChangedDuringCheck");
		assert.match(removedDuringRead.sourceId, /^sha256:/);
		assertProjectCheckDidNotWrite(disappearingDuringRead);

		const grown = projectCheckFixture(parent, "grown");
		const oversizedReread = runProjectCheck(grown, path.join(parent, "grown-result.json"), false,
			{ preload, readNumber: 2, action: "grow-before-read" });
		assert.equal(oversizedReread.status, "stale");
		assert.equal(oversizedReread.exitCode, 1);
		assert.equal(oversizedReread.diagnostics[0].code, "SourceChangedDuringCheck");
		assert.match(oversizedReread.sourceId, /^sha256:/);
		assertProjectCheckDidNotWrite(grown);

		const oversizedInitial = projectCheckFixture(parent, "oversized-initial");
		const rejectedOversizedInitial = runProjectCheck(oversizedInitial,
			path.join(parent, "oversized-initial-result.json"), false,
			{ preload, readNumber: 1, action: "grow-before-read" });
		assert.equal(rejectedOversizedInitial.status, "unsupported");
		assert.equal(rejectedOversizedInitial.exitCode, 2);
		assert.equal(rejectedOversizedInitial.diagnostics[0].code, "InputLimitExceeded");
		assertProjectCheckDidNotWrite(oversizedInitial);

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
		const nestedRojo = path.join(nested, "default.project.json");
		const nestedDocument = JSON.parse(fs.readFileSync(nestedRojo, "utf8"));
		nestedDocument.tree.ReplicatedStorage = {
			Direct: { $path: { optional: "assets/nested/default.project.json" } }, ...nestedDocument.tree.ReplicatedStorage,
		};
		fs.writeFileSync(nestedRojo, JSON.stringify(nestedDocument));
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

const runtime = path.join(root, "src");
const consumerSource = path.join(project, "src");
const generatedRuntime = path.join(consumerSource, "Relay");
assert.equal(fs.realpathSync(consumerSource), consumerSource);
if (fs.existsSync(generatedRuntime)) {
	assert.equal(fs.realpathSync(generatedRuntime), generatedRuntime);
	fs.rmSync(generatedRuntime, { recursive: true });
}
fs.cpSync(runtime, generatedRuntime, { recursive: true, errorOnExist: true, force: false });

function assertRuntimeCopy(directory) {
	const files = fs.readdirSync(runtime, { recursive: true }).sort();
	assert.deepEqual(fs.readdirSync(directory, { recursive: true }).sort(), files, `runtime inventory: ${directory}`);
	for (const file of files) {
		const original = path.join(runtime, file);
		if (fs.statSync(original).isFile())
			assert(fs.readFileSync(original).equals(fs.readFileSync(path.join(directory, file))), `runtime copy: ${file}`);
	}
}

assertRuntimeCopy(generatedRuntime);
run("lune", ["run", "scripts/roblox-ts/generate.luau", "scripts/roblox-ts/consumer/src/Spec.luau",
	"scripts/roblox-ts/consumer/src/Network.d.ts"]);
if (process.argv.includes("--prepare")) process.exit(0);

assert(!fs.existsSync(negativePath), "remove a leftover generated consumer/src/negative.ts before running checks");
run(process.execPath, compilerArgs);
assertRuntimeCopy(path.join(project, "out/Relay"));
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
