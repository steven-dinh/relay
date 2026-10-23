import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const tools = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(tools, "../..");
const project = path.join(tools, "consumer");
const negativePath = path.join(project, "src/negative.ts");
const compiler = path.join(tools, "node_modules/roblox-ts/out/CLI/cli.js");
const compilerArgs = [compiler, "-p", tools, "--rojo", path.join(project, "default.project.json"),
	"--includePath", path.join(project, "include")];

function run(command, args, expectedSuccess = true) {
	const result = spawnSync(command, args, { cwd: root, encoding: "utf8" });
	if (result.error) throw result.error;
	assert.equal(result.status === 0, expectedSuccess, `${command} ${args.join(" ")}\n${result.stdout}\n${result.stderr}`);
	return result;
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
for (const emitted of ["server:Start(", "server.events.Input:Connect(", "server.events.Output:Send("])
	assert(server.includes(emitted), emitted);
assert(!/\bNetwork:|\b_createClient:|\b_createServer:/.test(client + server), "module factories must use dot calls");
assert(client.includes("Active = true"), "set presence map must compile to member = true");
assert(contracts.includes("Enum.Material.Wood"), "native enum values must stay Roblox EnumItems");
assert(fs.existsSync(path.join(project, "out/Network.luau")), "Luau bridge must be copied by rbxtsc");
assert.equal(fs.readFileSync(path.join(project, "out/Relay/init.luau"), "utf8"),
	fs.readFileSync(path.join(root, "src/init.luau"), "utf8"));

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
