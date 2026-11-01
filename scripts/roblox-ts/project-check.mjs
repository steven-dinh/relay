import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const toolRoot = path.dirname(fileURLToPath(import.meta.url));
const toolRequire = createRequire(import.meta.url);
const MAX_INPUTS = 1024;
const MAX_INPUT_BYTES = 64 * 1024 * 1024;
const MAX_FILE_BYTES = 4 * 1024 * 1024;
const MAX_RESULT_BYTES = 4 * 1024 * 1024;
const MAX_LOG_BYTES = 16 * 1024;

class CheckError extends Error {
	constructor(code, message, action, status = "failed", failureKind = "configuration") {
		super(message);
		Object.assign(this, { code, action, status, failureKind });
	}
}

function within(root, candidate) {
	const relative = path.relative(root, candidate);
	return relative === "" || (!path.isAbsolute(relative) && relative !== ".." && !relative.startsWith(`..${path.sep}`));
}

function inside(root, candidate, label, mustExist = false) {
	const absolute = path.resolve(candidate);
	if (!within(root, absolute)) {
		throw new CheckError("ExternalPathUnsupported", `${label} escapes the project root: ${candidate}`,
			"Move the input or output under the selected project root and rerun the check.", "unsupported", "unsupported");
	}
	const relative = path.relative(root, absolute);
	let current = root;
	const segments = relative === "" ? [] : relative.split(path.sep);
	for (let index = 0; index < segments.length; index++) {
		current = path.join(current, segments[index]);
		let stat;
		try {
			stat = fs.lstatSync(current);
		} catch (error) {
			if (error?.code !== "ENOENT" && error?.code !== "ENOTDIR") throw error;
			if (mustExist) throw new CheckError("MissingProjectInput", `${label} does not exist: ${current}`,
				"Create the required project input and rerun the check.");
			break;
		}
		if (stat.isSymbolicLink() || (typeof stat.attributes === "number" && (stat.attributes & 0x400) !== 0)) {
			throw new CheckError("UnsupportedReparsePath", `${label} uses an unsupported symbolic link or reparse point: ${current}`,
				"Replace the reparse path with a regular project path and rerun the check.", "unsupported", "unsupported");
		}
		if (index < segments.length - 1 && !stat.isDirectory()) {
			throw new CheckError("InvalidProjectPath", `${label} has a non-directory parent: ${current}`,
				"Correct the project path and rerun the check.");
		}
	}
	return absolute;
}

function rel(root, absolute) {
	const value = path.relative(root, absolute).split(path.sep).join("/");
	if (value.length > 512) throw new CheckError("InputLimitExceeded", "A project input path exceeds 512 characters.",
		"Shorten project input paths and rerun the check.", "unsupported", "unsupported");
	return value;
}

function readFileBounded(file, limit = MAX_FILE_BYTES) {
	const stat = fs.statSync(file);
	if (!stat.isFile() || stat.size > limit) throw new CheckError("InputLimitExceeded", `Project input exceeds ${limit} bytes: ${file}`,
		"Reduce the project input size and rerun the check.", "unsupported", "unsupported");
	const bytes = fs.readFileSync(file);
	if (bytes.length > limit) throw new CheckError("InputLimitExceeded", `Project input exceeds ${limit} bytes: ${file}`,
		"Reduce the project input size and rerun the check.", "unsupported", "unsupported");
	return bytes;
}

function addInput(inputs, file, bytes, root) {
	const absolute = path.resolve(file);
	const previous = inputs.get(absolute);
	if (previous) {
		if (!previous.equals(bytes)) throw new CheckError("SourceChangedDuringCheck", `Project input changed while being read: ${rel(root, absolute)}`,
			"Wait for edits to finish and rerun the check.", "stale", "stale");
		return;
	}
	if (inputs.size >= MAX_INPUTS || [...inputs.values()].reduce((sum, value) => sum + value.length, 0) + bytes.length > MAX_INPUT_BYTES) {
		throw new CheckError("InputLimitExceeded", "Project compiler inputs exceed 1024 files or 64 MiB.",
			"Reduce the compiler input set and rerun the check.", "unsupported", "unsupported");
	}
	inputs.set(absolute, Buffer.from(bytes));
}

