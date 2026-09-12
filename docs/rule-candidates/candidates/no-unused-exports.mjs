import { basename } from "node:path";

let cachedCorpus;
let cachedUsage;

// scope is the suffixed-module convention, not a directory depth. a surface module
// is named <name>.<kind>.ts, and everything else in the tree is the root library, a
// process entry point or a schema module.
//
// this replaced a depth check (`dirname(relPath).split("/").length <= 1`), which is
// fragile in exactly the way section 6.3 records: the same file measures as depth one
// or depth two depending on whether the corpus paths carry a project prefix. measured
// at batch 43, the depth version fires **24 times on the holdout**, 6 per project,
// every hit in `<project>/lib/outcome.ts` — the template's own shared library, which
// the rule's message says is out of scope. `no-export-without-consumer` had the same
// bug and the same fix, so the two siblings now agree
const isRootModule = (relPath) => basename(relPath).split(".").length < 3;

// one pass over every identifier in the project, so a name that appears only
// at its own declaration site has no consumer
const collectIdentifierUsage = (ts, corpus) => {
  const usage = new Map();
  for (const file of corpus) {
    const visit = (node) => {
      if (ts.isIdentifier(node)) {
        usage.set(node.text, (usage.get(node.text) ?? 0) + 1);
      }
      ts.forEachChild(node, visit);
    };
    visit(file.sourceFile);
  }
  return usage;
};

const exportedNames = (ts, sourceFile) => {
  const names = [];
  for (const statement of sourceFile.statements) {
    const isExported = statement.modifiers?.some(
      (modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword,
    );
    if (!isExported) continue;
    if (
      (ts.isFunctionDeclaration(statement) ||
        ts.isTypeAliasDeclaration(statement) ||
        ts.isEnumDeclaration(statement) ||
        ts.isClassDeclaration(statement)) &&
      statement.name !== undefined
    ) {
      names.push(statement.name);
    }
    if (ts.isVariableStatement(statement)) {
      for (const declaration of statement.declarationList.declarations) {
        if (ts.isIdentifier(declaration.name)) names.push(declaration.name);
      }
    }
  }
  return names;
};

export default {
  id: "no-unused-exports",
  category: "architecture",
  layer: "structural",
  tier: "prepass",
  severity: "warn",
  patternKey: "unused-export",
  title:
    "an exported binding must have at least one consumer outside its own declaration",
  rationale:
    "an export is a promise that the symbol is part of the module's public surface, when nothing imports it the promise is false, the symbol is dead weight that readers still have to reason about, and its tests and branches stay alive only because the type checker cannot prove nobody calls it",
  replacement:
    "delete the export keyword when the symbol is only used inside its own module, or delete the declaration entirely when nothing references it at all. the rule skips top-level root modules (the shared library and entry points), whose export list is an api that one application cannot show to be unused",
  detect({ ts, sourceFile, relPath, corpus }) {
    if (relPath.endsWith(".d.ts")) return [];
    if (isRootModule(relPath)) return [];
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedUsage = collectIdentifierUsage(ts, corpus);
    }
    const usage = cachedUsage;
    const hits = [];
    for (const name of exportedNames(ts, sourceFile)) {
      if ((usage.get(name.text) ?? 0) <= 1) {
        const position = sourceFile.getLineAndCharacterOfPosition(
          name.getStart(sourceFile),
        );
        hits.push({
          line: position.line + 1,
          column: position.character + 1,
          snippet: `${name.text} is declared here and referenced nowhere else in the project`,
        });
      }
    }
    return hits;
  },
};
