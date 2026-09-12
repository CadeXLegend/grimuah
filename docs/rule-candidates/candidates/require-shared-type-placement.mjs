import { basename, dirname, resolve } from "node:path";

// a declaration-only file is not an implementation module, so a type living in
// one is already placed correctly
const DECLARATION_SUFFIXES = new Set(["types", "config", "spec", "d"]);

// a surface implementation module is named <name>.<kind>.ts, a file with no dot
// suffix at all is a root utility or entry point and is out of scope
const implementationSuffixOf = (relPath) => {
  const name = basename(relPath);
  if (!name.endsWith(".ts") || name.endsWith(".d.ts")) return undefined;
  const parts = name.replace(/\.ts$/, "").split(".");
  if (parts.length < 2) return undefined;
  const suffix = parts[parts.length - 1];
  return DECLARATION_SUFFIXES.has(suffix)
    ? undefined
    : { suffix, stem: parts.slice(0, -1).toString().replaceAll(",", ".") };
};

const normalize = (pathValue) => pathValue.replaceAll("\\", "/");

let cachedCorpus;
let cachedConsumed;

// every `${name}@${file}` where the declaration lives in the file and some
// import of it comes from a different directory
const collectExternallyConsumed = (ts, corpus) => {
  const knownPaths = new Set(corpus.map((file) => file.relPath));
  const declaredAt = new Map();
  for (const file of corpus) {
    for (const statement of file.sourceFile.statements) {
      const isExported = statement.modifiers?.some(
        (modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword,
      );
      if (!isExported) continue;
      if (
        ts.isTypeAliasDeclaration(statement) ||
        ts.isEnumDeclaration(statement)
      ) {
        const owners = declaredAt.get(statement.name.text) ?? new Set();
        owners.add(file.relPath);
        declaredAt.set(statement.name.text, owners);
      }
    }
  }
  const consumed = new Set();
  for (const file of corpus) {
    for (const statement of file.sourceFile.statements) {
      if (
        !ts.isImportDeclaration(statement) ||
        !ts.isStringLiteral(statement.moduleSpecifier)
      )
        continue;
      const specifier = statement.moduleSpecifier.text;
      if (!specifier.startsWith(".")) continue;
      const basePath = normalize(
        resolve("/", dirname(file.relPath), specifier),
      ).slice(1);
      const target = [basePath, `${basePath}.ts`, `${basePath}/index.ts`].find(
        (candidatePath) => knownPaths.has(candidatePath),
      );
      if (target === undefined || dirname(target) === dirname(file.relPath))
        continue;
      const clause = statement.importClause;
      if (clause === undefined) continue;
      const collectSpecifiers = (inner) => {
        if (ts.isImportSpecifier(inner)) {
          const name = inner.name.text;
          if (declaredAt.get(name)?.has(target) === true)
            consumed.add(`${name}@${target}`);
        }
        ts.forEachChild(inner, collectSpecifiers);
      };
      collectSpecifiers(clause);
    }
  }
  return consumed;
};

export default {
  id: "require-shared-type-placement",
  category: "architecture",
  layer: "structural",
  tier: "prepass",
  severity: "warn",
  patternKey: "shared-type-placement",
  title:
    "a type consumed from another directory must live in a declaration file, not an implementation module",
  rationale:
    "when the shared type sits inside the module that also implements behaviour, every consumer of the type imports the implementation, the dependency the import firewall reasons about is no longer the one the reader sees, the consumer is coupled to that module's other exports, and the type and the behaviour can no longer change independently",
  replacement:
    "declaring the type in the surface's .types.ts file gives the shared shape its own module, keeps the import edge pointing at a declaration, and lets the implementing module keep its behaviour private. enums are handled by require-enum-in-config-file instead, so the two rules never offer the same fix twice",
  detect({ ts, sourceFile, relPath, corpus }) {
    const implementation = implementationSuffixOf(relPath);
    if (implementation === undefined) return [];
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedConsumed = collectExternallyConsumed(ts, corpus);
    }
    const consumed = cachedConsumed;
    const hits = [];
    for (const statement of sourceFile.statements) {
      const isExported = statement.modifiers?.some(
        (modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword,
      );
      if (!isExported) continue;
      const isTypeAlias = ts.isTypeAliasDeclaration(statement);
      if (!isTypeAlias) continue;
      if (!consumed.has(`${statement.name.text}@${relPath}`)) continue;
      const destination = `${implementation.stem}.types.ts`;
      const position = sourceFile.getLineAndCharacterOfPosition(
        statement.getStart(sourceFile),
      );
      hits.push({
        line: position.line + 1,
        column: position.character + 1,
        snippet: `${statement.name.text} is imported from another directory -- declare it in ${destination}`,
      });
    }
    return hits;
  },
};