function digest(bytes) {
	return `sha256:${crypto.createHash("sha256").update(bytes).digest("hex")}`;
}

function sourceIdentity(root, inputs) {
	const rows = [...inputs.entries()].map(([file, bytes]) => ({ path: rel(root, file), bytes }))
		.sort((left, right) => left.path.localeCompare(right.path));
	const hash = crypto.createHash("sha256").update("RelayRobloxTsProjectSource:1\0", "utf8");
	for (const row of rows) {
		const name = Buffer.from(row.path, "utf8");
		const nameLength = Buffer.alloc(4);
		const byteLength = Buffer.alloc(8);
		nameLength.writeUInt32BE(name.length);
		byteLength.writeBigUInt64BE(BigInt(row.bytes.length));
		hash.update(nameLength).update(name).update(byteLength).update(row.bytes);
	}
	return { sourceId: `sha256:${hash.digest("hex")}`, rows };
}

function parseJson(bytes, file) {
	try {
		return JSON.parse(bytes.toString("utf8").replace(/^\uFEFF/, ""));
	} catch (error) {
		throw new CheckError("InvalidProjectConfig", `${file} is not valid JSON: ${String(error?.message ?? error).slice(0, 700)}`,
			`Correct ${file} and rerun the check.`);
	}
}

function diagnostic(code, message, action, file = "project", severity = "error") {
	const bounded = value => String(value ?? "").slice(0, 1024);
	return { severity, code, path: file, message: bounded(message), action: bounded(action) };
}

function nodeSupported(version) {
	const [major, minor] = version.split(".").map(Number);
	return major === 24 && minor >= 13;
}

function parseArgs(args) {
	const values = new Map();
	for (let index = 0; index < args.length; index++) {
		const flag = args[index];
		if (!["--project", "--result", "--workspace"].includes(flag)) throw new CheckError("InvalidUsage", `Unknown argument: ${flag}`,
			"Use --project <consumer-root> --result <machine-result.json>.", "unsupported", "usage");
		const value = args[++index];
		if (!value || value.startsWith("--") || values.has(flag)) throw new CheckError("InvalidUsage", `Missing or duplicate value for ${flag}.`,
			"Use --project <consumer-root> --result <machine-result.json>.", "unsupported", "usage");
		values.set(flag, value);
	}
	if (!values.has("--project") || !values.has("--result")) throw new CheckError("InvalidUsage", "Both --project and --result are required.",
		"Use --project <consumer-root> --result <machine-result.json>.", "unsupported", "usage");
	return { project: values.get("--project"), result: values.get("--result"), workspace: values.get("--workspace") };
}

function ownedWorkspace(value) {
	if (!path.isAbsolute(value)) throw new CheckError("InvalidWorkspace", "--workspace must be an absolute owned job directory.",
		"Pass the absolute directory reserved for this CLI job.", "unsupported", "usage");
	const absolute = path.resolve(value);
	if (!/^relay-tools-[0-9a-f]{24}$/i.test(path.basename(absolute))) throw new CheckError("InvalidWorkspace",
		"--workspace basename must be relay-tools- followed by the 24-hex job id.",
		"Pass the fresh job directory reserved by the Relay Tools CLI.", "unsupported", "usage");
	let current = path.parse(absolute).root;
	for (const part of path.relative(current, absolute).split(path.sep).filter(Boolean)) {
		current = path.join(current, part);
		const stat = fs.lstatSync(current);
		if (stat.isSymbolicLink() || (typeof stat.attributes === "number" && (stat.attributes & 0x400) !== 0)) {
			throw new CheckError("UnsupportedReparsePath", `--workspace uses a reparse path: ${current}`,
				"Reserve a regular local job directory and rerun the check.", "unsupported", "unsupported");
		}
	}
	if (!fs.statSync(absolute).isDirectory()) throw new CheckError("InvalidWorkspace", "--workspace must be an existing directory.",
		"Pass the fresh directory reserved by the Relay Tools CLI.", "unsupported", "usage");
	return absolute;
}

