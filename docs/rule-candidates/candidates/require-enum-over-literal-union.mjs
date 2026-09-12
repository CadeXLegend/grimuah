import { basename } from "node:path";

// scope is the suffixed-module convention, the same predicate the whole-program rules
// use. a surface module is named <name>.<kind>.ts, so an unsuffixed module is the root
// library or an entry script and stays out of scope. this is deliberate rather than
// incidental: the process entry scripts cannot use an enum at runtime, which is the
// reason the corpus duplicates its string tables there in the first place
const isSuffixedModule = (relPath) => basename(relPath).split(".").length >= 3;

const stringLiteralEntryCount = (ts, typeNode) => {
  if (typeNode === undefined || !ts.isUnionTypeNode(typeNode)) return 0;
  const literalEntries = typeNode.types.filter(
    (literalEntry) =>
      ts.isLiteralTypeNode(literalEntry) &&
      ts.isStringLiteralLike(literalEntry.literal),
  );
  const isAllEntriesLiteral = literalEntries.length === typeNode.types.length;
  return isAllEntriesLiteral && literalEntries.length >= 2
    ? literalEntries.length
    : 0;
};

export default {
  id: "require-enum-over-literal-union",
  category: "types",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "string-literal-union",
  title: "a union of two or more string literals must be an enum",
  rationale:
    "a union of string literals is the weaker half of the construct the shipped as-const ban exists to close. it carries the type but no runtime value, so every comparison against it is a retyped magic string, the set of allowed values is invisible at the call site, and adding a member is a text edit nobody can search for. the enum the project mandates for the object form gives both the type and one place to name the value, and the two forms are used for the same decision: a string that selects a behaviour",
  replacement:
    "declare a string enum beside the config it belongs to and use its members as the discriminant, so the allowed values exist once as a value and once as a type. the union form is only correct where the value must survive a boundary that cannot execute an enum, which is why process entry modules are out of scope here",
  detect({ ts, sourceFile, relPath }) {
    if (relPath.endsWith(".d.ts")) return [];
    if (!isSuffixedModule(relPath)) return [];
    const hits = [];
    const report = (typeNode) => {
      if (stringLiteralEntryCount(ts, typeNode) === 0) return;
      const position = sourceFile.getLineAndCharacterOfPosition(
        typeNode.getStart(sourceFile),
      );
      hits.push({
        line: position.line + 1,
        column: position.character + 1,
        snippet: typeNode
          .getText(sourceFile)
          .replace(/\s+/g, " ")
          .slice(0, 120),
      });
    };
    const visit = (node) => {
      if (ts.isTypeAliasDeclaration(node)) report(node.type);
      if (ts.isPropertySignature(node)) report(node.type);
      if (ts.isParameter(node)) report(node.type);
      if (ts.isVariableDeclaration(node)) report(node.type);
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
