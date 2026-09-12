import { basename } from "node:path";

let cachedCorpus;
let cachedUsageFiles;

// scope is the suffixed-module convention, not a directory depth. a surface module
// is named <name>.<kind>.ts, and everything else in the tree is the root library, a
// process entry point or a schema module. depth was the first attempt and it is
// fragile: the same file measures as depth one or depth two depending on whether the
// corpus paths carry a project prefix, which silently moves it in or out of scope
const isSuffixedModule = (relPath) => basename(relPath).split(".").length >= 3;

// name -> the set of files whose code names it. a declaration that only ever appears
// in its own file has no consumer, whatever the symbol does internally
const collectUsageFiles = (ts, corpus) => {
  const usage = new Map();
  for (const file of corpus) {
    const visit = (node) => {
      if (ts.isIdentifier(node)) {
        const holders = usage.get(node.text) ?? new Set();
        holders.add(file.relPath);
        usage.set(node.text, holders);
      }
      ts.forEachChild(node, visit);
    };
    visit(file.sourceFile);
  }
  return usage;
};

const exportedDeclarations = (ts, sourceFile) => {
  const declarations = [];
  for (const statement of sourceFile.statements) {
    const isExported = (statement.modifiers ?? []).some(
      (modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword,
    );
    if (!isExported) continue;
    if (ts.isVariableStatement(statement)) {
      for (const declaration of statement.declarationList.declarations) {
        if (ts.isIdentifier(declaration.name))
          declarations.push({ name: declaration.name, kind: "const" });
      }
      continue;
    }
    const isNamedDeclaration =
      ts.isTypeAliasDeclaration(statement) ||
      ts.isEnumDeclaration(statement) ||
      ts.isClassDeclaration(statement) ||
      ts.isFunctionDeclaration(statement);
    if (isNamedDeclaration && statement.name !== undefined) {
      declarations.push({
        name: statement.name,
        kind: ts.SyntaxKind[statement.kind],
      });
    }
  }
  return declarations;
};

export default {
  id: "no-export-without-consumer",
  category: "architecture",
  layer: "structural",
  tier: "prepass",
  severity: "warn",
  patternKey: "local-only-export",
  title: "an exported binding must be named by at least one other module",
  rationale:
    "the export keyword widens a symbol's audience to the whole project, so a reader who finds one has to assume something outside can depend on its shape. when no other module ever names the symbol the promise is false, the declaration is really module private, and every future edit carries a compatibility question the project cannot answer. this is a different defect from a declaration nothing uses at all, the symbol here is live inside its own module and only the visibility is wrong",
  replacement:
    "drop the export keyword when only this module names the symbol. keep the export if another module is meant to, then have that module name it, which is what makes the contract visible. top level root modules (the shared library and process entry points) are out of scope, their export list is an api no single application can prove unconsumed",
  detect({ ts, sourceFile, relPath, corpus }) {
    if (relPath.endsWith(".d.ts")) return [];
    if (!isSuffixedModule(relPath)) return [];
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedUsageFiles = collectUsageFiles(ts, corpus);
    }
    const usage = cachedUsageFiles;
    const hits = [];
    for (const declaration of exportedDeclarations(ts, sourceFile)) {
      const holders = usage.get(declaration.name.text);
      if (holders !== undefined && holders.size > 1) continue;
      const position = sourceFile.getLineAndCharacterOfPosition(
        declaration.name.getStart(sourceFile),
      );
      hits.push({
        line: position.line + 1,
        column: position.character + 1,
        snippet: `${declaration.kind} ${declaration.name.text} is exported but no other module names it`,
      });
    }
    return hits;
  },
};