function capture(stream) {
	const write = stream.write;
	const chunks = [];
	let size = 0;
	let truncated = false;
	stream.write = function (value, encoding, callback) {
		const bytes = Buffer.isBuffer(value) ? value : Buffer.from(String(value), typeof encoding === "string" ? encoding : undefined);
		const remaining = MAX_LOG_BYTES - size;
		if (remaining > 0) {
			const chunk = bytes.subarray(0, remaining);
			chunks.push(chunk);
			size += chunk.length;
		}
		if (bytes.length > remaining) truncated = true;
		const done = typeof encoding === "function" ? encoding : callback;
		if (typeof done === "function") queueMicrotask(done);
		return true;
	};
	return {
		restore: () => { stream.write = write; },
		flush: () => { if (chunks.length) write.call(stream, Buffer.concat(chunks)); },
		get truncated() { return truncated; },
	};
}

function installedTools() {
	const compilerPackage = path.join(toolRoot, "node_modules/roblox-ts/package.json");
	const typescriptPackage = path.join(toolRoot, "node_modules/typescript/package.json");
	const lockFile = path.join(toolRoot, "package-lock.json");
	for (const file of [compilerPackage, typescriptPackage, lockFile]) {
		if (!fs.existsSync(file)) throw new CheckError("PinnedCompilerMissing", `Pinned compiler dependency is missing: ${file}`,
			"Run npm ci in the Relay roblox-ts tooling directory; the project check never installs dependencies.", "unsupported", "unsupported");
	}
	const compiler = parseJson(readFileBounded(compilerPackage, 64 * 1024), "roblox-ts package metadata");
	const typescript = parseJson(readFileBounded(typescriptPackage, 64 * 1024), "TypeScript package metadata");
	if (compiler.version !== "3.0.0" || typescript.version !== "5.5.3") throw new CheckError("PinnedCompilerMismatch",
		`Expected roblox-ts 3.0.0 and TypeScript 5.5.3; found ${compiler.version} and ${typescript.version}.`,
		"Restore the locked tooling dependencies with npm ci.", "unsupported", "unsupported");
	return { compiler, compilerRoot: path.dirname(compilerPackage), typescript: typescript.version,
		lockDigest: digest(readFileBounded(lockFile, MAX_RESULT_BYTES)) };
}

