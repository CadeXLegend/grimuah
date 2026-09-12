import { basename, dirname } from "node:path";

const DECLARATION_SUFFIXES = new Set(["types", "config", "spec", "d"]);

// a module at the top level of the source tree is the shared root library or an
// entry point, out of scope for surface placement rules
const isRootModule = (relPath) => dirname(relPath).split("/").length <= 1;

const isImplementationModule = (relPath) => {
  const name = basename(relPath);
  if (!name.endsWith(".ts") || name.endsWith(".d.ts")) return false;
  const parts = name.replace(/\.ts$/, "").split(".");
  if (parts.length < 2) return false;
  return !DECLARATION_SUFFIXES.has(parts[parts.length - 1]);
};

export default {
  id: "require-enum-in-config-file",
  category: "architecture",
  layer: "structural",
  tier: "prepass",
  severity: "warn",
  patternKey: "enum-placement",
  title: "an exported enum must be declared in its surface's .config.ts file",
  rationale:
    "an enum is a configuration constant, and grimuah gives configuration its own innate member so its dag order is declared rather than inherited from whatever module happened to declare it, when the enum lives in the repository or service that raises it every consumer imports an implementation module to read a constant, and the declaration drifts into an import cycle because the module that owns the behaviour ends up owning the vocabulary too",
  replacement:
    "move the enum into the surface's .config.ts file, creating it when the surface has none, so the constant has a declaration home and the implementing module exports behaviour only",
  detect({ ts, sourceFile, relPath }) {
    if (!isImplementationModule(relPath)) return [];
    if (isRootModule(relPath)) return [];
    const hits = [];
    for (const statement of sourceFile.statements) {
      if (!ts.isEnumDeclaration(statement)) continue;
      const isExported = statement.modifiers?.some(
        (modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword,
      );
      if (!isExported) continue;
      const stem = basename(relPath)
        .replace(/\.ts$/, "")
        .split(".")
        .slice(0, -1)
        .toString()
        .replaceAll(",", ".");
      const position = sourceFile.getLineAndCharacterOfPosition(
        statement.getStart(sourceFile),
      );
      hits.push({
        line: position.line + 1,
        column: position.character + 1,
        snippet: `${statement.name.text} is declared in an implementation module -- move it to ${stem}.config.ts`,
      });
    }
    return hits;
  },
};
