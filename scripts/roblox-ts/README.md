# Optional roblox-ts declarations

This tooling generates a TypeScript declaration from a Relay Luau schema. The Luau schema remains the source of truth: there is no second IDL and no roblox-ts dependency in Relay's runtime package.

## Run the consumer checks

From the repository root:

```sh
npm ci --prefix scripts/roblox-ts
npm test --prefix scripts/roblox-ts
npm run build --prefix scripts/roblox-ts
rojo build scripts/roblox-ts/consumer/default.project.json -o .tmp/relay-roblox-ts-consumer.rbxlx
```

The package pins its compiler and type dependencies. `npm test` generates declarations, checks positive and negative TypeScript examples with the actual roblox-ts compiler, and verifies emitted Luau. `npm run build` regenerates declarations and builds the consumer. The declaration is generated output; edit the Luau schema or bridge, then regenerate it.

To generate a declaration directly:

```sh
lune run scripts/roblox-ts/generate.luau scripts/roblox-ts/consumer/src/Spec.luau scripts/roblox-ts/consumer/src/Network.d.ts
```

The command must run from the repository root. It accepts a repository-relative `.luau` module returning a schema table and a repository-relative `.d.ts` output path. It validates the schema with `Definition.define`, reads the frozen canonical record through `Definition.get`, and writes only after generation succeeds. Unknown Relay shapes fail closed.

## Use it with a game module

Keep one authored Luau schema module for both sides of the boundary. It can use conditional imports so Lune loads the same schema helpers and native enum values that Roblox uses. The checked example is `consumer/src/Spec.luau`. Its authored `consumer/src/Network.luau` module defines the schema with `Relay.define` and returns `createServer` and `createClient` functions bound to that definition. Generate `Network.d.ts` beside it; roblox-ts then pairs the declaration with the Luau module when TypeScript imports `./Network`.

After changing the schema, regenerate the declaration before type checking. Do not hand-edit generated declarations. The example project shows the full consumer and Rojo layout.

Declarations preserve exact event and request names, directions, argument order, and payload shapes. Struct fields remain readonly, optional struct fields use optional properties, optional tuple fields keep their position and accept `undefined`, and tagged unions retain their discriminator and variants. Numeric and quantized shapes map to `number`; Roblox values map to their native roblox-ts types; arrays use `ReadonlyArray`, maps use `ReadonlyMap`, and sets use `ReadonlyMap<Element, true>` to match Relay's keyed set representation.

Server options require `instanceRoot` when the shared schema contains Instance references, and omit it otherwise. Per-endpoint inbound rate buckets use a `ReadonlyMap<number, EndpointRate>` keyed by the authored endpoint ID.

Both constructor options accept an optional `namespace`. The consumer uses `typescript` on both sides so it can coexist with a game's default Relay session. Relay validates the namespace grammar and session limits at runtime.

The generated session surface covers event `Connect`/`Once` and send methods plus request `Connect`/`Request`. It omits queue, stream, and other advanced session APIs. Type checking documents the consumer contract; Relay still validates payloads and runtime options and enforces its wire and abuse limits.

## roblox-ts references

- [Using existing Luau modules and declaration files](https://roblox-ts.com/docs/guides/using-existing-luau/)
- [Callbacks versus methods](https://roblox-ts.com/docs/guides/callbacks-vs-methods/)
- [LuaTuple multiple returns](https://roblox-ts.com/docs/guides/lua-tuple/)
- [roblox-ts introduction](https://roblox-ts.com/docs/)