function patchSystem(ts, root, inputs, external, getTempRoot) {
	const system = ts.sys;
	const original = {};
	for (const key of ["readFile", "fileExists", "directoryExists", "readDirectory", "realpath", "writeFile", "createDirectory"]) {
		original[key] = system[key];
	}
	const libRoot = path.dirname(ts.getDefaultLibFilePath({ target: ts.ScriptTarget.ESNext }));
	const isToolInput = file => within(libRoot, path.resolve(file));
	const noteExternal = file => { if (fs.existsSync(file)) external.add(path.resolve(file)); };
	const outputRoot = () => {
		const value = getTempRoot();
		if (!value) throw new CheckError("CompilerOutputUnavailable", "The owned compiler output directory is unavailable.",
			"Reserve a fresh job workspace and rerun the check.", "unsupported", "unsupported");
		const parent = path.dirname(value);
		if (/^relay-tools-[0-9a-f]{24}$/i.test(path.basename(parent))) ownedWorkspace(parent);
		else inside(root, value, "temporary compiler output directory", true);
		const stat = fs.lstatSync(value);
		if (!stat.isDirectory() || stat.isSymbolicLink() || (typeof stat.attributes === "number" && (stat.attributes & 0x400) !== 0)) {
			throw new CheckError("CompilerOutputUnavailable", "The owned compiler output directory is no longer a regular directory.",
				"Reserve a fresh job workspace and rerun the check.", "unsupported", "unsupported");
		}
		return value;
	};
	system.readFile = (file, encoding) => {
		const absolute = path.resolve(file);
		if (!within(root, absolute)) {
			if (isToolInput(absolute)) return original.readFile(absolute, encoding);
			noteExternal(absolute);
			return undefined;
		}
		const safe = inside(root, absolute, "TypeScript input");
		if (!fs.existsSync(safe)) return undefined;
		const bytes = readFileBounded(safe);
		addInput(inputs, safe, bytes, root);
		return bytes.toString(encoding ?? "utf8");
	};
	system.fileExists = file => {
		const absolute = path.resolve(file);
		if (!within(root, absolute)) {
			if (isToolInput(absolute)) return original.fileExists(absolute);
			noteExternal(absolute);
			return false;
		}
		inside(root, absolute, "TypeScript input");
		return original.fileExists(absolute);
	};
	system.directoryExists = directory => {
		const absolute = path.resolve(directory);
		if (!within(root, absolute)) {
			if (isToolInput(absolute)) return original.directoryExists(absolute);
			noteExternal(absolute);
			return false;
		}
		inside(root, absolute, "TypeScript directory");
		return original.directoryExists(absolute);
	};
	system.readDirectory = (directory, extensions, excludes, includes, depth) => {
		const absolute = path.resolve(directory);
		if (!within(root, absolute)) {
			if (isToolInput(absolute)) return original.readDirectory(absolute, extensions, excludes, includes, depth);
			noteExternal(absolute);
			return [];
		}
		inside(root, absolute, "TypeScript directory", true);
		const files = original.readDirectory(absolute, extensions, excludes, includes, depth);
		for (const file of files) inside(root, file, "TypeScript input", true);
		return files;
	};
	system.realpath = file => {
		const absolute = path.resolve(file);
		if (!within(root, absolute)) return isToolInput(absolute) ? original.realpath(absolute) : absolute;
		inside(root, absolute, "TypeScript path");
		return absolute;
	};
	system.writeFile = (file, bytes, bom) => {
		const absolute = path.resolve(file);
		const tempRoot = outputRoot();
		if (!tempRoot || !within(root, absolute) || !within(tempRoot, absolute)) throw new CheckError("CompilerOutputEscape",
			`Compiler attempted to write outside its owned temporary output: ${absolute}`,
			"Review the TypeScript output configuration and rerun the check.", "unsupported", "unsupported");
		inside(root, absolute, "temporary compiler output");
		return original.writeFile(absolute, bytes, bom);
	};
	system.createDirectory = directory => {
		const absolute = path.resolve(directory);
		const tempRoot = outputRoot();
		if (!tempRoot || !within(root, absolute) || !within(tempRoot, absolute)) throw new CheckError("CompilerOutputEscape",
			`Compiler attempted to create a directory outside its owned temporary output: ${absolute}`,
			"Review the TypeScript output configuration and rerun the check.", "unsupported", "unsupported");
		inside(root, absolute, "temporary compiler output");
		return original.createDirectory(absolute);
	};
	return () => Object.assign(system, original);
}

function walkPaths(value, visit) {
	if (Array.isArray(value)) return value.forEach(child => walkPaths(child, visit));
	if (value === null || typeof value !== "object") return;
	for (const [key, child] of Object.entries(value)) {
		if (key === "$path") {
			if (typeof child !== "string" || child.length === 0) throw new CheckError("InvalidRojoPath", "Rojo $path must be a non-empty string.",
				"Correct default.project.json and rerun the check.");
			visit(child);
		} else walkPaths(child, visit);
	}
}

function sourceFiles(ts, root, program, inputs) {
	const libRoot = path.dirname(ts.getDefaultLibFilePath({ target: ts.ScriptTarget.ESNext }));
	const rows = [];
	for (const source of program.getSourceFiles()) {
		const file = path.resolve(source.fileName);
		if (!within(root, file)) {
			if (within(libRoot, file)) continue;
			throw new CheckError("ExternalSourceUnsupported", `Compiler input escapes the project root: ${file}`,
				"Install project dependencies under the consumer root and keep imported source within that root.", "unsupported", "unsupported");
		}
		inside(root, file, "TypeScript source", true);
		const bytes = inputs.get(file);
		if (!bytes) throw new CheckError("UntrackedCompilerInput", `Compiler input bytes were not captured: ${rel(root, file)}`,
			"Rerun with the pinned compiler after checking the tooling installation.", "unsupported", "tool");
		rows.push({ path: rel(root, file), digest: digest(bytes) });
	}
	rows.sort((left, right) => left.path.localeCompare(right.path));
	return rows;
}

function cleanup(root, files, directory, directoryRoot) {
	for (const file of files) {
		if (!file) continue;
		try {
			const safe = inside(root, file, "owned temporary path", true);
			const stat = fs.lstatSync(safe);
			if (!stat.isSymbolicLink() && stat.isFile()) fs.unlinkSync(safe);
		} catch { /* Leave replaced or escaped paths untouched. */ }
	}
	if (directory) {
		try {
			const safeRoot = /^relay-tools-[0-9a-f]{24}$/i.test(path.basename(directoryRoot))
				? ownedWorkspace(directoryRoot) : directoryRoot;
			const safe = inside(safeRoot, directory, "owned temporary directory", true);
			const stat = fs.lstatSync(safe);
			if (!stat.isSymbolicLink() && stat.isDirectory()) fs.rmSync(safe, { recursive: true, force: true });
		} catch { /* Leave replaced or escaped paths untouched. */ }
	}
}

async function main() {
	let resultPath;
	let root;
	let workspace;
	let workspaceBasename;
	let scratchRoot;
	let tempRoot;
	let shadowConfig;
	let shadowProject;
	let restoreSystem;
	let stdout;
	let stderr;
	const result = { schemaVersion: 1, operation: "typescript", status: "failed", exitCode: 2, projectRoot: "",
		nodeVersion: process.versions.node, compiler: {}, sourceId: "", sourceFiles: [], configFiles: [], outputs: [],
		diagnostics: [], unsupported: [] };
	stdout = capture(process.stdout);
	stderr = capture(process.stderr);
	const inputs = new Map();
	try {
		const args = parseArgs(process.argv.slice(2));
		resultPath = path.resolve(args.result);
		root = fs.realpathSync(path.resolve(args.project));
		if (!fs.statSync(root).isDirectory()) throw new CheckError("InvalidProjectRoot", "--project must name a directory.",
			"Pass the consumer root containing package.json, tsconfig.json and default.project.json.");
		result.projectRoot = root;
		if (args.workspace) {
			workspace = ownedWorkspace(args.workspace);
			if (path.parse(workspace).root.toLowerCase() !== path.parse(root).root.toLowerCase()) {
				throw new CheckError("WorkspaceVolumeMismatch", "roblox-ts temporary outputs must share the consumer volume for Rojo project mappings.",
					"Reserve the owned CLI workspace under the consumer root or on the same volume.", "unsupported", "unsupported");
			}
			workspaceBasename = path.basename(workspace);
			scratchRoot = workspace;
			tempRoot = path.join(workspace, "roblox-ts");
			if (fs.existsSync(tempRoot)) throw new CheckError("WorkspaceNotFresh", "The reserved roblox-ts workspace already exists.",
				"Reserve a fresh Relay Tools job directory and rerun the check.", "unsupported", "unsupported");
			fs.mkdirSync(tempRoot);
		} else {
			scratchRoot = root;
			tempRoot = fs.mkdtempSync(path.join(scratchRoot, ".relay-tools-ts-check-"));
			workspaceBasename = path.basename(tempRoot);
		}
		if (!nodeSupported(process.versions.node)) throw new CheckError("UnsupportedNodeVersion",
			`The optional TypeScript check supports Node >=24.13.0 <25; found ${process.versions.node}.`,
			"Run the check with Node 24.13.0 or a later Node 24 release.", "unsupported", "unsupported");

		const pinned = installedTools();
		result.compiler = { robloxTs: pinned.compiler.version, typescript: pinned.typescript, lockDigest: pinned.lockDigest };
		const ts = toolRequire(path.join(toolRoot, "node_modules/typescript"));
		const compilerRequire = createRequire(path.join(pinned.compilerRoot, "package.json"));
		const paths = new Map();
		for (const name of ["package.json", "tsconfig.json", "default.project.json"]) {
			const file = inside(root, path.join(root, name), name, true);
			const bytes = readFileBounded(file, 1024 * 1024);
			addInput(inputs, file, bytes, root);
			paths.set(name, file);
		}
		parseJson(inputs.get(paths.get("package.json")), "package.json");
		const configText = inputs.get(paths.get("tsconfig.json")).toString("utf8");
		const parsedText = ts.parseConfigFileTextToJson(paths.get("tsconfig.json"), configText);
		if (parsedText.error) throw new CheckError("InvalidTypeScriptConfig",
			ts.flattenDiagnosticMessageText(parsedText.error.messageText, "\n"), "Correct tsconfig.json and rerun the check.");
		const raw = parsedText.config ?? {};
		if (raw.references?.length) throw new CheckError("ProjectReferencesUnsupported", "TypeScript project references are not supported by this one-shot check.",
			"Use one consumer tsconfig.json for this check.", "unsupported", "unsupported");
		if (raw.compilerOptions?.plugins?.length) throw new CheckError("CustomTransformersUnsupported", "Custom TypeScript transformers/plugins are not run by this compiler check.",
			"Remove compilerOptions.plugins or run the custom build workflow explicitly.", "unsupported", "unsupported");
		const rojoBytes = inputs.get(paths.get("default.project.json"));
		const rojoDocument = parseJson(rojoBytes, "default.project.json");
		const external = new Set();
		restoreSystem = patchSystem(ts, root, inputs, external, () => tempRoot);
		const parseHost = Object.create(ts.sys);
		parseHost.onUnrecoverableConfigFileDiagnostic = () => {};
		const parsed = ts.getParsedCommandLineOfConfigFile(paths.get("tsconfig.json"), {}, parseHost);
		if (external.size) throw new CheckError("ExternalConfigEscape", `Config resolution reached outside the project root: ${[...external].sort()[0]}`,
			"Keep extended TypeScript configs and dependencies under the consumer root.", "unsupported", "unsupported");
		if (!parsed || parsed.errors.length) throw new CheckError("InvalidTypeScriptConfig",
			(parsed?.errors ?? []).map(item => ts.flattenDiagnosticMessageText(item.messageText, "\n")).join("\n") || "TypeScript could not parse tsconfig.json.",
			"Correct tsconfig.json and rerun the check.");
		if (parsed.projectReferences?.length) throw new CheckError("ProjectReferencesUnsupported", "TypeScript project references are not supported by this one-shot check.",
			"Use one consumer tsconfig.json for this check.", "unsupported", "unsupported");
		if (parsed.options.plugins?.length) throw new CheckError("CustomTransformersUnsupported", "Inherited TypeScript transformers/plugins are not run by this compiler check.",
			"Remove compilerOptions.plugins or run the custom build workflow explicitly.", "unsupported", "unsupported");
		if (parsed.options.outFile) throw new CheckError("OutFileUnsupported", "TypeScript outFile is not supported by roblox-ts.",
			"Use the compiler's outDir option.", "unsupported", "unsupported");
		if (!parsed.options.outDir) throw new CheckError("InvalidTypeScriptConfig", "compilerOptions.outDir must be set for a roblox-ts project.",
			"Add a project-rooted outDir to tsconfig.json.");
		for (const rootDir of [...(parsed.options.rootDir ? [parsed.options.rootDir] : []), ...(parsed.options.rootDirs ?? [])]) {
			inside(root, rootDir, "compilerOptions.rootDir/rootDirs");
		}
		for (const file of parsed.fileNames) inside(root, file, "TypeScript source", true);
		for (const typeRoot of parsed.options.typeRoots ?? []) inside(root, typeRoot, "compilerOptions.typeRoots");
		for (const typeName of parsed.options.types ?? []) {
			const found = (parsed.options.typeRoots ?? []).some(typeRoot => {
				const candidate = inside(root, path.join(typeRoot, typeName), `TypeScript type ${typeName}`);
				return fs.existsSync(candidate);
			});
			if (!found) throw new CheckError("MissingProjectDependency", `TypeScript type package "${typeName}" was not found under the consumer's typeRoots.`,
				`Install the project's declared type dependencies (including @rbxts/compiler-types when configured); this command does not install dependencies.`);
		}

		const options = parsed.options;
		const originalOut = inside(root, options.outDir, "compilerOptions.outDir");
		const originalInclude = inside(root, path.resolve(root, raw.rbxts?.includePath ?? "include"), "rbxts.includePath");
		const originalDecl = options.declarationDir ? inside(root, options.declarationDir, "compilerOptions.declarationDir") : undefined;
		const originalInfo = options.tsBuildInfoFile ? inside(root, options.tsBuildInfoFile, "compilerOptions.tsBuildInfoFile") : undefined;
		if (originalOut === root || originalInclude === root) throw new CheckError("UnsafeOutputPath", "Compiler output directories cannot be the project root.",
			"Choose output directories below the project root.", "unsupported", "unsupported");
		if (within(originalOut, originalInclude) || within(originalInclude, originalOut)) throw new CheckError("OverlappingOutputsUnsupported",
			"roblox-ts outDir and includePath must be separate directories.", "Choose separate output and include directories.", "unsupported", "unsupported");
		if (raw.rbxts?.watch) throw new CheckError("WatchModeUnsupported", "Watch mode is not supported by a one-shot check.",
			"Disable rbxts.watch and rerun the check.", "unsupported", "unsupported");
		const outputs = [{ path: rel(root, originalOut), kind: "roblox-ts-luau" }, { path: rel(root, originalInclude), kind: "roblox-ts-include" }];
		if ((options.declaration || options.composite) && originalDecl) outputs.push({ path: rel(root, originalDecl), kind: "typescript-declaration" });
		if ((options.incremental || options.composite) && originalInfo) outputs.push({ path: rel(root, originalInfo), kind: "typescript-build-info" });
		walkPaths(rojoDocument, value => inside(root, path.resolve(root, value), "Rojo $path"));

		const tempOut = path.join(tempRoot, "out");
		const tempInclude = path.join(tempRoot, "include");
		const tempDecl = path.join(tempRoot, "types");
		const tempInfo = path.join(tempRoot, "build.tsbuildinfo");
		const mapPath = value => {
			const input = path.resolve(root, value);
			let mapped;
			if (originalDecl && within(originalDecl, input)) mapped = path.join(tempDecl, path.relative(originalDecl, input));
			else if (within(originalOut, input)) mapped = path.join(tempOut, path.relative(originalOut, input));
			else if (within(originalInclude, input)) mapped = path.join(tempInclude, path.relative(originalInclude, input));
			return mapped ? path.relative(root, mapped).split(path.sep).join("/") : value;
		};
		const rewrite = value => Array.isArray(value) ? value.map(rewrite)
			: value && typeof value === "object" ? Object.fromEntries(Object.entries(value).map(([key, child]) =>
				[key, key === "$path" ? mapPath(child) : rewrite(child)])) : value;
		shadowConfig = path.join(root, args.workspace ? `.relay-tools-${workspaceBasename}.tsconfig.json`
			: `.relay-tools-tsconfig-${workspaceBasename}.json`);
		shadowProject = path.join(root, args.workspace ? `.relay-tools-${workspaceBasename}.project.json`
			: `.relay-tools-project-${workspaceBasename}.json`);
		fs.writeFileSync(shadowConfig, JSON.stringify({
			extends: paths.get("tsconfig.json"),
			compilerOptions: { outDir: tempOut,
				...(options.declaration || options.composite ? { declarationDir: tempDecl } : {}),
				...(options.incremental || options.composite ? { tsBuildInfoFile: tempInfo } : {}) },
			rbxts: { ...(raw.rbxts ?? {}), includePath: tempInclude, watch: false },
		}, null, 2), { flag: "wx" });
		fs.writeFileSync(shadowProject, JSON.stringify(rewrite(rojoDocument), null, 2), { flag: "wx" });
		const projectOptions = { ...compilerRequire("./out/Shared/constants").DEFAULT_PROJECT_OPTIONS,
			...(raw.rbxts ?? {}), includePath: tempInclude, rojo: shadowProject, watch: false, verbose: false };
		const data = compilerRequire("./out/Project/functions/createProjectData").createProjectData(shadowConfig, projectOptions);
		external.clear();
		const builder = compilerRequire("./out/Project/functions/createProjectProgram").createProjectProgram(data);
		inputs.delete(shadowConfig);
		inputs.delete(shadowProject);
		const program = builder.getProgram();
		if (external.size) throw new CheckError("ExternalSourceUnsupported", `TypeScript resolution found project inputs outside the consumer root: ${[...external].sort()[0]}`,
			"Install consumer dependencies under this project root and keep imported source inside it.", "unsupported", "unsupported");
		const sources = sourceFiles(ts, root, program, inputs);
		if (!sources.length) throw new CheckError("EmptyTypeScriptProgram", "tsconfig.json selected no compiler source files.",
			"Add the consumer sources to tsconfig.json and rerun the check.");
		const translator = compilerRequire("./out/Project/functions/createPathTranslator").createPathTranslator(builder, data);
		compilerRequire("./out/Project/functions/cleanup").cleanup(translator);
		compilerRequire("./out/Project/functions/copyInclude").copyInclude(data);
		const emitted = compilerRequire("./out/Project/functions/compileFiles").compileFiles(program, data, translator,
			compilerRequire("./out/Project/functions/getChangedSourceFiles").getChangedSourceFiles(builder));
		for (const item of emitted.diagnostics ?? []) {
			const isError = item.category === ts.DiagnosticCategory.Error;
			if (!isError && item.category !== ts.DiagnosticCategory.Warning) continue;
			const file = item.file && within(root, path.resolve(item.file.fileName)) ? rel(root, path.resolve(item.file.fileName)) : "project";
			const action = item.code === 2307 || item.code === 2688
				? "Install the missing consumer-owned type or module dependency under this project root; this command does not install packages."
				: "Correct the TypeScript or roblox-ts diagnostic and rerun the check.";
			result.diagnostics.push(diagnostic(`TS${item.code}`, ts.flattenDiagnosticMessageText(item.messageText, "\n"),
				action, file, isError ? "error" : "warning"));
			if (result.diagnostics.length >= 64) break;
			if (isError) ts.createDiagnosticReporter(ts.sys, true)(item);
		}

		let changed = false;
		for (const [file, bytes] of inputs) {
			try {
				const current = readFileBounded(inside(root, file, "captured project input", true));
				if (!current.equals(bytes)) changed = true;
			} catch { changed = true; }
		}
		const identity = sourceIdentity(root, inputs);
		result.sourceId = identity.sourceId;
		result.sourceFiles = sources;
		const sourceNames = new Set(sources.map(item => item.path));
		result.configFiles = identity.rows.filter(item => !sourceNames.has(item.path))
			.map(item => ({ path: item.path, digest: digest(item.bytes) }));
		result.outputs = outputs;
		if (changed) {
			result.status = "stale";
			result.exitCode = 1;
			result.diagnostics.push(diagnostic("SourceChangedDuringCheck", "A captured project input changed during compilation.",
				"Wait for project edits to finish and rerun the check."));
		} else if (result.diagnostics.some(item => item.severity === "error")) {
			result.status = "failed";
			result.exitCode = 1;
			result.failureKind = "compile";
		} else {
			result.status = "passed";
			result.exitCode = 0;
		}
	} catch (error) {
		const code = error instanceof CheckError ? error.code : "ProjectCheckFailed";
		const message = error instanceof CheckError ? error.message : String(error?.message ?? error);
		result.status = error instanceof CheckError ? error.status : "failed";
		result.failureKind = error instanceof CheckError ? error.failureKind : "tool";
		result.exitCode = error instanceof CheckError && error.status === "failed" && error.failureKind === "compile" ? 1 : 2;
		result.diagnostics.push(diagnostic(code, message, error instanceof CheckError ? error.action : "Review the compiler setup and rerun the check."));
		if (result.status === "unsupported") result.unsupported.push({ code, reason: String(message).slice(0, 1024) });
	} finally {
		if (restoreSystem) restoreSystem();
		cleanup(root, [shadowConfig, shadowProject], tempRoot, scratchRoot);
		stdout.restore();
		stderr.restore();
		result.logs = { stdoutTruncated: stdout.truncated, stderrTruncated: stderr.truncated, limitBytesPerStream: MAX_LOG_BYTES };
		if (resultPath) {
			try {
				const bytes = Buffer.from(`${JSON.stringify(result, null, 2)}\n`, "utf8");
				if (bytes.length > MAX_RESULT_BYTES) throw new Error(`result exceeds ${MAX_RESULT_BYTES} bytes`);
				fs.mkdirSync(path.dirname(resultPath), { recursive: true });
				fs.writeFileSync(resultPath, bytes);
			} catch (error) {
				process.stderr.write(`project-check could not write its result: ${String(error?.message ?? error).slice(0, 500)}\n`);
				result.exitCode = 2;
			}
		}
		stdout.flush();
		stderr.flush();
	}
	return result.exitCode;
}

main().then(code => { process.exitCode = code; }, error => {
	process.stderr.write(`${String(error?.stack ?? error).slice(0, 1024)}\n`);
	process.exitCode = 2;
});
